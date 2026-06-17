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
const policy = @import("policy.zig");

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
    \\{"type":"object","properties":{"thought":{"type":"string"},"action":{"type":"string","enum":["bash","file_read","file_write","file_edit","grep","glob","http_request","final"]},"action_input":{"type":"string"}},"required":["thought","action","action_input"],"additionalProperties":false}
;

/// 注入会话的系统提示：向模型讲清 ReACT 协议与工具约束。
pub const system_prompt =
    \\你是 Scoot，一个运行在命令行环境中的自主 AI 助手，通过「思考-行动-观察」循环完成用户任务。
    \\
    \\每一步都只输出一个 JSON 对象，严格匹配给定 schema，包含三个字段：
    \\  - "thought"：一句话说明你的推理。
    \\  - "action"：下列动作之一。
    \\  - "action_input"：该动作的输入，格式见下。
    \\
    \\可用动作：
    \\  - "bash"：执行一条 shell 命令；action_input 是命令字符串。命令在 POSIX sh（/bin/sh）的带硬超时沙盒里执行，其输出作为下一条「观察」返回。只用可移植的 POSIX 语法，避免 bash 专有写法（如 [[ ]]、数组、{1..10} 花括号展开、$'...'）。
    \\  - "file_read"：读取文件内容；action_input 是 JSON 对象 {"path":"文件路径"}。
    \\  - "file_write"：覆盖写入文件（不存在则创建）；action_input 是 JSON 对象 {"path":"文件路径","content":"完整新内容"}。
    \\  - "file_edit"：精确替换文件中的一段文本；action_input 是 JSON 对象 {"path":"文件路径","old":"要替换的确切文本（须在文件中唯一出现）","new":"替换成的文本"}。
    \\  - "grep"：在某个文件内按正则逐行搜索，返回命中行号与原文；action_input 是 JSON 对象 {"pattern":"正则","path":"文件路径"}。支持子集：. ^ $ * + ? [] () | \d \w \s（不支持捕获组/反向引用/lookaround/惰性量词）。
    \\  - "glob"：在目录子树下按通配模式列出匹配的文件路径；action_input 是 JSON 对象 {"pattern":"通配模式","root":"起始目录（可选，默认 .）"}。* ? [] 不跨 /，** 跨目录层级。返回的路径可直接喂给 file_read / grep。
    \\  - "http_request"：发起一次 HTTP/HTTPS 请求；action_input 是 JSON 对象 {"method":"GET","url":"https://...","body":"可选请求体"}。method 取 GET/POST/PUT/DELETE/HEAD/PATCH。返回状态码与响应体；带硬超时，绝不挂死。
    \\  - "final"：给出最终答复；action_input 是给用户的答复文本。
    \\
    \\工作方式：
    \\  - 读写文件优先用 file_read / file_write / file_edit —— 它们不依赖外部命令，在任何环境（含裁剪 / 嵌入式 Linux）都可靠一致。
    \\  - 查找文件用 glob、搜索文件内容用 grep —— 同样不依赖外部命令，优先于 ls/find/grep 等系统命令。
    \\  - 访问网络用 http_request —— 不依赖 curl/wget，带硬超时，HTTPS 自动协商。
    \\  - 其他系统操作用 bash；只使用非交互、会自行结束的命令，不要执行危险或破坏性操作。
    \\  - file_edit 的 old 必须在文件中唯一出现；若不确定，先用 file_read 看清确切内容。
    \\  - 收集到足够信息后，用 "final" 给出简洁、直接的答复。
    \\  - 除这个 JSON 对象外，不要输出任何额外文本。
;

/// 模型可选的动作。
pub const Action = enum { bash, file_read, file_write, file_edit, grep, glob, http_request, final };

/// 一个解析后的 ReACT 步骤。
pub const Step = struct {
    thought: []const u8,
    action: Action,
    action_input: []const u8,
};

/// 多参数内建工具的 action_input 承载一个 JSON 对象字符串，按工具二次解析。
/// 单参数工具（如 file_read）同样走 JSON（{"path":...}），统一「文件类工具 = JSON 参数」
/// 这条规则，降低小模型「何时裸串、何时 JSON」的认知负担。bash / final 仍是裸文本。
const FileReadArgs = struct { path: []const u8 };
const FileWriteArgs = struct { path: []const u8, content: []const u8 };
const FileEditArgs = struct { path: []const u8, old: []const u8, new: []const u8 };
const GrepArgs = struct { pattern: []const u8, path: []const u8 };
const GlobArgs = struct { pattern: []const u8, root: []const u8 = "." };
const HttpArgs = struct { method: []const u8 = "GET", url: []const u8, body: ?[]const u8 = null };

/// 防弹解析工具参数 JSON：失败统一收口为 error.MalformedArgs，由调用处回灌纠错
/// （铁律 #4：绝不信任模型输出，畸形参数不 panic 而是反馈让模型重试）。
fn parseToolArgs(comptime T: type, arena: std.mem.Allocator, input: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, input, .{
        .ignore_unknown_fields = true,
    }) catch error.MalformedArgs;
}

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
    /// 执行护栏模式（铁律：未经验证的模型输出不落系统）。bash 命令执行前必过此门。
    policy_mode: policy.Mode = .guarded,
    /// 自定义 CA bundle（PEM）绝对路径，传给 http_request 工具；null = 系统根证书。
    ca_file: ?[]const u8 = null,
    /// 可选 CLI 执行轨迹输出。仅用于显式调试；最终答复仍由调用方写 stdout。
    trace: ?*std.Io.Writer = null,

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
                self.traceMalformed(turn + 1);
                try sess.append(backing, .user, malformed_hint);
                continue;
            };
            if (self.audit) |lg| lg.log(.thought, step.thought) catch {};
            self.traceStep(turn + 1, step);

            switch (step.action) {
                .final => {
                    if (self.audit) |lg| lg.log(.final, step.action_input) catch {};
                    self.traceFinal(turn + 1, step.action_input);
                    return try backing.dupe(u8, step.action_input);
                },
                // 其余皆为工具类动作（bash + 内建 file_*）：统一「留痕 → 执行护栏 → 执行/回灌」。
                else => {
                    if (self.audit) |lg| lg.log(.tool_call, step.action_input) catch {};
                    // 铁律：模型产出的动作必须先过执行护栏，绝不直接落到系统上。
                    switch (self.guard(arena, step.action, step.action_input)) {
                        .deny => |reason| {
                            self.tracePolicyDeny(turn + 1, reason);
                            const denied = try std.fmt.allocPrint(
                                arena,
                                "[观察] 动作被执行护栏拒绝（{s} 模式）：{s}。请改用更安全或只读的方式达成目标。",
                                .{ @tagName(self.policy_mode), reason },
                            );
                            if (self.audit) |lg| lg.log(.policy_deny, denied) catch {};
                            try sess.append(backing, .user, denied);
                        },
                        .allow => {
                            self.tracePolicyAllow(turn + 1);
                            const observation = self.execTool(arena, step.action, step.action_input) catch |err|
                                try toolErrorObservation(arena, err);
                            if (self.audit) |lg| lg.log(.observation, observation) catch {};
                            self.traceObservation(turn + 1, observation);
                            try sess.append(backing, .user, observation);
                        },
                    }
                },
            }
        }
        return error.MaxTurnsExceeded;
    }

    /// 按动作类别选择执行护栏：bash 解析命令字符串（可经 shell 任意执行，须逐串审查）；
    /// 内建工具的读/写/网络语义静态已知，按能力分类判定（见 policy.evaluateTool）。
    fn guard(self: *Agent, arena: std.mem.Allocator, action: Action, input: []const u8) policy.Decision {
        return switch (action) {
            .bash => policy.evaluate(arena, input, self.policy_mode),
            .file_read, .grep, .glob => policy.evaluateTool(.read, self.policy_mode),
            .file_write, .file_edit => policy.evaluateTool(.write, self.policy_mode),
            .http_request => self.guardHttp(arena, input),
            .final => unreachable,
        };
    }

    /// http_request 按方法分类能力：GET/HEAD→net_read，写类方法→net_write。
    /// readonly 下 net_read/net_write 均拒绝，避免本地读结果经网络外带。
    /// 参数畸形 / 未知方法 → 按最严格的 net_write 判定（readonly 下拒绝，fail-closed）。
    fn guardHttp(self: *Agent, arena: std.mem.Allocator, input: []const u8) policy.Decision {
        const cap: policy.Capability = blk: {
            const args = parseToolArgs(HttpArgs, arena, input) catch break :blk .net_write;
            const m = tools.http.methodFromString(args.method) orelse break :blk .net_write;
            break :blk if (tools.http.isWrite(m)) .net_write else .net_read;
        };
        return policy.evaluateTool(cap, self.policy_mode);
    }

    /// 执行一个已过护栏的工具动作，返回回灌给模型的「观察」文本（arena 拥有）。
    /// 任何失败（参数畸形 / IO 错误 / 超时）都以 error 上抛，由调用处转成观察回灌，
    /// 全程不 panic（铁律 #4）。
    fn execTool(self: *Agent, arena: std.mem.Allocator, action: Action, input: []const u8) ![]const u8 {
        return switch (action) {
            .bash => try self.runBash(arena, input),
            .file_read => blk: {
                const args = try parseToolArgs(FileReadArgs, arena, input);
                const content = try tools.file.read(arena, self.io, args.path, tools.file.default_read_limit);
                break :blk try std.fmt.allocPrint(
                    arena,
                    "[观察] 读取 {s}（{d} 字节）：\n{s}",
                    .{ args.path, content.len, try clipTo(arena, content, file_read_observation_cap) },
                );
            },
            .file_write => blk: {
                const args = try parseToolArgs(FileWriteArgs, arena, input);
                try tools.file.write(self.io, args.path, args.content);
                break :blk try std.fmt.allocPrint(
                    arena,
                    "[观察] 已写入 {s}（{d} 字节）。",
                    .{ args.path, args.content.len },
                );
            },
            .file_edit => blk: {
                const args = try parseToolArgs(FileEditArgs, arena, input);
                const out = try tools.file.edit(arena, self.io, args.path, args.old, args.new, tools.file.default_read_limit);
                break :blk try std.fmt.allocPrint(
                    arena,
                    "[观察] 已编辑 {s}：替换 1 处，文件现 {d} 字节。",
                    .{ args.path, out.len },
                );
            },
            .grep => blk: {
                const args = try parseToolArgs(GrepArgs, arena, input);
                const hits = try tools.search.grepFile(arena, self.io, args.pattern, args.path, tools.search.default_max_hits);
                break :blk try formatGrepHits(arena, args.path, hits);
            },
            .glob => blk: {
                const args = try parseToolArgs(GlobArgs, arena, input);
                const paths = try tools.search.glob(arena, self.io, args.pattern, args.root, tools.search.default_max_results);
                break :blk try formatGlobPaths(arena, args.pattern, paths);
            },
            .http_request => blk: {
                const args = try parseToolArgs(HttpArgs, arena, input);
                const method = tools.http.methodFromString(args.method) orelse return error.UnknownMethod;
                const resp = try tools.http.request(arena, self.io, method, args.url, args.body, .{
                    .timeout_ms = self.tool_timeout_ms,
                    .ca_file = self.ca_file,
                });
                break :blk try formatHttpResponse(arena, args.url, resp);
            },
            .final => unreachable,
        };
    }

    /// 执行一条 bash 命令（带硬超时）并格式化成「观察」文本（arena 拥有）。
    fn runBash(self: *Agent, arena: std.mem.Allocator, command: []const u8) ![]u8 {
        const result = try tools.bash.run(arena, self.io, command, .{ .timeout_ms = self.tool_timeout_ms });
        return formatObservation(arena, result);
    }

    fn traceMalformed(self: *Agent, turn: u32) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] malformed model step; retrying\n", .{turn}) catch return;
        w.flush() catch {};
    }

    fn traceStep(self: *Agent, turn: u32, step: Step) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] reason: ", .{turn}) catch return;
        traceClipped(w, step.thought, trace_reason_cap) catch return;
        w.print("\n[trace {d}] action: {s}", .{ turn, @tagName(step.action) }) catch return;
        if (step.action != .final and step.action_input.len > 0) {
            w.writeAll(" ") catch return;
            traceClipped(w, step.action_input, trace_action_input_cap) catch return;
        }
        w.writeAll("\n") catch return;
        w.flush() catch {};
    }

    fn tracePolicyAllow(self: *Agent, turn: u32) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] policy: allow ({s})\n", .{ turn, @tagName(self.policy_mode) }) catch return;
        w.flush() catch {};
    }

    fn tracePolicyDeny(self: *Agent, turn: u32, reason: []const u8) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] policy: deny ({s}) ", .{ turn, @tagName(self.policy_mode) }) catch return;
        traceClipped(w, reason, trace_reason_cap) catch return;
        w.writeAll("\n") catch return;
        w.flush() catch {};
    }

    fn traceObservation(self: *Agent, turn: u32, observation: []const u8) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] observe: ", .{turn}) catch return;
        traceClipped(w, observation, trace_observation_cap) catch return;
        w.writeAll("\n") catch return;
        w.flush() catch {};
    }

    fn traceFinal(self: *Agent, turn: u32, reply: []const u8) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] final: ", .{turn}) catch return;
        traceClipped(w, reply, trace_final_cap) catch return;
        w.writeAll("\n") catch return;
        w.flush() catch {};
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

/// file_read 观察的截断上限：比 bash 输出更宽（文件内容是模型主动读取、相对结构化，
/// 给更大窗口便于后续 file_edit 看清确切文本），但仍设上限挡住超大文件撑爆上下文。
const file_read_observation_cap = 8000;

/// CLI trace 只展示执行轨迹摘要，避免海量工具输出刷屏。
const trace_reason_cap = 240;
const trace_action_input_cap = 240;
const trace_observation_cap = 600;
const trace_final_cap = 240;

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

    // 按 enum tag 名映射动作；新增动作只需扩 Action enum，无需改这里（反过载）。
    const action = std.meta.stringToEnum(Action, v.action) orelse return error.UnknownAction;
    return .{ .thought = v.thought, .action = action, .action_input = v.action_input };
}

/// 把工具执行 / 参数解析的错误转成回灌给模型的「观察」文本（arena 拥有）。
/// 对常见错误给出可操作的纠正提示，引导模型自我修复（铁律 #4：失败即反馈而非中断）。
fn toolErrorObservation(arena: std.mem.Allocator, err: anyerror) ![]u8 {
    const hint = switch (err) {
        error.MalformedArgs => "action_input 不是合法的参数 JSON。file_read 用 {\"path\":\"...\"}；file_write 用 {\"path\":\"...\",\"content\":\"...\"}；file_edit 用 {\"path\":\"...\",\"old\":\"...\",\"new\":\"...\"}；grep 用 {\"pattern\":\"...\",\"path\":\"...\"}；glob 用 {\"pattern\":\"...\"}；http_request 用 {\"method\":\"GET\",\"url\":\"...\"}。",
        error.UnknownMethod => "http_request 的 method 无法识别。请用 GET/POST/PUT/DELETE/HEAD/PATCH 之一。",
        error.PatternNotFound => "file_edit 的 old 文本未在文件中找到。请先用 file_read 读出确切文本再编辑。",
        error.AmbiguousMatch => "file_edit 的 old 文本在文件中出现多次。请提供更长、唯一的上下文片段以定位。",
        error.EmptyPattern => "file_edit 的 old 不能为空。",
        error.InvalidPattern => "grep 的正则非法。支持子集：. ^ $ * + ? [] () | \\d \\w \\s；不支持捕获组/反向引用/lookaround/惰性量词。请简化模式。",
        error.PatternTooLong => "正则模式过长，请缩短。",
        error.FileNotFound => "目标文件不存在。请确认路径，或先用 file_write 创建它。",
        error.AccessDenied => "对目标路径没有访问权限。",
        error.IsDir => "目标路径是目录而非文件。",
        else => @errorName(err),
    };
    return std.fmt.allocPrint(arena, "[观察] 工具执行失败：{s}", .{hint});
}

/// 把 grep 命中格式化成「观察」文本（arena 拥有），无命中亦明示。受 file_read 上限截断。
fn formatGrepHits(arena: std.mem.Allocator, path: []const u8, hits: []const tools.search.Hit) ![]const u8 {
    if (hits.len == 0) {
        return std.fmt.allocPrint(arena, "[观察] grep 在 {s} 中无命中。", .{path});
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "[观察] grep {s} 命中 {d} 行：\n", .{ path, hits.len }));
    for (hits) |h| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}:{s}\n", .{ h.line, h.text }));
    }
    return clipTo(arena, buf.items, file_read_observation_cap);
}

/// 把 glob 匹配到的路径格式化成「观察」文本（arena 拥有），无匹配亦明示。
fn formatGlobPaths(arena: std.mem.Allocator, pattern: []const u8, paths: []const []const u8) ![]const u8 {
    if (paths.len == 0) {
        return std.fmt.allocPrint(arena, "[观察] glob {s} 无匹配。", .{pattern});
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "[观察] glob {s} 匹配 {d} 个：\n", .{ pattern, paths.len }));
    for (paths) |p| {
        try buf.appendSlice(arena, p);
        try buf.append(arena, '\n');
    }
    return clipTo(arena, buf.items, file_read_observation_cap);
}

/// 把 http 响应格式化成「观察」文本（arena 拥有）。超时 / 传输失败亦明示。受上限截断。
fn formatHttpResponse(arena: std.mem.Allocator, url: []const u8, resp: tools.http.Response) ![]const u8 {
    if (resp.timed_out) {
        return std.fmt.allocPrint(arena, "[观察] http {s} 超过硬超时被取消，无响应。请改用更快的端点或缩短请求。", .{url});
    }
    if (resp.err) |e| {
        return std.fmt.allocPrint(arena, "[观察] http {s} 请求失败：{s}（连接/TLS/DNS）。", .{ url, e });
    }
    const clipped = try clipTo(arena, resp.body, file_read_observation_cap);
    return std.fmt.allocPrint(
        arena,
        "[观察] http {s} 状态码={d}，响应体（{d} 字节）：\n{s}",
        .{ url, resp.status, resp.body.len, clipped },
    );
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
    return clipTo(arena, s, observation_stream_cap);
}

/// 按给定上限截断输出（arena 拥有；不超长则原样返回）。
fn clipTo(arena: std.mem.Allocator, s: []const u8, cap: usize) ![]const u8 {
    if (s.len <= cap) return s;
    return std.fmt.allocPrint(
        arena,
        "{s}\n…（输出已截断，共 {d} 字节）",
        .{ s[0..cap], s.len },
    );
}

/// 往 trace writer 写入限长文本；超出时附带剩余字节数。
fn traceClipped(w: *std.Io.Writer, s: []const u8, cap: usize) !void {
    const n = if (s.len > cap) cap else s.len;
    try w.writeAll(s[0..n]);
    if (s.len > n) {
        try w.print(" ...(+{d} bytes)", .{s.len - n});
    }
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

test "run: trace 输出 reason/action/policy/observation/final 到注入 writer" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"查看\",\"action\":\"bash\",\"action_input\":\"printf OK\"}",
        "{\"thought\":\"完成\",\"action\":\"final\",\"action_input\":\"done\"}",
    } };
    var ag = testAgent(&brain, 16);

    var tracebuf: [4096]u8 = undefined;
    var tw = std.Io.Writer.fixed(&tracebuf);
    ag.trace = &tw;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "go");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);

    const trace = tw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 1] reason: 查看") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 1] action: bash printf OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 1] policy: allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 1] observe: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 2] action: final") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 2] final: done") != null);
}

test "run: 危险命令被执行护栏拦截——不执行、留痕 policy_deny、回灌后改道收敛" {
    const gpa = std.testing.allocator;
    // 第一步吐危险命令（guarded 默认拦截），第二步改道给最终答复。
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"清理\",\"action\":\"bash\",\"action_input\":\"rm -rf /\"}",
        "{\"thought\":\"改用安全方式\",\"action\":\"final\",\"action_input\":\"已避免危险操作\"}",
    } };
    var ag = testAgent(&brain, 16); // policy_mode 默认 .guarded

    var logbuf: [4096]u8 = undefined;
    var lw = std.Io.Writer.fixed(&logbuf);
    var logger = audit.Logger.init(&lw);
    ag.audit = &logger;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "把磁盘清掉");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);

    try std.testing.expectEqualStrings("已避免危险操作", reply);

    // 拒绝必须留痕，且会话里出现回灌的「被拒」观察，但绝无该命令的真实执行输出。
    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
    var saw_denied = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "执行护栏拒绝") != null) saw_denied = true;
    }
    try std.testing.expect(saw_denied);
}

test "run: file_write→file_read→file_edit 全链路（guarded 放行写，磁盘可验证）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_file_flow";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    // 用 Zig 多行字符串字面量承载 JSON（含转义引号）：action_input 本身是一段 JSON 对象字符串。
    const s_write =
        \\{"thought":"写文件","action":"file_write","action_input":"{\"path\":\"/tmp/scoot_agent_file_flow/note.txt\",\"content\":\"hello world\"}"}
    ;
    const s_read =
        \\{"thought":"读回确认","action":"file_read","action_input":"{\"path\":\"/tmp/scoot_agent_file_flow/note.txt\"}"}
    ;
    const s_edit =
        \\{"thought":"改一处","action":"file_edit","action_input":"{\"path\":\"/tmp/scoot_agent_file_flow/note.txt\",\"old\":\"world\",\"new\":\"scoot\"}"}
    ;
    const s_final =
        \\{"thought":"完成","action":"final","action_input":"done"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_write, s_read, s_edit, s_final } };
    var ag = testAgent(&brain, 16); // 默认 guarded：内建写工具放行

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "建并改文件");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    // 磁盘上文件应被精确编辑为 "hello scoot"。
    const final_bytes = try cwd.readFileAlloc(io, dir ++ "/note.txt", gpa, .limited(1 << 16));
    defer gpa.free(final_bytes);
    try std.testing.expectEqualStrings("hello scoot", final_bytes);

    // file_read 的观察里应回灌写入内容，供后续编辑定位。
    var saw_read = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "hello world") != null and
            std.mem.indexOf(u8, m.content, "字节") != null) saw_read = true;
    }
    try std.testing.expect(saw_read);
}

test "run: readonly 安全档下 file_write 被护栏拒绝（不落盘、留痕 policy_deny、无 observation）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_file_ro";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const s_write =
        \\{"thought":"尝试写","action":"file_write","action_input":"{\"path\":\"/tmp/scoot_agent_file_ro/evil.txt\",\"content\":\"x\"}"}
    ;
    const s_final =
        \\{"thought":"改道","action":"final","action_input":"只读模式无法写"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_write, s_final } };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly; // 模拟无人值守强制安全档

    var logbuf: [4096]u8 = undefined;
    var lw = std.Io.Writer.fixed(&logbuf);
    var logger = audit.Logger.init(&lw);
    ag.audit = &logger;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "写个文件");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("只读模式无法写", reply);

    // 文件绝不应被创建（内建写工具不可绕过 readonly）。
    try std.testing.expectError(error.FileNotFound, cwd.readFileAlloc(io, dir ++ "/evil.txt", gpa, .limited(64)));

    // 留痕 policy_deny，且因写被拒、命令从未执行 → 无该步 observation。
    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
}

test "run: file 工具参数畸形→回灌纠错提示后以正确参数收敛（防弹重试）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_file_malformed";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    // 第一步 action_input 不是合法参数 JSON；过护栏后在执行处失败，转纠错观察回灌。
    const s_bad =
        \\{"thought":"写","action":"file_write","action_input":"not a json object"}
    ;
    const s_good =
        \\{"thought":"按格式重来","action":"file_write","action_input":"{\"path\":\"/tmp/scoot_agent_file_malformed/ok.txt\",\"content\":\"fixed\"}"}
    ;
    const s_final =
        \\{"thought":"完成","action":"final","action_input":"done"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_bad, s_good, s_final } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "写文件");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    // 回灌里应出现针对参数格式的纠错提示。
    var saw_hint = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "不是合法的参数 JSON") != null) saw_hint = true;
    }
    try std.testing.expect(saw_hint);

    // 模型按提示用正确参数重试，最终成功写盘。
    const bytes = try cwd.readFileAlloc(io, dir ++ "/ok.txt", gpa, .limited(64));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("fixed", bytes);
}

test "run: glob 找文件 → grep 搜内容 全链路（readonly 安全档亦放行，因 grep/glob 属只读）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_search_flow";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    try cwd.createDirPath(io, dir ++ "/src");
    try tools.file.write(io, dir ++ "/src/main.zig", "const x = 1;\npub fn main() void {}\n");
    try tools.file.write(io, dir ++ "/README.md", "# doc\n");

    const s_glob =
        \\{"thought":"找 zig 文件","action":"glob","action_input":"{\"pattern\":\"**/*.zig\",\"root\":\"/tmp/scoot_agent_search_flow\"}"}
    ;
    const s_grep =
        \\{"thought":"搜 main","action":"grep","action_input":"{\"pattern\":\"pub fn \\\\w+\",\"path\":\"/tmp/scoot_agent_search_flow/src/main.zig\"}"}
    ;
    const s_final =
        \\{"thought":"完成","action":"final","action_input":"found"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_glob, s_grep, s_final } };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly; // grep/glob 是 .read，只读档应放行

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "找并搜文件");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("found", reply);

    // glob 观察应列出命中的 .zig 路径；grep 观察应带行号命中 "pub fn main"。
    var saw_glob = false;
    var saw_grep = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "glob") != null and
            std.mem.indexOf(u8, m.content, "main.zig") != null) saw_glob = true;
        if (std.mem.indexOf(u8, m.content, "2:pub fn main() void {}") != null) saw_grep = true;
    }
    try std.testing.expect(saw_glob);
    try std.testing.expect(saw_grep);
}

test "run: grep 正则非法→回灌可操作纠错提示后改用合法模式收敛（防弹）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_grep_bad";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    try tools.file.write(io, dir ++ "/f.txt", "alpha\nbeta\n");

    // 第一步正则非法（未闭合的 '('）；执行处 compile 失败 → InvalidPattern 纠错回灌。
    const s_bad =
        \\{"thought":"搜","action":"grep","action_input":"{\"pattern\":\"(alpha\",\"path\":\"/tmp/scoot_agent_grep_bad/f.txt\"}"}
    ;
    const s_good =
        \\{"thought":"改合法模式","action":"grep","action_input":"{\"pattern\":\"alpha\",\"path\":\"/tmp/scoot_agent_grep_bad/f.txt\"}"}
    ;
    const s_final =
        \\{"thought":"完成","action":"final","action_input":"ok"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_bad, s_good, s_final } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "搜文件");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("ok", reply);

    var saw_hint = false;
    var saw_hit = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "正则非法") != null) saw_hint = true;
        if (std.mem.indexOf(u8, m.content, "1:alpha") != null) saw_hit = true;
    }
    try std.testing.expect(saw_hint);
    try std.testing.expect(saw_hit);
}

test "run: readonly 安全档拒绝 http GET（防本地数据外带），留痕 policy_deny 无 observation" {
    const gpa = std.testing.allocator;
    const s_get =
        \\{"thought":"取数据","action":"http_request","action_input":"{\"method\":\"GET\",\"url\":\"http://10.255.255.1/\"}"}
    ;
    const s_final =
        \\{"thought":"改道","action":"final","action_input":"只读模式无法访问网络"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_get, s_final } };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly;

    var logbuf: [4096]u8 = undefined;
    var lw = std.Io.Writer.fixed(&logbuf);
    var logger = audit.Logger.init(&lw);
    ag.audit = &logger;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "取个网页");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("只读模式无法访问网络", reply);

    // GET=net_read 也在 readonly 被拒：留痕 policy_deny，命令未执行 → 无 observation。
    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
}

test "run: readonly 安全档拒绝 http POST（net_write，fail-closed），留痕 policy_deny 无 observation" {
    const gpa = std.testing.allocator;
    const s_post =
        \\{"thought":"提交","action":"http_request","action_input":"{\"method\":\"POST\",\"url\":\"http://127.0.0.1:1/\",\"body\":\"x\"}"}
    ;
    const s_final =
        \\{"thought":"改道","action":"final","action_input":"只读模式无法写网络"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_post, s_final } };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly;

    var logbuf: [4096]u8 = undefined;
    var lw = std.Io.Writer.fixed(&logbuf);
    var logger = audit.Logger.init(&lw);
    ag.audit = &logger;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "提交数据");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("只读模式无法写网络", reply);

    // POST=net_write 在 readonly 被拒：留痕 policy_deny，命令未执行 → 无 observation。
    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
}

test "run: http 未知方法→回灌可操作纠错提示后收敛（防弹，不触网）" {
    const gpa = std.testing.allocator;
    // method 非法在 execTool 解析处即失败（UnknownMethod），不触网。
    const s_bad =
        \\{"thought":"请求","action":"http_request","action_input":"{\"method\":\"FETCH\",\"url\":\"http://127.0.0.1:1/\"}"}
    ;
    const s_final =
        \\{"thought":"完成","action":"final","action_input":"ok"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_bad, s_final } };
    var ag = testAgent(&brain, 16); // guarded：放行后在执行处因未知方法失败

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "发请求");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("ok", reply);

    var saw_hint = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "method 无法识别") != null) saw_hint = true;
    }
    try std.testing.expect(saw_hint);
}

test {
    std.testing.refAllDecls(@This());
}
