//! 审计日志：每一次思考与工具调用都留痕，可回溯（见 ROADMAP「可回溯的审计链路」）。
const std = @import("std");

pub const EventKind = enum {
    thought,
    tool_call,
    observation,
    system_error,
};

/// 把审计事件写入给定的 writer（文件 / stderr / 纯文本日志）。
pub const Logger = struct {
    writer: *std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) Logger {
        return .{ .writer = writer };
    }

    pub fn log(self: *Logger, kind: EventKind, message: []const u8) !void {
        try self.writer.print("[{s}] {s}\n", .{ @tagName(kind), message });
    }
};

test {
    std.testing.refAllDecls(@This());
}
