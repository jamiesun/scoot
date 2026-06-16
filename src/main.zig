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
    \\
    \\选项:
    \\  -e, --eval <prompt>  单次执行一个目标后退出
    \\  -h, --help           显示本帮助
    \\  -v, --version        显示版本号
    \\
    \\运行目录默认为 ~/.scoot（可用环境变量 SCOOT_HOME 覆盖）。
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

    const args = try init.minimal.args.toSlice(arena);

    var eval_prompt: ?[]const u8 = null;
    var cmd_config = false;
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
        } else if (eql(arg, "config")) {
            cmd_config = true;
        } else if (eql(arg, "repl")) {
            // 默认即 REPL，显式接受该命令。
        } else {
            try out.print("error: 未知参数 '{s}'\n\n", .{arg});
            try out.writeAll(usage);
            die(out, 2);
        }
    }

    const dirs = scoot.paths.Paths.resolve(arena, env) catch |err| switch (err) {
        error.NoHomeDir => {
            try out.writeAll("error: 无法确定运行目录：请设置 HOME 或 SCOOT_HOME\n");
            die(out, 1);
        },
        else => return err,
    };
    const cfg = scoot.config.Config.loadFromDirs(arena, io, dirs) catch |err| switch (err) {
        error.InvalidConfig => {
            try out.print("error: 配置文件不是合法 JSON：{s}\n", .{dirs.config_file});
            die(out, 1);
        },
        else => {
            try out.print("error: 读取配置失败（{s}）：{s}\n", .{ @errorName(err), dirs.config_file });
            die(out, 1);
        },
    };

    cfg.dirs.ensure(io) catch |err| {
        try out.print("error: 无法创建运行目录（{s}）：{s}\n", .{ @errorName(err), cfg.dirs.home });
        die(out, 1);
    };

    if (cmd_config) {
        try out.print("运行目录:   {s}\n", .{cfg.dirs.home});
        try out.print("  配置文件: {s}\n", .{cfg.dirs.config_file});
        try out.print("  token:    {s}\n", .{cfg.dirs.token_file});
        try out.print("  skills:   {s}\n", .{cfg.dirs.skills_dir});
        try out.print("  日志:     {s}\n", .{cfg.dirs.logs_dir});
        try out.print("后端:       {s} (model={s})\n", .{ cfg.backend.base_url, cfg.backend.model });
        try out.print("token 来源: env[{s}] > file > cmd（明文不入库）\n", .{cfg.backend.api_key_env});
        return;
    }

    if (eval_prompt) |prompt| {
        const token = try resolveToken(out, cfg, arena, io, env);
        var client = scoot.llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
        var sess = scoot.session.Session.init("cli");
        try sess.append(arena, .system, scoot.agent.system_prompt);
        try sess.append(arena, .user, prompt);

        var ag = scoot.agent.Agent.initClient(&client);
        ag.max_turns = cfg.agent.max_turns;
        ag.tool_timeout_ms = cfg.tools.timeout_ms;
        ag.policy_mode = scoot.policy.Mode.fromString(cfg.tools.policy);

        // 审计留痕（铁律：可审计胜过黑盒）。打不开则降级为「明示警告 + 不留痕」。
        var sink: AuditSink = .{};
        sink.open(out, arena, io, cfg.dirs.logs_dir);
        ag.audit = sink.loggerPtr();
        if (ag.audit) |lg| lg.log(.run, prompt) catch {}; // 运行边界标记（携带用户目标）

        const reply = ag.run(arena, &sess) catch |err| {
            if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
            finalizeRun(io, &sess, cfg.dirs.sessions_dir, &sink);
            try out.print("[scoot] 调用后端失败：{s}\n", .{@errorName(err)});
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

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const repl_banner =
    \\输入目标后回车，Scoot 会在「思考-行动-观察」循环里完成它。
    \\  /exit、/quit  退出（会话与审计已落盘）
    \\  /help         再次显示本帮助
    \\
;

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
    const token: []const u8 = blk: {
        const s = cfg.resolveToken(arena, io, env) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk "", // NotImplemented / NoApiKey：降级为空 token
        };
        break :blk s.value;
    };
    if (token.len == 0 and (cfg.backend.api_key_file != null or cfg.backend.api_key_cmd != null)) {
        try out.print(
            "[scoot] 警告：已配置 token 文件/命令来源，但该来源尚未实现，将以空 token 继续。\n" ++
                "        远程后端请改用环境变量 {s}。\n",
            .{cfg.backend.api_key_env},
        );
    }
    return token;
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

    var sess = scoot.session.Session.init("repl");
    try sess.append(arena, .system, scoot.agent.system_prompt);

    var ag = scoot.agent.Agent.initClient(&client);
    ag.max_turns = cfg.agent.max_turns;
    ag.tool_timeout_ms = cfg.tools.timeout_ms;
    ag.policy_mode = scoot.policy.Mode.fromString(cfg.tools.policy);

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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(scoot);
}
