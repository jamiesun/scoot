//! 文件工具：file_read / file_write / file_edit。
const std = @import("std");
const Result = @import("tools.zig").Result;

pub fn read(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    _ = arena;
    _ = path;
    return error.NotImplemented;
}

pub fn write(path: []const u8, contents: []const u8) !void {
    _ = path;
    _ = contents;
    return error.NotImplemented;
}

/// 以 old_str -> new_str 精确替换的方式编辑文件。
pub fn edit(arena: std.mem.Allocator, path: []const u8, old_str: []const u8, new_str: []const u8) !Result {
    _ = arena;
    _ = path;
    _ = old_str;
    _ = new_str;
    return error.NotImplemented;
}

test {
    std.testing.refAllDecls(@This());
}
