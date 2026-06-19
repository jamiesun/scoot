//! 上下文压缩策略接缝。
//!
//! Session 负责保存与落盘消息；Compressor 负责决定超预算时怎样把历史折叠。
//! 内置策略保持有限：`drop` 是旧行为与兜底地板，`extractive` 是确定式滚动纪要。
const std = @import("std");
const llm = @import("llm.zig");
const session = @import("session.zig");

pub const Options = struct {
    keep_recent: usize,
};

pub const Compressor = union(enum) {
    drop: void,
    extractive: void,

    pub fn compact(self: Compressor, gpa: std.mem.Allocator, sess: *session.Session, opts: Options) !bool {
        return switch (self) {
            .drop => try dropCompact(gpa, sess, opts.keep_recent),
            .extractive => try extractiveCompact(gpa, sess, opts.keep_recent),
        };
    }
};

pub const default: Compressor = .{ .drop = {} };

pub fn fromString(s: []const u8) Compressor {
    if (std.mem.eql(u8, s, "extractive")) return .{ .extractive = {} };
    return default;
}

/// 旧行为的命名实现：保留 system + 原始 user 任务 + 最近 K 条，
/// 把中间整段较早消息替换为一条有损摘要标记。
fn dropCompact(gpa: std.mem.Allocator, sess: *session.Session, keep_recent: usize) !bool {
    return compactWithMarker(gpa, sess, keep_recent, buildDropMarker);
}

/// 确定式抽取纪要：只从已执行步骤与观察文本中提取稳定事实，不生成语义猜测。
fn extractiveCompact(gpa: std.mem.Allocator, sess: *session.Session, keep_recent: usize) !bool {
    return compactWithMarker(gpa, sess, keep_recent, buildExtractiveMarker);
}

fn compactWithMarker(
    gpa: std.mem.Allocator,
    sess: *session.Session,
    keep_recent: usize,
    markerFn: fn (std.mem.Allocator, []const llm.Message, usize, usize, usize) anyerror![]const u8,
) !bool {
    const msgs = sess.messages.items;
    const n = msgs.len;
    const prefix: usize = @min(n, 2);
    if (n <= prefix + keep_recent) return false;
    const drop_start = prefix;
    const drop_end = n - keep_recent;
    if (drop_end <= drop_start) return false;

    const elided_count = drop_end - drop_start;
    var elided_bytes: usize = 0;
    var k = drop_start;
    while (k < drop_end) : (k += 1) elided_bytes += msgs[k].content.len;

    const marker = try markerFn(gpa, msgs[drop_start..drop_end], elided_count, elided_bytes, keep_recent);
    errdefer gpa.free(marker);

    var rebuilt: std.ArrayList(llm.Message) = .empty;
    errdefer rebuilt.deinit(gpa);
    try rebuilt.ensureTotalCapacity(gpa, prefix + 1 + keep_recent);
    var i: usize = 0;
    while (i < prefix) : (i += 1) rebuilt.appendAssumeCapacity(msgs[i]);
    rebuilt.appendAssumeCapacity(.{ .role = .user, .content = marker });
    i = drop_end;
    while (i < n) : (i += 1) rebuilt.appendAssumeCapacity(msgs[i]);

    k = drop_start;
    while (k < drop_end) : (k += 1) gpa.free(msgs[k].content);

    sess.messages.deinit(gpa);
    sess.messages = rebuilt;
    return true;
}

fn buildDropMarker(
    gpa: std.mem.Allocator,
    dropped: []const llm.Message,
    elided_count: usize,
    elided_bytes: usize,
    keep_recent: usize,
) ![]const u8 {
    _ = dropped;
    return std.fmt.allocPrint(
        gpa,
        "[历史压缩] 为控制上下文预算，已省略较早的 {d} 条消息（约 {d} 字节，多为工具观察原文）。system 指令、原始任务与最近 {d} 条消息已保留；如需更早细节请用工具重新获取。",
        .{ elided_count, elided_bytes, keep_recent },
    );
}

const Extract = struct {
    commands: std.ArrayList([]const u8) = .empty,
    reads: std.ArrayList([]const u8) = .empty,
    writes: std.ArrayList([]const u8) = .empty,
    denials: std.ArrayList([]const u8) = .empty,
    notes: std.ArrayList([]const u8) = .empty,

    fn collect(self: *Extract, arena: std.mem.Allocator, dropped: []const llm.Message) !void {
        var pending_command: ?[]const u8 = null;
        for (dropped) |m| {
            switch (m.role) {
                .assistant => if (parseStoredStep(arena, m.content)) |step| {
                    try self.collectStep(arena, step);
                    pending_command = if (std.mem.eql(u8, step.action, "bash")) step.action_input else null;
                } else |_| {},
                .user => {
                    try self.collectObservation(arena, m.content, pending_command);
                    pending_command = null;
                },
                .system, .tool => {},
            }
        }
    }

    fn collectStep(self: *Extract, arena: std.mem.Allocator, step: StoredStep) !void {
        if (std.mem.eql(u8, step.action, "bash")) {
            // Command outcome is paired with the following observation when present.
        } else if (std.mem.eql(u8, step.action, "file_read") or
            std.mem.eql(u8, step.action, "grep") or
            std.mem.eql(u8, step.action, "glob") or
            std.mem.eql(u8, step.action, "outline") or
            std.mem.eql(u8, step.action, "skill"))
        {
            try appendActionInput(arena, &self.reads, step.action, step.action_input);
        } else if (std.mem.eql(u8, step.action, "file_write") or
            std.mem.eql(u8, step.action, "file_edit"))
        {
            try appendActionInput(arena, &self.writes, step.action, step.action_input);
        } else if (std.mem.eql(u8, step.action, "http_request") or
            std.mem.eql(u8, step.action, "parallel"))
        {
            try appendActionInput(arena, &self.notes, step.action, step.action_input);
        }
    }

    fn collectObservation(self: *Extract, arena: std.mem.Allocator, content: []const u8, pending_command: ?[]const u8) !void {
        const first = firstLine(content);
        if (std.mem.indexOf(u8, content, "动作被执行护栏拒绝") != null or
            std.mem.indexOf(u8, content, "policy") != null)
        {
            if (pending_command) |cmd| {
                try appendClipped(arena, &self.denials, try std.fmt.allocPrint(arena, "{s} -> {s}", .{ cmd, first }));
            } else {
                try appendClipped(arena, &self.denials, first);
            }
        } else if (std.mem.startsWith(u8, content, "[观察] 工具执行失败")) {
            try appendClipped(arena, &self.notes, first);
        } else if (pending_command) |cmd| {
            if (std.mem.startsWith(u8, content, "[观察] 退出码=")) {
                try appendClipped(arena, &self.commands, try std.fmt.allocPrint(arena, "{s} -> {s}", .{ cmd, first }));
            } else {
                try appendClipped(arena, &self.commands, cmd);
            }
        } else if (std.mem.startsWith(u8, content, "[观察] 已写入") or
            std.mem.startsWith(u8, content, "[观察] 已编辑"))
        {
            try appendClipped(arena, &self.writes, first);
        } else if (std.mem.indexOf(u8, content, "TODO") != null or
            std.mem.indexOf(u8, content, "todo") != null)
        {
            try appendClipped(arena, &self.notes, first);
        }
    }
};

const StoredStep = struct {
    thought: []const u8 = "",
    action: []const u8,
    action_input: []const u8,
};

fn buildExtractiveMarker(
    gpa: std.mem.Allocator,
    dropped: []const llm.Message,
    elided_count: usize,
    elided_bytes: usize,
    keep_recent: usize,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var ex: Extract = .{};
    try ex.collect(scratch, dropped);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendFmt(
        gpa,
        &out,
        "[历史压缩:extractive] 已折叠较早的 {d} 条消息（约 {d} 字节）。system 指令、原始任务与最近 {d} 条消息已保留；以下是确定式抽取纪要，不替代 transcript 原文。\n",
        .{ elided_count, elided_bytes, keep_recent },
    );
    try appendSection(gpa, &out, "文件/检索", ex.reads.items);
    try appendSection(gpa, &out, "文件变更", ex.writes.items);
    try appendSection(gpa, &out, "命令", ex.commands.items);
    try appendSection(gpa, &out, "拒绝/错误", ex.denials.items);
    try appendSection(gpa, &out, "待办/观察", ex.notes.items);
    if (ex.reads.items.len == 0 and ex.writes.items.len == 0 and ex.commands.items.len == 0 and
        ex.denials.items.len == 0 and ex.notes.items.len == 0)
    {
        try out.appendSlice(gpa, "- 未抽取到稳定结构化事实；如需更早细节请从 transcript 取回。\n");
    }
    return out.toOwnedSlice(gpa);
}

fn appendSection(gpa: std.mem.Allocator, out: *std.ArrayList(u8), title: []const u8, items: []const []const u8) !void {
    if (items.len == 0) return;
    try appendFmt(gpa, out, "- {s}：", .{title});
    const n = @min(items.len, max_extract_items);
    for (items[0..n], 0..) |item, i| {
        if (i != 0) try out.appendSlice(gpa, "；");
        try out.appendSlice(gpa, item);
    }
    if (items.len > n) try appendFmt(gpa, out, "；另 {d} 项", .{items.len - n});
    try out.append(gpa, '\n');
}

fn appendFmt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}

fn parseStoredStep(arena: std.mem.Allocator, content: []const u8) !StoredStep {
    const json = firstJsonObject(content) orelse return error.MalformedStep;
    return std.json.parseFromSliceLeaky(StoredStep, arena, json, .{ .ignore_unknown_fields = true }) catch error.MalformedStep;
}

fn firstJsonObject(content: []const u8) ?[]const u8 {
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

fn unwrapJsonFence(content: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, content, "```")) return content;
    var rest = content[3..];
    if (std.mem.startsWith(u8, rest, "json")) rest = rest[4..];
    rest = std.mem.trim(u8, rest, " \t\r\n");
    if (std.mem.endsWith(u8, rest, "```")) rest = rest[0 .. rest.len - 3];
    return std.mem.trim(u8, rest, " \t\r\n");
}

fn appendActionInput(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), action: []const u8, input: []const u8) !void {
    try appendClipped(arena, list, try std.fmt.allocPrint(arena, "{s} {s}", .{ action, input }));
}

fn appendClipped(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), text: []const u8) !void {
    if (list.items.len >= max_extract_items + 1) return;
    const clean = oneLine(text);
    const n = @min(clean.len, max_extract_item_bytes);
    try list.append(arena, try arena.dupe(u8, clean[0..n]));
}

fn oneLine(text: []const u8) []const u8 {
    return firstLine(std.mem.trim(u8, text, " \t\r\n"));
}

fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '\n')) |idx| return text[0..idx];
    return text;
}

const max_extract_items = 6;
const max_extract_item_bytes = 160;

test "drop: 保留 system+原始任务+最近 K，中段替换为标记，内容正确释放" {
    const gpa = std.testing.allocator;
    var s = session.Session.init("c1");
    defer s.deinit(gpa);

    try s.append(gpa, .system, "SYS-PROMPT");
    try s.append(gpa, .user, "ORIGINAL-GOAL");
    try s.append(gpa, .assistant, "old-a");
    try s.append(gpa, .user, "old-u");
    try s.append(gpa, .assistant, "recent-a");
    try s.append(gpa, .user, "recent-u");

    const did = try default.compact(gpa, &s, .{ .keep_recent = 2 });
    try std.testing.expect(did);
    try std.testing.expectEqual(@as(usize, 5), s.count());
    try std.testing.expectEqualStrings("SYS-PROMPT", s.items()[0].content);
    try std.testing.expectEqualStrings("ORIGINAL-GOAL", s.items()[1].content);
    try std.testing.expect(std.mem.indexOf(u8, s.items()[2].content, "已省略较早的 2 条消息") != null);
    try std.testing.expectEqualStrings("recent-a", s.items()[3].content);
    try std.testing.expectEqualStrings("recent-u", s.items()[4].content);
}

test "drop: 无可压缩中段时返回 false" {
    const gpa = std.testing.allocator;
    var s = session.Session.init("c2");
    defer s.deinit(gpa);

    try s.append(gpa, .system, "SYS");
    try s.append(gpa, .user, "GOAL");
    try s.append(gpa, .assistant, "A");

    try std.testing.expect(!try default.compact(gpa, &s, .{ .keep_recent = 100 }));
    try std.testing.expectEqual(@as(usize, 3), s.count());
}

test "extractive: 抽取文件、命令与拒绝信号并保留首尾" {
    const gpa = std.testing.allocator;
    var s = session.Session.init("c3");
    defer s.deinit(gpa);

    try s.append(gpa, .system, "SYS");
    try s.append(gpa, .user, "GOAL");
    try s.append(gpa, .assistant, "{\"thought\":\"读\",\"action\":\"file_read\",\"action_input\":\"{\\\"path\\\":\\\"src/main.zig\\\"}\"}");
    try s.append(gpa, .user, "[观察] 读取 src/main.zig（10 字节）：\nconst x=1;");
    try s.append(gpa, .assistant, "{\"thought\":\"跑测试\",\"action\":\"bash\",\"action_input\":\"zig build test\"}");
    try s.append(gpa, .user, "[观察] 退出码=0\n--- stdout ---\nok");
    try s.append(gpa, .assistant, "{\"thought\":\"写\",\"action\":\"file_write\",\"action_input\":\"{\\\"path\\\":\\\"README.md\\\",\\\"content\\\":\\\"x\\\"}\"}");
    try s.append(gpa, .user, "[观察] 已写入 README.md（1 字节）。");
    try s.append(gpa, .assistant, "{\"thought\":\"危险\",\"action\":\"bash\",\"action_input\":\"rm -rf /\"}");
    try s.append(gpa, .user, "[观察] 动作被执行护栏拒绝（guarded 模式）：危险命令。");
    try s.append(gpa, .assistant, "RECENT-A");
    try s.append(gpa, .user, "RECENT-U");

    const c = Compressor{ .extractive = {} };
    try std.testing.expect(try c.compact(gpa, &s, .{ .keep_recent = 2 }));

    try std.testing.expectEqual(@as(usize, 5), s.count());
    try std.testing.expectEqualStrings("SYS", s.items()[0].content);
    try std.testing.expectEqualStrings("GOAL", s.items()[1].content);
    const summary = s.items()[2].content;
    try std.testing.expect(std.mem.indexOf(u8, summary, "历史压缩:extractive") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "file_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "zig build test") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "退出码=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "护栏拒绝") != null);
    try std.testing.expectEqualStrings("RECENT-A", s.items()[3].content);
    try std.testing.expectEqualStrings("RECENT-U", s.items()[4].content);
}

test "fromString: 未知策略回落 drop" {
    try std.testing.expectEqual(Compressor.drop, std.meta.activeTag(fromString("drop")));
    try std.testing.expectEqual(Compressor.extractive, std.meta.activeTag(fromString("extractive")));
    try std.testing.expectEqual(Compressor.drop, std.meta.activeTag(fromString("semantic")));
}
