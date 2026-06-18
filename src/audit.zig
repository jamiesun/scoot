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

pub const default_max_jsonl_bytes: u64 = 10 * 1024 * 1024;

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

pub const Stats = struct {
    run: u64 = 0,
    thought: u64 = 0,
    tool_call: u64 = 0,
    observation: u64 = 0,
    final: u64 = 0,
    policy_deny: u64 = 0,
    system_error: u64 = 0,

    pub fn record(self: *Stats, kind: EventKind) void {
        switch (kind) {
            .run => self.run += 1,
            .thought => self.thought += 1,
            .tool_call => self.tool_call += 1,
            .observation => self.observation += 1,
            .final => self.final += 1,
            .policy_deny => self.policy_deny += 1,
            .system_error => self.system_error += 1,
        }
    }

    pub fn total(self: Stats) u64 {
        return self.run + self.thought + self.tool_call + self.observation + self.final + self.policy_deny + self.system_error;
    }
};

/// 把审计事件写入给定的 writer（文件 / stderr / 纯文本日志）。
pub const Logger = struct {
    writer: *std.Io.Writer,
    /// 读取墙钟（`.real`）为每个事件打 `ts` 时间戳。
    io: std.Io,
    /// 实例内单调递增的事件序号，从 0 起，每写一条 +1。
    seq: u64 = 0,
    stats: Stats = .{},

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
        self.stats.record(kind);
    }
};

pub fn rotateFileIfTooLarge(io: std.Io, arena: std.mem.Allocator, path: []const u8, max_bytes: u64) !bool {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (st.size < max_bytes) return false;

    const rotated = try std.fmt.allocPrint(arena, "{s}.1", .{path});
    cwd.deleteFile(io, rotated) catch {};
    try cwd.rename(path, cwd, rotated, io);
    return true;
}

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
    try std.testing.expectEqual(@as(u64, 2), lg.stats.total());
    try std.testing.expectEqual(@as(u64, 1), lg.stats.thought);
    try std.testing.expectEqual(@as(u64, 1), lg.stats.tool_call);
}

test "rotateFileIfTooLarge rotates bounded JSONL files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const path = "/tmp/scoot_audit_rotate.jsonl";
    cwd.deleteFile(io, path) catch {};
    cwd.deleteFile(io, path ++ ".1") catch {};
    defer cwd.deleteFile(io, path) catch {};
    defer cwd.deleteFile(io, path ++ ".1") catch {};
    try cwd.writeFile(io, .{ .sub_path = path, .data = "1234567890" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try std.testing.expect(try rotateFileIfTooLarge(io, arena_state.allocator(), path, 10));
    try std.testing.expect(!fileExists(io, path));
    try std.testing.expect(fileExists(io, path ++ ".1"));
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
