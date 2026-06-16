//! 会话（Session）：一次有边界的交互上下文 —— 一段 REPL 对话、一次 `-e` 调用，
//! 或一个被调度唤起的 job 运行。它持有该次交互的消息流（system/user/assistant/tool）。
//!
//! 为什么需要它（见 ROADMAP 方向二 /「可回溯审计链路」）：
//!   认知回合 (agent.zig) 每轮派生一个 per-turn arena 并在回合末整体释放，
//!   因此「跨回合存活的对话历史」必须落在一个**长寿命分配器**上，而不能放进
//!   会被重置的回合 arena。Session 就是这份历史的载体：内容在追加时复制进
//!   Session 自己的分配器，独立于来源 arena 的生命周期。
//!
//! 职责边界（与「长期记忆」的区分，见审计结论）：
//!   - Session 只管「短期、单会话」的消息记录与（可选）持久化；
//!   - 跨会话的「长期记忆 / 语义召回」**不在此实现** —— 由 Skill 机制（知识注入）
//!     或 state/ 下的纯文本摘要 + 文件工具承载，避免引入向量库等重依赖而撞穿铁律。
const std = @import("std");
const llm = @import("llm.zig");
const jsonio = @import("jsonio.zig");

/// 一次会话。`messages` 由 Session 的分配器拥有，跨回合存活。
pub const Session = struct {
    /// 会话标识（建议用时间戳 / uuid）；用于持久化文件名与日志。
    /// 内存由调用方持有，需保证其生命周期 >= Session。
    id: []const u8,
    /// 消息流；内容副本与节点均由传入的 gpa 拥有。
    messages: std.ArrayList(llm.Message) = .empty,

    pub fn init(id: []const u8) Session {
        return .{ .id = id };
    }

    /// 追加一条消息。`content` 会被复制进 `gpa`，使其不受来源（如回合 arena）释放影响。
    pub fn append(
        self: *Session,
        gpa: std.mem.Allocator,
        role: llm.Role,
        content: []const u8,
    ) !void {
        const owned = try gpa.dupe(u8, content);
        errdefer gpa.free(owned);
        try self.messages.append(gpa, .{ .role = role, .content = owned });
    }

    /// 便捷：追加一条已有的 llm.Message（内容同样会被复制）。
    pub fn appendMessage(self: *Session, gpa: std.mem.Allocator, m: llm.Message) !void {
        return self.append(gpa, m.role, m.content);
    }

    /// 只读消息视图，可直接喂给 `llm.Client.chat`。
    pub fn items(self: *const Session) []const llm.Message {
        return self.messages.items;
    }

    pub fn count(self: *const Session) usize {
        return self.messages.items.len;
    }

    pub fn last(self: *const Session) ?llm.Message {
        const n = self.messages.items.len;
        return if (n == 0) null else self.messages.items[n - 1];
    }

    /// 释放消息流及其内容副本（必须用与 append 相同的 gpa）。
    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        for (self.messages.items) |m| gpa.free(m.content);
        self.messages.deinit(gpa);
    }

    /// 以 JSONL（每行一条消息）把整段会话写入 `w`。
    /// 纯文本、可追加、可回溯，满足 ROADMAP「状态严格本地（SQLite 或纯文本）」与审计链路。
    pub fn writeJsonl(self: *const Session, w: *std.Io.Writer) !void {
        for (self.messages.items) |m| {
            try writeMessageJson(w, m);
            try w.writeByte('\n');
        }
    }

    /// 把会话追加持久化到 `<sessions_dir>/<id>.jsonl`（不存在则创建）。
    /// 序列化逻辑见 `writeJsonl`；此处只负责通过 Io 打开 / 追加文件。
    /// TODO: 用 Io 打开（O_CREATE|O_APPEND）目标文件并写入 writeJsonl 的结果。
    pub fn persist(self: *const Session, io: std.Io, sessions_dir: []const u8) !void {
        _ = self;
        _ = io;
        _ = sessions_dir;
        return error.NotImplemented;
    }
};

/// 把单条消息写成一行 JSON 对象：{"role":"user","content":"..."}
fn writeMessageJson(w: *std.Io.Writer, m: llm.Message) !void {
    try w.writeAll("{\"role\":\"");
    try w.writeAll(@tagName(m.role));
    try w.writeAll("\",\"content\":");
    try jsonio.writeString(w, m.content);
    try w.writeByte('}');
}

test "append 复制内容，独立于来源缓冲" {
    const gpa = std.testing.allocator;
    var s = Session.init("t1");
    defer s.deinit(gpa);

    var tmp = [_]u8{ 'h', 'i' };
    try s.append(gpa, .user, &tmp);
    tmp[0] = 'X'; // 篡改来源缓冲，不应影响已存入会话的副本

    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expectEqualStrings("hi", s.items()[0].content);
    try std.testing.expectEqual(llm.Role.user, s.last().?.role);
}

test "writeJsonl 产出可被 std.json 解析的合法行（含转义）" {
    const gpa = std.testing.allocator;
    var s = Session.init("t2");
    defer s.deinit(gpa);

    try s.append(gpa, .system, "you are \"scoot\"");
    try s.append(gpa, .user, "line1\nline2\t\x01");

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try s.writeJsonl(&w);

    const Line = struct { role: []const u8, content: []const u8 };
    const expect_roles = [_][]const u8{ "system", "user" };
    const expect_content = [_][]const u8{ "you are \"scoot\"", "line1\nline2\t\x01" };

    var it = std.mem.tokenizeScalar(u8, w.buffered(), '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        const parsed = try std.json.parseFromSlice(Line, gpa, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(expect_roles[idx], parsed.value.role);
        try std.testing.expectEqualStrings(expect_content[idx], parsed.value.content);
    }
    try std.testing.expectEqual(@as(usize, 2), idx);
}

test {
    std.testing.refAllDecls(@This());
}
