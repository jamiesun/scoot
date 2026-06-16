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

const system_prompt =
    \\你是 Scoot，一个严谨、简洁的命令行 AI 助手。
    \\必须只返回与给定 JSON Schema 匹配的 JSON 对象，把回答放进 "reply" 字段，不要输出多余文本。
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

    const cfg = try scoot.config.Config.load(arena, io, env);

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
        try sess.append(arena, .system, system_prompt);
        try sess.append(arena, .user, prompt);

        var ag = scoot.agent.Agent.init(&client);
        const reply = ag.run(arena, &sess) catch |err| {
            try out.print("[scoot] 调用后端失败：{s}\n", .{@errorName(err)});
            try out.print(
                "        后端 {s}（model={s}）。请确认 OpenAI 兼容服务在运行，必要时设置 {s}。\n",
                .{ cfg.backend.base_url, cfg.backend.model, cfg.backend.api_key_env },
            );
            die(out, 1);
        };
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

/// 打印完信息后干净退出（刷新 stdout，不抛错误回溯）：用于面向用户的可预期失败。
fn die(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(scoot);
}
