//! Runtime path resolution: `~/.scoot/` is Scoot's home and runtime directory.
//! Resolution priority: CLI `--scoot-home`, handled by main, then SCOOT_HOME,
//! then `$HOME/.scoot`. This module only resolves path strings; actual directory
//! creation and I/O go through `Io` in ensure.
const std = @import("std");
const Environ = std.process.Environ;

pub const Paths = struct {
    /// Runtime root directory, defaulting to ~/.scoot.
    home: []const u8,
    /// Main JSON config file: <home>/config.json.
    config_file: []const u8,
    /// TOML config file: <home>/config.toml, preferred over config.json.
    config_toml_file: []const u8,
    /// Default token file: <home>/token, requiring 0600.
    token_file: []const u8,
    /// User-level skill directory: <home>/skills.
    skills_dir: []const u8,
    /// Cross-agent user skill directory: $HOME/.agents/skills, independent of
    /// SCOOT_HOME. Null when $HOME is unavailable. Only `resolve` fills this;
    /// `fromHome`, used for explicit home and tests, leaves it null.
    agents_skills_dir: ?[]const u8 = null,
    /// Audit and runtime log directory: <home>/logs.
    logs_dir: []const u8,
    /// Local state directory for scheduled jobs, sessions, and similar state.
    state_dir: []const u8,
    /// Persisted session directory: <home>/state/sessions.
    sessions_dir: []const u8,

    /// Resolves runtime paths. All returned strings are owned by `arena`.
    pub fn resolve(arena: std.mem.Allocator, env: *const Environ.Map) !Paths {
        // Keep real $HOME separate from SCOOT_HOME: cross-agent ~/.agents/skills
        // is always relative to the actual home directory, even if SCOOT_HOME
        // moves Scoot runtime state elsewhere.
        const user_home = env.get("HOME");
        const home = env.get("SCOOT_HOME") orelse blk: {
            const h = user_home orelse return error.NoHomeDir;
            break :blk try std.fs.path.join(arena, &.{ h, ".scoot" });
        };
        var p = try fromHome(arena, home);
        if (user_home) |h|
            p.agents_skills_dir = try std.fs.path.join(arena, &.{ h, ".agents", "skills" });
        return p;
    }

    /// Derives the full runtime tree from an explicit home directory.
    pub fn fromHome(arena: std.mem.Allocator, home: []const u8) !Paths {
        const state_dir = try std.fs.path.join(arena, &.{ home, "state" });
        return .{
            .home = home,
            .config_file = try std.fs.path.join(arena, &.{ home, "config.json" }),
            .config_toml_file = try std.fs.path.join(arena, &.{ home, "config.toml" }),
            .token_file = try std.fs.path.join(arena, &.{ home, "token" }),
            .skills_dir = try std.fs.path.join(arena, &.{ home, "skills" }),
            .logs_dir = try std.fs.path.join(arena, &.{ home, "logs" }),
            .state_dir = state_dir,
            .sessions_dir = try std.fs.path.join(arena, &.{ state_dir, "sessions" }),
        };
    }

    /// Ensures the runtime directory and subdirectories exist idempotently, and
    /// tightens them to owner read/write/execute. Session transcripts and audit
    /// logs may contain prompts, model output, and file content, so directories
    /// must not inherit a same-host-readable umask.
    pub fn ensure(self: Paths, io: std.Io) !void {
        try ensurePrivateDir(io, self.home);
        try ensurePrivateDir(io, self.skills_dir);
        try ensurePrivateDir(io, self.logs_dir);
        try ensurePrivateDir(io, self.state_dir);
        try ensurePrivateDir(io, self.sessions_dir);
    }
};

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, path, std.Io.File.Permissions.fromMode(0o700));
    try cwd.setFilePermissions(io, path, std.Io.File.Permissions.fromMode(0o700), .{});
}

/// Whether `child` is inside `parent`, including equality. Both should be
/// normalized absolute realpaths. String-only check reused by symlink escape
/// guards across modules (issues #41, #52, #54). Separator-boundary matching
/// prevents prefix confusion such as `/a/bc` under `/a/b`.
pub fn within(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    return child[parent.len] == std.fs.path.sep;
}

/// Symlink escape guard for read paths (#41 skill reads, #54 wasm validation):
/// realpath-normalize `dir` and existing `full`, then check whether full escapes
/// dir. Any realpath failure, such as missing target or unsupported platform,
/// returns false because escape cannot be confirmed; the caller's later open/read
/// will fail naturally, and missing targets leak no content.
pub fn realPathEscapes(io: std.Io, arena: std.mem.Allocator, dir: []const u8, full: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const real_dir = cwd.realPathFileAlloc(io, dir, arena) catch return false;
    const real_full = cwd.realPathFileAlloc(io, full, arena) catch return false;
    return !within(real_full, real_dir);
}

/// Symlink escape guard for write paths (#52, aligned with #41 read handling):
/// the realpath-normalized parent directory of relative `target`, which may not
/// exist yet, must still be within project-root `base`. Lexical checks banning
/// absolute paths and `..` are only a prefilter; writes follow symlinks. The
/// parent directory is the actual write landing point, so realpath catches
/// preexisting `link -> /etc` escapes. Missing parent -> realpath failure ->
/// false because the write itself will fail.
pub fn writeEscapesBase(io: std.Io, arena: std.mem.Allocator, base: []const u8, target: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const real_base = cwd.realPathFileAlloc(io, base, arena) catch return false;
    const parent_rel = std.fs.path.dirname(target) orelse ".";
    const parent_path = std.fs.path.join(arena, &.{ base, parent_rel }) catch return false;
    const real_parent = cwd.realPathFileAlloc(io, parent_path, arena) catch return false;
    if (!within(real_parent, real_base)) return true;

    const target_path = std.fs.path.join(arena, &.{ base, target }) catch return false;
    const lst = cwd.statFile(io, target_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    if (lst.kind == .sym_link) return true;

    const real_target = cwd.realPathFileAlloc(io, target_path, arena) catch return false;
    return !within(real_target, real_base);
}

test {
    std.testing.refAllDecls(@This());
}

test "within: sep boundary check prevents prefix confusion" {
    try std.testing.expect(within("/a/b", "/a/b"));
    try std.testing.expect(within("/a/b/c", "/a/b"));
    try std.testing.expect(!within("/a/bc", "/a/b"));
    try std.testing.expect(!within("/a", "/a/b"));
}

test "realPathEscapes detects skill and base directory symlink escapes (issue #41/#54)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_realpath_escapes_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/pkg");
    try cwd.createDirPath(io, root ++ "/outside");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/pkg/in.txt", .data = "IN" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/outside/secret.txt", .data = "OUT" });
    cwd.symLink(io, root ++ "/outside/secret.txt", root ++ "/pkg/leak", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(realPathEscapes(io, arena, root ++ "/pkg", root ++ "/pkg/leak"));
    try std.testing.expect(!realPathEscapes(io, arena, root ++ "/pkg", root ++ "/pkg/in.txt"));
    // Missing target: escape cannot be confirmed, so later read should fail naturally.
    try std.testing.expect(!realPathEscapes(io, arena, root ++ "/pkg", root ++ "/pkg/missing"));
}

test "writeEscapesBase: precreated symlink write escape detection(issue #52)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_write_escapes_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/proj/sub");
    try cwd.createDirPath(io, root ++ "/outside");
    cwd.symLink(io, root ++ "/outside", root ++ "/proj/link", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = root ++ "/proj";
    // Valid in-project write: parent directory stays inside base.
    try std.testing.expect(!writeEscapesBase(io, arena, base, "sub/file.txt"));
    try std.testing.expect(!writeEscapesBase(io, arena, base, "file.txt"));
    // Write through a preexisting symlink: parent realpath lands outside -> escape.
    try std.testing.expect(writeEscapesBase(io, arena, base, "link/escape.txt"));
}

test "writeEscapesBase: final path component symlink is rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_write_final_symlink_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/proj/sub");
    try cwd.createDirPath(io, root ++ "/outside");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/outside/target.txt", .data = "OUT" });
    cwd.symLink(io, root ++ "/outside/target.txt", root ++ "/proj/sub/out", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(writeEscapesBase(io, arena, root ++ "/proj", "sub/out"));
    try std.testing.expect(!writeEscapesBase(io, arena, root ++ "/proj", "sub/new.txt"));
}

test "fromHome: derives runtime tree from explicit home" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try Paths.fromHome(arena_state.allocator(), "/tmp/scoot_explicit_home");

    try std.testing.expectEqualStrings("/tmp/scoot_explicit_home", p.home);
    try std.testing.expectEqualStrings("/tmp/scoot_explicit_home/config.toml", p.config_toml_file);
    try std.testing.expectEqualStrings("/tmp/scoot_explicit_home/logs", p.logs_dir);
    try std.testing.expectEqualStrings("/tmp/scoot_explicit_home/state/sessions", p.sessions_dir);
}

test "ensure creates runtime directories" {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const home = "/tmp/scoot_paths_test";
    cwd.deleteTree(io, home) catch {};
    defer cwd.deleteTree(io, home) catch {};

    const p: Paths = .{
        .home = home,
        .config_file = home ++ "/config.json",
        .config_toml_file = home ++ "/config.toml",
        .token_file = home ++ "/token",
        .skills_dir = home ++ "/skills",
        .logs_dir = home ++ "/logs",
        .state_dir = home ++ "/state",
        .sessions_dir = home ++ "/state/sessions",
    };
    try p.ensure(io); // First creation.
    try p.ensure(io); // Second call must be idempotent.

    // Subdirectory should open as a directory, proving existence.
    var d = try cwd.openDir(io, p.sessions_dir, .{});
    d.close(io);

    const st = try cwd.statFile(io, p.sessions_dir, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), st.permissions.toMode() & 0o777);
}
