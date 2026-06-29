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

pub const status_format = "scoot.daemon.status.v1";

pub const Liveness = enum {
    alive,
    dead,
    unknown,
};

pub const StatusSnapshot = struct {
    format: []const u8 = status_format,
    state_path: []const u8,
    pid_path: []const u8,
    state: ?State,
    pid_file: ?i64,
    liveness: Liveness,
    probed_pid: ?i64,
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

pub fn statusSnapshot(arena: std.mem.Allocator, io: std.Io, state_dir: []const u8) !StatusSnapshot {
    const state = try readState(arena, io, state_dir);
    const pid_file = try readPid(arena, io, state_dir);
    const probe_pid: ?i64 = if (pid_file) |p| p else if (state) |s| s.pid else null;
    const liveness: Liveness = if (probe_pid) |p|
        if (pidAlive(p)) .alive else .dead
    else
        .unknown;
    return .{
        .state_path = try statePath(arena, state_dir),
        .pid_path = try pidPath(arena, state_dir),
        .state = state,
        .pid_file = pid_file,
        .liveness = liveness,
        .probed_pid = probe_pid,
    };
}

pub fn writeStatusJson(out: *std.Io.Writer, snapshot: StatusSnapshot) !void {
    try std.json.Stringify.value(snapshot, .{}, out);
    try out.writeByte('\n');
}

pub fn previousRunWasUnclean(state: ?State) bool {
    const s = state orelse return false;
    return std.mem.eql(u8, s.status, "running");
}

/// Process liveness probe (issue #53): use signal 0 to check whether `pid`
/// still belongs to a live process.
///
/// Tradeoff: the project does not link libc, and Zig 0.16 lacks
/// `std.posix.flock`/`open`, so this avoids file locks or full supervision.
/// The lightweight probe narrows stale-PID and false-running failure modes.
/// Signal 0 does not deliver a real signal; it only asks the kernel to check
/// permission and existence:
///   - success -> process exists and is accessible -> alive
///   - error.PermissionDenied -> process exists but belongs to another user -> alive
///   - anything else, such as ProcessNotFound -> not alive
/// Residual risk: PID reuse can misclassify a new process with the same PID as
/// alive. Without process identity metadata this cannot be eliminated, and is
/// documented as accepted residual risk in issue #53. pid <= 0 is always dead
/// to avoid `kill` process-group semantics.
pub fn pidAlive(pid: i64) bool {
    if (pid <= 0) return false;
    const sig0: std.posix.SIG = @enumFromInt(0);
    std.posix.kill(@intCast(pid), sig0) catch |err| switch (err) {
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
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

    const snapshot = try statusSnapshot(arena, io, root);
    try std.testing.expectEqualStrings("scoot.daemon.status.v1", snapshot.format);
    try std.testing.expectEqual(@as(?i64, 123), snapshot.pid_file);
    try std.testing.expectEqual(@as(?i64, 123), snapshot.probed_pid);
    try std.testing.expectEqual(Liveness.dead, snapshot.liveness);

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

test "status snapshot serializes as machine-readable JSON" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_daemon_status_json_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snapshot = try statusSnapshot(arena, io, root);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeStatusJson(&aw.writer, snapshot);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.writer.buffered(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("scoot.daemon.status.v1", obj.get("format").?.string);
    try std.testing.expectEqualStrings("unknown", obj.get("liveness").?.string);
    try std.testing.expect(obj.get("state").? == .null);
    try std.testing.expect(obj.get("pid_file").? == .null);
}

test "pidAlive: current process alive, invalid and unused pids dead (issue #53)" {
    // The current process must be alive.
    const self_pid: i64 = @intCast(std.posix.system.getpid());
    try std.testing.expect(pidAlive(self_pid));

    // Invalid pids (<=0) are always dead to avoid kill process-group semantics.
    try std.testing.expect(!pidAlive(0));
    try std.testing.expect(!pidAlive(-1));

    // A huge, nearly impossible pid should probe as dead.
    try std.testing.expect(!pidAlive(2_000_000_000));
}

test {
    std.testing.refAllDecls(@This());
}
