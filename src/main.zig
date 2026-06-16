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
    \\  repl                 进入交互式 REPL（默认）
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
        // token 可选：本地无鉴权后端（如 Ollama）留空即可。
        const token: []const u8 = blk: {
            const s = cfg.resolveToken(arena, io, env) catch break :blk "";
            break :blk s.value;
        };
        var client = scoot.llm.Client.init(io, cfg.backend.base_url, cfg.backend.model, token);
        var sess = scoot.session.Session.init("cli");
        try sess.append(arena, .system, scoot.agent.system_prompt);
        try sess.append(arena, .user, prompt);

        var ag = scoot.agent.Agent.initClient(&client);
        ag.max_turns = cfg.agent.max_turns;
        ag.tool_timeout_ms = cfg.tools.timeout_ms;
        ag.policy_mode = scoot.policy.Mode.fromString(cfg.tools.policy);

        // 审计留痕（铁律：可审计胜过黑盒）。审计文件打不开时降级为「明示警告 + 不留痕」，
        // 既不静默退回黑盒，也不因日志故障阻断任务。
        const audit_path = try std.fmt.allocPrint(arena, "{s}/audit.jsonl", .{cfg.dirs.logs_dir});
        var audit_buf: [4096]u8 = undefined;
        var audit_fw: Io.File.Writer = undefined;
        var logger: scoot.audit.Logger = undefined;
        const audit_file: ?Io.File = blk: {
            const f = Io.Dir.cwd().createFile(io, audit_path, .{ .truncate = false }) catch |err| {
                try out.print("[scoot] 警告：审计日志无法写入（{s}：{s}），本次运行不留痕\n", .{ audit_path, @errorName(err) });
                break :blk null;
            };
            audit_fw = f.writer(io, &audit_buf);
            if (f.stat(io)) |st| {
                audit_fw.seekTo(st.size) catch {}; // 追加到末尾，不覆盖历史
            } else |_| {}
            logger = scoot.audit.Logger.init(&audit_fw.interface);
            ag.audit = &logger;
            logger.log(.run, prompt) catch {}; // 运行边界标记（携带用户目标）
            break :blk f;
        };

        const reply = ag.run(arena, &sess) catch |err| {
            if (ag.audit) |lg| lg.log(.system_error, @errorName(err)) catch {};
            finalizeRun(io, &sess, cfg.dirs.sessions_dir, audit_file, &audit_fw);
            try out.print("[scoot] 调用后端失败：{s}\n", .{@errorName(err)});
            try out.print(
                "        后端 {s}（model={s}）。请确认 OpenAI 兼容服务在运行，必要时设置 {s}。\n",
                .{ cfg.backend.base_url, cfg.backend.model, cfg.backend.api_key_env },
            );
            die(out, 1);
        };
        finalizeRun(io, &sess, cfg.dirs.sessions_dir, audit_file, &audit_fw);
        try out.print("{s}\n", .{reply});
        return;
    }

    try out.print("scoot {s} — 交互式 REPL（stub）\n", .{scoot.version});
    try out.print("运行目录: {s}\n", .{cfg.dirs.home});
    try out.writeAll("认知引擎、skill 加载与 /schedule 指令尚未实现，详见 ROADMAP.md。\n");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 收尾一次运行：flush 审计缓冲、关闭审计文件，并把会话快照追加落盘。
/// 全部为尽力而为——收尾失败不应再改变已决定的退出路径。
fn finalizeRun(
    io: std.Io,
    sess: *scoot.session.Session,
    sessions_dir: []const u8,
    audit_file: ?Io.File,
    audit_fw: *Io.File.Writer,
) void {
    if (audit_file) |f| {
        audit_fw.interface.flush() catch {};
        f.close(io);
    }
    sess.persist(io, sessions_dir) catch {};
}

/// 打印完信息后干净退出（刷新 stdout，不抛错误回溯）：用于面向用户的可预期失败。
fn die(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(scoot);
}
