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

pub const Agent = struct {
    client: *llm.Client,
    mode: Mode = .goal,
    max_turns: u32 = 32,

    pub fn init(client: *llm.Client) Agent {
        return .{ .client = client };
    }

    /// 围绕一个会话运行任务，直至完成或达到回合上限。
    /// `backing` 是进程级长寿命分配器；每回合在其上派生 arena，回合末整体释放。
    /// `sess` 持有跨回合存活的消息历史（须由调用方预先 append 初始 user 目标）；
    /// 历史不放进回合 arena，因此不受每轮 `arena_state.deinit()` 影响。
    pub fn run(self: *Agent, backing: std.mem.Allocator, sess: *session.Session) !void {
        var turn: u32 = 0;
        while (turn < self.max_turns) : (turn += 1) {
            var arena_state = std.heap.ArenaAllocator.init(backing);
            defer arena_state.deinit(); // 回合制内存：每轮临时分配整体释放。
            const arena = arena_state.allocator();

            // 历史存活于 sess（backing 拥有），可直接喂给 LLM；本回合临时分配走 arena。
            const completion = self.client.chat(arena, sess.items()) catch |err| {
                // TODO: 若为脏 JSON 解析失败，包装成 System Error append 回 sess 触发重试，而非中断。
                return err;
            };
            // 把模型输出落入会话历史（复制进 backing，独立于本回合 arena）。
            try sess.append(backing, .assistant, completion.content);

            // TODO: 1) 校验并执行工具（硬超时）2) 把观察结果 append(.tool, ...) 回灌下一回合
            //       3) 判定任务完成则 break。
            return error.NotImplemented;
        }
        return error.MaxTurnsExceeded;
    }
};

test {
    std.testing.refAllDecls(@This());
}
