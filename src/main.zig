//! Scoot CLI 入口：解析参数并分派到 REPL / 单次执行 / 守护 / config。
const std = @import("std");
const Io = std.Io;
const scoot = @import("scoot");

var daemon_stop_requested = std.atomic.Value(bool).init(false);

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
    \\  skills pack <dir> [out.tar]
    \\                       校验并导出 skill tar 包，包内带 .scoot-skill.json 审查清单
    \\  wasm-tools check <dir>
    \\                       校验本地 Wasm 工具包边界（manifest / policy / schema；不执行 Wasm）
    \\  schedule [list|run]  列出 / 运行调度任务（无人值守，强制只读安全档）
    \\  daemon [run|status|stop]
    \\                       前台守护调度任务，记录 pid/state，并支持 SIGTERM 停止
    \\
    \\选项:
    \\  -e, --eval <prompt>  单次执行一个目标后退出
    \\  --retries <N>        -e 模式下后端临时错误重试次数（默认 2，0=不重试）
    \\  --scoot-home <dir>   覆盖运行目录（优先于 SCOOT_HOME，便于测试隔离）
    \\  --trace              把执行轨迹打印到 stderr（-e/--eval 与 REPL 交互模式均支持）
    \\  --ticks <N>          schedule run / daemon run 仅跑 N 轮后退出（默认 0=持续运行）
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
    var eval_retries: u32 = default_eval_retries;
    var eval_retries_set = false;
    var scoot_home_override: ?[]const u8 = null;
    var trace = false;
    var cmd_config = false;
    var cmd_doctor = false;
    var cmd_policy_check: ?PolicyCheckCommand = null;
    var cmd_skills: ?SkillsCommand = null;
    var cmd_wasm_tools: ?WasmToolsCommand = null;
    var cmd_schedule: ?[]const u8 = null; // null=未请求；否则为子动作 list/run
    var cmd_daemon: ?[]const u8 = null; // null=未请求；否则为子动作 run/status/stop
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
        } else if (eql(arg, "--retries")) {
            i += 1;
            if (i >= args.len) {
                try out.writeAll("error: --retries 需要一个整数参数\n");
                die(out, 2);
            }
            eval_retries = std.fmt.parseInt(u32, args[i], 10) catch {
                try out.print("error: --retries 参数不是合法整数：'{s}'\n", .{args[i]});
                die(out, 2);
            };
            eval_retries_set = true;
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
                } else if (eql(args[i], "pack")) {
                    if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "-")) {
                        try out.writeAll("error: skills pack 需要 skill 目录参数\n");
                        die(out, 2);
                    }
                    i += 1;
                    const dir = args[i];
                    var output: ?[]const u8 = null;
                    if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                        i += 1;
                        output = args[i];
                    }
                    cmd_skills = .{ .pack = .{ .dir = dir, .output = output } };
                } else {
                    try out.print("error: 未知 skills 子命令 '{s}'（可用：check / pack）\n", .{args[i]});
                    die(out, 2);
                }
            } else {
                cmd_skills = .list;
            }
        } else if (eql(arg, "wasm-tools")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "-")) {
                try out.writeAll("error: wasm-tools 仅支持子命令：check <dir>\n");
                die(out, 2);
            }
            i += 1;
            if (eql(args[i], "check")) {
                if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "-")) {
                    try out.writeAll("error: wasm-tools check 需要工具包目录参数\n");
                    die(out, 2);
                }
                i += 1;
                cmd_wasm_tools = .{ .check = args[i] };
            } else {
                try out.print("error: 未知 wasm-tools 子命令 '{s}'（可用：check）\n", .{args[i]});
                die(out, 2);
            }
        } else if (eql(arg, "schedule")) {
            // 可选子动作；缺省为 list（只读、无副作用）。下一 token 若是选项则不消费。
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                cmd_schedule = args[i];
            } else {
                cmd_schedule = "list";
            }
        } else if (eql(arg, "daemon")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                cmd_daemon = args[i];
            } else {
                cmd_daemon = "status";
            }
        } else if (eql(arg, "repl")) {
            // 默认即 REPL，显式接受该命令。
        } else {
            try out.print("error: 未知参数 '{s}'\n\n", .{arg});
            try out.writeAll(usage);
            die(out, 2);
        }
    }

    // --trace 仅对会跑 ReACT 闭环的入口（-e/--eval 与默认 REPL）有意义；
    // config/doctor/policy/skills/wasm-tools/schedule/daemon 这些非 agent 子命令下拒绝，避免静默无效。
    const non_agent_cmd = cmd_config or cmd_doctor or
        (cmd_policy_check != null) or (cmd_skills != null) or
        (cmd_wasm_tools != null) or (cmd_schedule != null) or (cmd_daemon != null);
    if (trace and non_agent_cmd) {
        try out.writeAll("error: --trace 仅用于 -e/--eval 或 REPL 交互模式\n");
        die(out, 2);
    }
    if (eval_retries_set and eval_prompt == null) {
        try out.writeAll("error: --retries 目前仅支持 -e/--eval 单次执行模式\n");
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
    var load_report: scoot.config.LoadReport = .{};
    var cfg = scoot.config.Config.loadFromDirs(arena, io, dirs, &load_report) catch |err| switch (err) {
        error.InvalidConfig => {
            if (load_report.toml_diag) |d| {
                try out.print(
                    "error: 配置文件解析失败：{s}:{d}:{d}（第 {d} 字节附近的 TOML 语法错误）。\n",
                    .{ dirs.config_toml_file, d.line, d.col, d.byte },
                );
            } else {
                try out.print(
                    "error: 配置文件解析失败（TOML/JSON 语法或字段类型不符）。请检查 {s} 或 {s}\n",
                    .{ dirs.config_toml_file, dirs.config_file },
                );
            }
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
    // 未识别的配置键（拼写错误）会被静默回落默认，可能悄悄降低安全性（如把 policy 误写成 polcy 而落回 guarded）；
    // 加载成功后统一告警到 stderr，避免污染 stdout（含 -e 可脚本输出，issue #45/#23）。
    if (load_report.unknown_keys.len > 0) {
        for (load_report.unknown_keys) |k|
            err_out.print("warning: 配置含未识别的键 `{s}`，已忽略并回落默认值（请检查拼写）。\n", .{k}) catch {};
        err_out.flush() catch {};
    }

    // SCOOT_* 环境变量覆盖（优先级 env > 配置文件 > 默认）：支持 CI / 零配置临时运行。
    // 密钥不在此读明文，仍走 backend.api_key_env 指向的变量（默认 OPENAI_API_KEY）。
    cfg.applyEnvOverrides(arena, env, &load_report) catch |err| {
        try out.print("error: 应用环境变量配置覆盖失败（{s}）\n", .{@errorName(err)});
        die(out, 1);
    };
    if (load_report.env_warnings.len > 0) {
        for (load_report.env_warnings) |w|
            err_out.print("warning: 环境变量配置覆盖被忽略——{s}\n", .{w}) catch {};
        err_out.flush() catch {};
    }

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
            .pack => |sp| try packSkillCommand(out, arena, io, sp),
        }
        return;
    }

    if (cmd_wasm_tools) |cmd| {
        switch (cmd) {
            .check => |dir| try checkWasmToolPackage(out, arena, io, dir),
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

    if (cmd_daemon) |action| {
        if (eql(action, "run")) {
            try runDaemon(out, arena, io, env, cfg, schedule_ticks);
            return;
        } else if (eql(action, "status")) {
            try printDaemonStatus(out, arena, io, cfg);
            return;
        } else if (eql(action, "stop")) {
            try stopDaemon(out, arena, io, cfg);
            return;
        } else {
            try out.print("error: 未知 daemon 子命令 '{s}'（可用：run / status / stop）\n", .{action});
            die(out, 2);
        }
    }

    if (eval_prompt) |prompt| {
        // `-e` 单次：stdout 仅承载最终答案（可脚本/管道），故所有降级告警与错误改走 stderr（issue #23）。
        var client = try initBackendClient(err_out, cfg, arena, io, env);

        // 审计留痕（铁律：可审计胜过黑盒）。打不开则降级为「明示警告（→stderr）+ 不留痕」。
        var sink: AuditSink = .{};
        const setup = try setupRun(&client, &sink, err_out, arena, io, cfg, "cli", scoot.policy.Mode.fromString(cfg.tools.policy));
        var sess = setup.sess;
        var ag = setup.agent;
        try sess.append(arena, .user, prompt);
        if (trace) ag.trace = err_out;
        if (ag.audit) |lg| lg.log(.run, prompt) catch {}; // 运行边界标记（携带用户目标）

        var retries_done: u32 = 0;
        while (true) {
            const reply = ag.run(arena, &sess) catch |err| {
                if (shouldRetryEvalError(err, &client, retries_done, eval_retries)) {
                    retries_done += 1;
                    const delay_ns = evalRetryDelayNs(retries_done);
                    if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
                    try err_out.print(
                        "[scoot] 后端临时失败：{s}，第 {d}/{d} 次重试，{d}ms 后继续。\n",
                        .{ @errorName(err), retries_done, eval_retries, delay_ns / std.time.ns_per_ms },
                    );
                    try printBackendErrorDetail(err_out, &client);
                    try err_out.flush();
                    io.sleep(std.Io.Duration.fromNanoseconds(@intCast(delay_ns)), .awake) catch {};
                    continue;
                }

                if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
                finalizeRun(io, &sess, cfg.dirs.sessions_dir, &sink);
                try err_out.print("[scoot] 调用后端失败：{s}\n", .{@errorName(err)});
                try printBackendErrorDetail(err_out, &client);
                try err_out.print(
                    "        后端 {s}（model={s}）。请确认 OpenAI 兼容服务在运行，必要时设置 {s}。\n",
                    .{ cfg.backend.base_url, cfg.backend.model, cfg.backend.api_key_env },
                );
                try err_out.flush();
                die(out, 1);
            };
            finalizeRun(io, &sess, cfg.dirs.sessions_dir, &sink);
            try out.print("{s}\n", .{reply});
            return;
        }
    }

    try runRepl(out, err_out, arena, io, env, cfg, trace);
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

const default_eval_retries: u32 = 2;
const eval_retry_base_delay_ns: u64 = 2 * std.time.ns_per_s;
const eval_retry_max_delay_ns: u64 = 10 * std.time.ns_per_s;

fn shouldRetryEvalError(
    err: anyerror,
    client: *const scoot.llm.Client,
    retries_done: u32,
    max_retries: u32,
) bool {
    if (retries_done >= max_retries) return false;

    if (err == error.BackendError) {
        const status = client.last_error_status;
        return status == 0 or isRetryableBackendStatus(status);
    }

    return isRetryableTransportError(err);
}

fn isRetryableBackendStatus(status: u16) bool {
    return status == 408 or status == 409 or status == 425 or status == 429 or
        status == 500 or status == 502 or status == 503 or status == 504;
}

fn isRetryableTransportError(err: anyerror) bool {
    const name = @errorName(err);
    const retryable = [_][]const u8{
        "ConnectionRefused",
        "ConnectionResetByPeer",
        "ConnectionTimedOut",
        "HttpConnectionClosing",
        "NetworkUnreachable",
        "TemporaryNameServerFailure",
        "TlsInitializationFailed",
    };
    for (retryable) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn evalRetryDelayNs(retry_index: u32) u64 {
    const zero_based = if (retry_index == 0) 0 else retry_index - 1;
    const shift: u6 = @intCast(@min(zero_based, 4));
    const delay = eval_retry_base_delay_ns << shift;
    return @min(delay, eval_retry_max_delay_ns);
}

const PolicyCheckCommand = struct {
    action: []const u8,
    input: []const u8,
    mode: ?[]const u8 = null,
};

const SkillsCommand = union(enum) {
    list,
    check: ?[]const u8,
    pack: SkillPackCommand,
};

const SkillPackCommand = struct {
    dir: []const u8,
    output: ?[]const u8 = null,
};

const WasmToolsCommand = union(enum) {
    check: []const u8,
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
const PolicyParallelCallArgs = struct {
    action: []const u8,
    input: []const u8 = "",
    action_input: []const u8 = "",
};
const PolicyParallelArgs = struct { calls: []const PolicyParallelCallArgs };

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
        .parallel => policyDecisionForParallel(arena, mode, input),
        .skill => .allow, // 原生只读能力，刻意不受执行策略约束（与 agent.guard 对齐）。
        .final => .{ .deny = "final 不是可执行工具动作" },
    };
}

fn policyDecisionForParallel(
    arena: std.mem.Allocator,
    mode: scoot.policy.Mode,
    input: []const u8,
) scoot.policy.Decision {
    const args = std.json.parseFromSliceLeaky(PolicyParallelArgs, arena, input, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .deny = "parallel 的 action_input 必须是 {\"calls\":[...]} JSON" };
    if (args.calls.len == 0) return .{ .deny = "parallel 至少需要 1 个调用" };
    if (args.calls.len > 4) return .{ .deny = "parallel 超过最大并发调用数 4" };
    for (args.calls, 0..) |call, idx| {
        const child = std.meta.stringToEnum(scoot.agent.Action, call.action) orelse
            return .{ .deny = "parallel 包含未知 action" };
        const child_input = if (call.input.len != 0) call.input else call.action_input;
        if (child_input.len == 0) return .{ .deny = "parallel 子调用缺少 input" };
        switch (child) {
            .file_read, .grep, .glob => {},
            .http_request => {
                const http_args = std.json.parseFromSliceLeaky(PolicyHttpArgs, arena, child_input, .{
                    .ignore_unknown_fields = true,
                }) catch return .{ .deny = "parallel 无法解析 http_request 参数" };
                const method = scoot.tools.http.methodFromString(http_args.method) orelse
                    return .{ .deny = "parallel http_request method 无法识别" };
                if (scoot.tools.http.isWrite(method))
                    return .{ .deny = "parallel 只允许 HTTP GET/HEAD，不允许写类 HTTP 方法" };
            },
            .bash => return .{ .deny = "parallel 禁止 bash；请使用结构化只读工具" },
            .file_write, .file_edit => return .{ .deny = "parallel 禁止写文件或编辑文件" },
            .skill => return .{ .deny = "parallel 禁止 skill；请用独立的 skill 动作读取技能指令" },
            .parallel => return .{ .deny = "parallel 禁止嵌套 parallel" },
            .final => return .{ .deny = "parallel 子调用不能是 final" },
        }
        switch (policyDecisionForAction(arena, mode, child, child_input)) {
            .allow => {},
            .deny => |reason| return .{
                .deny = std.fmt.allocPrint(arena, "parallel 子调用 #{d} 被拒绝：{s}", .{ idx + 1, reason }) catch reason,
            },
        }
    }
    return .allow;
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

    // issue #50：把加固护栏的「实际生效与否」在 doctor 中显式化，避免 guarded 看似加固、
    // 实则两道护栏默认关闭。block_internal_http 默认开启，confine_writes 仍为 opt-in。
    const guarded = if (parsePolicyModeStrict(cfg.tools.policy)) |m| m == .guarded else false;
    if (cfg.tools.block_internal_http) {
        try d.ok("tools.block_internal_http", "enabled（拒绝环回/内网/链路本地/云元数据，收窄 SSRF）");
    } else if (guarded) {
        try d.warn("tools.block_internal_http", "disabled：http_request 可访问环回/内网/云元数据；建议设为 true");
    } else {
        try d.info("tools.block_internal_http", "disabled（当前策略档不强制网络护栏）");
    }
    if (cfg.tools.confine_writes) {
        try d.ok("tools.confine_writes", "enabled（file_write/file_edit 收口到项目根内）");
    } else if (guarded) {
        try d.info("tools.confine_writes", "disabled（opt-in；如需把写入收口到项目根设为 true）");
    } else {
        try d.info("tools.confine_writes", "disabled（当前策略档不强制写入收口）");
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
    var cron_unsupported: usize = 0;
    for (cfg.schedule.jobs) |job| {
        if (job.toJob()) |j| {
            if (j.trigger == .cron) cron_unsupported += 1;
        } else invalid += 1;
    }
    if (invalid == 0 and cron_unsupported == 0) {
        try d.ok("schedule.jobs", "all valid");
    } else if (invalid == 0) {
        // cron 触发器能解析但暂不支持，运行时会跳过——doctor 须如实示警（issue #25）。
        try d.warn("schedule.jobs", "含 cron 触发器（暂不支持），运行时会跳过");
    } else {
        try d.warn("schedule.jobs", "存在非法/不支持的任务触发器，运行时会跳过");
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
    warn: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    sess: *scoot.session.Session,
) []const scoot.agent.SkillRef {
    if (!cfg.skills.enabled) return &.{};
    const paths = cfg.skillPaths(arena) catch return &.{};
    var reg: scoot.skill.Registry = .{};
    reg.discoverAll(arena, io, paths) catch |err| {
        warn.print("[scoot] 技能发现失败（{s}），已跳过技能装载。\n", .{@errorName(err)}) catch {};
        return &.{};
    };
    if (reg.count() == 0) return &.{};
    const text = reg.manifest(arena) catch return &.{};
    sess.append(arena, .system, text) catch {};
    // 把已发现技能映射为 agent 的 name→dir 句柄表，供原生 `skill` 动作按名只读其指令/资源。
    // reg 的字符串均由 arena 分配（discover 以 arena 为 gpa），生命周期=本次运行，故不 deinit。
    const refs = arena.alloc(scoot.agent.SkillRef, reg.count()) catch return &.{};
    for (reg.skills.items, 0..) |s, i| refs[i] = .{ .name = s.name, .dir = s.dir };
    return refs;
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
        try printSkillMetadata(out, s.capabilities, s.allowed_tools, s.scope, "    ");
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
        .valid => |meta| {
            try out.print("OK {s} name={s} description={s}\n", .{
                dir,
                meta.name,
                meta.description,
            });
            try printSkillMetadata(out, meta.capabilities, meta.allowed_tools, meta.scope, "");
        },
        .invalid => |msg| {
            summary.failures += 1;
            try out.print("FAIL {s}: {s}\n", .{ dir, msg });
        },
    }
}

fn printSkillMetadata(
    out: *Io.Writer,
    capabilities: []const u8,
    allowed_tools: []const u8,
    scope: []const u8,
    prefix: []const u8,
) !void {
    if (capabilities.len != 0) try out.print("{s}capabilities={s}\n", .{ prefix, capabilities });
    if (allowed_tools.len != 0) try out.print("{s}allowed_tools={s}\n", .{ prefix, allowed_tools });
    if (scope.len != 0) try out.print("{s}scope={s}\n", .{ prefix, scope });
}

/// `scoot wasm-tools check <dir>`：只读校验 Wasm 工具包边界，不加载或执行 Wasm。
fn checkWasmToolPackage(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) !void {
    const res = try scoot.wasm_tool.validatePackage(arena, io, dir);
    switch (res) {
        .valid => |summary| {
            try out.print("OK {s} name={s} entry={s}\n", .{ dir, summary.name, summary.entry });
            try out.print("description={s}\n", .{summary.description});
            try out.print("component={s}\n", .{summary.component});
            try out.print("input_schema={s}\n", .{summary.input_schema});
            try out.print("output_schema={s}\n", .{summary.output_schema});
            try out.writeAll("capabilities=");
            try printList(out, summary.capabilities);
            try out.writeAll("\npolicy_capabilities=");
            try printList(out, summary.policy_capabilities);
            try out.writeAll("\n");
        },
        .invalid => |msg| {
            try out.print("FAIL {s}: {s}\n", .{ dir, msg });
            die(out, 1);
        },
    }
}

fn printList(out: *Io.Writer, items: []const []const u8) !void {
    for (items, 0..) |item, idx| {
        if (idx != 0) try out.writeAll(",");
        try out.writeAll(item);
    }
}

const SkillPackFile = struct {
    rel: []const u8,
    size: u64,
};

const SkillPackResult = struct {
    name: []const u8,
    output: []const u8,
    file_count: usize,
    total_bytes: u64,
    skipped_hidden: usize,
};

/// `scoot skills pack <dir> [out.tar]`：先校验，再导出可审查 tar 包。只读 skill 目录，不执行脚本。
fn packSkillCommand(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cmd: SkillPackCommand,
) !void {
    const result = packSkill(arena, io, cmd.dir, cmd.output) catch |err| switch (err) {
        error.InvalidSkill => {
            try out.print("FAIL {s}: invalid skill; run `scoot skills check {s}` for details\n", .{ cmd.dir, cmd.dir });
            die(out, 1);
        },
        error.PathAlreadyExists => {
            const output = cmd.output orelse "默认输出文件";
            try out.print("error: 输出文件已存在：{s}\n", .{output});
            die(out, 1);
        },
        error.UnsupportedSkillPackageEntry => {
            try out.writeAll("error: skill 目录包含不支持打包的文件类型（例如符号链接或设备文件）\n");
            die(out, 1);
        },
        else => return err,
    };

    try out.print(
        "OK packed {s} -> {s}\nfiles={d} bytes={d} skipped_hidden={d}\n",
        .{ result.name, result.output, result.file_count, result.total_bytes, result.skipped_hidden },
    );
}

fn packSkill(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    output_override: ?[]const u8,
) !SkillPackResult {
    const validation = try scoot.skill.validateDir(arena, io, dir);
    const meta = switch (validation) {
        .valid => |m| m,
        .invalid => return error.InvalidSkill,
    };

    var files: std.ArrayList(SkillPackFile) = .empty;
    var skipped_hidden: usize = 0;
    try collectSkillPackFiles(arena, io, dir, "", &files, &skipped_hidden);
    std.mem.sort(SkillPackFile, files.items, {}, struct {
        fn lessThan(_: void, a: SkillPackFile, b: SkillPackFile) bool {
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lessThan);

    var total_bytes: u64 = 0;
    for (files.items) |f| total_bytes += f.size;

    const output = output_override orelse try std.fmt.allocPrint(arena, "{s}.scoot-skill.tar", .{meta.name});
    const manifest = try skillPackManifest(arena, meta, files.items, total_bytes, skipped_hidden);

    const cwd = Io.Dir.cwd();
    var archive = try cwd.createFile(io, output, .{ .truncate = false, .exclusive = true });
    defer archive.close(io);
    var archive_buf: [8192]u8 = undefined;
    var fw = archive.writer(io, &archive_buf);
    const aw = &fw.interface;

    var tw: std.tar.Writer = .{ .underlying_writer = aw };
    try tw.setRoot(meta.name);
    try tw.writeFileBytes(".scoot-skill.json", manifest, .{ .mode = 0o644, .mtime = 0 });
    for (files.items) |f| {
        const full = try std.fs.path.join(arena, &.{ dir, f.rel });
        const content = try cwd.readFileAlloc(io, full, arena, .limited(8 << 20));
        try tw.writeFileBytes(f.rel, content, .{ .mode = 0o644, .mtime = 0 });
    }
    try tw.finishPedantically();
    try aw.flush();

    return .{
        .name = meta.name,
        .output = output,
        .file_count = files.items.len,
        .total_bytes = total_bytes,
        .skipped_hidden = skipped_hidden,
    };
}

fn collectSkillPackFiles(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    rel: []const u8,
    files: *std.ArrayList(SkillPackFile),
    skipped_hidden: *usize,
) !void {
    const cwd = Io.Dir.cwd();
    const here = if (rel.len == 0) root else try std.fs.path.join(arena, &.{ root, rel });
    var dir = try cwd.openDir(io, here, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') {
            skipped_hidden.* += 1;
            continue;
        }
        const child_rel = if (rel.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name });

        switch (entry.kind) {
            .directory => try collectSkillPackFiles(arena, io, root, child_rel, files, skipped_hidden),
            .file => {
                const full = try std.fs.path.join(arena, &.{ root, child_rel });
                const stat = try cwd.statFile(io, full, .{});
                try files.append(arena, .{ .rel = child_rel, .size = stat.size });
            },
            else => return error.UnsupportedSkillPackageEntry,
        }
    }
}

const SkillPackManifestFile = struct {
    path: []const u8,
    size: u64,
};

const SkillPackManifest = struct {
    format: []const u8 = "scoot.skill.package.v1",
    name: []const u8,
    description: []const u8,
    capabilities: []const []const u8,
    allowed_tools: []const []const u8,
    scope: []const u8,
    files: []const SkillPackManifestFile,
    file_count: usize,
    total_bytes: u64,
    skipped_hidden: usize,
    policy_note: []const u8 = "Skill scripts and commands do not bypass Scoot policy gates; reading a skill's instructions is a native, audited read-only capability confined to the skill directory.",
};

fn skillPackManifest(
    arena: std.mem.Allocator,
    meta: scoot.skill.Meta,
    files: []const SkillPackFile,
    total_bytes: u64,
    skipped_hidden: usize,
) ![]const u8 {
    const manifest_files = try arena.alloc(SkillPackManifestFile, files.len);
    for (files, 0..) |f, i| manifest_files[i] = .{ .path = f.rel, .size = f.size };
    const capabilities = try scoot.skill.parseInlineList(arena, meta.capabilities);
    const allowed_tools = try scoot.skill.parseInlineList(arena, meta.allowed_tools);

    var aw = std.Io.Writer.Allocating.init(arena);
    try std.json.Stringify.value(SkillPackManifest{
        .name = meta.name,
        .description = meta.description,
        .capabilities = capabilities,
        .allowed_tools = allowed_tools,
        .scope = meta.scope,
        .files = manifest_files,
        .file_count = files.len,
        .total_bytes = total_bytes,
        .skipped_hidden = skipped_hidden,
    }, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.written();
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
            if (job.trigger == .cron) {
                // cron 暂不支持：明确标记 INACTIVE，避免用户误以为它会按表运行（issue #25）。
                try out.print("  - {s}  [{s}]  ⚠ INACTIVE（cron 暂不支持，不会运行）  goal={s}\n", .{
                    jc.id, triggerLabel(&tbuf, job.trigger), job.goal,
                });
                continue;
            }
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
        // schedule/daemon 的 stdout 即运行日志，降级告警走 self.out（与 -e 的 stderr 路由不同）。
        var sink: AuditSink = .{};
        const setup = setupRun(self.client, &sink, self.out, a, self.io, self.cfg, sid, eff) catch return;
        var sess = setup.sess;
        var ag = setup.agent;
        sess.append(a, .user, job.goal) catch {};

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

const ScheduleLoad = struct {
    scheduler: scoot.schedule.Scheduler,
    valid: usize,
};

fn loadSchedule(out: *Io.Writer, arena: std.mem.Allocator, cfg: scoot.config.Config) !ScheduleLoad {
    var sch: scoot.schedule.Scheduler = .{};
    var valid: usize = 0;
    for (cfg.schedule.jobs) |jc| {
        const job = jc.toJob() orelse {
            try out.print("[scoot] 跳过非法任务 '{s}'（触发器须恰好设置其一）。\n", .{jc.id});
            continue;
        };
        if (job.trigger == .cron) {
            // cron 触发器暂不支持（schedule.dueAt 对 cron 恒 false）：fail loud——明示跳过且
            // 不计入可运行任务，杜绝「列在表里、调度启动数里有它，却永不触发」的静默陷阱（issue #25）。
            try out.print("[scoot] 跳过任务 '{s}'：cron 触发器暂不支持，不会运行（请改用 every_sec / at_unix）。\n", .{jc.id});
            continue;
        }
        try sch.add(arena, job); // job 内容借 cfg/arena 生命周期（>= scheduler）
        valid += 1;
    }
    return .{ .scheduler = sch, .valid = valid };
}

fn runSchedulerLoop(
    io: std.Io,
    scheduler: *scoot.schedule.Scheduler,
    poll_ms: u64,
    max_ticks: usize,
    stop_flag: ?*std.atomic.Value(bool),
    ctx: *anyopaque,
    runFn: scoot.schedule.Scheduler.RunFn,
) usize {
    var total: usize = 0;
    var ticks: usize = 0;
    while (max_ticks == 0 or ticks < max_ticks) : (ticks += 1) {
        if (isStopRequested(stop_flag)) break;
        const now_unix = std.Io.Timestamp.now(io, .real).toSeconds();
        total += scheduler.tick(now_unix, ctx, runFn);
        if (isStopRequested(stop_flag)) break;
        if (max_ticks != 0 and ticks + 1 >= max_ticks) break;
        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(poll_ms)), .awake) catch break;
    }
    return total;
}

fn isStopRequested(stop_flag: ?*std.atomic.Value(bool)) bool {
    const flag = stop_flag orelse return false;
    return flag.load(.acquire);
}

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

    var loaded = try loadSchedule(out, arena, cfg);
    const valid = loaded.valid;
    if (valid == 0) {
        try out.writeAll("[scoot] 无可运行任务，退出。\n");
        return;
    }

    var client = try initBackendClient(out, cfg, arena, io, env);

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

    const fired = runSchedulerLoop(io, &loaded.scheduler, sc.poll_ms, ticks, null, &rctx, RunCtx.runJob);
    try out.print("[scoot] 调度结束：累计触发 {d} 次。\n", .{fired});
}

fn runDaemon(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    ticks: usize,
) !void {
    const sc = cfg.schedule;
    if (!sc.enabled) {
        try out.writeAll("[scoot] daemon 依赖调度配置：请先设置 schedule.enabled=true。\n");
        die(out, 1);
    }

    const previous_state = scoot.daemon.readState(arena, io, cfg.dirs.state_dir) catch |err| blk: {
        try out.print("[scoot] 警告：无法读取 daemon 状态文件（{s}），将覆盖为新状态。\n", .{@errorName(err)});
        break :blk null;
    };
    if (scoot.daemon.previousRunWasUnclean(previous_state)) {
        const prev = previous_state.?;
        // issue #53：上次状态仍为 running。若该 pid 确实存活（且不是本进程），说明已有 daemon
        // 在跑——拒绝重复启动，避免双实例争用同一份调度/状态文件。否则视为上次崩溃残留的陈旧
        // running 记录，按重启恢复语义继续（signal-0 探活无法区分 PID 复用，作为可接受残留）。
        if (scoot.daemon.pidAlive(prev.pid) and prev.pid != currentPid()) {
            try out.print(
                "[scoot] 拒绝启动：检测到 daemon 已在运行（pid={d} started_at={d}）。请先 `scoot daemon stop`。\n",
                .{ prev.pid, prev.started_at_unix },
            );
            die(out, 1);
        }
        try out.print(
            "[scoot] 检测到上次 daemon 未记录正常停止：pid={d} started_at={d}（进程已不存活，按重启恢复语义继续）。\n",
            .{ prev.pid, prev.started_at_unix },
        );
    }

    var loaded = try loadSchedule(out, arena, cfg);
    const valid = loaded.valid;
    if (valid == 0) {
        try out.writeAll("[scoot] 无可运行任务，daemon 退出。\n");
        return;
    }

    var client = try initBackendClient(out, cfg, arena, io, env);

    var job_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer job_arena.deinit();

    var rctx = RunCtx{
        .out = out,
        .io = io,
        .cfg = cfg,
        .client = &client,
        .job_arena = &job_arena,
    };

    daemon_stop_requested.store(false, .release);
    installDaemonSignalHandlers();

    const pid = currentPid();
    const started_at = std.Io.Timestamp.now(io, .real).toSeconds();
    try scoot.daemon.writePid(arena, io, cfg.dirs.state_dir, pid);
    try scoot.daemon.writeState(arena, io, cfg.dirs.state_dir, .{
        .status = "running",
        .pid = pid,
        .started_at_unix = started_at,
        .updated_at_unix = started_at,
        .schedule_enabled = sc.enabled,
        .jobs = valid,
        .poll_ms = sc.poll_ms,
    });

    try out.print("[scoot] daemon 启动：pid={d} jobs={d} poll={d}ms，{s}。\n", .{
        pid,
        valid,
        sc.poll_ms,
        if (ticks == 0) "持续运行（daemon stop 或 Ctrl-C 停止）" else "有界运行",
    });
    try out.flush();

    const fired = runSchedulerLoop(io, &loaded.scheduler, sc.poll_ms, ticks, &daemon_stop_requested, &rctx, RunCtx.runJob);
    const stopped_at = std.Io.Timestamp.now(io, .real).toSeconds();
    const reason = if (daemon_stop_requested.load(.acquire)) "signal" else if (ticks != 0) "ticks" else "loop_end";
    try scoot.daemon.writeState(arena, io, cfg.dirs.state_dir, .{
        .status = "stopped",
        .pid = pid,
        .started_at_unix = started_at,
        .updated_at_unix = stopped_at,
        .stopped_at_unix = stopped_at,
        .stop_reason = reason,
        .schedule_enabled = sc.enabled,
        .jobs = valid,
        .poll_ms = sc.poll_ms,
    });
    scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
    try out.print("[scoot] daemon 停止：reason={s} fired={d}。\n", .{ reason, fired });
}

fn printDaemonStatus(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
) !void {
    const state = try scoot.daemon.readState(arena, io, cfg.dirs.state_dir);
    const pid = try scoot.daemon.readPid(arena, io, cfg.dirs.state_dir);
    const state_path = try scoot.daemon.statePath(arena, cfg.dirs.state_dir);
    const pid_path = try scoot.daemon.pidPath(arena, cfg.dirs.state_dir);

    if (state) |s| {
        try out.print("daemon status={s} pid={d} jobs={d} poll_ms={d}\n", .{ s.status, s.pid, s.jobs, s.poll_ms });
        try out.print("started_at={d} updated_at={d}\n", .{ s.started_at_unix, s.updated_at_unix });
        if (s.stopped_at_unix) |t| try out.print("stopped_at={d}\n", .{t});
        if (s.stop_reason) |reason| try out.print("stop_reason={s}\n", .{reason});
    } else {
        try out.writeAll("daemon status=unknown（尚无 daemon 状态文件）\n");
    }
    if (pid) |p| {
        try out.print("pid_file={s} pid={d}\n", .{ pid_path, p });
    } else {
        try out.print("pid_file={s} missing\n", .{pid_path});
    }
    try out.print("state_file={s}\n", .{state_path});

    // issue #53：实际探活，替代旧的「not_probed」占位。优先探 pid 文件中的 pid，否则退回状态里的 pid。
    const probe_pid: ?i64 = if (pid) |p| p else if (state) |s| s.pid else null;
    if (probe_pid) |pp| {
        const alive = scoot.daemon.pidAlive(pp);
        try out.print("liveness={s} probed_pid={d}\n", .{ if (alive) "alive" else "dead", pp });
        // 若状态文件仍记为 running 但进程已不存活，则对账：写入 stopped 记录并清理陈旧 pid 文件，
        // 避免 status 长期误报 running（issue #53 的陈旧 PID 失败模式）。
        if (!alive) {
            if (state) |s| {
                if (std.mem.eql(u8, s.status, "running")) {
                    try writeDaemonStoppedAfterFailedStop(arena, io, cfg, pp, "stale_pid_reconciled");
                    scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
                    try out.writeAll("[scoot] 已将陈旧的 running 状态对账为 stopped 并清理 pid 文件。\n");
                }
            }
        }
    } else {
        try out.writeAll("liveness=unknown（无 pid 可探测）\n");
    }
}

fn stopDaemon(
    out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
) !void {
    const pid = (try scoot.daemon.readPid(arena, io, cfg.dirs.state_dir)) orelse {
        try out.writeAll("[scoot] 没有 daemon pid 文件；daemon 可能未运行。\n");
        return;
    };
    if (pid <= 0) {
        try out.print("[scoot] daemon pid 非法：{d}\n", .{pid});
        die(out, 1);
    }
    // issue #53：发 SIGTERM 前先探活。进程已不存活时直接清理 pid 文件并对账状态，
    // 避免对陈旧 pid 发信号（PID 复用时甚至可能误杀无关进程的最坏情况由 status/stop 的探活共同收窄）。
    if (!scoot.daemon.pidAlive(pid)) {
        try out.print("[scoot] daemon pid={d} 已不存活；清理 pid 文件并对账状态。\n", .{pid});
        scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
        try writeDaemonStoppedAfterFailedStop(arena, io, cfg, pid, "process_not_alive");
        return;
    }
    std.posix.kill(@intCast(pid), .TERM) catch |err| switch (err) {
        error.ProcessNotFound => {
            try out.print("[scoot] pid={d} 不存在；清理过期 pid 文件。\n", .{pid});
            scoot.daemon.clearPid(arena, io, cfg.dirs.state_dir);
            try writeDaemonStoppedAfterFailedStop(arena, io, cfg, pid, "process_not_found");
            return;
        },
        error.PermissionDenied => {
            try out.print("[scoot] 无权限停止 daemon pid={d}。\n", .{pid});
            die(out, 1);
        },
        else => return err,
    };
    try out.print("[scoot] 已向 daemon pid={d} 发送 SIGTERM。\n", .{pid});
}

fn writeDaemonStoppedAfterFailedStop(
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    pid: i64,
    reason: []const u8,
) !void {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    try scoot.daemon.writeState(arena, io, cfg.dirs.state_dir, .{
        .status = "stopped",
        .pid = pid,
        .started_at_unix = now,
        .updated_at_unix = now,
        .stopped_at_unix = now,
        .stop_reason = reason,
        .schedule_enabled = cfg.schedule.enabled,
        .jobs = cfg.schedule.jobs.len,
        .poll_ms = cfg.schedule.poll_ms,
    });
}

fn installDaemonSignalHandlers() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleDaemonSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.INT, &action, null);
}

fn handleDaemonSignal(_: std.posix.SIG) callconv(.c) void {
    daemon_stop_requested.store(true, .release);
}

fn currentPid() i64 {
    return @intCast(std.posix.system.getpid());
}

/// 解析 API token（env > file > cmd）。本地无鉴权后端可留空。
/// 修复静默吞咽：当用户**显式**配置了 file/cmd 来源却尚未实现时，明示告警，
/// 不再把 NotImplemented 装作「无鉴权」悄悄吞掉。
fn resolveToken(
    warn: *Io.Writer,
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
            try warn.print(
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
                try warn.print(
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

/// 解析 token 并构建后端 client。`-e` / REPL / schedule / daemon 四入口共用，杜绝各自漂移。
/// `warn` 承载降级告警（token 来源落空 / 权限过宽）：交互式入口传 stdout，
/// `-e` 单次传 stderr 以免污染可脚本输出（issue #23）。
fn initBackendClient(
    warn: *Io.Writer,
    cfg: scoot.config.Config,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !scoot.llm.Client {
    const token = try resolveToken(warn, cfg, arena, io, env);
    var client = scoot.llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
    client.ca_file = cfg.backend.ca_file;
    client.extra_body = cfg.backend.extra_body;
    return client;
}

/// 一次运行装配结果。client/sink 的存储由**调用方**持有（保证 agent 内部指针稳定），
/// 本结构只承载可按值安全搬运的 session 与 agent（二者均不自引用）。
const RunSetup = struct {
    sess: scoot.session.Session,
    agent: scoot.agent.Agent,
};

/// 统一装配 session（system prompt + 技能注入）+ agent（档位/超时/CA + 审计 sink）。
/// `-e` / REPL / schedule job 三入口共用，消除三处近乎逐字重复的设置（issue #30）——
/// 任一处修订（审计路由、新增 agent 字段等）只需改这一处，不再各自漂移。
/// `warn` 路由降级告警（技能发现失败 / 审计打不开）：`-e` 传 stderr，其余传 stdout（issue #23）。
/// 调用方负责后续追加 user/goal 消息、按需设 trace、写运行边界审计标记（各入口语义不同）。
fn setupRun(
    client: *scoot.llm.Client,
    sink: *AuditSink,
    warn: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    cfg: scoot.config.Config,
    session_id: []const u8,
    policy_mode: scoot.policy.Mode,
) !RunSetup {
    var sess = scoot.session.Session.init(session_id);
    try sess.append(arena, .system, scoot.agent.system_prompt);
    const skills = injectSkills(warn, arena, io, cfg, &sess);

    var ag = scoot.agent.Agent.initClient(client);
    ag.max_turns = cfg.agent.max_turns;
    ag.tool_timeout_ms = cfg.tools.timeout_ms;
    ag.policy_mode = policy_mode;
    ag.ca_file = cfg.backend.ca_file;
    ag.context_budget_bytes = cfg.agent.context_budget_bytes;
    ag.confine_writes = cfg.tools.confine_writes;
    ag.block_internal_http = cfg.tools.block_internal_http;
    ag.skills = skills;

    sink.open(warn, arena, io, cfg.dirs.logs_dir);
    ag.audit = sink.loggerPtr();

    return .{ .sess = sess, .agent = ag };
}

/// 交互式 REPL：在单一会话里跨多轮复用 ReACT 闭环。人在场监督，
/// 单次后端失败只提示并继续，不终止整段会话。退出时落盘会话与审计。
fn runRepl(
    out: *Io.Writer,
    err_out: *Io.Writer,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cfg: scoot.config.Config,
    trace: bool,
) !void {
    // REPL 为人在场的交互式入口，stdout 即对话界面，故降级告警随 out 即可。
    var client = try initBackendClient(out, cfg, arena, io, env);
    var sink: AuditSink = .{};
    const setup = try setupRun(&client, &sink, out, arena, io, cfg, "repl", scoot.policy.Mode.fromString(cfg.tools.policy));
    var sess = setup.sess;
    var ag = setup.agent;
    // 与 -e/--eval 一致：执行轨迹走 stderr，使 stdout 对话可单独重定向、轨迹不污染回复。
    if (trace) ag.trace = err_out;

    try out.print("scoot {s} — 交互式 REPL（后端 {s}，model={s}，策略 {s}）\n", .{
        scoot.version, cfg.backend.base_url, cfg.backend.model, cfg.tools.policy,
    });
    if (trace) try out.writeAll("（--trace 已开启：执行轨迹输出到 stderr）\n");
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
            if (ag.trace) |tw| tw.flush() catch {};
            if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
            try out.print("[scoot] 后端调用失败：{s}（请检查后端是否在运行）\n", .{@errorName(err)});
            continue; // REPL 不因单次失败退出
        };
        if (ag.trace) |tw| tw.flush() catch {}; // 轨迹及时刷出 stderr：否则缓冲到进程退出才可见
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
    fn open(self: *AuditSink, warn: *Io.Writer, arena: std.mem.Allocator, io: std.Io, logs_dir: []const u8) void {
        const path = std.fmt.allocPrint(arena, "{s}/audit.jsonl", .{logs_dir}) catch return;
        const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch |err| {
            warn.print("[scoot] 警告：审计日志无法写入（{s}：{s}），本次不留痕\n", .{ path, @errorName(err) }) catch {};
            return;
        };
        self.file = f;
        self.fw = f.writer(io, &self.buf);
        if (f.stat(io)) |st| {
            self.fw.seekTo(st.size) catch {}; // 追加到末尾，不覆盖历史
        } else |_| {}
        self.logger = scoot.audit.Logger.init(&self.fw.interface, io);
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

test "replLoop: --trace 时执行轨迹写入注入的 trace writer，且不污染 stdout 对话" {
    const gpa = std.testing.allocator;
    var brain = TestBrain{ .steps = &.{
        "{\"thought\":\"答\",\"action\":\"final\",\"action_input\":\"你好\"}",
    } };
    var tracebuf: [4096]u8 = undefined;
    var tw = Io.Writer.fixed(&tracebuf);
    var ag = scoot.agent.Agent{
        .io = std.testing.io,
        .complete_ctx = &brain,
        .complete_fn = testBrainComplete,
        .max_turns = 4,
        .trace = &tw, // 模拟 runRepl 在 --trace 下把 ag.trace 指向 stderr
    };

    var sess = scoot.session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, scoot.agent.system_prompt);

    var in = Io.Reader.fixed("hi\n/exit\n");
    var obuf: [4096]u8 = undefined;
    var ow = Io.Writer.fixed(&obuf);

    try replLoop(&ow, &in, &ag, &sess, gpa);

    const o = ow.buffered();
    try std.testing.expect(std.mem.indexOf(u8, o, "你好") != null); // 回复仍走 stdout
    try std.testing.expect(std.mem.indexOf(u8, o, "[trace") == null); // 轨迹不混入对话

    const t = tw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, t, "[trace 1] reason: 答") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "[trace 1] action: final") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "[trace 1] final: 你好") != null);
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
    switch (policyDecisionForAction(arena, .readonly, .parallel, "{\"calls\":[{\"action\":\"file_read\",\"input\":\"{\\\"path\\\":\\\"README.md\\\"}\"}]}")) {
        .allow => {},
        .deny => return error.ExpectedAllow,
    }
    switch (policyDecisionForAction(arena, .readonly, .parallel, "{\"calls\":[{\"action\":\"http_request\",\"input\":\"{\\\"method\\\":\\\"GET\\\",\\\"url\\\":\\\"https://example.com\\\"}\"}]}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
    switch (policyDecisionForAction(arena, .guarded, .parallel, "{\"calls\":[{\"action\":\"file_write\",\"input\":\"{\\\"path\\\":\\\"x\\\",\\\"content\\\":\\\"y\\\"}\"}]}")) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
}

test "checkPolicyConfig: 报告加固护栏的生效状态（issue #50）" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 默认档（guarded + block_internal_http=true + confine_writes=false）：
    // SSRF 护栏应报 OK，写入收口报 INFO（opt-in），无 WARN。
    {
        var buf: [4096]u8 = undefined;
        var ow = Io.Writer.fixed(&buf);
        var d = Doctor{ .out = &ow };
        const cfg: scoot.config.Config = .{ .dirs = undefined };
        try checkPolicyConfig(&d, arena, cfg);
        const o = ow.buffered();
        try std.testing.expect(std.mem.indexOf(u8, o, "OK\ttools.block_internal_http") != null);
        try std.testing.expect(std.mem.indexOf(u8, o, "INFO\ttools.confine_writes") != null);
        try std.testing.expectEqual(@as(usize, 0), d.warnings);
    }

    // guarded 下显式关闭 SSRF 护栏：应 WARN，提示生效姿态被削弱。
    {
        var buf: [4096]u8 = undefined;
        var ow = Io.Writer.fixed(&buf);
        var d = Doctor{ .out = &ow };
        var cfg: scoot.config.Config = .{ .dirs = undefined };
        cfg.tools.block_internal_http = false;
        try checkPolicyConfig(&d, arena, cfg);
        const o = ow.buffered();
        try std.testing.expect(std.mem.indexOf(u8, o, "WARN\ttools.block_internal_http") != null);
        try std.testing.expect(d.warnings >= 1);
    }
}

test "packSkill: 导出 tar 包并写入审查 manifest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const root = "/tmp/scoot_skill_pack_ok";
    const out_path = "/tmp/scoot_skill_pack_ok.tar";
    cwd.deleteTree(io, root) catch {};
    cwd.deleteFile(io, out_path) catch {};
    defer cwd.deleteTree(io, root) catch {};
    defer cwd.deleteFile(io, out_path) catch {};

    try cwd.createDirPath(io, root ++ "/scripts");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/SKILL.md",
        .data = "---\nname: pack-ok\ndescription: Pack test skill.\ncapabilities: [instructions, scripts]\nallowed_tools: [bash, file_read]\nscope: workflow\n---\n# Pack\n",
    });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/scripts/run.sh", .data = "echo ok\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/.env", .data = "SECRET=must-not-package\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try packSkill(arena, io, root, out_path);
    try std.testing.expectEqualStrings("pack-ok", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.file_count);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_hidden);

    const archive = try cwd.readFileAlloc(io, out_path, arena, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, archive, "scoot.skill.package.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"capabilities\": [") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"scripts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"allowed_tools\": [") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"file_read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "\"scope\": \"workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "pack-ok/.scoot-skill.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "pack-ok/SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "pack-ok/scripts/run.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "must-not-package") == null);
}

test "packSkill: 无效 skill 不打包" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const root = "/tmp/scoot_skill_pack_invalid";
    const out_path = "/tmp/scoot_skill_pack_invalid.tar";
    cwd.deleteTree(io, root) catch {};
    cwd.deleteFile(io, out_path) catch {};
    defer cwd.deleteTree(io, root) catch {};
    defer cwd.deleteFile(io, out_path) catch {};

    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/SKILL.md",
        .data = "---\nname: no-description\n---\n# Invalid\n",
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidSkill, packSkill(arena_state.allocator(), io, root, out_path));
    try std.testing.expect(!fileExists(io, out_path));
}

test "shouldRetryEvalError: 只重试临时后端错误且受次数限制" {
    var client = scoot.llm.Client.init(std.testing.io, "http://backend", "model", "");

    client.last_error_status = 429;
    try std.testing.expect(shouldRetryEvalError(error.BackendError, &client, 0, 2));
    try std.testing.expect(shouldRetryEvalError(error.BackendError, &client, 1, 2));
    try std.testing.expect(!shouldRetryEvalError(error.BackendError, &client, 2, 2));

    client.last_error_status = 503;
    try std.testing.expect(shouldRetryEvalError(error.BackendError, &client, 0, 1));

    client.last_error_status = 400;
    try std.testing.expect(!shouldRetryEvalError(error.BackendError, &client, 0, 2));

    client.last_error_status = 0;
    try std.testing.expect(!shouldRetryEvalError(error.Unauthorized, &client, 0, 2));
}

test "evalRetryDelayNs: 指数退避且有上限" {
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), evalRetryDelayNs(1));
    try std.testing.expectEqual(@as(u64, 4 * std.time.ns_per_s), evalRetryDelayNs(2));
    try std.testing.expectEqual(@as(u64, 8 * std.time.ns_per_s), evalRetryDelayNs(3));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), evalRetryDelayNs(4));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s), evalRetryDelayNs(10));
}

test "parsePolicyModeStrict: 未知策略不静默回落" {
    try std.testing.expectEqual(scoot.policy.Mode.guarded, parsePolicyModeStrict("guarded").?);
    try std.testing.expectEqual(scoot.policy.Mode.readonly, parsePolicyModeStrict("readonly").?);
    try std.testing.expectEqual(scoot.policy.Mode.unrestricted, parsePolicyModeStrict("unrestricted").?);
    try std.testing.expect(parsePolicyModeStrict("surprise") == null);
}

test "schedule: cron 触发器 fail-loud——loadSchedule 跳过且不计入、printSchedule 标记 INACTIVE（issue #25）" {
    const jobs = [_]scoot.config.JobConfig{
        .{ .id = "tick", .goal = "g", .every_sec = 5 },
        .{ .id = "nightly", .goal = "g", .cron = "0 3 * * *" },
    };
    var cfg: scoot.config.Config = .{ .dirs = undefined };
    cfg.schedule = .{ .enabled = true, .jobs = &jobs };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // loadSchedule：只有 every_sec 计入有效任务；cron 被显式跳过并打印原因。
    var lbuf: [1024]u8 = undefined;
    var lw = Io.Writer.fixed(&lbuf);
    const loaded = try loadSchedule(&lw, arena.allocator(), cfg);
    try std.testing.expectEqual(@as(usize, 1), loaded.valid);
    const lout = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, lout, "nightly") != null);
    try std.testing.expect(std.mem.indexOf(u8, lout, "cron 触发器暂不支持") != null);

    // printSchedule：cron 任务显式标记 INACTIVE（不展示执行档，杜绝「以为会运行」）。
    var pbuf: [1024]u8 = undefined;
    var pw = Io.Writer.fixed(&pbuf);
    try printSchedule(&pw, cfg);
    const pout = pw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, pout, "INACTIVE") != null);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(scoot);
}
