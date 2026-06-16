//! 认知流引擎：思考–行动–观察（ReACT）闭环。
//!
//! 设计取向（见 ROADMAP 方向二 / 铁律 #2 #4）：
//!   - 不依赖后端的「原生 tool_calls」（本地小模型支持参差），而是每一回合都用
//!     强制 json_schema 让模型产出一个结构化「步骤」：{thought, action, action_input}。
//!     这既守住铁律 #2（始终 response_format=json_schema + strict），又对任何
//!     OpenAI 兼容后端（含简陋本地模型）稳健，且复用已验证的防弹解析路径。
//!   - action ∈ {bash, final}：bash 走统一工具沙盒（带硬超时）执行，输出作为
//!     「观察」回灌；final 即终态答复。
//!
//! 内存策略：每个推理回合派生局部 ArenaAllocator，回合末整体 deinit 重置，
//! 从根上杜绝常驻进程的内存碎片与泄漏（见 ROADMAP 方向一）。跨回合存活的对话
//! 历史落在 `backing`（经 Session 复制），不受回合 arena 影响。
const std = @import("std");
const llm = @import("llm.zig");
const session = @import("session.zig");
const tools = @import("tools/tools.zig");
const audit = @import("audit.zig");

/// 双轨认知模式（见 ROADMAP 方向二）。
pub const Mode = enum {
    /// 目标模式：宏大指令 + 自主探索纠错（ReACT）。
    goal,
    /// 计划模式：先产出执行 DAG，经审计后严格按步执行。
    plan,
};

/// 每回合的结构化输出 Schema（铁律 #2）：强制模型只产出一个 ReACT 步骤。
/// `action` 用 enum 收口到已知动作，`additionalProperties:false` + 全 required 满足 strict。
const react_schema =
    \\{"type":"object","properties":{"thought":{"type":"string"},"action":{"type":"string","enum":["bash","final"]},"action_input":{"type":"string"}},"required":["thought","action","action_input"],"additionalProperties":false}
;

/// 注入会话的系统提示：向模型讲清 ReACT 协议与工具约束。
pub const system_prompt =
    \\你是 Scoot，一个运行在命令行环境中的自主 AI 助手，通过「思考-行动-观察」循环完成用户任务。
    \\
    \\每一步都只输出一个 JSON 对象，严格匹配给定 schema，包含三个字段：
    \\  - "thought"：一句话说明你的推理。
    \\  - "action"："bash" 或 "final"。
    \\  - "action_input"：当 action 为 "bash" 时是要执行的 shell 命令；为 "final" 时是给用户的最终答复。
    \\
    \\工作方式：
    \\  - 需要查看系统、读文件或运行命令时，用 action="bash"；命令会在带硬超时的沙盒里执行，其输出会作为下一条「观察」返回给你。
    \\  - 只使用非交互、会自行结束的命令；不要执行危险或破坏性操作。
    \\  - 收集到足够信息后，用 action="final" 给出简洁、直接的答复。
    \\  - 除这个 JSON 对象外，不要输出任何额外文本。
;

/// 模型可选的动作。
pub const Action = enum { bash, final };

/// 一个解析后的 ReACT 步骤。
pub const Step = struct {
    thought: []const u8,
    action: Action,
    action_input: []const u8,
};

/// 获取下一条补全的抽象（测试可注入脚本化大脑，无需真实后端）。
/// 默认实现 `clientComplete` 直接转调 `llm.Client.chat`。
pub const CompleteFn = *const fn (
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    messages: []const llm.Message,
    opts: llm.ChatOptions,
) anyerror!llm.Completion;

pub const Agent = struct {
    io: std.Io,
    complete_ctx: *anyopaque,
    complete_fn: CompleteFn,
    mode: Mode = .goal,
    /// 回合上限：防止模型陷入工具调用死循环拖垮守护进程。
    max_turns: u32 = 16,
    /// 单条工具调用的硬超时（毫秒）。
    tool_timeout_ms: u64 = 30_000,
    /// 可选审计日志：非 null 时把每步 思考/工具调用/观察/终态/错误 留痕（铁律：可审计）。
    /// 注入式，测试可挂内存 writer 验证；审计写入失败不阻断任务（最终在 flush 处暴露）。
    audit: ?*audit.Logger = null,

    /// 用真实 LLM 后端构造 Agent。
    pub fn initClient(client: *llm.Client) Agent {
        return .{ .io = client.io, .complete_ctx = client, .complete_fn = clientComplete };
    }

    fn complete(
        self: *Agent,
        arena: std.mem.Allocator,
        messages: []const llm.Message,
        opts: llm.ChatOptions,
    ) anyerror!llm.Completion {
        return self.complete_fn(self.complete_ctx, arena, messages, opts);
    }

    /// 围绕一个会话运行 ReACT 闭环，返回最终回复文本（由 `backing` 拥有）。
    /// `backing` 是长寿命分配器；每回合在其上派生 arena，回合末整体释放。
    /// `sess` 持有跨回合存活的消息历史（须由调用方预先 append 初始 system / user 消息）。
    pub fn run(self: *Agent, backing: std.mem.Allocator, sess: *session.Session) ![]const u8 {
        var turn: u32 = 0;
        while (turn < self.max_turns) : (turn += 1) {
            var arena_state = std.heap.ArenaAllocator.init(backing);
            defer arena_state.deinit(); // 回合制内存：每轮临时分配整体释放。
            const arena = arena_state.allocator();

            const completion = try self.complete(arena, sess.items(), .{
                .json_schema = react_schema,
                .schema_name = "scoot_step",
            });
            // 原始结构化输出落入会话历史（复制进 backing，独立于本回合 arena）。
            try sess.append(backing, .assistant, completion.content);

            // 防弹解析（铁律 #4）：模型没吐合法步骤时不 panic，把错误作为观察回灌触发重试。
            const step = parseStep(arena, completion.content) catch {
                if (self.audit) |lg| lg.log(.system_error, "模型输出不是合法步骤 JSON，已回灌纠错并重试") catch {};
                try sess.append(backing, .user, malformed_hint);
                continue;
            };
            if (self.audit) |lg| lg.log(.thought, step.thought) catch {};

            switch (step.action) {
                .final => {
                    if (self.audit) |lg| lg.log(.final, step.action_input) catch {};
                    return try backing.dupe(u8, step.action_input);
                },
                .bash => {
                    if (self.audit) |lg| lg.log(.tool_call, step.action_input) catch {};
                    const observation = self.runBash(arena, step.action_input) catch |err|
                        try std.fmt.allocPrint(arena, "[观察] 工具执行失败：{s}", .{@errorName(err)});
                    if (self.audit) |lg| lg.log(.observation, observation) catch {};
                    try sess.append(backing, .user, observation);
                },
            }
        }
        return error.MaxTurnsExceeded;
    }

    /// 执行一条 bash 命令（带硬超时）并格式化成「观察」文本（arena 拥有）。
    fn runBash(self: *Agent, arena: std.mem.Allocator, command: []const u8) ![]u8 {
        const result = try tools.bash.run(arena, self.io, command, .{ .timeout_ms = self.tool_timeout_ms });
        return formatObservation(arena, result);
    }
};

/// 转调真实后端的默认补全实现。
fn clientComplete(
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    messages: []const llm.Message,
    opts: llm.ChatOptions,
) anyerror!llm.Completion {
    const client: *llm.Client = @ptrCast(@alignCast(ctx));
    return client.chat(arena, messages, opts);
}

/// 模型未产出合法步骤时回灌的纠错观察。
const malformed_hint = "[观察] 你上一条输出不是合法的步骤 JSON。请严格按 schema 只输出一个含 thought/action/action_input 的 JSON 对象。";

/// 单条流的输出在观察里的最大字节数，超出截断，避免脏/海量输出挤爆上下文。
const observation_stream_cap = 2000;

/// 防弹解析一个 ReACT 步骤。非法 JSON → MalformedStep；未知 action → UnknownAction。
pub fn parseStep(arena: std.mem.Allocator, content: []const u8) !Step {
    const Raw = struct {
        thought: []const u8 = "",
        action: []const u8,
        action_input: []const u8 = "",
    };
    const v = std.json.parseFromSliceLeaky(Raw, arena, content, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedStep;

    const action: Action = if (std.mem.eql(u8, v.action, "bash"))
        .bash
    else if (std.mem.eql(u8, v.action, "final"))
        .final
    else
        return error.UnknownAction;

    return .{ .thought = v.thought, .action = action, .action_input = v.action_input };
}

/// 把工具执行结果格式化成回灌给模型的「观察」文本（arena 拥有）。
fn formatObservation(arena: std.mem.Allocator, r: tools.Result) ![]u8 {
    if (r.timed_out) {
        return arena.dupe(u8, "[观察] 命令超过硬超时被强制终止，无输出。请改用更快、会自行结束的命令。");
    }
    const out = try clip(arena, r.stdout);
    const err = try clip(arena, r.stderr);
    return std.fmt.allocPrint(
        arena,
        "[观察] 退出码={d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
        .{ r.exit_code, out, err },
    );
}

/// 截断过长的输出流，超出时附带说明（arena 拥有；不超长则原样返回）。
fn clip(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len <= observation_stream_cap) return s;
    return std.fmt.allocPrint(
        arena,
        "{s}\n…（输出已截断，共 {d} 字节）",
        .{ s[0..observation_stream_cap], s.len },
    );
}

test "parseStep 解析合法步骤" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try parseStep(arena, "{\"thought\":\"看看\",\"action\":\"bash\",\"action_input\":\"ls -a\"}");
    try std.testing.expectEqual(Action.bash, s.action);
    try std.testing.expectEqualStrings("ls -a", s.action_input);

    const f = try parseStep(arena, "{\"thought\":\"好了\",\"action\":\"final\",\"action_input\":\"完成\"}");
    try std.testing.expectEqual(Action.final, f.action);
    try std.testing.expectEqualStrings("完成", f.action_input);
}

test "parseStep 防弹：非法 JSON 与未知动作" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.MalformedStep, parseStep(arena, "not json"));
    try std.testing.expectError(error.MalformedStep, parseStep(arena, "{\"action\":}"));
    try std.testing.expectError(error.UnknownAction, parseStep(arena, "{\"action\":\"rmrf\",\"action_input\":\"x\"}"));
}

test "formatObservation 正常 / 超时 / 截断" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const normal = try formatObservation(arena, .{ .stdout = "hi", .stderr = "", .exit_code = 0 });
    try std.testing.expect(std.mem.indexOf(u8, normal, "退出码=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, normal, "hi") != null);

    const t = try formatObservation(arena, .{ .timed_out = true });
    try std.testing.expect(std.mem.indexOf(u8, t, "超时") != null);

    const big = try arena.alloc(u8, observation_stream_cap + 500);
    @memset(big, 'x');
    const clipped = try formatObservation(arena, .{ .stdout = big, .exit_code = 0 });
    try std.testing.expect(std.mem.indexOf(u8, clipped, "已截断") != null);
}

/// 测试用「脚本化大脑」：按顺序吐出预设的步骤 JSON，无需真实后端即可驱动循环。
const ScriptedBrain = struct {
    steps: []const []const u8,
    idx: usize = 0,
};

fn scriptedComplete(
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    messages: []const llm.Message,
    opts: llm.ChatOptions,
) anyerror!llm.Completion {
    _ = messages;
    _ = opts;
    const self: *ScriptedBrain = @ptrCast(@alignCast(ctx));
    if (self.idx >= self.steps.len) return error.ScriptExhausted;
    const content = self.steps[self.idx];
    self.idx += 1;
    return .{ .content = try arena.dupe(u8, content), .finish_reason = "stop" };
}

fn testAgent(brain: *ScriptedBrain, max_turns: u32) Agent {
    return .{
        .io = std.testing.io,
        .complete_ctx = brain,
        .complete_fn = scriptedComplete,
        .max_turns = max_turns,
    };
}

test "run: ReACT 循环执行 bash 工具后给出最终答复" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"查看\",\"action\":\"bash\",\"action_input\":\"printf RESULT-42\"}",
        "{\"thought\":\"已知结果\",\"action\":\"final\",\"action_input\":\"答案是 RESULT-42\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, system_prompt);
    try sess.append(gpa, .user, "跑个命令并回答");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);

    try std.testing.expectEqualStrings("答案是 RESULT-42", reply);
    try std.testing.expectEqual(@as(usize, 2), brain.idx); // 恰好两次补全

    // 会话里应留有一条含真实命令输出的「观察」。
    var saw_observation = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "RESULT-42") != null and
            std.mem.indexOf(u8, m.content, "观察") != null) saw_observation = true;
    }
    try std.testing.expect(saw_observation);
}

test "run: 非法步骤触发自纠重试后仍能收敛" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "这不是 JSON",
        "{\"thought\":\"重来\",\"action\":\"final\",\"action_input\":\"已恢复\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "做点事");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);

    try std.testing.expectEqualStrings("已恢复", reply);
    var saw_hint = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "不是合法") != null) saw_hint = true;
    }
    try std.testing.expect(saw_hint);
}

test "run: 超过 max_turns 返回错误而非无限循环" {
    const gpa = std.testing.allocator;
    const bash_true = "{\"thought\":\"再来\",\"action\":\"bash\",\"action_input\":\"true\"}";
    var brain = ScriptedBrain{ .steps = &.{ bash_true, bash_true, bash_true, bash_true } };
    var ag = testAgent(&brain, 2);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "永不收敛");

    try std.testing.expectError(error.MaxTurnsExceeded, ag.run(gpa, &sess));
    try std.testing.expectEqual(@as(usize, 2), brain.idx); // 恰好用满 2 回合
}

test "run: 审计日志按序记录 thought/tool_call/observation/final 链路" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"查看\",\"action\":\"bash\",\"action_input\":\"printf OK\"}",
        "{\"thought\":\"完成\",\"action\":\"final\",\"action_input\":\"done\"}",
    } };
    var ag = testAgent(&brain, 16);

    var logbuf: [4096]u8 = undefined;
    var lw = std.Io.Writer.fixed(&logbuf);
    var logger = audit.Logger.init(&lw);
    ag.audit = &logger;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "go");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);

    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"thought\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"tool_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"final\"") != null);
    // 审计行必须是逐行合法 JSON（可回放）。
    var it = std.mem.tokenizeScalar(u8, log, '\n');
    while (it.next()) |line| {
        const v = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        v.deinit();
    }
}

test {
    std.testing.refAllDecls(@This());
}
