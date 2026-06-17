//! 审计日志：每一次思考与工具调用都留痕，可回溯（见 ROADMAP「可回溯的审计链路」）。
//! 行格式为 JSONL：每个事件一行 `{"seq":N,"ts":MS,"kind":"...","msg":"..."}`，msg 经
//! JSON 转义，因此 bash 输出里的换行/引号不会撑破行结构，可被逐行 std.json 回放。
//!
//! `seq` 是每个 Logger 实例内单调递增的事件序号（从 0 起），`ts` 是事件发生时的
//! 墙钟时间（Unix 毫秒）。二者让追加日志可在时间线上重建顺序与延迟、与外部系统
//! 关联，并区分同一毫秒内的并发事件（如 parallel 的多个子调用）——纯靠文件追加
//! 顺序无法可靠承载这些（见 issue #31）。
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
    /// 读取墙钟（`.real`）为每个事件打 `ts` 时间戳。
    io: std.Io,
    /// 实例内单调递增的事件序号，从 0 起，每写一条 +1。
    seq: u64 = 0,

    pub fn init(writer: *std.Io.Writer, io: std.Io) Logger {
        return .{ .writer = writer, .io = io };
    }

    /// 追加一行 JSONL 审计事件。调用方负责在合适时机 flush 底层 writer。
    /// 每条带单调 `seq` 与墙钟 `ts`（Unix 毫秒），便于按时间线回放与关联。
    pub fn log(self: *Logger, kind: EventKind, message: []const u8) !void {
        const w = self.writer;
        const ts_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const seq = self.seq;
        self.seq += 1;
        try w.print("{{\"seq\":{d},\"ts\":{d},\"kind\":\"", .{ seq, ts_ms });
        try w.writeAll(@tagName(kind));
        try w.writeAll("\",\"msg\":");
        try jsonio.writeString(w, message);
        try w.writeAll("}\n");
    }
};

test "log 产出可被逐行解析的 JSONL（含 seq/ts 与转义）" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var lg = Logger.init(&w, std.testing.io);
    try lg.log(.thought, "看看 \"日志\"\n下一行");
    try lg.log(.tool_call, "ls -a");

    const Line = struct { seq: u64, ts: i64, kind: []const u8, msg: []const u8 };
    var it = std.mem.tokenizeScalar(u8, w.buffered(), '\n');

    const l0 = try std.json.parseFromSlice(Line, std.testing.allocator, it.next().?, .{});
    defer l0.deinit();
    try std.testing.expectEqual(@as(u64, 0), l0.value.seq);
    try std.testing.expect(l0.value.ts >= 0);
    try std.testing.expectEqualStrings("thought", l0.value.kind);
    try std.testing.expectEqualStrings("看看 \"日志\"\n下一行", l0.value.msg);

    const l1 = try std.json.parseFromSlice(Line, std.testing.allocator, it.next().?, .{});
    defer l1.deinit();
    try std.testing.expectEqual(@as(u64, 1), l1.value.seq); // 单调递增
    try std.testing.expect(l1.value.ts >= l0.value.ts); // 墙钟不回退
    try std.testing.expectEqualStrings("tool_call", l1.value.kind);
    try std.testing.expectEqualStrings("ls -a", l1.value.msg);
}

test {
    std.testing.refAllDecls(@This());
}
