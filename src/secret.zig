//! Secret (API token) safety management.
//!
//! Core principle: plaintext secrets are never written to config.json or casual
//! disk storage by default. Tokens live briefly in memory, are released with the
//! process, and are never written to logs or audit.
//!
//! Resolution priority, highest to lowest, tries each source until one succeeds:
//!   1) Environment variable, default OPENAI_API_KEY and configurable through
//!      config.backend.api_key_env.
//!   2) Standalone token file, default ~/.scoot/token, requiring 0600.
//!   3) Credential command api_key_cmd, such as `pass show openai` or a keychain
//!      read command, whose stdout is the token. External tools provide secure
//!      storage without platform keychain coupling.
//! `Source.inline_value` is supported at the library layer, but config
//! intentionally does not expose it to prevent plaintext secrets in repository
//! config. It remains only for tests or embedding.
const std = @import("std");
const Environ = std.process.Environ;
const bash = @import("tools/bash.zig");

/// One token source.
pub const Source = union(enum) {
    /// Environment variable name.
    env: []const u8,
    /// Token file path requiring 0600.
    file: []const u8,
    /// Credential command; stdout is the token.
    command: []const u8,
    /// Inline plaintext, not recommended.
    inline_value: []const u8,
};

pub const Secret = struct {
    value: []const u8,
    source: std.meta.Tag(Source),
};

/// Credential command hard timeout in milliseconds.
const command_timeout_ms: u64 = 10_000;
/// Token file / command output size cap: far above valid tokens, below huge files.
const token_size_limit: usize = 64 * 1024;

/// Resolves a token by priority. `io` is used for files and credential commands.
///
/// Unavailable sources, such as unset env, missing file, failed command, or empty
/// output, fall through to the next source. The one hard failure is an existing
/// token file with broad permissions (`InsecurePermissions`), which refuses
/// downgrade because world-readable secret files must never be read.
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
            // Check permissions before reading: any group/other bit is rejected,
            // like SSH keys or .netrc. Missing file falls through; broad
            // permissions fail explicitly and are never read into memory.
            assertPrivate(io, path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(token_size_limit)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            const tok = std.mem.trim(u8, raw, " \t\r\n");
            if (tok.len == 0) continue; // Empty file: skip.
            return .{ .value = tok, .source = .file };
        },
        .command => |cmd| {
            // Credential command, e.g. `pass show openai`: stdout is the token.
            // It is trusted user config and does not go through policy, but it
            // still has a hard timeout. Failures, timeouts, and empty output skip.
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

/// Verifies a secret file is not open to group/other, like SSH/.netrc. Broad
/// permissions return `InsecurePermissions`. Missing files propagate
/// `FileNotFound`, allowing fallback. Non-POSIX platforms without mode_t skip
/// this because Unix permission bits do not exist there.
pub fn assertPrivate(io: std.Io, path: []const u8) !void {
    const Perm = std.Io.File.Permissions;
    if (comptime !@hasDecl(Perm, "toMode")) return; // Non-POSIX: no mode_t to check.
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (st.permissions.toMode() & 0o077 != 0) return error.InsecurePermissions;
}

/// Log redaction: pass secrets through this before printing.
pub fn redact(value: []const u8) []const u8 {
    _ = value;
    return "****";
}

test {
    std.testing.refAllDecls(@This());
}

/// Test helper: writes a temp file and forces exact permissions, bypassing umask.
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

test "assertPrivate: 0600 accepts 0600, rejects 0644, and passes through FileNotFound" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const ok_path = "/tmp/scoot_secret_ok";
    const bad_path = "/tmp/scoot_secret_bad";
    defer cwd.deleteFile(io, ok_path) catch {};
    defer cwd.deleteFile(io, bad_path) catch {};

    try writeFileMode(io, ok_path, "tok", 0o600);
    try assertPrivate(io, ok_path); // 0600: ok.

    try writeFileMode(io, bad_path, "tok", 0o644);
    try std.testing.expectError(error.InsecurePermissions, assertPrivate(io, bad_path));

    try std.testing.expectError(error.FileNotFound, assertPrivate(io, "/tmp/scoot_secret_nope"));
}

test "resolve: env takes precedence over file" {
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

test "resolve: file source--0600 matchedand trims trailing newline" {
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
        .{ .env = "SCOOT_ABSENT_ENV" }, // Unset: skip.
        .{ .file = path },
    });
    try std.testing.expectEqual(std.meta.Tag(Source).file, s.source);
    try std.testing.expectEqualStrings("sk-TOKEN-123", s.value); // Trailing \n removed.
}

test "resolve: file sourcetoo-broad permissions return InsecurePermissions without fallback or reading into memory" {
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

test "resolve: file missing file falls through to next source with env fallback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("SCOOT_FALLBACK_KEY", "FALLBACK");

    const s = try resolve(arena, io, &map, &.{
        .{ .file = "/tmp/scoot_secret_missing_xyz" }, // Missing: skip.
        .{ .env = "SCOOT_FALLBACK_KEY" },
    });
    try std.testing.expectEqual(std.meta.Tag(Source).env, s.source);
    try std.testing.expectEqualStrings("FALLBACK", s.value);
}

test "resolve: command source uses stdout as token and trims trailing newline" {
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

test "resolve: command nonzero exit is skipped; all missing returns NoApiKey" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();

    try std.testing.expectError(error.NoApiKey, resolve(arena, io, &map, &.{
        .{ .command = "exit 7" }, // Failure: skip.
        .{ .env = "SCOOT_DEFINITELY_ABSENT" }, // Unset: skip.
    }));
}
