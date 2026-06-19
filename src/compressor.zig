//! 上下文压缩策略接缝。
//!
//! Session 负责保存与落盘消息；Compressor 负责决定超预算时怎样把历史折叠。
//! M0 仅提供 `drop`，逐字保持旧的有损标记行为，为后续 `extractive` / `plugin:*`
//! 留出替换点。
const std = @import("std");
const llm = @import("llm.zig");
const session = @import("session.zig");

pub const Options = struct {
    keep_recent: usize,
};

pub const Compressor = union(enum) {
    drop: void,

    pub fn compact(self: Compressor, gpa: std.mem.Allocator, sess: *session.Session, opts: Options) !bool {
        return switch (self) {
            .drop => try dropCompact(gpa, sess, opts.keep_recent),
        };
    }
};

pub const default: Compressor = .{ .drop = {} };

/// 旧行为的命名实现：保留 system + 原始 user 任务 + 最近 K 条，
/// 把中间整段较早消息替换为一条有损摘要标记。
fn dropCompact(gpa: std.mem.Allocator, sess: *session.Session, keep_recent: usize) !bool {
    const msgs = sess.messages.items;
    const n = msgs.len;
    const prefix: usize = @min(n, 2);
    if (n <= prefix + keep_recent) return false;
    const drop_start = prefix;
    const drop_end = n - keep_recent;
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

    k = drop_start;
    while (k < drop_end) : (k += 1) gpa.free(msgs[k].content);

    sess.messages.deinit(gpa);
    sess.messages = rebuilt;
    return true;
}

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
