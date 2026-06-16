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

/// config.json 的可序列化镜像：仅含可落盘的配置节，不含运行目录。
/// 每节都带默认值，缺省的节/字段自动回落默认，从而实现按节合并。
const FileConfig = struct {
    backend: Backend = .{},
    agent: Agent = .{},
    tools: Tools = .{},
    skills: Skills = .{},
    audit: Audit = .{},
};

/// 配置文件大小上限：1 MiB（config.json 实际仅几 KiB，留足冗余）。
const config_read_limit: std.Io.Limit = .limited(1 << 20);

/// 解析 config.json 文本为 FileConfig。
/// 空白内容回落默认；未知字段忽略（向后兼容）；畸形 JSON → error.InvalidConfig。
/// 字符串/数组分配在 arena 上，生命周期随 arena。
fn parseFileConfig(arena: std.mem.Allocator, bytes: []const u8) !FileConfig {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return .{};
    return std.json.parseFromSliceLeaky(FileConfig, arena, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
}

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
    /// 文件缺失 → 静默回落默认；存在但畸形 → error.InvalidConfig（让坏配置可见）。
    pub fn load(arena: std.mem.Allocator, io: std.Io, env: *const Environ.Map) !Config {
        const dirs = try paths.Paths.resolve(arena, env);
        return loadFromDirs(arena, io, dirs);
    }

    /// 在运行目录已解析后加载配置。供 CLI 先解析目录、再针对配置文件单独报错。
    pub fn loadFromDirs(arena: std.mem.Allocator, io: std.Io, dirs: paths.Paths) !Config {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, dirs.config_file, arena, config_read_limit) catch |err| switch (err) {
            error.FileNotFound => return .{ .dirs = dirs },
            else => return err,
        };
        const fc = try parseFileConfig(arena, bytes);
        return .{
            .backend = fc.backend,
            .agent = fc.agent,
            .tools = fc.tools,
            .skills = fc.skills,
            .audit = fc.audit,
            .dirs = dirs,
        };
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

test "parseFileConfig: 空白内容回落默认" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "  \n\t ");
    try std.testing.expectEqualStrings("qwen2.5", fc.backend.model);
    try std.testing.expectEqual(@as(u32, 32), fc.agent.max_turns);
    try std.testing.expectEqual(@as(u64, 30_000), fc.tools.timeout_ms);
}

test "parseFileConfig: 空对象回落默认" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(), "{}");
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1", fc.backend.base_url);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", fc.backend.api_key_env);
}

test "parseFileConfig: 按节按字段合并，未指定字段保留默认" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{
        \\  "backend": { "model": "llama3.1", "base_url": "http://10.0.0.2:1234/v1" },
        \\  "agent": { "max_turns": 8 },
        \\  "tools": { "timeout_ms": 5000 }
        \\}
    ;
    const fc = try parseFileConfig(arena.allocator(), json);
    try std.testing.expectEqualStrings("llama3.1", fc.backend.model);
    try std.testing.expectEqualStrings("http://10.0.0.2:1234/v1", fc.backend.base_url);
    // 未指定 → 默认
    try std.testing.expectEqualStrings("OPENAI_API_KEY", fc.backend.api_key_env);
    try std.testing.expectEqual(@as(u32, 8), fc.agent.max_turns);
    try std.testing.expectEqualStrings("goal", fc.agent.default_mode);
    try std.testing.expectEqual(@as(u64, 5000), fc.tools.timeout_ms);
}

test "parseFileConfig: 可选 token 来源与额外 skill 路径" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{
        \\  "backend": { "api_key_cmd": "pass show openai" },
        \\  "skills": { "extra_paths": ["/opt/scoot/skills", "./skills"] }
        \\}
    ;
    const fc = try parseFileConfig(arena.allocator(), json);
    try std.testing.expect(fc.backend.api_key_cmd != null);
    try std.testing.expectEqualStrings("pass show openai", fc.backend.api_key_cmd.?);
    try std.testing.expect(fc.backend.api_key_file == null);
    try std.testing.expectEqual(@as(usize, 2), fc.skills.extra_paths.len);
    try std.testing.expectEqualStrings("/opt/scoot/skills", fc.skills.extra_paths[0]);
}

test "parseFileConfig: 未知字段忽略" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const fc = try parseFileConfig(arena.allocator(),
        \\{ "backend": { "model": "m" }, "future_key": 123, "nested": { "x": true } }
    );
    try std.testing.expectEqualStrings("m", fc.backend.model);
}

test "parseFileConfig: 畸形 JSON → InvalidConfig" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidConfig, parseFileConfig(arena.allocator(), "{ not json"));
    try std.testing.expectError(error.InvalidConfig, parseFileConfig(arena.allocator(),
        \\{ "agent": { "max_turns": "not-a-number" } }
    ));
}
