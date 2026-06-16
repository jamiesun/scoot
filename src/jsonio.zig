//! 手写紧凑 JSON 的小工具：正确转义的字符串字面量。
//! 供需要生成紧凑 JSON（如 OpenAI 请求体、会话 JSONL）的模块复用，
//! 把「字符串转义正确性」这件易错的事收敛到一处。
//! 注意：解析（读取外部 / 模型数据）一律走 std.json，以满足「绝不信任模型输出」铁律。
const std = @import("std");

/// 向 `w` 写入一个合法的 JSON 字符串字面量（含两端引号），
/// 正确转义控制字符与特殊符号。
pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        else => |ch| if (ch < 0x20)
            try w.print("\\u{x:0>4}", .{ch})
        else
            try w.writeByte(ch),
    };
    try w.writeByte('"');
}

test "writeString 转义并产出可被 std.json 回解的合法字符串" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeString(&aw.writer, "a\"b\\c\n\t\x01 末");
    const parsed = try std.json.parseFromSlice([]const u8, gpa, aw.writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b\\c\n\t\x01 末", parsed.value);
}

test {
    std.testing.refAllDecls(@This());
}
