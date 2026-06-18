//! 文件工具：file_read / file_write / file_edit。
//!
//! 为什么自包含（见 ROADMAP「静态单体 / 零外部依赖」与用户明示需求）：
//!   Scoot 会部署到裁剪 Linux 乃至嵌入式 Linux —— 那里可能连 busybox 的
//!   coreutils（cat/sed/...）都没有。把文件读写做成进程内原语，使 Agent 在
//!   「只有一个 /bin/sh、甚至没有 sh」的环境里仍能读写文件，而不外包给系统命令。
//!
//! 安全分层：写类操作（write/edit）能否执行由调用方（agent）经
//!   `policy.evaluateTool(.write, mode)` 前置把关 —— readonly 安全档下结构性拒绝。
//!   本模块只负责 I/O 本身，并自带大小上限防止把超大文件读爆内存 / 撑爆上下文。
const std = @import("std");

/// 单次读取的默认上限（1 MiB）：远超任何「配置 / 源码 / 文本」合法用例，
/// 又能挡住误读巨型二进制 / 日志把内存读爆。
pub const default_read_limit: std.Io.Limit = .limited(1 << 20);

/// 读取整个文件内容（arena 拥有）。超过 `limit` 返回错误而非截断 —— 截断的文件
/// 内容喂回模型会诱发错误编辑，宁可明确失败让模型改用更精确的手段。
pub fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8, limit: std.Io.Limit) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit);
}

/// 一次行窗口读取的结果。`text` 为所选行以 `\n` 连接后的内容（arena 拥有，不含尾随换行）。
/// `total_lines` 为文件总行数（编辑器约定：末尾换行不额外计一空行）。
/// 当 `start_line == 0` 表示请求的窗口落在文件行数之外（空窗口）。
pub const LineWindow = struct {
    text: []const u8,
    total_lines: usize,
    start_line: usize,
    end_line: usize,
};

/// 读取文件的指定行窗口：从 1-based 行 `offset` 起，最多 `limit` 行（`null` = 读到文件尾）。
/// 仍受 `limit_bytes` 整文件上限保护（先整读再按行切片）——目的是省「喂回模型的 token」，
/// 而非省文件 I/O。让 Agent 能分页啃大文件、并与 grep 返回的行号精确配合。
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

    // 末尾换行产生的尾随空段不计作一行（贴合编辑器/grep 的行号约定）。
    var total = lines.items.len;
    if (total > 0 and src.len > 0 and src[src.len - 1] == '\n') total -= 1;
    if (total == 0) return .{ .text = "", .total_lines = 0, .start_line = 0, .end_line = 0 };

    const start0 = if (offset == 0) 0 else offset - 1;
    if (start0 >= total) return .{ .text = "", .total_lines = total, .start_line = 0, .end_line = 0 };

    const want = limit orelse (total - start0);
    const end0 = @min(start0 + want, total); // 0-based 排他上界

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

/// 覆盖写入文件（不存在则创建，存在则截断为新内容）。
pub fn write(io: std.Io, path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}

/// 精确编辑：要求 `old` 在文件中**恰好出现一次**，替换为 `new` 后写回，返回新内容（arena 拥有）。
///   - `old` 为空 → error.EmptyPattern（空匹配无意义且危险）；
///   - 未找到   → error.PatternNotFound；
///   - 出现多次 → error.AmbiguousMatch（拒绝歧义替换，防止误改无关位置）。
/// 「唯一匹配」语义是刻意的安全选择：sed 之所以在自动化里不可靠，正是因为它会
/// 静默地批量替换；强制唯一让每次编辑的影响面确定、可审计。
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
    // 从 first+1 起再找一次（含重叠）：若仍能命中即非唯一，拒绝以防误改。
    if (std.mem.indexOfPos(u8, src, first + 1, old) != null) return error.AmbiguousMatch;

    const out = try arena.alloc(u8, src.len - old.len + new.len);
    @memcpy(out[0..first], src[0..first]);
    @memcpy(out[first..][0..new.len], new);
    @memcpy(out[first + new.len ..], src[first + old.len ..]);

    try write(io, path, out);
    return out;
}

test "write 然后 read 往返一致" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_rw";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const path = dir ++ "/a.txt";
    try write(io, path, "hello 世界\n第二行");
    const got = try read(gpa, io, path, default_read_limit);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello 世界\n第二行", got);
}

test "write 覆盖既有文件（截断而非追加）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_file_tool_overwrite";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const path = dir ++ "/a.txt";
    try write(io, path, "原来很长的一段内容");
    try write(io, path, "短");
    const got = try read(gpa, io, path, default_read_limit);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("短", got);
}

test "read 不存在的文件返回错误而非 panic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.FileNotFound, read(gpa, io, "/tmp/scoot_file_tool_nope_404", default_read_limit));
}

test "readLineRange：行窗口、越界、limit 截断与无尾换行" {
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

    // 5 行、含末尾换行 → 总行数 5（尾随空段不计）。
    try write(io, path, "l1\nl2\nl3\nl4\nl5\n");

    // 中段窗口 [2,4]
    const w = try readLineRange(arena, io, path, default_read_limit, 2, 2);
    try std.testing.expectEqual(@as(usize, 5), w.total_lines);
    try std.testing.expectEqual(@as(usize, 2), w.start_line);
    try std.testing.expectEqual(@as(usize, 3), w.end_line);
    try std.testing.expectEqualStrings("l2\nl3", w.text);

    // offset=1, limit=null → 读到尾
    const all = try readLineRange(arena, io, path, default_read_limit, 1, null);
    try std.testing.expectEqual(@as(usize, 1), all.start_line);
    try std.testing.expectEqual(@as(usize, 5), all.end_line);
    try std.testing.expectEqualStrings("l1\nl2\nl3\nl4\nl5", all.text);

    // limit 超过剩余 → 截断到尾
    const tail = try readLineRange(arena, io, path, default_read_limit, 4, 100);
    try std.testing.expectEqual(@as(usize, 4), tail.start_line);
    try std.testing.expectEqual(@as(usize, 5), tail.end_line);
    try std.testing.expectEqualStrings("l4\nl5", tail.text);

    // offset 越界 → 空窗口但 total_lines 保留
    const oob = try readLineRange(arena, io, path, default_read_limit, 99, 3);
    try std.testing.expectEqual(@as(usize, 5), oob.total_lines);
    try std.testing.expectEqual(@as(usize, 0), oob.start_line);
    try std.testing.expectEqualStrings("", oob.text);

    // 无尾换行：总行数仍按编辑器约定计 3
    const path2 = dir ++ "/b.txt";
    try write(io, path2, "a\nb\nc");
    const nn = try readLineRange(arena, io, path2, default_read_limit, 1, null);
    try std.testing.expectEqual(@as(usize, 3), nn.total_lines);
    try std.testing.expectEqualStrings("a\nb\nc", nn.text);

    // 空文件 → total 0、空窗口
    const path3 = dir ++ "/c.txt";
    try write(io, path3, "");
    const empty = try readLineRange(arena, io, path3, default_read_limit, 1, 10);
    try std.testing.expectEqual(@as(usize, 0), empty.total_lines);
    try std.testing.expectEqual(@as(usize, 0), empty.start_line);
}

test "edit 唯一匹配成功替换并写回" {
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

test "edit 未找到 old → PatternNotFound（不改文件）" {
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
    try std.testing.expectEqualStrings("abc", got); // 未改
}

test "edit old 出现多次 → AmbiguousMatch（拒绝歧义替换）" {
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
    try std.testing.expectEqualStrings("x foo y foo z", got); // 未改
}

test "edit 空 old → EmptyPattern" {
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
