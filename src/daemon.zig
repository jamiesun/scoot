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

/// 进程存活探测（issue #53）：用 signal 0 探针判断 `pid` 是否对应一个仍存活的进程。
///
/// 设计取舍：项目未链接 libc，且 0.16 无 `std.posix.flock`/`open`，故不引入文件锁或
/// 全量监督，仅做轻量探活以缩小失败模式（陈旧 PID、误判 running）。signal 0 不会真正投递
/// 信号，只触发内核的权限/存在性检查：
///   - 成功返回         → 进程存在且本进程有权限 → 存活
///   - error.PermissionDenied → 进程存在但属于他人 → 仍视为存活
///   - 其它（ProcessNotFound 等） → 进程不存在 → 非存活
/// 残留风险：PID 复用可能把“恰好复用同号的新进程”误判为存活，这是无进程身份信息时不可消除的，
/// 已在 issue #53 中作为可接受的文档化残留。pid <= 0 一律视为非存活（避免 kill 的进程组语义）。
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

test "pidAlive: current process alive, invalid and unused pids dead (issue #53)" {
    // 当前进程必然存活。
    const self_pid: i64 = @intCast(std.posix.system.getpid());
    try std.testing.expect(pidAlive(self_pid));

    // 非法 pid（<=0）一律视为非存活，避免触发 kill 的进程组语义。
    try std.testing.expect(!pidAlive(0));
    try std.testing.expect(!pidAlive(-1));

    // 一个几乎不可能被占用的超大 pid：探针应判为非存活。
    try std.testing.expect(!pidAlive(2_000_000_000));
}

test {
    std.testing.refAllDecls(@This());
}
