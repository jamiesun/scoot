//! Scoot CLI 入口：解析参数并分派到 REPL / 单次执行 / 守护 / config。
const std = @import("std");
const Io = std.Io;
const scoot = @import("scoot");

const usage =
    \\Scoot — 轻量级 AI Agent 守护进程 (Daemon / CLI)
    \\
    \\用法:
    \\  scoot [选项] [命令]
    \\
    \\命令:
    \\  repl                 进入交互式 REPL（默认；/exit 退出）
    \\  config               打印解析后的运行目录与后端配置
    \\  doctor               检查本地运行环境、配置、密钥来源与审计路径
    \\  policy check <action> <input> [--mode <mode>]
    \\                       解释某个工具动作在策略档下会被允许还是拒绝
    \\  skills               列出已发现的技能（name / 描述 / 目录）
    \\  skills check [dir]   校验本地 skill 目录；缺省扫描配置的 skill 搜索路径
    \\  schedule [list|run]  列出 / 运行调度任务（无人值守，强制只读安全档）
    \\
    \\选项:
    \\  -e, --eval <prompt>  单次执行一个目标后退出
    \\  --scoot-home <dir>   覆盖运行目录（优先于 SCOOT_HOME，便于测试隔离）
    \\  --trace              在 -e/--eval 模式下把执行轨迹打印到 stderr
    \\  --ticks <N>          schedule run 仅跑 N 轮后退出（默认 0=持续运行）
    \\  -h, --help           显示本帮助
    \\  -v, --version        显示版本号
    \\
    \\运行目录默认为 ~/.scoot（可用 --scoot-home 或环境变量 SCOOT_HOME 覆盖）。
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_writer.interface;
    defer err_out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);

    var eval_prompt: ?[]const u8 = null;
    var scoot_home_override: ?[]const u8 = null;
    var trace = false;
    var cmd_config = false;
    var cmd_doctor = false;
    var cmd_policy_check: ?PolicyCheckCommand = null;
    var cmd_skills: ?SkillsCommand = null;
    var cmd_schedule: ?[]const u8 = null; // null=未请求；否则为子动作 list/run
    var schedule_ticks: usize = 0; // 0=持续运行
    var i: usize = 1; // args[0] 是程序名。
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "-h") or eql(arg, "--help")) {
            try out.writeAll(usage);
            return;
        } else if (eql(arg, "-v") or eql(arg, "--version")) {
            try out.print("scoot {s}\n", .{scoot.version});
            return;
        } else if (eql(arg, "-e") or eql(arg, "--eval")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: -e/--eval 需要一个 prompt 参数\n");
                die(out, 2);
            }
            eval_prompt = args[i];
        } else if (eql(arg, "--scoot-home")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) {
                try out.writeAll("error: --scoot-home 需要一个目录参数\n");
                die(out, 2);
            }
            scoot_home_override = args[i];
        } else if (eql(arg, "--trace")) {
            trace = true;
        } else if (eql(arg, "--ticks")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: --ticks 需要一个整数参数\n");
                die(out, 2);
            }
            schedule_ticks = std.fmt.parseInt(usize, args[i], 10) catch {
                try out.print("error: --ticks 参数不是合法整数：'{s}'\n", .{args[i]});
                die(out, 2);
            };
        } else if (eql(arg, "config")) {
            cmd_config = true;
        } else if (eql(arg, "doctor")) {
            cmd_doctor = true;
        } else if (eql(arg, "policy")) {
            cmd_policy_check = parsePolicyCommand(out, args, &i);
        } else if (eql(arg, "skills")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                if (eql(args[i], "check")) {
                    var target: ?[]const u8 = null;
                    if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                        i += 1;
                        target = args[i];
                    }
                    cmd_skills = .{ .check = target };
                } else {
                    try out.print("error: 未知 skills 子命令 '{s}'（可用：check）\n", .{args[i]});
                    die(out, 2);
                }
            } else {
                cmd_skills = .list;
            }
        } else if (eql(arg, "schedule")) {
            // 可选子动作；缺省为 list（只读、无副作用）。下一 token 若是选项则不消费。
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                cmd_schedule = args[i];
            } else {
                cmd_schedule = "list";
            }
        } else if (eql(arg, "repl")) {
            // 默认即 REPL，显式接受该命令。
        } else {
            try out.print("error: 未知参数 '{s}'\n\n", .{arg});
            try out.writeAll(usage);
            die(out, 2);
        }
    }

    if (trace and eval_prompt == null) {
        try out.writeAll("error: --trace 目前仅支持 -e/--eval 单次执行模式\n");
        die(out, 2);
    }

    const dirs = if (scoot_home_override) |home|
        try scoot.paths.Paths.fromHome(arena, home)
    else
        scoot.paths.Paths.resolve(arena, env) catch |err| switch (err) {
            error.NoHomeDir => {
                try out.writeAll("error: 无法确定运行目录：请设置 --scoot-home、HOME 或 SCOOT_HOME\n");
                die(out, 1);
            },
            else => return err,
        };
    const cfg = scoot.config.Config.loadFromDirs(arena, io, dirs) catch |err| switch (err) {
        error.InvalidConfig => {
            try out.print(
                "error: 配置文件解析失败（TOML/JSON 语法或字段类型不符）。请检查 {s} 或 {s}\n",
                .{ dirs.config_toml_file, dirs.config_file },
            );
            die(out, 1);
        },
        else => {
            try out.print(
                "error: 读取配置失败（{s}）。涉及 {s} 或 {s}\n",
                .{ @errorName(err), dirs.config_toml_file, dirs.config_file },
            );
            die(out, 1);
        },
    };

    cfg.dirs.ensure(io) catch |err| {
        try out.print("error: 无法创建运行目录（{s}）：{s}\n", .{ @errorName(err), cfg.dirs.home });
        die(out, 1);
    };

    if (cmd_config) {
        try out.print("运行目录:   {s}\n", .{cfg.dirs.home});
        try out.print("  配置文件: {s}\n", .{cfg.active_config_file});
        try out.print("  token:    {s}\n", .{cfg.dirs.token_file});
        try out.print("  skills:   {s}\n", .{cfg.dirs.skills_dir});
        try out.print("  日志:     {s}\n", .{cfg.dirs.logs_dir});
        try out.print("后端:       {s} (model={s})\n", .{ cfg.backend.base_url, cfg.backend.model });
        if (cfg.backend.ca_file) |ca| try out.print("  CA:       {s}\n", .{ca});
        if (cfg.backend.extra_body) |eb| try out.print("  扩展参数: {f}\n", .{std.json.fmt(eb, .{})});
        try out.print("token 来源: env[{s}] > file > cmd（明文不入库）\n", .{cfg.backend.api_key_env});
        return;
    }

    if (cmd_doctor) {
        try runDoctor(out, arena, io, env, cfg);
        return;
    }

    if (cmd_policy_check) |pc| {
        try runPolicyCheck(out, arena, cfg, pc);
        return;
    }

    if (cmd_skills) |cmd| {
        switch (cmd) {
            .list => try printSkills(out, arena, io, cfg),
            .check => |target| try checkSkills(out, arena, io, cfg, target),
        }
        return;
    }

    if (cmd_schedule) |action| {
        if (eql(action, "list")) {
            try printSchedule(out, cfg);
            return;
        } else if (eql(action, "run")) {
            try runSchedule(out, arena, io, env, cfg, schedule_ticks);
            return;
        } else {
            try out.print("error: 未知 schedule 子命令 '{s}'（可用：list / run）\n", .{action});
            die(out, 2);
        }
    }

    if (eval_prompt) |prompt| {
        const token = try resolveToken(out, cfg, arena, io, env);
        var client = scoot.llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
        client.ca_file = cfg.backend.ca_file;
        client.extra_body = cfg.backend.extra_body;
        var sess = scoot.session.Session.init("cli");
        try sess.append(arena, .system, scoot.agent.system_prompt);
        injectSkills(out, arena, io, cfg, &sess);
        try sess.append(arena, .user, prompt);

        var ag = scoot.agent.Agent.initClient(&client);
        ag.max_turns = cfg.agent.max_turns;
        ag.tool_timeout_ms = cfg.tools.timeout_ms;
        ag.policy_mode = scoot.policy.Mode.fromString(cfg.tools.policy);
        ag.ca_file = cfg.backend.ca_file;
        if (trace) ag.trace = err_out;

        // 审计留痕（铁律：可审计胜过黑盒）。打不开则降级为「明示警告 + 不留痕」。
        var sink: AuditSink = .{};
        sink.open(out, arena, io, cfg.dirs.logs_dir);
        ag.audit = sink.loggerPtr();
        if (ag.audit) |lg| lg.log(.run, prompt) catch {}; // 运行边界标记（携带用户目标）

        const reply = ag.run(arena, &sess) catch |err| {
            if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
            finalizeRun(io, &sess, cfg.dirs.sessions_dir, &sink);
            try out.print("[scoot] 调用后端失败：{s}\n", .{@errorName(err)});
            try printBackendErrorDetail(out, &client);
            try out.print(
                "        后端 {s}（model={s}）。请确认 OpenAI 兼容服务在运行，必要时设置 {s}。\n",
                .{ cfg.backend.base_url, cfg.backend.model, cfg.backend.api_key_env },
            );
            die(out, 1);
        };
        finalizeRun(io, &sess, cfg.dirs.sessions_dir, &sink);
        try out.print("{s}\n", .{reply});
        return;
    }

    try runRepl(out, arena, io, env, cfg);
}

fn printBackendErrorDetail(out: *Io.Writer, client: *const scoot.llm.Client) !void {
    const body = client.lastErrorBody();
    if (client.last_error_status == 0 and body.len == 0) return;

    try out.print("        后端响应 status={d}", .{client.last_error_status});
    if (body.len == 0) {
        try out.writeAll("，无响应体。\n");
        return;
    }
    try out.print("，body（前 {d} 字节{s}）：\n{s}\n", .{
        body.len,
        if (client.last_error_body_truncated) "，已截断" else "",
        body,
    });
}

const PolicyCheckCommand = struct {
    action: []const u8,
    input: []const u8,
    mode: ?[]const u8 = null,
};

const SkillsCommand = union(enum) {
    list,
    check: ?[]const u8,
};

fn parsePolicyCommand(out: *Io.Writer, args: []const []const u8, i: *usize) PolicyCheckCommand {
    if (i.* + 1 >= args.len or !eql(args[i.* + 1], "check")) {
        out.writeAll("error: policy 仅支持子命令：check <action> <input> [--mode <mode>]\n") catch {};
        die(out, 2);
    }
    if (i.* + 3 >= args.len) {
        out.writeAll("error: policy check 需要 action 和 input 参数\n") catch {};
        die(out, 2);
    }

    var pc = PolicyCheckCommand{
        .action = args[i.* + 2],
        .input = args[i.* + 3],
    };
    var j = i.* + 4;
    while (j < args.len) : (j += 1) {
        if (eql(args[j], "--mode")) {
            j += 1;
            if (j >= args.len) {
                out.writeAll("error: --mode 需要 guarded/readonly/unrestricted 参数\n") catch {};
                die(out, 2);
            }
            pc.mode = args[j];
        } else {
            out.print("error: policy check 未知参数 '{s}'\n", .{args[j]}) catch {};
            die(out, 2);
        }
    }
    i.* = args.len - 1;
    return pc;
}

fn runPolicyCheck(out: *Io.Writer, arena: std.mem.Allocator, cfg: scoot.config.Config, pc: PolicyCheckCommand) !void {
    const mode_text = pc.mode orelse cfg.tools.policy;
    const mode = parsePolicyModeStrict(mode_text) orelse {
        try out.print("error: 未知策略档 '{s}'（可用：guarded / readonly / unrestricted）\n", .{mode_text});
        die(out, 2);
    };
    const action = std.meta.stringToEnum(scoot.agent.Action, pc.action) orelse {
        try out.print("error: 未知 action '{s}'\n", .{pc.action});
        die(out, 2);
    };
    const decision = policyDecisionForAction(arena, mode, action, pc.input);

    try out.print("mode={s}\n", .{@tagName(mode)});
    try out.print("action={s}\n", .{@tagName(action)});
    switch (decision) {
        .allow => try out.writeAll("decision=allow\n"),
        .deny => |reason| try out.print("decision=deny\nreason={s}\n", .{reason}),
    }
}

fn parsePolicyModeStrict(s: []const u8) ?scoot.policy.Mode {
    if (eql(s, "guarded")) return .guarded;
    if (eql(s, "readonly")) return .readonly;
    if (eql(s, "unrestricted") or eql(s, "yolo")) return .unrestricted;
    return null;
}

const PolicyHttpArgs = struct {
    url: []const u8,
    method: []const u8 = "GET",
    body: ?[]const u8 = null,
};
const PolicyFileReadArgs = struct { path: []const u8 };
const PolicyGrepArgs = struct { pattern: []const u8, path: []const u8 };
const PolicyGlobArgs = struct { pattern: []const u8, root: []const u8 = "." };

fn policyDecisionForAction(
    arena: std.mem.Allocator,
    mode: scoot.policy.Mode,
    action: scoot.agent.Action,
    input: []const u8,
) scoot.policy.Decision {
    return switch (action) {
        .bash => scoot.policy.evaluate(arena, input, mode),
        .file_read => policyDecisionForReadPath(PolicyFileReadArgs, arena, mode, input, "file_read", "path"),
        .grep => policyDecisionForReadPath(PolicyGrepArgs, arena, mode, input, "grep", "path"),
        .glob => policyDecisionForGlob(arena, mode, input),
        .file_write, .file_edit => scoot.policy.evaluateTool(.write, mode),
        .http_request => blk: {
            const args = std.json.parseFromSliceLeaky(PolicyHttpArgs, arena, input, .{
                .ignore_unknown_fields = true,
            }) catch break :blk scoot.policy.evaluateTool(.net_write, mode);
            const method = scoot.tools.http.methodFromString(args.method) orelse
                break :blk scoot.policy.evaluateTool(.net_write, mode);
            break :blk scoot.policy.evaluateTool(if (scoot.tools.http.isWrite(method)) .net_write else .net_read, mode);
        },
        .final => .{ .deny = "final 不是可执行工具动作" },
    };
}

fn policyDecisionForReadPath(
    comptime T: type,
    arena: std.mem.Allocator,
    mode: scoot.policy.Mode,
    input: []const u8,
    comptime action_name: []const u8,
    comptime field_name: []const u8,
) scoot.policy.Decision {
    const base = scoot.policy.evaluateTool(.read, mode);
    switch (base) {
        .deny => return base,
        .allow => {},
    }
    if (mode != .readonly) return .allow;
    const args = std.json.parseFromSliceLeaky(T, arena, input, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .deny = "只读模式无法解析 " ++ action_name ++ " 路径，已拒绝" };
    return scoot.policy.evaluateReadPath(@field(args, field_name), mode);
}

fn policyDecisionForGlob(arena: std.mem.Allocator, mode: scoot.policy.Mode, input: []const u8) scoot.policy.Decision {
    const base = scoot.policy.evaluateTool(.read, mode);
    switch (base) {
        .deny => return base,
        .allow => {},
    }
    if (mode != .readonly) return .allow;
    const args = std.json.parseFromSliceLeaky(PolicyGlobArgs, arena, input, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .deny = "只读模式无法解析 glob 参数，已拒绝" };
    const root_decision = scoot.policy.evaluateReadPath(args.root, mode);
    switch (root_decision) {
        .deny => return root_decision,
        .allow => {},
    }
    return scoot.policy.evaluateReadPath(args.pattern, mode);
}

const Doctor = struct {
    out: *Io.Writer,
    failures: usize = 0,
    warnings: usize = 0,

    fn ok(self: *Doctor, name: []const u8, detail: []const u8) !void {
        try self.out.print("OK\t{s}\t{s}\n", .{ name, detail });
    }

    fn info(self: *Doctor, name: []const u8, detail: []const u8) !void {
        try self.out.print("INFO\t{s}\t{s}\n", .{ name, detail });
    }

    fn warn(self: *Doctor, name: []const u8, detail: []const u8) !void {
        self.warnings += 1;
        try self.out.print("WARN\t{s}\t{s}\n", .{ name, detail });
    }

    fn fail(self: *Doctor, name: []const u8, detail: []const u8) !void {
        self.failures += 1;
        try self.out.print("FAIL\t{s}\t{s}\n", .{ name, detail });
    }
};

fn runDoctor(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
) !void {
    var d = Doctor{ .out = out };
    try out.writeAll("scoot doctor\n");

    try d.ok("runtime.home", cfg.dirs.home);
    try checkConfigFile(&d, io, cfg);
    try checkWritablePath(&d, arena, io, "runtime.logs", cfg.dirs.logs_dir);
    try checkWritablePath(&d, arena, io, "runtime.sessions", cfg.dirs.sessions_dir);
    try checkBackendConfig(&d, io, cfg);
    try checkPolicyConfig(&d, arena, cfg);
    try checkAgentConfig(&d, arena, cfg);
    try checkTokenSource(&d, arena, io, env, cfg);
    try checkSkillsConfig(&d, arena, io, cfg);
    try checkScheduleConfig(&d, cfg);

    try d.info("backend.reachability", "skipped; doctor 第一版不主动触网");
    try out.print("summary\tfailures={d}\twarnings={d}\n", .{ d.failures, d.warnings });
    if (d.failures != 0) die(out, 1);
}

fn checkConfigFile(d: *Doctor, io: std.Io, cfg: scoot.config.Config) !void {
    if (fileExists(io, cfg.active_config_file)) {
        try d.ok("config.file", cfg.active_config_file);
    } else {
        try d.warn("config.file", "未找到配置文件，当前使用内置默认值");
    }
}

fn checkWritablePath(
    d: *Doctor,
    arena: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    dir: []const u8,
) !void {
    const path = try std.fs.path.join(arena, &.{ dir, ".scoot-doctor-write-test" });
    const cwd = Io.Dir.cwd();
    var f = cwd.createFile(io, path, .{ .truncate = true }) catch |err| {
        try d.fail(name, try std.fmt.allocPrint(arena, "{s}: {s}", .{ dir, @errorName(err) }));
        return;
    };
    f.close(io);
    cwd.deleteFile(io, path) catch {};
    try d.ok(name, dir);
}

fn checkBackendConfig(d: *Doctor, io: std.Io, cfg: scoot.config.Config) !void {
    if (!startsWithHttp(cfg.backend.base_url)) {
        try d.fail("backend.base_url", "必须以 http:// 或 https:// 开头");
    } else {
        try d.ok("backend.base_url", cfg.backend.base_url);
    }
    if (cfg.backend.model.len == 0) {
        try d.fail("backend.model", "model 不能为空");
    } else {
        try d.ok("backend.model", cfg.backend.model);
    }
    if (cfg.backend.ca_file) |ca| {
        if (fileExists(io, ca)) {
            try d.ok("backend.ca_file", ca);
        } else {
            try d.fail("backend.ca_file", "配置了 CA 文件但路径不可读");
        }
    }
}

fn checkPolicyConfig(d: *Doctor, arena: std.mem.Allocator, cfg: scoot.config.Config) !void {
    if (parsePolicyModeStrict(cfg.tools.policy)) |mode| {
        try d.ok("tools.policy", @tagName(mode));
    } else {
        try d.fail("tools.policy", "未知策略档；可用 guarded / readonly / unrestricted");
    }
    if (cfg.tools.timeout_ms == 0) {
        try d.warn("tools.timeout_ms", "0 表示工具无硬超时，不建议用于 agent 运行");
    } else {
        try d.ok("tools.timeout_ms", try std.fmt.allocPrint(arena, "{d}ms", .{cfg.tools.timeout_ms}));
    }
}

fn checkAgentConfig(d: *Doctor, arena: std.mem.Allocator, cfg: scoot.config.Config) !void {
    if (cfg.agent.max_turns == 0) {
        try d.fail("agent.max_turns", "max_turns 必须大于 0");
    } else {
        try d.ok("agent.max_turns", try std.fmt.allocPrint(arena, "{d}", .{cfg.agent.max_turns}));
    }
}

fn checkTokenSource(
    d: *Doctor,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
) !void {
    const token = cfg.resolveToken(arena, io, env) catch |err| switch (err) {
        error.NoApiKey => {
            try d.warn("token", "未找到 token；本地无鉴权后端可忽略");
            return;
        },
        error.InsecurePermissions => {
            try d.fail("token", "token 文件权限过宽，已拒绝读取；请 chmod 600");
            return;
        },
        else => {
            try d.warn("token", @errorName(err));
            return;
        },
    };
    try d.ok("token", try std.fmt.allocPrint(arena, "source={s} value={s}", .{
        @tagName(token.source),
        scoot.secret.redact(token.value),
    }));
}

fn checkSkillsConfig(d: *Doctor, arena: std.mem.Allocator, io: std.Io, cfg: scoot.config.Config) !void {
    if (!cfg.skills.enabled) {
        try d.info("skills", "disabled");
        return;
    }
    const paths = cfg.skillPaths(arena) catch |err| {
        try d.fail("skills.paths", @errorName(err));
        return;
    };
    for (paths) |p| {
        if (dirExists(io, p)) {
            try d.ok("skills.path", p);
        } else {
            try d.warn("skills.path", try std.fmt.allocPrint(arena, "{s} 不存在", .{p}));
        }
    }
}

fn checkScheduleConfig(d: *Doctor, cfg: scoot.config.Config) !void {
    if (!cfg.schedule.enabled) {
        try d.info("schedule", "disabled");
        return;
    }
    var invalid: usize = 0;
    for (cfg.schedule.jobs) |job| {
        if (job.toJob() == null) invalid += 1;
    }
    if (invalid == 0) {
        try d.ok("schedule.jobs", "all valid");
    } else {
        try d.warn("schedule.jobs", "存在非法任务触发器，运行时会跳过");
    }
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn startsWithHttp(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const repl_banner =
    \\输入目标后回车，Scoot 会在「思考-行动-观察」循环里完成它。
    \\  /exit、/quit  退出（会话与审计已落盘）
    \\  /help         再次显示本帮助
    \\
;

/// 发现技能并把清单注入会话 system 上下文（渐进式披露：只注入 name+description+路径）。
/// 技能是增强项——发现失败或无技能时静默跳过，绝不阻断主流程或污染 `-e` 的可脚本输出。
/// Registry 借 `arena` 分配，随进程退出整体回收，无需单独 deinit。
fn injectSkills(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    sess: *scoot.session.Session,
) void {
    if (!cfg.skills.enabled) return;
    const paths = cfg.skillPaths(arena) catch return;
    var reg: scoot.skill.Registry = .{};
    reg.discoverAll(arena, io, paths) catch |err| {
        out.print("[scoot] 技能发现失败（{s}），已跳过技能装载。\n", .{@errorName(err)}) catch {};
        return;
    };
    if (reg.count() == 0) return;
    const text = reg.manifest(arena) catch return;
    sess.append(arena, .system, text) catch {};
}

/// `scoot skills`：列出各搜索路径下发现的技能，供用户确认技能是否被正确识别。
fn printSkills(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
) !void {
    const paths = try cfg.skillPaths(arena);
    try out.writeAll("技能搜索路径:\n");
    for (paths) |p| try out.print("  {s}\n", .{p});

    if (!cfg.skills.enabled) {
        try out.writeAll("\n技能机制已在配置中禁用（skills.enabled=false）。\n");
        return;
    }

    var reg: scoot.skill.Registry = .{};
    try reg.discoverAll(arena, io, paths);
    if (reg.count() == 0) {
        try out.writeAll("\n未发现任何技能。在某搜索路径下建 <技能名>/SKILL.md（含 front-matter）即可。\n");
        return;
    }
    try out.print("\n已发现 {d} 个技能:\n", .{reg.count()});
    for (reg.skills.items) |s| {
        try out.print("  - {s}：{s}\n    {s}\n", .{ s.name, s.description, s.dir });
    }
}

const SkillCheckSummary = struct {
    checked: usize = 0,
    failures: usize = 0,
    warnings: usize = 0,
};

/// `scoot skills check [dir]`：只读校验 skill 结构。它只解析 SKILL.md，不执行任何脚本。
fn checkSkills(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    target: ?[]const u8,
) !void {
    var summary: SkillCheckSummary = .{};
    try out.writeAll("技能校验:\n");

    if (target) |dir| {
        try checkOneSkill(out, arena, io, dir, &summary);
    } else {
        if (!cfg.skills.enabled) {
            summary.warnings += 1;
            try out.writeAll("INFO skills disabled by config (skills.enabled=false)\n");
        } else {
            const paths = try cfg.skillPaths(arena);
            for (paths) |root| {
                try scanSkillRoot(out, arena, io, root, &summary);
            }
            if (summary.checked == 0) {
                summary.warnings += 1;
                try out.writeAll("WARN no skill directories with SKILL.md were found in configured search paths\n");
            }
        }
    }

    try out.print("summary checked={d} failures={d} warnings={d}\n", .{
        summary.checked,
        summary.failures,
        summary.warnings,
    });
    if (summary.failures > 0) die(out, 1);
}

fn scanSkillRoot(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    summary: *SkillCheckSummary,
) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            summary.warnings += 1;
            try out.print("WARN {s}: search path not found\n", .{root});
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const candidate = try std.fs.path.join(arena, &.{ root, entry.name });
        const md_path = try std.fs.path.join(arena, &.{ candidate, "SKILL.md" });
        if (!fileExists(io, md_path)) continue;
        try checkOneSkill(out, arena, io, candidate, summary);
    }
}

fn checkOneSkill(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    summary: *SkillCheckSummary,
) !void {
    summary.checked += 1;
    const res = try scoot.skill.validateDir(arena, io, dir);
    switch (res) {
        .valid => |meta| try out.print("OK {s} name={s} description={s}\n", .{
            dir,
            meta.name,
            meta.description,
        }),
        .invalid => |msg| {
            summary.failures += 1;
            try out.print("FAIL {s}: {s}\n", .{ dir, msg });
        },
    }
}

/// 把触发器渲染为人类可读描述（供 `schedule list`）。
fn triggerLabel(buf: []u8, trig: scoot.schedule.Trigger) []const u8 {
    return switch (trig) {
        .every_sec => |s| std.fmt.bufPrint(buf, "每 {d}s", .{s}) catch "every",
        .at_unix => |t| std.fmt.bufPrint(buf, "@{d}", .{t}) catch "at",
        .cron => |c| std.fmt.bufPrint(buf, "cron '{s}'（暂不支持）", .{c}) catch "cron",
    };
}

/// `scoot schedule list`：展示调度开关、轮询间隔与各任务（含**有效执行档**与非法标记）。
/// 只读、无副作用——让用户在真正 `run` 前先核对安全档与触发器是否如预期。
fn printSchedule(out: *Io.Writer, cfg: scoot.config.Config) !void {
    const sc = cfg.schedule;
    try out.print("调度: {s}（poll={d}ms，jobs={d}）\n", .{
        if (sc.enabled) "已启用" else "已禁用（schedule.enabled=false）",
        sc.poll_ms,
        sc.jobs.len,
    });
    if (sc.jobs.len == 0) {
        try out.writeAll("  （无任务。在配置文件的 schedule.jobs 配置）\n");
        return;
    }
    var tbuf: [128]u8 = undefined;
    for (sc.jobs) |jc| {
        if (jc.toJob()) |job| {
            const eff = job.effectiveMode();
            const coerced = if (eff != job.mode) "（强制矫正）" else "";
            try out.print("  - {s}  [{s}]  执行档={s}{s}  goal={s}\n", .{
                jc.id, triggerLabel(&tbuf, job.trigger), @tagName(eff), coerced, job.goal,
            });
        } else {
            try out.print("  - {s}  ⚠ 触发器非法（须恰好设置 every_sec/at_unix/cron 之一），运行时将跳过\n", .{jc.id});
        }
    }
    if (!sc.enabled) {
        try out.writeAll("\n提示：`scoot schedule run` 需先在配置文件设 schedule.enabled=true。\n");
    }
}

/// 单任务运行上下文：携带跑一个 job 所需的一切 + 一个**可重置 arena**。
/// 调度器只判到点，真正执行经 `runJob` 回调注入（解耦 agent 依赖）。
const RunCtx = struct {
    out: *Io.Writer,
    io: std.Io,
    cfg: scoot.config.Config,
    client: *scoot.llm.Client,
    /// 每个 job 用它分配 scratch，跑完 `reset(.retain_capacity)`——长效守护零泄漏。
    job_arena: *std.heap.ArenaAllocator,

    /// schedule.Scheduler.RunFn 回调：到点时执行单个 job。**绝不抛错**（返回 void），
    /// 单任务失败只记审计 + 打印并继续，不拖垮守护循环。
    fn runJob(ctx: *anyopaque, job: *scoot.schedule.Job) void {
        const self: *RunCtx = @ptrCast(@alignCast(ctx));
        const a = self.job_arena.allocator();
        defer _ = self.job_arena.reset(.retain_capacity); // 本轮 scratch 回收，内存平稳

        // 铁律 #1：无人值守执行强制安全档——guarded 绊线对无人值守无意义，矫正为 readonly。
        const eff = job.effectiveMode();

        const sid = std.fmt.allocPrint(a, "job-{s}", .{job.id}) catch return;
        var sess = scoot.session.Session.init(sid);
        sess.append(a, .system, scoot.agent.system_prompt) catch {};
        injectSkills(self.out, a, self.io, self.cfg, &sess);
        sess.append(a, .user, job.goal) catch {};

        var ag = scoot.agent.Agent.initClient(self.client);
        ag.max_turns = self.cfg.agent.max_turns;
        ag.tool_timeout_ms = self.cfg.tools.timeout_ms;
        ag.policy_mode = eff; // 强制有效安全档（结构上不可能跑在 guarded 之上）
        ag.ca_file = self.cfg.backend.ca_file;

        var sink: AuditSink = .{};
        sink.open(self.out, a, self.io, self.cfg.dirs.logs_dir);
        ag.audit = sink.loggerPtr();
        if (ag.audit) |lg| {
            const marker = std.fmt.allocPrint(a, "schedule job={s} mode={s} goal={s}", .{
                job.id, @tagName(eff), job.goal,
            }) catch job.goal;
            lg.log(.run, marker) catch {};
        }

        self.out.print("[scoot] ▶ 任务 {s}（{s}）：{s}\n", .{ job.id, @tagName(eff), job.goal }) catch {};
        const reply = ag.run(a, &sess) catch |err| {
            if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
            finalizeRun(self.io, &sess, self.cfg.dirs.sessions_dir, &sink);
            self.out.print("[scoot] ✗ 任务 {s} 失败：{s}（继续下一个）\n", .{ job.id, @errorName(err) }) catch {};
            self.out.flush() catch {};
            return;
        };
        finalizeRun(self.io, &sess, self.cfg.dirs.sessions_dir, &sink);
        self.out.print("[scoot] ✓ 任务 {s}：{s}\n", .{ job.id, reply }) catch {};
        self.out.flush() catch {}; // 长效运行下让进度即时可见
    }
};

/// `scoot schedule run [--ticks N]`：装载合法任务，进入守护循环到点唤起 Agent。
/// 必须显式开启 `schedule.enabled`（无人值守自主执行是高风险，默认拒绝）。
/// `client`/`token` 在守护生命周期内只构建一次；每个 job 的 scratch 走可重置 arena。
fn runSchedule(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    ticks: usize,
) !void {
    const sc = cfg.schedule;
    if (!sc.enabled) {
        try out.writeAll("[scoot] 调度未启用：请在配置文件设 schedule.enabled=true 后再运行。\n");
        die(out, 1);
    }

    var sch: scoot.schedule.Scheduler = .{};
    var valid: usize = 0;
    for (sc.jobs) |jc| {
        const job = jc.toJob() orelse {
            try out.print("[scoot] 跳过非法任务 '{s}'（触发器须恰好设置其一）。\n", .{jc.id});
            continue;
        };
        try sch.add(arena, job); // job 内容借 cfg/arena 生命周期（>= scheduler）
        valid += 1;
    }
    if (valid == 0) {
        try out.writeAll("[scoot] 无可运行任务，退出。\n");
        return;
    }

    const token = try resolveToken(out, cfg, arena, io, env);
    var client = scoot.llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
    client.ca_file = cfg.backend.ca_file;
    client.extra_body = cfg.backend.extra_body;

    var job_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer job_arena.deinit();

    var rctx = RunCtx{
        .out = out,
        .io = io,
        .cfg = cfg,
        .client = &client,
        .job_arena = &job_arena,
    };

    try out.print("[scoot] 调度启动：{d} 个任务，poll={d}ms，{s}（后端 {s}，model={s}）。\n", .{
        valid,
        sc.poll_ms,
        if (ticks == 0) "持续运行（Ctrl-C 退出）" else "有界运行",
        cfg.backend.base_url,
        cfg.backend.model,
    });
    try out.flush();

    const fired = sch.runForever(io, sc.poll_ms, ticks, &rctx, RunCtx.runJob);
    try out.print("[scoot] 调度结束：累计触发 {d} 次。\n", .{fired});
}

/// 解析 API token（env > file > cmd）。本地无鉴权后端可留空。
/// 修复静默吞咽：当用户**显式**配置了 file/cmd 来源却尚未实现时，明示告警，
/// 不再把 NotImplemented 装作「无鉴权」悄悄吞掉。
fn resolveToken(
    out: *Io.Writer,
    cfg: scoot.config.Config,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    const explicit_source = cfg.backend.api_key_file != null or cfg.backend.api_key_cmd != null;
    const s = cfg.resolveToken(arena, io, env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // token 文件存在但权限过宽：明示告警（指导 chmod 600），降级为空 token 续跑。
        // 绝不读取世界可读的密钥（密钥零泄漏铁律）；本地无须密钥的后端不受影响。
        error.InsecurePermissions => {
            try out.print(
                "[scoot] 警告：token 文件权限过宽（group/other 可读），已拒绝读取。\n" ++
                    "        请执行 `chmod 600 {s}` 收紧后重试。\n",
                .{cfg.backend.api_key_file orelse cfg.dirs.token_file},
            );
            return "";
        },
        // 所有来源均落空：本地 Ollama 等无须密钥，静默以空 token 续跑；
        // 仅当用户**显式**配置了 file/cmd 来源却仍落空时才提示（配置未生效是值得知道的）。
        error.NoApiKey => {
            if (explicit_source) {
                try out.print(
                    "[scoot] 警告：已配置 token 文件/命令来源，但均未取得有效 token，将以空 token 继续。\n" ++
                        "        请检查文件是否存在且非空，或凭证命令是否成功输出。\n",
                    .{},
                );
            }
            return "";
        },
        else => return err,
    };
    return s.value;
}

/// 交互式 REPL：在单一会话里跨多轮复用 ReACT 闭环。人在场监督，
/// 单次后端失败只提示并继续，不终止整段会话。退出时落盘会话与审计。
fn runRepl(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
) !void {
    const token = try resolveToken(out, cfg, arena, io, env);
    var client = scoot.llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
    client.ca_file = cfg.backend.ca_file;
    client.extra_body = cfg.backend.extra_body;

    var sess = scoot.session.Session.init("repl");
    try sess.append(arena, .system, scoot.agent.system_prompt);
    injectSkills(out, arena, io, cfg, &sess);

    var ag = scoot.agent.Agent.initClient(&client);
    ag.max_turns = cfg.agent.max_turns;
    ag.tool_timeout_ms = cfg.tools.timeout_ms;
    ag.policy_mode = scoot.policy.Mode.fromString(cfg.tools.policy);
    ag.ca_file = cfg.backend.ca_file;

    var sink: AuditSink = .{};
    sink.open(out, arena, io, cfg.dirs.logs_dir);
    ag.audit = sink.loggerPtr();

    try out.print("scoot {s} — 交互式 REPL（后端 {s}，model={s}，策略 {s}）\n", .{
        scoot.version, cfg.backend.base_url, cfg.backend.model, cfg.tools.policy,
    });
    try out.writeAll(repl_banner);

    var in_buf: [1 << 16]u8 = undefined;
    var ir: Io.File.Reader = .init(.stdin(), io, &in_buf);

    replLoop(out, &ir.interface, &ag, &sess, arena) catch {};

    finalizeRun(io, &sess, cfg.dirs.sessions_dir, &sink);
    try out.writeAll("再见。\n");
}

/// REPL 主循环（与 IO 来源、后端解耦，便于注入测试）。`backing` 承载跨轮会话历史。
/// 注：会话历史与每轮 scratch 都累积在 `backing` 上；REPL 由用户驱动、有界，可接受。
/// 无人值守的 daemon/schedule（切片九）须改用可回收分配器以保证长效内存平稳。
fn replLoop(
    out: *Io.Writer,
    in: *Io.Reader,
    ag: *scoot.agent.Agent,
    sess: *scoot.session.Session,
    backing: std.mem.Allocator,
) !void {
    while (true) {
        try out.writeAll("\n› ");
        out.flush() catch {}; // 让提示符先于阻塞读出现；失败仅影响显示
        const raw = (readLine(in) catch break) orelse break;
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        if (eql(line, "/exit") or eql(line, "/quit")) break;
        if (eql(line, "/help")) {
            try out.writeAll(repl_banner);
            continue;
        }

        try sess.append(backing, .user, line); // append 内部复制，line 随后失效无碍
        if (ag.audit) |lg| lg.log(.run, line) catch {};

        const reply = ag.run(backing, sess) catch |err| {
            if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
            try out.print("[scoot] 后端调用失败：{s}（请检查后端是否在运行）\n", .{@errorName(err)});
            continue; // REPL 不因单次失败退出
        };
        defer backing.free(reply); // arena 下为空操作；真实分配器下避免泄漏
        try out.print("{s}\n", .{reply});
    }
}

/// 从 reader 读一行（去掉行尾 \r\n）。EOF 且无残留行时返回 null。
fn readLine(in: *Io.Reader) !?[]const u8 {
    const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => {
            const rest = in.take(in.bufferedLen()) catch return null;
            if (rest.len == 0) return null;
            return rest; // 末行无换行符的残留
        },
        else => return err,
    };
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// 审计落盘句柄：打开 logs/audit.jsonl（追加），自持缓冲与 writer，便于跨多轮复用。
const AuditSink = struct {
    file: ?Io.File = null,
    fw: Io.File.Writer = undefined,
    logger: scoot.audit.Logger = undefined,
    buf: [4096]u8 = undefined,

    /// 打开审计日志（追加到末尾）。打不开则降级为「明示警告 + 不留痕」——
    /// 既不静默退回黑盒，也不因日志故障阻断任务（铁律：可审计胜过黑盒）。
    fn open(self: *AuditSink, out: *Io.Writer, arena: std.mem.Allocator, io: std.Io, logs_dir: []const u8) void {
        const path = std.fmt.allocPrint(arena, "{s}/audit.jsonl", .{logs_dir}) catch return;
        const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch |err| {
            out.print("[scoot] 警告：审计日志无法写入（{s}：{s}），本次不留痕\n", .{ path, @errorName(err) }) catch {};
            return;
        };
        self.file = f;
        self.fw = f.writer(io, &self.buf);
        if (f.stat(io)) |st| {
            self.fw.seekTo(st.size) catch {}; // 追加到末尾，不覆盖历史
        } else |_| {}
        self.logger = scoot.audit.Logger.init(&self.fw.interface);
    }

    /// 可注入 agent 的 logger 指针；未成功打开时为 null（agent 静默跳过留痕）。
    fn loggerPtr(self: *AuditSink) ?*scoot.audit.Logger {
        return if (self.file != null) &self.logger else null;
    }

    fn close(self: *AuditSink, io: std.Io) void {
        if (self.file) |f| {
            self.fw.interface.flush() catch {};
            f.close(io);
        }
    }
};

/// 收尾一次运行：flush + 关闭审计，并把会话快照追加落盘。全部尽力而为。
fn finalizeRun(io: std.Io, sess: *scoot.session.Session, sessions_dir: []const u8, sink: *AuditSink) void {
    sink.close(io);
    sess.persist(io, sessions_dir) catch {};
}

/// 打印完信息后干净退出（刷新 stdout，不抛错误回溯）：用于面向用户的可预期失败。
fn die(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

const TestBrain = struct {
    steps: []const []const u8,
    idx: usize = 0,
};

fn testBrainComplete(
    ctx: *anyopaque,
    a: std.mem.Allocator,
    msgs: []const scoot.llm.Message,
    opts: scoot.llm.ChatOptions,
) anyerror!scoot.llm.Completion {
    _ = msgs;
    _ = opts;
    const self: *TestBrain = @ptrCast(@alignCast(ctx));
    if (self.idx >= self.steps.len) return error.ScriptExhausted;
    const c = self.steps[self.idx];
    self.idx += 1;
    return .{ .content = try a.dupe(u8, c), .finish_reason = "stop" };
}

test "replLoop: 多轮、空行跳过、/exit 退出、单次后端失败不终止会话" {
    const gpa = std.testing.allocator;
    // 仅脚本化一步 final；第二轮真实输入时脚本耗尽 → ag.run 报错（模拟后端失败）。
    var brain = TestBrain{ .steps = &.{
        "{\"thought\":\"答\",\"action\":\"final\",\"action_input\":\"你好\"}",
    } };
    var ag = scoot.agent.Agent{
        .io = std.testing.io,
        .complete_ctx = &brain,
        .complete_fn = testBrainComplete,
        .max_turns = 4,
    };

    var sess = scoot.session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, scoot.agent.system_prompt);

    // 输入：有效→空行→纯空白→第二个有效（触发失败）→/exit→/exit 之后的行不应被读。
    var in = Io.Reader.fixed("hi\n\n   \nsecond\n/exit\n绝不应读到\n");
    var obuf: [4096]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);

    try replLoop(&ow, &in, &ag, &sess, gpa);

    const o = ow.buffered();
    try std.testing.expect(std.mem.indexOf(u8, o, "你好") != null); // 第一轮成功回复
    try std.testing.expect(std.mem.indexOf(u8, o, "后端调用失败") != null); // 第二轮失败但未终止
    try std.testing.expect(std.mem.indexOf(u8, o, "绝不应读到") == null); // /exit 后立即停读
    // 两条 user 输入应入会话历史（system + hi + second = 至少 3 条 user/assistant 混合）。
    var user_msgs: usize = 0;
    for (sess.items()) |m| {
        if (m.role == .user) user_msgs += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), user_msgs); // "hi" 与 "second"
}

test "readLine: 含换行/无尾换行/空输入" {
    var in1 = Io.Reader.fixed("a\nbb\n");
    try std.testing.expectEqualStrings("a", (try readLine(&in1)).?);
    try std.testing.expectEqualStrings("bb", (try readLine(&in1)).?);
    try std.testing.expect((try readLine(&in1)) == null);

    var in2 = Io.Reader.fixed("tail-no-nl");
    try std.testing.expectEqualStrings("tail-no-nl", (try readLine(&in2)).?);
    try std.testing.expect((try readLine(&in2)) == null);

    var in3 = Io.Reader.fixed("");
    try std.testing.expect((try readLine(&in3)) == null);
}

test "policyDecisionForAction: 复用工具策略语义" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (policyDecisionForAction(arena, .guarded, .bash, "rm -rf /")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (policyDecisionForAction(arena, .readonly, .file_read, "{\"path\":\"README.md\"}")) {
        .allow => {},
        .deny => return error.ExpectedAllow,
    }
    switch (policyDecisionForAction(arena, .readonly, .file_read, "{\"path\":\"/etc/passwd\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (policyDecisionForAction(arena, .readonly, .glob, "{\"pattern\":\"**/*.zig\",\"root\":\".\"}")) {
        .allow => {},
        .deny => return error.ExpectedAllow,
    }
    switch (policyDecisionForAction(arena, .readonly, .glob, "{\"pattern\":\"**/*\",\"root\":\"..\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (policyDecisionForAction(arena, .readonly, .file_write, "{\"path\":\"x\",\"content\":\"y\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (policyDecisionForAction(arena, .readonly, .bash, "cat README.md")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (policyDecisionForAction(arena, .readonly, .http_request, "{\"method\":\"GET\",\"url\":\"https://example.com\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (policyDecisionForAction(arena, .readonly, .http_request, "{\"method\":\"POST\",\"url\":\"https://example.com\"}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
}

test "parsePolicyModeStrict: 未知策略不静默回落" {
    try std.testing.expectEqual(scoot.policy.Mode.guarded, parsePolicyModeStrict("guarded").?);
    try std.testing.expectEqual(scoot.policy.Mode.readonly, parsePolicyModeStrict("readonly").?);
    try std.testing.expectEqual(scoot.policy.Mode.unrestricted, parsePolicyModeStrict("unrestricted").?);
    try std.testing.expect(parsePolicyModeStrict("surprise") == null);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(scoot);
}
