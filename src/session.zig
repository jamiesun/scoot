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

    /// 历史压缩（issue #71）：保留**首条 system 指令 + 次条原始 user 任务 + 最近
    /// `keep_recent` 条**，把中间整段较早消息替换为一条「已省略」摘要标记，让逼近上下文
    /// 预算的长 run 能压缩后继续，而非整段中止或无界增长。
    ///
    /// 被丢弃消息的内容副本用 `gpa` 释放（须与 `append` 同一分配器）：真实分配器下立即回收；
    /// arena backing 下 `free` 为 no-op——不回收但语义安全，且**发送给后端的历史确实变小**
    /// （token 成本即时下降，这才是压缩的首要目的）。
    ///
    /// 返回是否实际发生了压缩（中段为空时为 false，调用方据此决定是否仍需 fail-fast）。
    pub fn compact(self: *Session, gpa: std.mem.Allocator, keep_recent: usize) !bool {
        const msgs = self.messages.items;
        const n = msgs.len;
        const prefix: usize = @min(n, 2); // system + 原始 user（按存在取，最多 2 条）
        if (n <= prefix + keep_recent) return false; // 没有可压缩的中段
        const drop_start = prefix;
        const drop_end = n - keep_recent; // 独占
        if (drop_end <= drop_start) return false;

        var elided_bytes: usize = 0;
        var k = drop_start;
        while (k < drop_end) : (k += 1) elided_bytes += msgs[k].content.len;
        const elided_count = drop_end - drop_start;

        const marker = try std.fmt.allocPrint(
            gpa,
            "[历史压缩] 为控制上下文预算，已省略较早的 {d} 条消息（约 {d} 字节，多为工具观察原文）。system 指令、原始任务与最近 {d} 条消息已保留；如需更早细节请用工具重新获取。",
            .{ elided_count, elided_bytes, keep_recent },
        );
        errdefer gpa.free(marker);

        var rebuilt: std.ArrayList(llm.Message) = .empty;
        errdefer rebuilt.deinit(gpa);
        try rebuilt.ensureTotalCapacity(gpa, prefix + 1 + keep_recent);
        var i: usize = 0;
        while (i < prefix) : (i += 1) rebuilt.appendAssumeCapacity(msgs[i]);
        rebuilt.appendAssumeCapacity(.{ .role = .user, .content = marker });
        i = drop_end;
        while (i < n) : (i += 1) rebuilt.appendAssumeCapacity(msgs[i]);

        // 仅释放被丢弃消息的内容（prefix/tail 的内容已转交 rebuilt 继续引用）。
        k = drop_start;
        while (k < drop_end) : (k += 1) gpa.free(msgs[k].content);

        self.messages.deinit(gpa); // 释放旧节点数组（内容已分别转移/释放）
        self.messages = rebuilt;
        return true;
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

    /// 把会话追加持久化到 `<sessions_dir>/<id>.jsonl`（不存在则创建，存在则**追加**）。
    /// 序列化逻辑见 `writeJsonl`；此处负责通过 Io 打开文件、定位到末尾后写入。
    /// 追加语义让同一会话的多次运行快照在一个文件里按时间累积，服务可回溯审计链路。
    pub fn persist(self: *const Session, io: std.Io, sessions_dir: []const u8) !void {
        var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&pathbuf, "{s}/{s}.jsonl", .{ sessions_dir, self.id });

        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        defer file.close(io);

        const st = try file.stat(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.seekTo(st.size); // 定位到文件末尾以追加，不覆盖既有记录
        try self.writeJsonl(&fw.interface);
        try fw.interface.flush();
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

test "persist 追加写 JSONL 到 <dir>/<id>.jsonl 并可读回" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_session_persist_test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    var s = Session.init("conv1");
    defer s.deinit(gpa);
    try s.append(gpa, .user, "你好\"世界\"");
    try s.append(gpa, .assistant, "在");

    try s.persist(io, dir);
    try s.persist(io, dir); // 再次持久化必须追加（验证不是覆盖）

    const bytes = try cwd.readFileAlloc(io, dir ++ "/conv1.jsonl", gpa, .limited(1 << 16));
    defer gpa.free(bytes);

    var lines: usize = 0;
    var it = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (it.next()) |line| : (lines += 1) {
        const v = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        v.deinit(); // 每行都应是合法 JSON
    }
    try std.testing.expectEqual(@as(usize, 4), lines); // 2 条消息 × 2 次持久化
    try std.testing.expect(std.mem.indexOf(u8, bytes, "你好") != null);
}

test {
    std.testing.refAllDecls(@This());
}

test "compact：保留 system+原始任务+最近 K，中段替换为标记，内容正确释放" {
    const gpa = std.testing.allocator;
    var s = Session.init("c1");
    defer s.deinit(gpa);

    try s.append(gpa, .system, "SYS-PROMPT");
    try s.append(gpa, .user, "ORIGINAL-TASK");
    // 6 条中间消息（assistant 动作 + user 观察交替），均应被压掉。
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try s.append(gpa, .assistant, "{\"action\":\"bash\",\"action_input\":\"x\"}");
        try s.append(gpa, .user, "[观察] OLD-OBSERVATION-PAYLOAD");
    }
    // 最近 2 条应原样保留。
    try s.append(gpa, .assistant, "RECENT-ACTION");
    try s.append(gpa, .user, "RECENT-OBSERVATION");

    const before = s.count();
    const did = try s.compact(gpa, 2);
    try std.testing.expect(did);
    // prefix(2) + marker(1) + tail(2) = 5。
    try std.testing.expectEqual(@as(usize, 5), s.count());
    try std.testing.expect(s.count() < before);

    const it = s.items();
    try std.testing.expectEqualStrings("SYS-PROMPT", it[0].content);
    try std.testing.expectEqualStrings("ORIGINAL-TASK", it[1].content);
    try std.testing.expect(std.mem.indexOf(u8, it[2].content, "历史压缩") != null);
    try std.testing.expect(std.mem.indexOf(u8, it[2].content, "已省略较早的 6 条") != null);
    try std.testing.expectEqualStrings("RECENT-ACTION", it[3].content);
    try std.testing.expectEqualStrings("RECENT-OBSERVATION", it[4].content);
    // 被压掉的观察原文不再出现。
    for (it) |m| try std.testing.expect(std.mem.indexOf(u8, m.content, "OLD-OBSERVATION-PAYLOAD") == null);

    // 中段为空时不压缩。
    try std.testing.expect(!try s.compact(gpa, 100));
}
