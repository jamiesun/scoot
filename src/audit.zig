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
const jsonl_line_buffer_bytes: usize = (1 << 20) + 4096;

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

pub const Event = struct {
    seq: u64,
    ts: i64,
    session_id: []const u8,
    run_id: ?[]const u8 = null,
    kind: EventKind,
    msg: []const u8,
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

pub fn querySession(arena: std.mem.Allocator, io: std.Io, logs_dir: []const u8, session_id: []const u8) ![]Event {
    const path = try std.fmt.allocPrint(arena, "{s}/audit.jsonl", .{logs_dir});
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer file.close(io);
    const buf = try arena.alloc(u8, jsonl_line_buffer_bytes);
    var fr = file.reader(io, buf);

    var events: std.ArrayList(Event) = .empty;
    while (try readJsonLine(&fr.interface)) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const ev = try parseEventLine(arena, line);
        if (!std.mem.eql(u8, ev.session_id, session_id)) continue;
        try events.append(arena, ev);
    }
    return events.items;
}

pub fn writeEventJsonl(w: *std.Io.Writer, ev: Event) !void {
    try w.print("{{\"seq\":{d},\"ts\":{d},\"session_id\":", .{ ev.seq, ev.ts });
    try jsonio.writeString(w, ev.session_id);
    if (ev.run_id) |run_id| {
        try w.writeAll(",\"run_id\":");
        try jsonio.writeString(w, run_id);
    }
    try w.writeAll(",\"kind\":\"");
    try w.writeAll(@tagName(ev.kind));
    try w.writeAll("\",\"msg\":");
    try jsonio.writeString(w, ev.msg);
    try w.writeAll("}\n");
}

fn parseEventLine(arena: std.mem.Allocator, line: []const u8) !Event {
    const Raw = struct {
        seq: u64,
        ts: i64,
        session_id: ?[]const u8 = null,
        run_id: ?[]const u8 = null,
        kind: []const u8,
        msg: []const u8,
    };
    const parsed = std.json.parseFromSlice(Raw, arena, line, .{ .ignore_unknown_fields = true }) catch return error.InvalidAuditLog;
    const sid = parsed.value.session_id orelse return error.InvalidAuditLog;
    return .{
        .seq = parsed.value.seq,
        .ts = parsed.value.ts,
        .session_id = try arena.dupe(u8, sid),
        .run_id = if (parsed.value.run_id) |rid| try arena.dupe(u8, rid) else null,
        .kind = std.meta.stringToEnum(EventKind, parsed.value.kind) orelse return error.InvalidAuditLog,
        .msg = try arena.dupe(u8, parsed.value.msg),
    };
}

fn readJsonLine(in: *std.Io.Reader) !?[]const u8 {
    const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => {
            const rest = in.take(in.bufferedLen()) catch return null;
            if (rest.len == 0) return null;
            return rest;
        },
        else => return err,
    };
    return std.mem.trimEnd(u8, line, "\r\n");
}

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

/// Default cap on how many retired (non-active) audit generations are kept on
/// disk before the oldest is evicted. Bounds disk usage while still giving a
/// future edge shipper multiple rotations of slack to catch up before any
/// data is permanently lost (issue #187).
pub const default_max_retained_generations: u32 = 8;

/// One durably recorded eviction: the inclusive `[gap_from, gap_to]` range of
/// generation numbers that were deleted by the retention cap before ever
/// being acknowledged, and when. A future edge shipper reads these to emit an
/// explicit `audit_gap` marker for any range it never got to ship, instead of
/// silently missing it.
pub const GapRecord = struct {
    gap_from: u64,
    gap_to: u64,
    ts: i64,
};

/// Outcome of one `rotateGenerational` call.
pub const RotateResult = struct {
    /// Whether the active file was rotated out because it grew past `max_bytes`.
    rotated: bool = false,
    /// The generation that is now active (the fresh, empty file the caller
    /// should create next). Meaningful only when `rotated` is true.
    file_gen: u64 = 0,
    /// Set when the retention cap forced eviction of one or more generations
    /// during this call. Also durably appended to `<path>.gaps.jsonl`
    /// regardless of whether the caller inspects this field.
    gap: ?struct { from: u64, to: u64 } = null,
};

/// Durable rotation cursor for `rotateGenerational`, persisted as a small JSON
/// object in a `<path>.gen` sidecar so it survives process restarts (Scoot is
/// invoked fresh on every run). Always fully rewritten, never appended, so a
/// torn write can only lose the latest rotation's bookkeeping, never corrupt
/// history.
const GenState = struct {
    /// Monotonic generation of the current active (unrotated) file. 0 means
    /// "never rotated / no sidecar yet" and is never a real generation number.
    file_gen: u64 = 0,
    /// Lowest generation number still retained on disk as `<path>.<gen>`.
    /// Anything below this has been evicted by the retention cap and is
    /// recorded in `<path>.gaps.jsonl` instead.
    oldest_retained_gen: u64 = 0,
};

fn genStatePath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.gen", .{path});
}

fn gapLogPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.gaps.jsonl", .{path});
}

fn readGenState(io: std.Io, arena: std.mem.Allocator, path: []const u8) !GenState {
    const cwd = std.Io.Dir.cwd();
    const state_path = try genStatePath(arena, path);
    const content = cwd.readFileAlloc(io, state_path, arena, .limited(1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const parsed = std.json.parseFromSlice(GenState, arena, content, .{ .ignore_unknown_fields = true }) catch return .{};
    var state = parsed.value;
    // Defend against a hand-edited or otherwise inconsistent sidecar: the
    // retention math below assumes oldest_retained_gen <= file_gen, and a
    // u64 underflow there would be a safety panic, not a silent bug.
    if (state.file_gen != 0 and state.oldest_retained_gen > state.file_gen) {
        state.oldest_retained_gen = state.file_gen;
    }
    return state;
}

fn writeGenState(io: std.Io, arena: std.mem.Allocator, path: []const u8, state: GenState) !void {
    const cwd = std.Io.Dir.cwd();
    const state_path = try genStatePath(arena, path);
    const data = try std.fmt.allocPrint(arena, "{{\"file_gen\":{d},\"oldest_retained_gen\":{d}}}\n", .{ state.file_gen, state.oldest_retained_gen });
    try cwd.writeFile(io, .{ .sub_path = state_path, .data = data });
}

fn appendGapRecord(io: std.Io, arena: std.mem.Allocator, path: []const u8, from: u64, to: u64) !void {
    const cwd = std.Io.Dir.cwd();
    const gap_path = try gapLogPath(arena, path);
    const f = try cwd.createFile(io, gap_path, .{ .truncate = false });
    defer f.close(io);
    const st = try f.stat(io);
    var buf: [256]u8 = undefined;
    var fw = f.writer(io, &buf);
    try fw.seekTo(st.size);
    const ts_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    try fw.interface.print("{{\"gap_from\":{d},\"gap_to\":{d},\"ts\":{d}}}\n", .{ from, to, ts_ms });
    try fw.interface.flush();
}

/// Rotates `<path>` to `<path>.<gen>` once it grows past `max_bytes`, tracking
/// a monotonic generation counter durably in a `<path>.gen` sidecar so the
/// cursor survives process restarts. Up to `max_retained_generations` retired
/// segments are kept on disk; once the cap is exceeded, the oldest is deleted
/// and the drop is durably recorded in `<path>.gaps.jsonl` so a future edge
/// shipper can emit an explicit `audit_gap` for any range it never got to
/// ship, rather than silently missing it (issue #187).
///
/// Unlike `rotateFileIfTooLarge` (still used for non-shipped files such as
/// per-session transcripts), this never clobbers a retired segment that has
/// not yet been counted against the retention cap: every rotation gets its
/// own numbered file, so two rotations between shipper polls no longer
/// silently destroys the middle range.
pub fn rotateGenerational(
    io: std.Io,
    arena: std.mem.Allocator,
    path: []const u8,
    max_bytes: u64,
    max_retained_generations: u32,
) !RotateResult {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    if (st.size < max_bytes) return .{};

    var state = try readGenState(io, arena, path);
    if (state.file_gen == 0) {
        // First-ever rotation for this path (or the sidecar was lost): the
        // file that has been accumulating on disk so far is implicitly
        // generation 1.
        state.file_gen = 1;
    }
    // Guard against clobbering an existing retired segment if the sidecar was
    // lost or reset while numbered segments still exist on disk: probe
    // forward to a generation number confirmed free before renaming, rather
    // than trusting a possibly-stale counter.
    while (fileExists(io, try std.fmt.allocPrint(arena, "{s}.{d}", .{ path, state.file_gen }))) {
        state.file_gen += 1;
    }
    if (state.oldest_retained_gen == 0 or state.oldest_retained_gen > state.file_gen) {
        state.oldest_retained_gen = state.file_gen;
    }

    const retiring_gen = state.file_gen;
    const retired_path = try std.fmt.allocPrint(arena, "{s}.{d}", .{ path, retiring_gen });
    try cwd.rename(path, cwd, retired_path, io);
    state.file_gen = retiring_gen + 1;

    var result: RotateResult = .{ .rotated = true, .file_gen = state.file_gen };

    // Retained (frozen) segments now on disk span [oldest_retained_gen, retiring_gen].
    const retained_count = state.file_gen - state.oldest_retained_gen;
    if (retained_count > max_retained_generations) {
        const evict_from = state.oldest_retained_gen;
        var evict_to = evict_from;
        while (state.file_gen - state.oldest_retained_gen > max_retained_generations) {
            const victim = try std.fmt.allocPrint(arena, "{s}.{d}", .{ path, state.oldest_retained_gen });
            cwd.deleteFile(io, victim) catch {};
            evict_to = state.oldest_retained_gen;
            state.oldest_retained_gen += 1;
        }
        try appendGapRecord(io, arena, path, evict_from, evict_to);
        result.gap = .{ .from = evict_from, .to = evict_to };
    }

    try writeGenState(io, arena, path, state);
    return result;
}

/// Reads every durably recorded gap event for `<path>.gaps.jsonl`, in the
/// order they were appended. Returns an empty slice if no gaps have ever
/// occurred, including when the log does not exist yet — the common case.
pub fn readGapLog(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]GapRecord {
    const cwd = std.Io.Dir.cwd();
    const gap_path = try gapLogPath(arena, path);
    var file = cwd.openFile(io, gap_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer file.close(io);
    const buf = try arena.alloc(u8, jsonl_line_buffer_bytes);
    var fr = file.reader(io, buf);

    var records: std.ArrayList(GapRecord) = .empty;
    while (try readJsonLine(&fr.interface)) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(GapRecord, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        try records.append(arena, parsed.value);
    }
    return records.items;
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

test "rotateGenerational rotates into monotonic numbered generations without clobbering history" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/scoot_audit_rotate_gen_basic.jsonl";
    const suffixes = [_][]const u8{ "", ".1", ".2", ".3", ".gen", ".gaps.jsonl" };
    for (suffixes) |suf| {
        const p = try std.fmt.allocPrint(gpa, "{s}{s}", .{ path, suf });
        defer gpa.free(p);
        cwd.deleteFile(io, p) catch {};
    }
    defer for (suffixes) |suf| {
        const p = std.fmt.allocPrint(gpa, "{s}{s}", .{ path, suf }) catch continue;
        defer gpa.free(p);
        cwd.deleteFile(io, p) catch {};
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // First rotation: generation 1 retires to `.1`, generation 2 becomes active.
    try cwd.writeFile(io, .{ .sub_path = path, .data = "1234567890" });
    const r1 = try rotateGenerational(io, arena, path, 10, default_max_retained_generations);
    try std.testing.expect(r1.rotated);
    try std.testing.expectEqual(@as(u64, 2), r1.file_gen);
    try std.testing.expect(r1.gap == null);
    try std.testing.expect(fileExists(io, path ++ ".1"));
    try std.testing.expect(!fileExists(io, path));

    // Second rotation: generation 2 retires to `.2`, `.1` must survive untouched.
    try cwd.writeFile(io, .{ .sub_path = path, .data = "abcdefghij" });
    const r2 = try rotateGenerational(io, arena, path, 10, default_max_retained_generations);
    try std.testing.expect(r2.rotated);
    try std.testing.expectEqual(@as(u64, 3), r2.file_gen);
    try std.testing.expect(fileExists(io, path ++ ".1"));
    try std.testing.expect(fileExists(io, path ++ ".2"));

    const c1 = try cwd.readFileAlloc(io, path ++ ".1", gpa, .limited(64));
    defer gpa.free(c1);
    try std.testing.expectEqualStrings("1234567890", c1);
    const c2 = try cwd.readFileAlloc(io, path ++ ".2", gpa, .limited(64));
    defer gpa.free(c2);
    try std.testing.expectEqualStrings("abcdefghij", c2);

    // A file still under the size threshold is left completely alone.
    try cwd.writeFile(io, .{ .sub_path = path, .data = "small" });
    const r3 = try rotateGenerational(io, arena, path, 10, default_max_retained_generations);
    try std.testing.expect(!r3.rotated);
    try std.testing.expect(fileExists(io, path));
}

test "rotateGenerational evicts past the retention cap and durably records the gap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/scoot_audit_rotate_gen_cap.jsonl";
    const suffixes = [_][]const u8{ "", ".1", ".2", ".3", ".4", ".gen", ".gaps.jsonl" };
    for (suffixes) |suf| {
        const p = try std.fmt.allocPrint(gpa, "{s}{s}", .{ path, suf });
        defer gpa.free(p);
        cwd.deleteFile(io, p) catch {};
    }
    defer for (suffixes) |suf| {
        const p = std.fmt.allocPrint(gpa, "{s}{s}", .{ path, suf }) catch continue;
        defer gpa.free(p);
        cwd.deleteFile(io, p) catch {};
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Cap retention at 2 retired generations: the 3rd rotation must evict gen 1.
    try cwd.writeFile(io, .{ .sub_path = path, .data = "1234567890" });
    const r1 = try rotateGenerational(io, arena, path, 10, 2);
    try std.testing.expect(r1.gap == null);
    try cwd.writeFile(io, .{ .sub_path = path, .data = "1234567890" });
    const r2 = try rotateGenerational(io, arena, path, 10, 2);
    try std.testing.expect(r2.gap == null);
    try std.testing.expect(fileExists(io, path ++ ".1"));
    try std.testing.expect(fileExists(io, path ++ ".2"));

    try cwd.writeFile(io, .{ .sub_path = path, .data = "1234567890" });
    const r3 = try rotateGenerational(io, arena, path, 10, 2);
    try std.testing.expect(r3.rotated);
    try std.testing.expect(r3.gap != null);
    try std.testing.expectEqual(@as(u64, 1), r3.gap.?.from);
    try std.testing.expectEqual(@as(u64, 1), r3.gap.?.to);
    try std.testing.expect(!fileExists(io, path ++ ".1")); // Evicted.
    try std.testing.expect(fileExists(io, path ++ ".2")); // Retained.
    try std.testing.expect(fileExists(io, path ++ ".3")); // Just retired.

    const gaps = try readGapLog(arena, io, path);
    try std.testing.expectEqual(@as(usize, 1), gaps.len);
    try std.testing.expectEqual(@as(u64, 1), gaps[0].gap_from);
    try std.testing.expectEqual(@as(u64, 1), gaps[0].gap_to);
    try std.testing.expect(gaps[0].ts >= 0);
}

test "rotateGenerational never clobbers an existing retired segment after a lost sidecar" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/scoot_audit_rotate_gen_clobber_guard.jsonl";
    const suffixes = [_][]const u8{ "", ".1", ".2", ".gen", ".gaps.jsonl" };
    for (suffixes) |suf| {
        const p = try std.fmt.allocPrint(gpa, "{s}{s}", .{ path, suf });
        defer gpa.free(p);
        cwd.deleteFile(io, p) catch {};
    }
    defer for (suffixes) |suf| {
        const p = std.fmt.allocPrint(gpa, "{s}{s}", .{ path, suf }) catch continue;
        defer gpa.free(p);
        cwd.deleteFile(io, p) catch {};
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Simulate a prior retained generation 1 with no `.gen` sidecar (as if the
    // sidecar were lost): rotateGenerational must not silently overwrite it.
    try cwd.writeFile(io, .{ .sub_path = path ++ ".1", .data = "PRECIOUS-PRIOR-GENERATION" });
    try cwd.writeFile(io, .{ .sub_path = path, .data = "1234567890" });

    const r = try rotateGenerational(io, arena, path, 10, default_max_retained_generations);
    try std.testing.expect(r.rotated);
    const preserved = try cwd.readFileAlloc(io, path ++ ".1", gpa, .limited(64));
    defer gpa.free(preserved);
    try std.testing.expectEqualStrings("PRECIOUS-PRIOR-GENERATION", preserved);
    try std.testing.expect(fileExists(io, path ++ ".2"));
}

test "readGapLog returns an empty slice when no gap sidecar exists" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const gaps = try readGapLog(arena_state.allocator(), io, "/tmp/scoot_audit_no_such_gap_log.jsonl");
    try std.testing.expectEqual(@as(usize, 0), gaps.len);
}

test "querySession filters session-correlated audit events and rewrites JSONL" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_audit_query_session_test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{
        .sub_path = dir ++ "/audit.jsonl",
        .data =
        \\{"seq":0,"ts":10,"session_id":"s1","kind":"run","msg":"goal","extra":true}
        \\{"seq":1,"ts":11,"session_id":"s2","kind":"run","msg":"other"}
        \\{"seq":2,"ts":12,"session_id":"s1","run_id":"r1","kind":"final","msg":"done\nok"}
        \\
        ,
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const events = try querySession(arena, io, dir, "s1");
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(u64, 0), events[0].seq);
    try std.testing.expectEqual(EventKind.run, events[0].kind);
    try std.testing.expectEqualStrings("goal", events[0].msg);
    try std.testing.expectEqual(EventKind.final, events[1].kind);
    try std.testing.expectEqualStrings("r1", events[1].run_id.?);
    try std.testing.expectEqualStrings("done\nok", events[1].msg);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEventJsonl(&w, events[1]);
    const Line = struct {
        seq: u64,
        ts: i64,
        session_id: []const u8,
        run_id: ?[]const u8 = null,
        kind: []const u8,
        msg: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Line, gpa, std.mem.trim(u8, w.buffered(), "\n"), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 2), parsed.value.seq);
    try std.testing.expectEqualStrings("s1", parsed.value.session_id);
    try std.testing.expectEqualStrings("final", parsed.value.kind);
    try std.testing.expectEqualStrings("done\nok", parsed.value.msg);

    const missing = try querySession(arena, io, dir ++ "/missing", "s1");
    try std.testing.expectEqual(@as(usize, 0), missing.len);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
