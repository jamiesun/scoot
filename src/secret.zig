//! 密钥（API token）安全管理。
//!
//! 核心原则：默认绝不把明文密钥写进 config.json 或随意落盘；token 只在内存中
//! 短暂存活，随进程结束释放，且绝不写进日志 / 审计。
//!
//! 解析优先级（高 → 低），逐个尝试、命中即返回：
//!   1) 环境变量（默认 OPENAI_API_KEY，可由 config.backend.api_key_env 覆盖）；
//!   2) 独立 token 文件（默认 ~/.scoot/token，必须 0600，否则拒绝读取）；
//!   3) 凭证命令 api_key_cmd（如 `pass show openai` / 钥匙串读取命令），
//!      stdout 即 token —— 借助外部工具实现安全存储，不引入平台钥匙串依赖。
//! `Source.inline_value`（config 内联明文）库层支持但 config **刻意不暴露**该字段，
//! 以杜绝明文密钥随仓库提交；仅留作测试 / 嵌入用途。
const std = @import("std");
const Environ = std.process.Environ;
const bash = @import("tools/bash.zig");

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

/// 凭证命令的硬超时（毫秒）：坏命令（如卡死的钥匙串/网络读取）绝不能拖死启动。
const command_timeout_ms: u64 = 10_000;
/// token 文件 / 命令输出的大小上限：远超任何合法 token，又挡住误读巨型文件。
const token_size_limit: usize = 64 * 1024;

/// 按优先级解析出 token。`io` 用于读取文件 / 执行凭证命令。
///
/// 逐个来源尝试，命中即返回；某来源"不可用"（环境变量未设、文件不存在、命令失败/空输出）
/// 则**跳到下一来源**；唯有 token 文件存在但权限过宽（`InsecurePermissions`）会**明示失败**
/// 而非降级——拒绝读取世界可读的密钥文件，是"密钥零泄漏"铁律的结构性保证。
pub fn resolve(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const Environ.Map,
    sources: []const Source,
) !Secret {
    for (sources) |src| switch (src) {
        .env => |name| {
            if (env.get(name)) |v| if (v.len != 0) return .{ .value = v, .source = .env };
        },
        .file => |path| {
            // 读前先校验权限：group/other 有任何位即拒绝（仿 SSH 私钥 / .netrc）。
            // 文件不存在 → 跳到下一来源；权限过宽 → 明示失败（绝不读入内存）。
            assertPrivate(io, path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(token_size_limit)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const tok = std.mem.trim(u8, raw, " \t\r\n");
            if (tok.len == 0) continue; // 空文件 → 跳过
            return .{ .value = tok, .source = .file };
        },
        .command => |cmd| {
            // 凭证命令（如 `pass show openai`）：stdout 即 token。受信（用户自己的 config），
            // 故不过 policy 门，但必须硬超时（坏命令不拖死启动）。失败/超时/空输出 → 跳过。
            const r = bash.run(arena, io, cmd, .{
                .timeout_ms = command_timeout_ms,
                .stdout_limit = token_size_limit,
            }) catch continue;
            if (r.timed_out or r.exit_code != 0) continue;
            const tok = std.mem.trim(u8, r.stdout, " \t\r\n");
            if (tok.len == 0) continue;
            return .{ .value = tok, .source = .command };
        },
        .inline_value => |v| {
            if (v.len != 0) return .{ .value = v, .source = .inline_value };
        },
    };
    return error.NoApiKey;
}

/// 校验密钥文件未对 group/other 开放（仿 SSH/.netrc）。权限过宽即 `InsecurePermissions`。
/// 文件不存在透传 `FileNotFound`（调用方据此跳到下一来源）。
/// 非 POSIX 平台（无 mode_t）跳过校验——该平台无 Unix 权限位概念。
pub fn assertPrivate(io: std.Io, path: []const u8) !void {
    const Perm = std.Io.File.Permissions;
    if (comptime !@hasDecl(Perm, "toMode")) return; // 非 POSIX 平台无 mode_t，跳过权限校验
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (st.permissions.toMode() & 0o077 != 0) return error.InsecurePermissions;
}

/// 日志脱敏：任何时候打印密钥都应先经过它。
pub fn redact(value: []const u8) []const u8 {
    _ = value;
    return "****";
}

test {
    std.testing.refAllDecls(@This());
}

/// 测试辅助：在临时路径写一个文件并强制精确权限（绕过 umask 影响，保证确定性）。
fn writeFileMode(io: std.Io, path: []const u8, content: []const u8, mode: std.posix.mode_t) !void {
    const cwd = std.Io.Dir.cwd();
    var f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var fw = f.writer(io, &buf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
    try f.setPermissions(io, std.Io.File.Permissions.fromMode(mode));
}

test "assertPrivate: 0600 通过、0644 拒绝、缺失透传 FileNotFound" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const ok_path = "/tmp/scoot_secret_ok";
    const bad_path = "/tmp/scoot_secret_bad";
    defer cwd.deleteFile(io, ok_path) catch {};
    defer cwd.deleteFile(io, bad_path) catch {};

    try writeFileMode(io, ok_path, "tok", 0o600);
    try assertPrivate(io, ok_path); // 0600：无异常

    try writeFileMode(io, bad_path, "tok", 0o644);
    try std.testing.expectError(error.InsecurePermissions, assertPrivate(io, bad_path));

    try std.testing.expectError(error.FileNotFound, assertPrivate(io, "/tmp/scoot_secret_nope"));
}

test "resolve: env 优先于 file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/scoot_secret_prio";
    defer cwd.deleteFile(io, path) catch {};
    try writeFileMode(io, path, "FROM_FILE", 0o600);

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("SCOOT_TEST_KEY", "FROM_ENV");

    const s = try resolve(arena, io, &map, &.{
        .{ .env = "SCOOT_TEST_KEY" },
        .{ .file = path },
    });
    try std.testing.expectEqual(std.meta.Tag(Source).env, s.source);
    try std.testing.expectEqualStrings("FROM_ENV", s.value);
}

test "resolve: file 来源——0600 命中并去除尾随换行" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/scoot_secret_file";
    defer cwd.deleteFile(io, path) catch {};
    try writeFileMode(io, path, "sk-TOKEN-123\n", 0o600);

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();

    const s = try resolve(arena, io, &map, &.{
        .{ .env = "SCOOT_ABSENT_ENV" }, // 未设 → 跳过
        .{ .file = path },
    });
    try std.testing.expectEqual(std.meta.Tag(Source).file, s.source);
    try std.testing.expectEqualStrings("sk-TOKEN-123", s.value); // 尾随 \n 已去除
}

test "resolve: file 来源权限过宽 → InsecurePermissions（不降级、不读入内存）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/scoot_secret_insecure";
    defer cwd.deleteFile(io, path) catch {};
    try writeFileMode(io, path, "leaked", 0o644);

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();

    try std.testing.expectError(error.InsecurePermissions, resolve(arena, io, &map, &.{
        .{ .file = path },
    }));
}

test "resolve: file 缺失 → 跳到下一来源（env 兜底）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("SCOOT_FALLBACK_KEY", "FALLBACK");

    const s = try resolve(arena, io, &map, &.{
        .{ .file = "/tmp/scoot_secret_missing_xyz" }, // 不存在 → 跳过
        .{ .env = "SCOOT_FALLBACK_KEY" },
    });
    try std.testing.expectEqual(std.meta.Tag(Source).env, s.source);
    try std.testing.expectEqualStrings("FALLBACK", s.value);
}

test "resolve: command 来源——stdout 即 token（去尾随换行）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();

    const s = try resolve(arena, io, &map, &.{
        .{ .command = "printf 'sk-CMD-456\\n'" },
    });
    try std.testing.expectEqual(std.meta.Tag(Source).command, s.source);
    try std.testing.expectEqualStrings("sk-CMD-456", s.value);
}

test "resolve: command 非零退出 → 跳过；全部落空 → NoApiKey" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();

    try std.testing.expectError(error.NoApiKey, resolve(arena, io, &map, &.{
        .{ .command = "exit 7" }, // 失败 → 跳过
        .{ .env = "SCOOT_DEFINITELY_ABSENT" }, // 未设 → 跳过
    }));
}
