//! 密钥（API token）安全管理。
//!
//! 核心原则：默认绝不把明文密钥写进 config.json 或随意落盘；token 只在内存中
//! 短暂存活，随进程结束释放，且绝不写进日志 / 审计。
//!
//! 解析优先级（高 → 低）：
//!   1) 环境变量（默认 OPENAI_API_KEY，可由 config.backend.api_key_env 覆盖）；
//!   2) 独立 token 文件（默认 ~/.scoot/token，必须 0600，否则拒绝读取）；
//!   3) 凭证命令 api_key_cmd（如 `pass show openai` / 钥匙串读取命令），
//!      stdout 即 token —— 借助外部工具实现安全存储，不引入平台钥匙串依赖；
//!   4) （强烈不推荐）config 内联 api_key —— 一旦检测到即告警。
const std = @import("std");
const Environ = std.process.Environ;

/// 一个 token 来源。
pub const Source = union(enum) {
    /// 环境变量名。
    env: []const u8,
    /// token 文件路径（要求 0600）。
    file: []const u8,
    /// 凭证命令；其 stdout 即 token。
    command: []const u8,
    /// 内联明文（不推荐）。
    inline_value: []const u8,
};

pub const Secret = struct {
    value: []const u8,
    source: std.meta.Tag(Source),
};

/// 按优先级解析出 token。`io` 用于读取文件 / 执行凭证命令。
/// TODO: 实现 file（校验 0600）与 command 分支；当前仅实现环境变量与内联。
pub fn resolve(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const Environ.Map,
    sources: []const Source,
) !Secret {
    _ = arena;
    _ = io;
    for (sources) |src| switch (src) {
        .env => |name| {
            if (env.get(name)) |v| return .{ .value = v, .source = .env };
        },
        .file => return error.NotImplemented, // TODO: 读文件 + assertPrivate
        .command => return error.NotImplemented, // TODO: 执行命令取 stdout
        .inline_value => |v| return .{ .value = v, .source = .inline_value },
    };
    return error.NoApiKey;
}

/// 校验密钥文件未对 group/other 开放（仿 SSH/.netrc）。权限过宽即拒绝。
/// TODO: 用 Io 取文件 mode，(mode & 0o077) != 0 则 return error.InsecurePermissions。
pub fn assertPrivate(io: std.Io, path: []const u8) !void {
    _ = io;
    _ = path;
    return error.NotImplemented;
}

/// 日志脱敏：任何时候打印密钥都应先经过它。
pub fn redact(value: []const u8) []const u8 {
    _ = value;
    return "****";
}

test {
    std.testing.refAllDecls(@This());
}
