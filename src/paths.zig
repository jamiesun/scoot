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

    /// 解析运行目录。所有字符串由 `arena` 拥有（进程级生命周期即可）。
    pub fn resolve(arena: std.mem.Allocator, env: *const Environ.Map) !Paths {
        const home = env.get("SCOOT_HOME") orelse blk: {
            const h = env.get("HOME") orelse return error.NoHomeDir;
            break :blk try std.fs.path.join(arena, &.{ h, ".scoot" });
        };
        return .{
            .home = home,
            .config_file = try std.fs.path.join(arena, &.{ home, "config.json" }),
            .token_file = try std.fs.path.join(arena, &.{ home, "token" }),
            .skills_dir = try std.fs.path.join(arena, &.{ home, "skills" }),
            .logs_dir = try std.fs.path.join(arena, &.{ home, "logs" }),
            .state_dir = try std.fs.path.join(arena, &.{ home, "state" }),
        };
    }

    /// 确保运行目录及子目录存在，并校正权限（home 期望 0700）。
    /// TODO: 用 Io 创建目录（不存在则建，权限过宽则收紧）。
    pub fn ensure(self: Paths, io: std.Io) !void {
        _ = self;
        _ = io;
        return error.NotImplemented;
    }
};

test {
    std.testing.refAllDecls(@This());
}
