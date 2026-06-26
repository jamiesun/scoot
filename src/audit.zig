//! Audit log: every thought and tool call leaves a replayable trace.
//! Each line is JSONL:
//! `{"seq":N,"ts":MS,"session_id":"...","kind":"...","msg":"..."}`.
//! `msg` is JSON-escaped, so newlines or quotes in bash output cannot break
//! the line structure and can be replayed line by line with `std.json`.
//!
//! `seq` is monotonic within each Logger instance, starting at 0. `ts` is the
//! wall-clock event time in Unix milliseconds. Together they let appended logs
//! reconstruct order, latency, and external correlations, and distinguish
//! concurrent events in the same millisecond, such as parallel subcalls. File
//! append order alone cannot carry that reliably (issue #31).
const std = @import("std");
const jsonio = @import("jsonio.zig");

pub const default_max_jsonl_bytes: u64 = 10 * 1024 * 1024;

pub const EventKind = enum {
    /// Start marker for one run, written by main with the user goal.
    run,
    thought,
    tool_call,
    observation,
    /// Final answer.
    final,
    /// Command denied by the execution policy gate.
    policy_deny,
    system_error,
};

pub const Stats = struct {
    run: u64 = 0,
    thought: u64 = 0,
    tool_call: u64 = 0,
    observation: u64 = 0,
    final: u64 = 0,
    policy_deny: u64 = 0,
    system_error: u64 = 0,

    pub fn record(self: *Stats, kind: EventKind) void {
        switch (kind) {
            .run => self.run += 1,
            .thought => self.thought += 1,
            .tool_call => self.tool_call += 1,
            .observation => self.observation += 1,
            .final => self.final += 1,
            .policy_deny => self.policy_deny += 1,
            .system_error => self.system_error += 1,
        }
    }

    pub fn total(self: Stats) u64 {
        return self.run + self.thought + self.tool_call + self.observation + self.final + self.policy_deny + self.system_error;
    }
};

/// Writes audit events to the given writer.
pub const Logger = struct {
    writer: *std.Io.Writer,
    /// Reads the real clock to timestamp each event.
    io: std.Io,
    /// Monotonic per-instance event sequence, starting at 0.
    seq: u64 = 0,
    stats: Stats = .{},
    /// Stable correlation for the local session/run that produced this event.
    session_id: ?[]const u8 = null,
    /// Optional finer-grained run correlation for future multi-run sessions.
    run_id: ?[]const u8 = null,

    pub fn init(writer: *std.Io.Writer, io: std.Io) Logger {
        return .{ .writer = writer, .io = io };
    }

    pub fn setContext(self: *Logger, session_id: []const u8, run_id: ?[]const u8) void {
        self.session_id = session_id;
        self.run_id = run_id;
    }

    /// Appends one JSONL audit event. The caller flushes the writer when needed.
    /// Each event includes monotonic `seq` and wall-clock `ts` for timeline replay.
    pub fn log(self: *Logger, kind: EventKind, message: []const u8) !void {
        const w = self.writer;
        const ts_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const seq = self.seq;
        self.seq += 1;
        try w.print("{{\"seq\":{d},\"ts\":{d}", .{ seq, ts_ms });
        if (self.session_id) |session_id| {
            try w.writeAll(",\"session_id\":");
            try jsonio.writeString(w, session_id);
        }
        if (self.run_id) |run_id| {
            try w.writeAll(",\"run_id\":");
            try jsonio.writeString(w, run_id);
        }
        try w.writeAll(",\"kind\":\"");
        try w.writeAll(@tagName(kind));
        try w.writeAll("\",\"msg\":");
        try jsonio.writeString(w, message);
        try w.writeAll("}\n");
        self.stats.record(kind);
    }
};

pub fn rotateFileIfTooLarge(io: std.Io, arena: std.mem.Allocator, path: []const u8, max_bytes: u64) !bool {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (st.size < max_bytes) return false;

    const rotated = try std.fmt.allocPrint(arena, "{s}.1", .{path});
    cwd.deleteFile(io, rotated) catch {};
    try cwd.rename(path, cwd, rotated, io);
    return true;
}

test "log writes parseable JSONL with seq ts and escaping" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = Logger.init(&w, std.testing.io);
    lg.setContext("cli-1", "run-1");
    try lg.log(.thought, "look at \"Logs\"\nnext line");
    try lg.log(.tool_call, "ls -a");

    const Line = struct {
        seq: u64,
        ts: i64,
        session_id: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
        kind: []const u8,
        msg: []const u8,
    };
    var it = std.mem.tokenizeScalar(u8, w.buffered(), '\n');

    const l0 = try std.json.parseFromSlice(Line, std.testing.allocator, it.next().?, .{});
    defer l0.deinit();
    try std.testing.expectEqual(@as(u64, 0), l0.value.seq);
    try std.testing.expect(l0.value.ts >= 0);
    try std.testing.expectEqualStrings("cli-1", l0.value.session_id.?);
    try std.testing.expectEqualStrings("run-1", l0.value.run_id.?);
    try std.testing.expectEqualStrings("thought", l0.value.kind);
    try std.testing.expectEqualStrings("look at \"Logs\"\nnext line", l0.value.msg);

    const l1 = try std.json.parseFromSlice(Line, std.testing.allocator, it.next().?, .{});
    defer l1.deinit();
    try std.testing.expectEqual(@as(u64, 1), l1.value.seq); // Monotonic.
    try std.testing.expect(l1.value.ts >= l0.value.ts); // Wall clock does not move backward.
    try std.testing.expectEqualStrings("tool_call", l1.value.kind);
    try std.testing.expectEqualStrings("ls -a", l1.value.msg);
    try std.testing.expectEqual(@as(u64, 2), lg.stats.total());
    try std.testing.expectEqual(@as(u64, 1), lg.stats.thought);
    try std.testing.expectEqual(@as(u64, 1), lg.stats.tool_call);
}

test "rotateFileIfTooLarge rotates bounded JSONL files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/scoot_audit_rotate.jsonl";
    cwd.deleteFile(io, path) catch {};
    cwd.deleteFile(io, path ++ ".1") catch {};
    defer cwd.deleteFile(io, path) catch {};
    defer cwd.deleteFile(io, path ++ ".1") catch {};
    try cwd.writeFile(io, .{ .sub_path = path, .data = "1234567890" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try std.testing.expect(try rotateFileIfTooLarge(io, arena_state.allocator(), path, 10));
    try std.testing.expect(!fileExists(io, path));
    try std.testing.expect(fileExists(io, path ++ ".1"));
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
