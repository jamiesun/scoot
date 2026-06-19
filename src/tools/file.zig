//! File tools: file_read, file_write, and file_edit.
//!
//! Self-contained rationale: Scoot may run on trimmed or embedded Linux systems
//! that do not even have busybox coreutils such as cat or sed. Keeping file I/O
//! in-process lets the agent read and write files when only `/bin/sh`, or even
//! no shell, is available.
//!
//! Safety layering: the caller, normally the agent, decides whether write/edit
//! actions may run via `policy.evaluateTool(.write, mode)`. Readonly mode denies
//! them structurally. This module handles I/O itself and enforces size limits to
//! avoid reading huge files into memory or context.
const std = @import("std");

/// Default single-read limit (1 MiB): far above normal config, source, or text
/// use, but still blocks accidental giant binaries or logs.
pub const default_read_limit: std.Io.Limit = .limited(1 << 20);

/// Reads an entire file into arena-owned memory. Exceeding `limit` returns an
/// error instead of truncating, because feeding truncated file content to the
/// model can lead to incorrect edits.
pub fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8, limit: std.Io.Limit) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit);
}

/// Result for one line-window read. `text` joins selected lines with `\n`, is
/// arena-owned, and has no trailing newline. `total_lines` follows editor
/// convention: a trailing newline does not add an empty final line.
/// `start_line == 0` means the requested window is out of range.
pub const LineWindow = struct {
    text: []const u8,
    total_lines: usize,
    start_line: usize,
    end_line: usize,
};

/// Reads a file line window starting at 1-based `offset`, for at most `limit`
/// lines (`null` means through EOF). Still bounded by whole-file `limit_bytes`;
/// this saves returned model context rather than file I/O, and pairs precisely
/// with grep line numbers.
pub fn readLineRange(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit_bytes: std.Io.Limit,
    offset: usize,
    limit: ?usize,
) !LineWindow {
    const src = try read(arena, io, path, limit_bytes);
    if (src.len == 0) return .{ .text = "", .total_lines = 0, .start_line = 0, .end_line = 0 };

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |seg| try lines.append(arena, seg);

    // A trailing empty split from final newline is not a line, matching editors and grep.
    var total = lines.items.len;
    if (total > 0 and src.len > 0 and src[src.len - 1] == '\n') total -= 1;
    if (total == 0) return .{ .text = "", .total_lines = 0, .start_line = 0, .end_line = 0 };

    const start0 = if (offset == 0) 0 else offset - 1;
    if (start0 >= total) return .{ .text = "", .total_lines = total, .start_line = 0, .end_line = 0 };

    const want = limit orelse (total - start0);
    const end0 = @min(start0 + want, total); // 0-based exclusive upper bound.

    var buf: std.ArrayList(u8) = .empty;
    for (lines.items[start0..end0], 0..) |ln, i| {
        if (i != 0) try buf.append(arena, '\n');
        try buf.appendSlice(arena, ln);
    }
    return .{
        .text = buf.items,
        .total_lines = total,
        .start_line = start0 + 1,
        .end_line = end0,
    };
}

/// Overwrites a file, creating it if needed and truncating existing content.
pub fn write(io: std.Io, path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}

/// Exact edit: requires `old` to appear exactly once, replaces it with `new`,
/// writes the file back, and returns arena-owned new content.
///   - empty `old` -> error.EmptyPattern, because empty matches are unsafe;
///   - not found -> error.PatternNotFound;
///   - multiple matches -> error.AmbiguousMatch to avoid ambiguous edits.
/// The unique-match rule is deliberate: sed is unreliable in automation because
/// it silently performs bulk replacement. Requiring one match keeps each edit's
/// impact deterministic and auditable.
pub fn edit(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    old: []const u8,
    new: []const u8,
    limit: std.Io.Limit,
) ![]const u8 {
    if (old.len == 0) return error.EmptyPattern;
    const src = try read(arena, io, path, limit);

    const first = std.mem.indexOf(u8, src, old) orelse return error.PatternNotFound;
    // Search again from first+1, including overlaps; any hit means non-unique.
    if (std.mem.indexOfPos(u8, src, first + 1, old) != null) return error.AmbiguousMatch;

    const out = try arena.alloc(u8, src.len - old.len + new.len);
    @memcpy(out[0..first], src[0..first]);
    @memcpy(out[first..][0..new.len], new);
    @memcpy(out[first + new.len ..], src[first + old.len ..]);

    try write(io, path, out);
    return out;
}

test "write then read round-trips" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_rw";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const path = dir ++ "/a.txt";
    try write(io, path, "hello world\nsecond line");
    const got = try read(gpa, io, path, default_read_limit);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello world\nsecond line", got);
}

test "write overwrites existing file by truncating instead of appending" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_overwrite";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const path = dir ++ "/a.txt";
    try write(io, path, "original long content");
    try write(io, path, "short");
    const got = try read(gpa, io, path, default_read_limit);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("short", got);
}

test "read missing file returns an error without panic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.FileNotFound, read(gpa, io, "/tmp/scoot_file_tool_nope_404", default_read_limit));
}

test "readLineRange:line window, out-of-bounds, limit truncation, and no trailing newline" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_range";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const path = dir ++ "/a.txt";

    // Five lines with trailing newline -> total 5; trailing split is ignored.
    try write(io, path, "l1\nl2\nl3\nl4\nl5\n");

    // Middle window [2,4].
    const w = try readLineRange(arena, io, path, default_read_limit, 2, 2);
    try std.testing.expectEqual(@as(usize, 5), w.total_lines);
    try std.testing.expectEqual(@as(usize, 2), w.start_line);
    try std.testing.expectEqual(@as(usize, 3), w.end_line);
    try std.testing.expectEqualStrings("l2\nl3", w.text);

    // offset=1, limit=null -> read through EOF.
    const all = try readLineRange(arena, io, path, default_read_limit, 1, null);
    try std.testing.expectEqual(@as(usize, 1), all.start_line);
    try std.testing.expectEqual(@as(usize, 5), all.end_line);
    try std.testing.expectEqualStrings("l1\nl2\nl3\nl4\nl5", all.text);

    // limit beyond remaining lines -> clamp to EOF.
    const tail = try readLineRange(arena, io, path, default_read_limit, 4, 100);
    try std.testing.expectEqual(@as(usize, 4), tail.start_line);
    try std.testing.expectEqual(@as(usize, 5), tail.end_line);
    try std.testing.expectEqualStrings("l4\nl5", tail.text);

    // Out-of-range offset -> empty window while preserving total_lines.
    const oob = try readLineRange(arena, io, path, default_read_limit, 99, 3);
    try std.testing.expectEqual(@as(usize, 5), oob.total_lines);
    try std.testing.expectEqual(@as(usize, 0), oob.start_line);
    try std.testing.expectEqualStrings("", oob.text);

    // No trailing newline: total still follows editor convention and is 3.
    const path2 = dir ++ "/b.txt";
    try write(io, path2, "a\nb\nc");
    const nn = try readLineRange(arena, io, path2, default_read_limit, 1, null);
    try std.testing.expectEqual(@as(usize, 3), nn.total_lines);
    try std.testing.expectEqualStrings("a\nb\nc", nn.text);

    // Empty file -> total 0 and empty window.
    const path3 = dir ++ "/c.txt";
    try write(io, path3, "");
    const empty = try readLineRange(arena, io, path3, default_read_limit, 1, 10);
    try std.testing.expectEqual(@as(usize, 0), empty.total_lines);
    try std.testing.expectEqual(@as(usize, 0), empty.start_line);
}

test "edit unique match replaces and writes back" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_edit_ok";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const path = dir ++ "/a.txt";
    try write(io, path, "hello world\nbye world?no");
    const out = try edit(arena, io, path, "world\nbye", "WORLD\nBYE", default_read_limit);
    try std.testing.expectEqualStrings("hello WORLD\nBYE world?no", out);

    const got = try read(arena, io, path, default_read_limit);
    try std.testing.expectEqualStrings("hello WORLD\nBYE world?no", got);
}

test "edit missing old returns PatternNotFound without changing file" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_edit_404";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const path = dir ++ "/a.txt";
    try write(io, path, "abc");
    try std.testing.expectError(error.PatternNotFound, edit(arena, io, path, "xyz", "Q", default_read_limit));
    const got = try read(arena, io, path, default_read_limit);
    try std.testing.expectEqualStrings("abc", got); // Unchanged.
}

test "edit multiple old matches return AmbiguousMatch and reject ambiguous replacement" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_edit_ambig";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const path = dir ++ "/a.txt";
    try write(io, path, "x foo y foo z");
    try std.testing.expectError(error.AmbiguousMatch, edit(arena, io, path, "foo", "BAR", default_read_limit));
    const got = try read(arena, io, path, default_read_limit);
    try std.testing.expectEqualStrings("x foo y foo z", got); // Unchanged.
}

test "edit empty old returns EmptyPattern" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_edit_empty";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const path = dir ++ "/a.txt";
    try write(io, path, "abc");
    try std.testing.expectError(error.EmptyPattern, edit(gpa, io, path, "", "Q", default_read_limit));
}

test {
    std.testing.refAllDecls(@This());
}
