//! 认知流引擎：思考–行动–观察（ReACT）闭环。
//! 内存策略：每个推理回合派生局部 ArenaAllocator，回合末整体 deinit 重置，
//! 从根上杜绝常驻进程的内存碎片与泄漏（见 ROADMAP 方向一）。
const std = @import("std");
const llm = @import("llm.zig");
const session = @import("session.zig");

/// 双轨认知模式（见 ROADMAP 方向二）。
pub const Mode = enum {
    /// 目标模式：宏大指令 + 自主探索纠错（ReACT）。
    goal,
    /// 计划模式：先产出执行 DAG，经审计后严格按步执行。
    plan,
};

/// 阶段一的结构化输出 Schema：强制模型返回 {"reply": "..."}（铁律 #2）。
/// 后续接入工具时，这里会扩展为 ReACT 步骤（thought / action / action_input / final）。
const reply_schema =
    \\{"type":"object","properties":{"reply":{"type":"string"}},"required":["reply"],"additionalProperties":false}
;

pub const Agent = struct {
    client: *llm.Client,
    mode: Mode = .goal,
    max_turns: u32 = 32,

    pub fn init(client: *llm.Client) Agent {
        return .{ .client = client };
    }

    /// 围绕一个会话运行任务，返回最终回复文本（由 `backing` 拥有）。
    /// `backing` 是长寿命分配器；每回合在其上派生 arena，回合末整体释放。
    /// `sess` 持有跨回合存活的消息历史（须由调用方预先 append 初始 system / user 消息）；
    /// 历史不放进回合 arena，因此不受每轮 `arena_state.deinit()` 影响。
    pub fn run(self: *Agent, backing: std.mem.Allocator, sess: *session.Session) ![]const u8 {
        var turn: u32 = 0;
        while (turn < self.max_turns) : (turn += 1) {
            var arena_state = std.heap.ArenaAllocator.init(backing);
            defer arena_state.deinit(); // 回合制内存：每轮临时分配整体释放。
            const arena = arena_state.allocator();

            // 历史存活于 sess（backing 拥有），可直接喂给 LLM；本回合临时分配走 arena。
            const completion = try self.client.chat(arena, sess.items(), .{
                .json_schema = reply_schema,
                .schema_name = "scoot_reply",
            });
            // 原始结构化输出落入会话历史（复制进 backing，独立于本回合 arena）。
            try sess.append(backing, .assistant, completion.content);

            // 防弹解析结构化回复；模型没吐合法 JSON 时不 panic，退回原文展示。
            const reply = parseReply(backing, completion.content) catch
                return try backing.dupe(u8, completion.content);

            // 阶段一：无工具调用 → 首轮即终态。
            // TODO: 接入工具后，据 tool_calls 执行工具（硬超时）并把观察 append(.tool, ...) 回灌继续循环。
            return reply;
        }
        return error.MaxTurnsExceeded;
    }
};

/// 防弹解析 {"reply": "..."}，返回 `backing` 拥有的回复文本；非法 JSON 返回 MalformedReply。
fn parseReply(backing: std.mem.Allocator, content: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(backing);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Reply = struct { reply: []const u8 };
    const v = std.json.parseFromSliceLeaky(Reply, arena, content, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedReply;
    return backing.dupe(u8, v.reply);
}

test "parseReply 防弹解析结构化回复" {
    const gpa = std.testing.allocator;
    const r = try parseReply(gpa, "{\"reply\":\"hi 世界\"}");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("hi 世界", r);
    try std.testing.expectError(error.MalformedReply, parseReply(gpa, "not json"));
}

test {
    std.testing.refAllDecls(@This());
}
