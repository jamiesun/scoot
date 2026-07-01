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

/// Env var name fragments that commonly carry secrets. Matched case-insensitively
/// as a substring of the variable NAME, not the value, so `OPENAI_API_KEY`,
/// `AWS_SECRET_ACCESS_KEY`, `REMOTE_MCP_TOKEN`, and `DB_PASSWORD` are all caught
/// without needing an exhaustive exact-name list.
pub const secret_env_name_fragments = [_][]const u8{
    "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL",
};

/// Reports whether an environment variable name looks secret-bearing by the
/// patterns above.
pub fn isSecretEnvName(name: []const u8) bool {
    for (secret_env_name_fragments) |frag| {
        if (containsIgnoreCase(name, frag)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn containsExactName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Builds a subprocess-safe copy of `source`: every variable is kept except
/// those matching a secret-name pattern (`isSecretEnvName`) or explicitly named
/// in `extra_names` (typically the configured `backend.api_key_env`, in case a
/// custom name does not match a generic pattern). The result is allocated from
/// `arena` and is meant to be handed to `std.process.RunOptions.environ_map`,
/// which REPLACES rather than merges with the child environment.
///
/// This defends Hard Rule 7 (issue #190): a model-triggered bash subprocess
/// must not receive ambient credential env vars just because the parent Scoot
/// process happened to have them (e.g. the backend API token). It is
/// deliberately a denylist, not an allowlist, so ordinary variables such as
/// PATH/HOME/LANG keep working for legitimate shell commands.
pub fn scrubEnvForSubprocess(
    arena: std.mem.Allocator,
    source: *const Environ.Map,
    extra_names: []const []const u8,
) !Environ.Map {
    var out: Environ.Map = .init(arena);
    var it = source.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (isSecretEnvName(name)) continue;
        if (containsExactName(extra_names, name)) continue;
        try out.put(name, entry.value_ptr.*);
    }
    return out;
}

/// Collects the plaintext values of every ambient environment variable whose
/// NAME looks secret-bearing (`isSecretEnvName`) or is explicitly listed in
/// `extra_names` (typically a custom-named `backend.api_key_env`). Companion
/// to `scrubEnvForSubprocess`, which removes the same variables from a bash
/// subprocess environment; this instead surfaces their values so callers can
/// redact them out of persisted audit/trace/event/hook text (issue #189).
/// Empty values are skipped since there is nothing to match against.
pub fn collectSecretEnvValues(
    arena: std.mem.Allocator,
    env: *const Environ.Map,
    extra_names: []const []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = env.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value.len == 0) continue;
        if (isSecretEnvName(name) or containsExactName(extra_names, name)) {
            try list.append(arena, value);
        }
    }
    return list.items;
}

/// Placeholder written in place of every redacted secret occurrence.
pub const redaction_placeholder = "[REDACTED]";

/// Secret values shorter than this are never scanned for in `redactSecretsInText`:
/// a very short "secret" (e.g. a stray 2-3 char env value) is far more likely to
/// be a false positive than genuine credential material, and redacting a common
/// short substring would mangle unrelated text. Real tokens/keys are comfortably
/// longer than this.
const min_redact_secret_len: usize = 6;

/// Replaces every occurrence of any sufficiently long value in `secrets` found
/// inside `text` with `redaction_placeholder`. Unlike `redact`, which replaces a
/// value already known to be a whole secret, this scans arbitrary text that may
/// merely *contain* a secret as a substring — the shape needed to scrub tool
/// input/output, trace lines, structured events, and PostToolUse hook payloads
/// before they reach a persisted/observable channel (issue #189). Returns `text`
/// unchanged, with no allocation, when nothing matches.
pub fn redactSecretsInText(
    arena: std.mem.Allocator,
    text: []const u8,
    secrets: []const []const u8,
) ![]const u8 {
    if (text.len == 0) return text;
    var hit = false;
    for (secrets) |s| {
        if (s.len >= min_redact_secret_len and std.mem.indexOf(u8, text, s) != null) {
            hit = true;
            break;
        }
    }
    if (!hit) return text;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    scan: while (i < text.len) {
        for (secrets) |s| {
            if (s.len < min_redact_secret_len) continue;
            if (i + s.len <= text.len and std.mem.eql(u8, text[i .. i + s.len], s)) {
                try out.appendSlice(arena, redaction_placeholder);
                i += s.len;
                continue :scan;
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}

test {
    std.testing.refAllDecls(@This());
}

test "isSecretEnvName: matches common secret patterns case-insensitively and spares ordinary vars" {
    try std.testing.expect(isSecretEnvName("OPENAI_API_KEY"));
    try std.testing.expect(isSecretEnvName("REMOTE_MCP_TOKEN"));
    try std.testing.expect(isSecretEnvName("AWS_SECRET_ACCESS_KEY"));
    try std.testing.expect(isSecretEnvName("db_password"));
    try std.testing.expect(isSecretEnvName("GH_PASSWD"));
    try std.testing.expect(isSecretEnvName("SOME_CREDENTIAL_PATH"));
    try std.testing.expect(!isSecretEnvName("PATH"));
    try std.testing.expect(!isSecretEnvName("HOME"));
    try std.testing.expect(!isSecretEnvName("LANG"));
    try std.testing.expect(!isSecretEnvName("SCOOT_LOG_LEVEL"));
}

test "scrubEnvForSubprocess: drops secret-named and explicit extra vars, keeps the rest" {
    const gpa = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var src: std.process.Environ.Map = .init(gpa);
    defer src.deinit();
    try src.put("PATH", "/usr/bin");
    try src.put("OPENAI_API_KEY", "sk-should-not-leak");
    try src.put("CUSTOM_ENV_NAME", "should-not-leak-either");
    try src.put("SCOOT_LOG_LEVEL", "debug");

    var scrubbed = try scrubEnvForSubprocess(arena, &src, &.{"CUSTOM_ENV_NAME"});
    try std.testing.expectEqualStrings("/usr/bin", scrubbed.get("PATH").?);
    try std.testing.expectEqualStrings("debug", scrubbed.get("SCOOT_LOG_LEVEL").?);
    try std.testing.expect(scrubbed.get("OPENAI_API_KEY") == null);
    try std.testing.expect(scrubbed.get("CUSTOM_ENV_NAME") == null);
    try std.testing.expectEqual(@as(usize, 2), scrubbed.count());
}

test "collectSecretEnvValues: surfaces values of secret-named and explicit extra vars only (issue #189)" {
    const gpa = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var src: std.process.Environ.Map = .init(gpa);
    defer src.deinit();
    try src.put("PATH", "/usr/bin");
    try src.put("OPENAI_API_KEY", "sk-should-be-collected");
    try src.put("CUSTOM_ENV_NAME", "collected-too");
    try src.put("EMPTY_SECRET_TOKEN", "");

    const values = try collectSecretEnvValues(arena, &src, &.{"CUSTOM_ENV_NAME"});
    try std.testing.expectEqual(@as(usize, 2), values.len);
    var saw_key = false;
    var saw_custom = false;
    for (values) |v| {
        if (std.mem.eql(u8, v, "sk-should-be-collected")) saw_key = true;
        if (std.mem.eql(u8, v, "collected-too")) saw_custom = true;
    }
    try std.testing.expect(saw_key);
    try std.testing.expect(saw_custom);
}

test "redactSecretsInText: replaces every occurrence of known secret values and ignores short noise" {
    const gpa = std.testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const secrets = [_][]const u8{ "sk-live-abcdef123456", "ab" }; // "ab" is below min length, must not mangle text.
    const text = "token=sk-live-abcdef123456 (again: sk-live-abcdef123456) abstract";
    const got = try redactSecretsInText(arena, text, &secrets);
    try std.testing.expect(std.mem.indexOf(u8, got, "sk-live-abcdef123456") == null);
    try std.testing.expectEqualStrings(
        "token=[REDACTED] (again: [REDACTED]) abstract",
        got,
    );

    // No match: returns the input unchanged (same pointer, no allocation).
    const unchanged = try redactSecretsInText(arena, "nothing secret here", &secrets);
    try std.testing.expectEqualStrings("nothing secret here", unchanged);

    // Empty secret list is a no-op.
    const no_secrets = try redactSecretsInText(arena, text, &.{});
    try std.testing.expectEqualStrings(text, no_secrets);
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
