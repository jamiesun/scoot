//! 运行目录解析：~/.scoot/ 作为 Scoot 的家目录与运行目录。
//! 解析优先级：环境变量 SCOOT_HOME > $HOME/.scoot。
//! 本模块只做路径字符串解析；实际目录创建/读写走 Io（见 ensure）。
const std = @import("std");
const Environ = std.process.Environ;

pub const Paths = struct {
    /// 运行目录根（默认 ~/.scoot）。
    home: []const u8,
    /// 主配置文件：<home>/config.json
    config_file: []const u8,
    /// 默认 token 文件：<home>/token（要求 0600）
    token_file: []const u8,
    /// 用户级 skill 目录：<home>/skills
    skills_dir: []const u8,
    /// 审计 / 运行日志目录：<home>/logs
    logs_dir: []const u8,
    /// 本地状态目录（调度任务、会话等）：<home>/state
    state_dir: []const u8,
    /// 会话落盘目录：<home>/state/sessions
    sessions_dir: []const u8,

    /// 解析运行目录。所有字符串由 `arena` 拥有（进程级生命周期即可）。
    pub fn resolve(arena: std.mem.Allocator, env: *const Environ.Map) !Paths {
        const home = env.get("SCOOT_HOME") orelse blk: {
            const h = env.get("HOME") orelse return error.NoHomeDir;
            break :blk try std.fs.path.join(arena, &.{ h, ".scoot" });
        };
        const state_dir = try std.fs.path.join(arena, &.{ home, "state" });
        return .{
            .home = home,
            .config_file = try std.fs.path.join(arena, &.{ home, "config.json" }),
            .token_file = try std.fs.path.join(arena, &.{ home, "token" }),
            .skills_dir = try std.fs.path.join(arena, &.{ home, "skills" }),
            .logs_dir = try std.fs.path.join(arena, &.{ home, "logs" }),
            .state_dir = state_dir,
            .sessions_dir = try std.fs.path.join(arena, &.{ state_dir, "sessions" }),
        };
    }

    /// 确保运行目录及子目录存在（幂等：已存在不报错）。
    /// 用 Io 的 createDirPath（mkdir -p 语义）逐个创建。
    /// 注：权限收紧（home 期望 0700、token 0600）由 secret 子系统在读写密钥时把关；
    ///     此处先保证目录存在，目录权限沿用系统默认。
    pub fn ensure(self: Paths, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, self.home);
        try cwd.createDirPath(io, self.skills_dir);
        try cwd.createDirPath(io, self.logs_dir);
        try cwd.createDirPath(io, self.state_dir);
        try cwd.createDirPath(io, self.sessions_dir);
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "ensure: 在临时目录下创建运行目录树且幂等" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const home = "/tmp/scoot_paths_test";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const p: Paths = .{
        .home = home,
        .config_file = home ++ "/config.json",
        .token_file = home ++ "/token",
        .skills_dir = home ++ "/skills",
        .logs_dir = home ++ "/logs",
        .state_dir = home ++ "/state",
        .sessions_dir = home ++ "/state/sessions",
    };
    try p.ensure(io); // 首次创建
    try p.ensure(io); // 再次调用必须幂等、不报错

    // 子目录应可被再次以目录方式打开（存在性验证）。
    var d = try cwd.openDir(io, p.sessions_dir, .{});
    d.close(io);
}
