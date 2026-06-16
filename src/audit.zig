//! 审计日志：每一次思考与工具调用都留痕，可回溯（见 ROADMAP「可回溯的审计链路」）。
//! 行格式为 JSONL：每个事件一行 `{"kind":"...","msg":"..."}`，msg 经 JSON 转义，
//! 因此 bash 输出里的换行/引号不会撑破行结构，可被逐行 std.json 回放。
const std = @import("std");
const jsonio = @import("jsonio.zig");

pub const EventKind = enum {
    /// 一次运行的起点标记（main 写入，携带用户目标），用于在追加日志里分隔多次运行。
    run,
    thought,
    tool_call,
    observation,
    /// 终态答复。
    final,
    /// 命令被执行护栏拒绝（铁律：未经验证的输出不落系统）。
    policy_deny,
    system_error,
};

/// 把审计事件写入给定的 writer（文件 / stderr / 纯文本日志）。
pub const Logger = struct {
    writer: *std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) Logger {
        return .{ .writer = writer };
    }

    /// 追加一行 JSONL 审计事件。调用方负责在合适时机 flush 底层 writer。
    pub fn log(self: *Logger, kind: EventKind, message: []const u8) !void {
        const w = self.writer;
        try w.writeAll("{\"kind\":\"");
        try w.writeAll(@tagName(kind));
        try w.writeAll("\",\"msg\":");
        try jsonio.writeString(w, message);
        try w.writeAll("}\n");
    }
};

test "log 产出可被逐行解析的 JSONL（含转义）" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = Logger.init(&w);
    try lg.log(.thought, "看看 \"日志\"\n下一行");
    try lg.log(.tool_call, "ls -a");

    const Line = struct { kind: []const u8, msg: []const u8 };
    var it = std.mem.tokenizeScalar(u8, w.buffered(), '\n');

    const l0 = try std.json.parseFromSlice(Line, std.testing.allocator, it.next().?, .{});
    defer l0.deinit();
    try std.testing.expectEqualStrings("thought", l0.value.kind);
    try std.testing.expectEqualStrings("看看 \"日志\"\n下一行", l0.value.msg);

    const l1 = try std.json.parseFromSlice(Line, std.testing.allocator, it.next().?, .{});
    defer l1.deinit();
    try std.testing.expectEqualStrings("tool_call", l1.value.kind);
    try std.testing.expectEqualStrings("ls -a", l1.value.msg);
}

test {
    std.testing.refAllDecls(@This());
}
