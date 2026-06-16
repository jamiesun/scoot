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
