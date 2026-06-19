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

/// 取文本中的第一个完整顶层 JSON 对象。
/// 可容忍兼容后端把对象包在 ```json fence``` 中，或在对象后继续输出其它文本。
pub fn firstJsonObject(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const body = unwrapJsonFence(trimmed);
    if (body.len == 0 or body[0] != '{') return null;

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (body, 0..) |c, i| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return body[0 .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

pub fn unwrapJsonFence(content: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, content, "```")) return content;
    var rest = content[3..];
    if (std.mem.startsWith(u8, rest, "json")) rest = rest[4..];
    rest = std.mem.trim(u8, rest, " \t\r\n");
    if (std.mem.endsWith(u8, rest, "```")) rest = rest[0 .. rest.len - 3];
    return std.mem.trim(u8, rest, " \t\r\n");
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

test "firstJsonObject: 支持 fenced JSON 与连续对象" {
    try std.testing.expectEqualStrings("{\"a\":1}", firstJsonObject("```json\n{\"a\":1}\n```").?);
    try std.testing.expectEqualStrings("{\"a\":{\"b\":\"}\"}}", firstJsonObject("{\"a\":{\"b\":\"}\"}} trailing").?);
    try std.testing.expect(firstJsonObject("not json") == null);
}

test {
    std.testing.refAllDecls(@This());
}
