//! Daemon lifecycle state for foreground long-running Scoot processes.
//!
//! This module does not fork or supervise processes. It owns the small on-disk
//! state contract used by `scoot daemon run/status/stop`.
const std = @import("std");

pub const format = "scoot.daemon.state.v1";

pub const State = struct {
    format: []const u8 = format,
    status: []const u8,
    pid: i64,
    started_at_unix: i64,
    updated_at_unix: i64,
    stopped_at_unix: ?i64 = null,
    stop_reason: ?[]const u8 = null,
    schedule_enabled: bool,
    jobs: usize,
    poll_ms: u64,
    note: []const u8 = "daemon run is foreground; scheduled jobs keep using effective readonly mode unless explicitly unrestricted",
};

pub fn statePath(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, "daemon.json" });
}

pub fn pidPath(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ state_dir, "daemon.pid" });
}

pub fn writeState(arena: std.mem.Allocator, io: std.Io, state_dir: []const u8, state: State) !void {
    const path = try statePath(arena, state_dir);
    var aw = std.Io.Writer.Allocating.init(arena);
    try std.json.Stringify.value(state, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

pub fn writePid(arena: std.mem.Allocator, io: std.Io, state_dir: []const u8, pid: i64) !void {
    const path = try pidPath(arena, state_dir);
    const bytes = try std.fmt.allocPrint(arena, "{d}\n", .{pid});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn readState(arena: std.mem.Allocator, io: std.Io, state_dir: []const u8) !?State {
    const path = try statePath(arena, state_dir);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return std.json.parseFromSliceLeaky(State, arena, bytes, .{
        .ignore_unknown_fields = true,
    }) catch error.InvalidDaemonState;
}

pub fn readPid(arena: std.mem.Allocator, io: std.Io, state_dir: []const u8) !?i64 {
    const path = try pidPath(arena, state_dir);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(128)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch error.InvalidDaemonPid;
}

pub fn clearPid(arena: std.mem.Allocator, io: std.Io, state_dir: []const u8) void {
    const path = pidPath(arena, state_dir) catch return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub fn previousRunWasUnclean(state: ?State) bool {
    const s = state orelse return false;
    return std.mem.eql(u8, s.status, "running");
}

test "statePath and pidPath live under state directory" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("/tmp/scoot/state/daemon.json", try statePath(arena, "/tmp/scoot/state"));
    try std.testing.expectEqualStrings("/tmp/scoot/state/daemon.pid", try pidPath(arena, "/tmp/scoot/state"));
}

test "write/read daemon state and pid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_daemon_state_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try writeState(arena, io, root, .{
        .status = "running",
        .pid = 123,
        .started_at_unix = 10,
        .updated_at_unix = 11,
        .schedule_enabled = true,
        .jobs = 2,
        .poll_ms = 1000,
    });
    try writePid(arena, io, root, 123);

    const state = (try readState(arena, io, root)) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("scoot.daemon.state.v1", state.format);
    try std.testing.expectEqualStrings("running", state.status);
    try std.testing.expectEqual(@as(i64, 123), state.pid);
    try std.testing.expect(previousRunWasUnclean(state));
    try std.testing.expectEqual(@as(?i64, 123), try readPid(arena, io, root));

    clearPid(arena, io, root);
    try std.testing.expect((try readPid(arena, io, root)) == null);
}

test "previousRunWasUnclean only flags running state" {
    try std.testing.expect(!previousRunWasUnclean(null));
    try std.testing.expect(previousRunWasUnclean(.{
        .status = "running",
        .pid = 1,
        .started_at_unix = 1,
        .updated_at_unix = 1,
        .schedule_enabled = true,
        .jobs = 1,
        .poll_ms = 1000,
    }));
    try std.testing.expect(!previousRunWasUnclean(.{
        .status = "stopped",
        .pid = 1,
        .started_at_unix = 1,
        .updated_at_unix = 2,
        .stopped_at_unix = 2,
        .stop_reason = "ticks",
        .schedule_enabled = true,
        .jobs = 1,
        .poll_ms = 1000,
    }));
}

test {
    std.testing.refAllDecls(@This());
}
