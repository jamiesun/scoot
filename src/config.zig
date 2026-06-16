//! 运行时配置：默认从 ~/.scoot/config.json 加载，缺省即用内置默认值。
//! 状态严格本地化；密钥默认不内联，见 secret.zig。
const std = @import("std");
const Environ = std.process.Environ;
const paths = @import("paths.zig");
const secret = @import("secret.zig");

/// LLM 后端配置。仅 OpenAI 兼容协议（见 ROADMAP 非目标）。
pub const Backend = struct {
    base_url: []const u8 = "http://127.0.0.1:11434/v1",
    model: []const u8 = "qwen2.5",
    /// 读取 token 的环境变量名（默认来源）。此处不存放明文。
    api_key_env: []const u8 = "OPENAI_API_KEY",
    /// token 文件路径；null 表示用 ~/.scoot/token。
    api_key_file: ?[]const u8 = null,
    /// 凭证命令（如 `pass show openai`）；null 表示不用。
    api_key_cmd: ?[]const u8 = null,
};

/// 认知引擎配置。
pub const Agent = struct {
    max_turns: u32 = 32,
    /// 默认认知模式：goal / plan。
    default_mode: []const u8 = "goal",
};

/// 工具沙盒配置。
pub const Tools = struct {
    /// 工具调用硬超时（毫秒）。
    timeout_ms: u64 = 30_000,
};

/// Skill 机制配置。
pub const Skills = struct {
    enabled: bool = true,
    /// 额外 skill 搜索路径（默认已含 ~/.scoot/skills）。
    extra_paths: []const []const u8 = &.{},
};

/// 审计日志配置。
pub const Audit = struct {
    /// 日志级别：debug / info / warn / error。
    level: []const u8 = "info",
    /// 是否把审计日志写入 ~/.scoot/logs。
    to_file: bool = true,
};

pub const Config = struct {
    backend: Backend = .{},
    agent: Agent = .{},
    tools: Tools = .{},
    skills: Skills = .{},
    audit: Audit = .{},
    /// 解析出的运行目录。
    dirs: paths.Paths,

    /// 从 ~/.scoot/config.json 加载配置；文件不存在则用默认值。
    /// `io` 用于读取配置文件，`env` 用于解析运行目录。
    /// TODO: 用 std.json 解析配置文件并按节合并；当前返回默认值 + 解析后的运行目录。
    pub fn load(arena: std.mem.Allocator, io: std.Io, env: *const Environ.Map) !Config {
        _ = io;
        const dirs = try paths.Paths.resolve(arena, env);
        return .{ .dirs = dirs };
    }

    /// 按配置来源解析 API token（env > file > cmd）。明文绝不入库。
    pub fn resolveToken(
        self: Config,
        arena: std.mem.Allocator,
        io: std.Io,
        env: *const Environ.Map,
    ) !secret.Secret {
        var srcs: std.ArrayList(secret.Source) = .empty;
        try srcs.append(arena, .{ .env = self.backend.api_key_env });
        try srcs.append(arena, .{ .file = self.backend.api_key_file orelse self.dirs.token_file });
        if (self.backend.api_key_cmd) |cmd| try srcs.append(arena, .{ .command = cmd });
        return secret.resolve(arena, io, env, srcs.items);
    }

    /// 全部 skill 搜索路径：默认 ~/.scoot/skills 叠加 config 中的额外路径。
    pub fn skillPaths(self: Config, arena: std.mem.Allocator) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(arena, self.dirs.skills_dir);
        for (self.skills.extra_paths) |p| try list.append(arena, p);
        return list.items;
    }
};

test {
    std.testing.refAllDecls(@This());
}
