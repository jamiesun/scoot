//! 搜索工具：grep（内容）与 glob（路径）。
const std = @import("std");

/// 在文件内容中按正则 / 字面量搜索。
pub fn grep(arena: std.mem.Allocator, pattern: []const u8, path: []const u8) ![]const u8 {
    _ = arena;
    _ = pattern;
    _ = path;
    return error.NotImplemented;
}

/// 按 glob 模式匹配路径。
pub fn glob(arena: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
    _ = arena;
    _ = pattern;
    return error.NotImplemented;
}

test {
    std.testing.refAllDecls(@This());
}
