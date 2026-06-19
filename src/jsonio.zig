//! Small hand-written helpers for compact JSON string literals.
//! Modules that emit compact JSON, such as OpenAI request bodies or session
//! JSONL, reuse this so string escaping correctness is centralized.
//! Parsing external or model data still always goes through `std.json`.
const std = @import("std");

/// Writes a valid JSON string literal to `w`, including quotes, with control
/// characters and special symbols escaped.
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

/// Returns the first complete top-level JSON object in the text.
/// Tolerates compatible backends wrapping it in a ```json fence``` or appending
/// extra text after the object.
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

test "writeString escaping matches std.json parsing" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeString(&aw.writer, "a\"b\\c\n\t\x01 end");
    const parsed = try std.json.parseFromSlice([]const u8, gpa, aw.writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b\\c\n\t\x01 end", parsed.value);
}

test "firstJsonObject: supports fenced JSON and consecutive objects" {
    try std.testing.expectEqualStrings("{\"a\":1}", firstJsonObject("```json\n{\"a\":1}\n```").?);
    try std.testing.expectEqualStrings("{\"a\":{\"b\":\"}\"}}", firstJsonObject("{\"a\":{\"b\":\"}\"}} trailing").?);
    try std.testing.expect(firstJsonObject("not json") == null);
}

test {
    std.testing.refAllDecls(@This());
}
