//! 认知流引擎：思考–行动–观察（ReACT）闭环。
//!
//! 设计取向（见 ROADMAP 方向二 / 铁律 #2 #4）：
//!   - 不依赖后端的「原生 tool_calls」（本地小模型支持参差），而是每一回合都用
//!     强制 json_schema 让模型产出一个结构化「步骤」：{thought, action, action_input}。
//!     这既守住铁律 #2（始终 response_format=json_schema + strict），又对任何
//!     OpenAI 兼容后端（含简陋本地模型）稳健，且复用已验证的防弹解析路径。
//!   - action ∈ {bash, file_read, ..., parallel, final}：工具走统一护栏（带硬超时）执行，输出作为
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
const pathsafe = @import("paths.zig");
const jsonio = @import("jsonio.zig");
const obs = @import("obs.zig");

// 双轨认知模式（goal / plan，见 ROADMAP 方向二）暂未实现：plan 模式的执行 DAG
// 尚未落地，故此处不保留「定义却从不读取」的死字段（曾经的 Mode 枚举 + Agent.mode），
// 以免误导读者以为切到 plan 会改变执行。待真正实现计划模式时再引入并接通该字段。

/// 每回合的结构化输出 Schema（铁律 #2）：强制模型只产出一个 ReACT 步骤。
/// `action` 用 enum 收口到已知动作，`additionalProperties:false` + 全 required 满足 strict。
/// action 的枚举数组在 comptime 由 `Action` 派生（见 `actionEnumArrayJson`），使 enum
/// 成为唯一真相源：新增/改名动作只改 `Action`，schema 自动同步，杜绝手工漂移（issue #27）。
const react_schema = "{\"type\":\"object\",\"properties\":{\"thought\":{\"type\":\"string\"}," ++
    "\"action\":{\"type\":\"string\",\"enum\":" ++ actionEnumArrayJson() ++ "}," ++
    "\"action_input\":{\"type\":\"string\"}}," ++
    "\"required\":[\"thought\",\"action\",\"action_input\"],\"additionalProperties\":false}";

/// 在 comptime 把 `Action` 的成员名拼成 JSON 字符串数组（如 `["bash",...,"final"]`）。
/// react_schema 据此生成，让 `Action` enum 成为动作集合的唯一真相源（issue #27）。
fn actionEnumArrayJson() []const u8 {
    comptime {
        var s: []const u8 = "[";
        for (@typeInfo(Action).@"enum".fields, 0..) |f, i| {
            if (i != 0) s = s ++ ",";
            s = s ++ "\"" ++ f.name ++ "\"";
        }
        return s ++ "]";
    }
}

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
    \\  - "file_read"：读取文件内容；action_input 是 JSON 对象 {"path":"文件路径"}。读大文件时优先用行窗口分页：可选 {"offset":起始行(1 起),"limit":行数} 只取指定区间，省 token 且能与 grep 返回的行号精确配合（如先 grep 命中第 420 行，再 file_read {"path":"...","offset":400,"limit":60}）。省略 offset/limit 即整读（超长会被截断）。
    \\  - "file_write"：覆盖写入文件（不存在则创建）；action_input 是 JSON 对象 {"path":"文件路径","content":"完整新内容"}。
    \\  - "file_edit"：精确替换文件中的一段文本；action_input 是 JSON 对象 {"path":"文件路径","old":"要替换的确切文本（须在文件中唯一出现）","new":"替换成的文本"}。
    \\  - "grep"：在某个文件内按正则逐行搜索，返回命中行号与原文；action_input 是 JSON 对象 {"pattern":"正则","path":"文件路径"}。可选 {"context":N} 同时返回每个命中前后各 N 行（类似 grep -C，上下文行以 行号-原文 标注、命中行以 行号:原文 标注，相邻命中合并、块间以 -- 分隔），一次拿到命中点周边即可省掉随后的整文件读。支持子集：. ^ $ * + ? [] () | \d \w \s（不支持捕获组/反向引用/lookaround/惰性量词）。
    \\  - "glob"：在目录子树下按通配模式列出匹配的文件路径；action_input 是 JSON 对象 {"pattern":"通配模式","root":"起始目录（可选，默认 .）"}。* ? [] 不跨 /，** 跨目录层级。返回的路径可直接喂给 file_read / grep。
    \\  - "outline"：以极低 token 取回一个文件的「结构骨架」——源码的函数/类型签名、Markdown 的标题层级；action_input 是 JSON 对象 {"path":"文件路径"}。用于在**不整读**大文件的前提下先了解其结构，再决定要不要用 file_read 行窗口精读某段。零依赖启发式（按扩展名识别 Zig / Markdown，其余走通用关键字匹配），是 best-effort 概览而非精确解析。
    \\  - "http_request"：发起一次 HTTP/HTTPS 请求；action_input 是 JSON 对象 {"method":"GET","url":"https://...","body":"可选请求体"}。method 取 GET/POST/PUT/DELETE/HEAD/PATCH。返回状态码与响应体；带硬超时，绝不挂死。
    \\  - "skill"：读取一个已装载技能的指令或资源文件。这是 Scoot 的原生只读能力，不受执行策略限制（即便 readonly 也可用）；action_input 是 JSON 对象 {"name":"技能名","path":"技能目录内的相对路径（可选，默认 SKILL.md）"}。仅能读取「可用技能」清单中列出技能其目录内的文件，用于按需取回该技能的完整操作指令（技能里要你执行的 bash/写/网络动作仍各自受执行策略约束）。
    \\  - "parallel"：并发执行 1-4 个彼此独立的只读调用；action_input 是 JSON 对象 {"calls":[{"action":"file_read","input":"{\"path\":\"README.md\"}"},{"action":"grep","input":"{\"pattern\":\"Scoot\",\"path\":\"AGENT.md\"}"}]}。只允许 file_read / grep / glob / outline / HTTP GET 或 HEAD；禁止 bash、写操作、嵌套 parallel。
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
pub const Action = enum { bash, file_read, file_write, file_edit, grep, glob, outline, http_request, skill, parallel, final };

/// 一个解析后的 ReACT 步骤。
pub const Step = struct {
    thought: []const u8,
    action: Action,
    action_input: []const u8,
};

/// 多参数内建工具的 action_input 承载一个 JSON 对象字符串，按工具二次解析。
/// 单参数工具（如 file_read）同样走 JSON（{"path":...}），统一「文件类工具 = JSON 参数」
/// 这条规则，降低小模型「何时裸串、何时 JSON」的认知负担。bash / final 仍是裸文本。
const FileReadArgs = struct { path: []const u8, offset: ?usize = null, limit: ?usize = null };
const FileWriteArgs = struct { path: []const u8, content: []const u8 };
const FileEditArgs = struct { path: []const u8, old: []const u8, new: []const u8 };
const GrepArgs = struct { pattern: []const u8, path: []const u8, context: ?usize = null };
const GlobArgs = struct { pattern: []const u8, root: []const u8 = "." };
const OutlineArgs = struct { path: []const u8 };
const HttpArgs = struct { method: []const u8 = "GET", url: []const u8, body: ?[]const u8 = null };
const SkillArgs = struct { name: []const u8, path: []const u8 = "SKILL.md" };
const ParallelCallArgs = struct {
    action: []const u8,
    input: []const u8 = "",
    action_input: []const u8 = "",
};
const ParallelArgs = struct { calls: []const ParallelCallArgs };

/// 防弹解析工具参数 JSON：失败统一收口为 error.MalformedArgs，由调用处回灌纠错
/// （铁律 #4：绝不信任模型输出，畸形参数不 panic 而是反馈让模型重试）。
fn parseToolArgs(comptime T: type, arena: std.mem.Allocator, input: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, input, .{
        .ignore_unknown_fields = true,
    }) catch error.MalformedArgs;
}

/// 低于此体量的观察不去重：占位文本本身约百余字节，给小观察去重反而增重（issue #73）。
const dedup_min_bytes: usize = 256;

/// 同一 run 内对只读动作（file_read / grep / glob）做内容去重（issue #73）：按
/// `(action, 规范化参数)` 记下上次观察的内容哈希；若本回合重复同一读取且观察逐字节
/// 未变，就回灌一条简短引用（指向上次全文出现的回合）而非再灌一遍全文——避免重复观察在
/// 历史里堆叠、并随后每回合一起重发（与去 thought #70 / 历史压缩 #71 叠加）。
/// bash / 写动作有副作用，绝不去重。单次 run 内读次数有限（≤ max_turns），线性扫足够。
const ReadCache = struct {
    /// run 级寿命分配器：键与表存活至整轮结束，随调用方的 cache arena 整体释放。
    store: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: []const u8, hash: u64, turn: u32 };

    /// 命中重复（同键、同内容哈希）→ 返回去重占位（用 `out` 分配，交调用方入历史）；
    /// 否则返回 null（调用方保留完整观察）。非去重动作 / 参数畸形 / 体量过小一律返回 null。
    fn dedup(
        self: *ReadCache,
        out: std.mem.Allocator,
        turn: u32,
        action: Action,
        input: []const u8,
        observation: []const u8,
    ) !?[]const u8 {
        const key = (readKey(out, action, input) catch return null) orelse return null;
        if (observation.len < dedup_min_bytes) return null;
        const h = std.hash.Wyhash.hash(0, observation);
        for (self.entries.items) |*e| {
            if (!std.mem.eql(u8, e.key, key)) continue;
            if (e.hash == h) {
                return try std.fmt.allocPrint(
                    out,
                    "[观察] 去重：{s} 的结果与第 {d} 回合一致，已省略本次重复观察（{d} 字节）；请复用第 {d} 回合的观察。",
                    .{ key, e.turn, observation.len, e.turn },
                );
            }
            // 内容已变：刷新记录，照常回灌新全文。
            e.hash = h;
            e.turn = turn;
            return null;
        }
        try self.entries.append(self.store, .{ .key = try self.store.dupe(u8, key), .hash = h, .turn = turn });
        return null;
    }
};

/// 把只读动作规范化成稳定的去重键（兼作回灌占位里的可读标签）；非去重动作返回 null。
fn readKey(arena: std.mem.Allocator, action: Action, input: []const u8) !?[]const u8 {
    return switch (action) {
        .file_read => blk: {
            const a = try parseToolArgs(FileReadArgs, arena, input);
            break :blk try std.fmt.allocPrint(arena, "file_read {s} off={?d} lim={?d}", .{ a.path, a.offset, a.limit });
        },
        .grep => blk: {
            const a = try parseToolArgs(GrepArgs, arena, input);
            break :blk try std.fmt.allocPrint(arena, "grep {s} /{s}/ ctx={?d}", .{ a.path, a.pattern, a.context });
        },
        .glob => blk: {
            const a = try parseToolArgs(GlobArgs, arena, input);
            break :blk try std.fmt.allocPrint(arena, "glob {s} /{s}/", .{ a.root, a.pattern });
        },
        .outline => blk: {
            const a = try parseToolArgs(OutlineArgs, arena, input);
            break :blk try std.fmt.allocPrint(arena, "outline {s}", .{a.path});
        },
        else => null,
    };
}

/// 获取下一条补全的抽象（测试可注入脚本化大脑，无需真实后端）。
/// 默认实现 `clientComplete` 直接转调 `llm.Client.chat`。
pub const CompleteFn = *const fn (
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    messages: []const llm.Message,
    opts: llm.ChatOptions,
) anyerror!llm.Completion;

/// 已装载技能的轻量句柄：名字 → 目录。`skill` 动作据此把技能名解析为目录后只读其内文件。
pub const SkillRef = struct { name: []const u8, dir: []const u8 };

pub const Agent = struct {
    io: std.Io,
    complete_ctx: *anyopaque,
    complete_fn: CompleteFn,
    /// 回合上限：防止模型陷入工具调用死循环拖垮守护进程。
    max_turns: u32 = 16,
    /// 上下文预算（字节，0=关闭）：跨回合累计的提示历史超过此值时，先**压缩历史**
    /// （保留 system + 原始任务 + 最近若干条，中段较早消息替换为摘要标记，见
    /// session.compact / issue #71）让 run 继续推进，而非直接中止整个任务（旧行为）或
    /// 任由请求体无界增长。仅当压缩后仍超限（连最小保留集都放不下、预算配得过小）时
    /// 才 fail-fast（`error.ContextBudgetExceeded`）。压缩即时缩小发往后端的历史，token
    /// 成本随之下降；arena backing 下被丢弃内容不立即回收但语义安全（见 session.compact）。
    context_budget_bytes: usize = 0,
    /// 单条工具调用的硬超时（毫秒）。
    tool_timeout_ms: u64 = 30_000,
    /// 可选审计日志：非 null 时把每步 思考/工具调用/观察/终态/错误 留痕（铁律：可审计）。
    /// 注入式，测试可挂内存 writer 验证；审计写入失败不阻断任务（最终在 flush 处暴露）。
    audit: ?*audit.Logger = null,
    /// 执行护栏模式（铁律：未经验证的模型输出不落系统）。bash 命令执行前必过此门。
    policy_mode: policy.Mode = .guarded,
    /// opt-in 加固（默认关闭，仅 guarded 生效）：把 file_write/file_edit 收口到项目根内，
    /// 拒绝绝对路径 / `..` 逃逸 / shell 展开（见 policy.evaluateWritePath，issue #32）。
    confine_writes: bool = false,
    /// opt-in 加固（默认关闭，仅 guarded 生效）：拒绝 http_request 访问环回 / 内网 /
    /// 链路本地 / 云元数据地址，收窄 SSRF / 外带面（见 policy.evaluateHttpUrl，issue #32）。
    block_internal_http: bool = false,
    /// 自定义 CA bundle（PEM）绝对路径，传给 http_request 工具；null = 系统根证书。
    ca_file: ?[]const u8 = null,
    /// 可选 CLI 执行轨迹输出。仅用于显式调试；最终答复仍由调用方写 stdout。
    trace: ?*std.Io.Writer = null,
    /// 已装载技能的 name→dir 表（由 setupRun 从 Registry 注入；arena 拥有，生命周期=本次运行）。
    /// `skill` 动作据此解析技能名、只读其指令/资源。空表表示未装载任何技能。
    skills: []const SkillRef = &.{},

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
        // 只读动作内容去重缓存（issue #73）：run 级寿命，跨回合存活，整轮结束随 arena 释放。
        // 用独立 arena（非每回合 arena）承载键/表，使其不被回合末释放；测试以 GPA 作 backing
        // 时也保证整轮结束统一回收，无泄漏。
        var cache_arena = std.heap.ArenaAllocator.init(backing);
        defer cache_arena.deinit();
        var read_cache = ReadCache{ .store = cache_arena.allocator() };
        while (turn < self.max_turns) : (turn += 1) {
            var arena_state = std.heap.ArenaAllocator.init(backing);
            defer arena_state.deinit(); // 回合制内存：每轮临时分配整体释放。
            const arena = arena_state.allocator();

            // 上下文预算闸（issue #28 + #71）：把整段历史发往后端前先量体量；超预算时
            // 先压缩历史（保留 system + 原始任务 + 最近 K 条）再继续，而非中止整个 run。
            // 仅当压缩后仍超限（预算配得过小、连最小保留集都放不下）才 fail-fast。0 = 关闭。
            if (self.context_budget_bytes != 0) {
                var used = historyBytes(sess.items());
                if (used > self.context_budget_bytes) {
                    const compacted = sess.compact(backing, history_keep_recent) catch false;
                    if (compacted) {
                        used = historyBytes(sess.items());
                        self.traceCompacted(turn + 1, used);
                        if (self.audit) |lg| {
                            var b: [160]u8 = undefined;
                            const m = std.fmt.bufPrint(&b, "上下文预算超限：已压缩历史，现 {d} 字节 / 上限 {d}（第 {d} 回合前）", .{ used, self.context_budget_bytes, turn + 1 }) catch "上下文预算超限：已压缩历史";
                            lg.log(.system_error, m) catch {};
                        }
                    }
                    if (used > self.context_budget_bytes) {
                        if (self.audit) |lg| {
                            var b: [160]u8 = undefined;
                            const m = std.fmt.bufPrint(&b, "上下文预算超限且压缩后仍超：累计 {d} 字节 > 上限 {d}，第 {d} 回合前主动中止", .{ used, self.context_budget_bytes, turn + 1 }) catch "上下文预算超限且压缩后仍超，主动中止";
                            lg.log(.system_error, m) catch {};
                        }
                        return error.ContextBudgetExceeded;
                    }
                }
            }

            // 进入推理前先留一条「推理中」轨迹并即时刷出：complete 是本回合最长的阻塞点
            // （等待后端推理），而 reason/action 只能在它**返回后**才打印——不预先标记的话，
            // 这段等待期 trace 全静默，前端会显得卡死（本次需求）。
            self.traceThinking(turn + 1);
            const completion = try self.complete(arena, sess.items(), .{
                .json_schema = react_schema,
                .schema_name = "scoot_step",
            });

            // 防弹解析（铁律 #4）：模型没吐合法步骤时不 panic，把错误作为观察回灌触发重试。
            const step = parseStep(arena, completion.content) catch {
                if (self.audit) |lg| lg.log(.system_error, "模型输出不是合法步骤 JSON，已回灌纠错并重试") catch {};
                self.traceMalformed(turn + 1);
                // 畸形输出仍原样入历史（assistant）：让模型看到自己产出的坏 JSON，配合纠错回灌自我修复。
                try sess.append(backing, .assistant, completion.content);
                try sess.append(backing, .user, malformed_hint);
                continue;
            };
            if (self.audit) |lg| lg.log(.thought, step.thought) catch {};
            self.traceStep(turn + 1, step);

            // 只把不含 thought 的紧凑步骤写入历史（issue #70）：thought 是模型本回合的私有推理，
            // 对后续回合无复用价值；持久化它会让历史逐回合膨胀且每次全量重发，使输入 token 随
            // 回合数呈 O(N²)。thought 仅用于审计/trace（上面），历史只留 action/action_input。
            const compact = try compactStepJson(arena, @tagName(step.action), step.action_input);
            try sess.append(backing, .assistant, compact);

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
                            // 工具执行也是阻塞点（bash / http_request 可能很慢），观察结果只能在
                            // 执行**返回后**打印；执行前先标记「正在执行哪个工具」，等待期不致静默。
                            self.traceRunning(turn + 1, step.action);
                            var observation: []const u8 = self.execTool(arena, step.action, step.action_input) catch |err|
                                try toolErrorObservation(arena, err);
                            // 只读动作内容去重（issue #73）：重复读取且观察未变时，用简短引用替换
                            // 全文回灌，避免同份内容在历史里反复堆叠、逐回合重发。
                            if (try read_cache.dedup(arena, turn + 1, step.action, step.action_input, observation)) |deduped|
                                observation = deduped;
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
    /// readonly 下本地读工具额外执行路径策略，避免读取项目目录外或常见敏感文件。
    fn guard(self: *Agent, arena: std.mem.Allocator, action: Action, input: []const u8) policy.Decision {
        return switch (action) {
            .bash => policy.evaluate(arena, input, self.policy_mode),
            .file_read, .grep, .glob, .outline => self.guardLocalRead(arena, action, input),
            .file_write, .file_edit => self.guardWrite(arena, action, input),
            .http_request => self.guardHttp(arena, input),
            .skill => .allow, // 见下：读取技能指令是原生只读能力，刻意置于执行策略之外。
            .parallel => self.guardParallel(arena, input),
            // 调用方契约：`run` 在调用 guard 前已就地处理 .final（终态不过护栏）。
            // 这里**不 panic**而是降级为 deny（防弹/铁律 #4）：未来若某调用方误把
            // .final 路由到此，退化为一条可回灌的拒绝观察，而非进程级 panic。
            .final => .{ .deny = "final 是终态答复，不是可执行工具动作（不应到达护栏）" },
        };
    }

    fn guardLocalRead(self: *Agent, arena: std.mem.Allocator, action: Action, input: []const u8) policy.Decision {
        const base = policy.evaluateTool(.read, self.policy_mode);
        switch (base) {
            .deny => return base,
            .allow => {},
        }
        if (self.policy_mode != .readonly) return .allow;
        return switch (action) {
            .file_read => blk: {
                const args = parseToolArgs(FileReadArgs, arena, input) catch
                    break :blk .{ .deny = "只读模式无法解析 file_read 路径，已拒绝" };
                break :blk policy.evaluateReadPath(args.path, self.policy_mode);
            },
            .grep => blk: {
                const args = parseToolArgs(GrepArgs, arena, input) catch
                    break :blk .{ .deny = "只读模式无法解析 grep 路径，已拒绝" };
                break :blk policy.evaluateReadPath(args.path, self.policy_mode);
            },
            .glob => blk: {
                const args = parseToolArgs(GlobArgs, arena, input) catch
                    break :blk .{ .deny = "只读模式无法解析 glob 参数，已拒绝" };
                const root_decision = policy.evaluateReadPath(args.root, self.policy_mode);
                if (root_decision != .allow) break :blk root_decision;
                break :blk policy.evaluateReadPath(args.pattern, self.policy_mode);
            },
            .outline => blk: {
                const args = parseToolArgs(OutlineArgs, arena, input) catch
                    break :blk .{ .deny = "只读模式无法解析 outline 路径，已拒绝" };
                break :blk policy.evaluateReadPath(args.path, self.policy_mode);
            },
            // 调用方契约：guardLocalRead 只对本地读动作（file_read/grep/glob）调用。
            // 降级为 deny 而非 unreachable：契约被未来重构破坏时退化为可回灌的拒绝，不 panic。
            else => .{ .deny = "guardLocalRead 收到非本地读动作（内部不应到达），已拒绝" },
        };
    }

    /// http_request 按方法分类能力：GET/HEAD→net_read，写类方法→net_write。
    /// readonly 下 net_read/net_write 均拒绝，避免本地读结果经网络外带。
    /// 参数畸形 / 未知方法 → 按最严格的 net_write 判定（readonly 下拒绝，fail-closed）。
    /// 另：开启 SSRF 防护（block_internal_http）时，guarded 下还会校验 URL 主机（issue #32）。
    fn guardHttp(self: *Agent, arena: std.mem.Allocator, input: []const u8) policy.Decision {
        const args = parseToolArgs(HttpArgs, arena, input) catch {
            // 参数畸形：按最严格 net_write 过 evaluateTool；guarded 下若开了 SSRF 防护，
            // 无法解析 URL 即 fail-closed 拒绝（不放过一个无法分类的目标）。
            const d = policy.evaluateTool(.net_write, self.policy_mode);
            if (d == .deny) return d;
            if (self.block_internal_http and self.policy_mode == .guarded)
                return .{ .deny = "已开启 SSRF 防护：无法解析 http_request 参数，已拒绝" };
            return .allow;
        };
        const cap: policy.Capability = blk: {
            const m = tools.http.methodFromString(args.method) orelse break :blk .net_write;
            break :blk if (tools.http.isWrite(m)) .net_write else .net_read;
        };
        switch (policy.evaluateTool(cap, self.policy_mode)) {
            .deny => |reason| return .{ .deny = reason },
            .allow => {},
        }
        return policy.evaluateHttpUrl(args.url, self.policy_mode, self.block_internal_http);
    }

    /// file_write / file_edit 的护栏：先过能力判定（readonly fail-closed 拒写），
    /// 再在开启项目根约束（confine_writes）时校验写路径不逃逸项目目录（issue #32）。
    fn guardWrite(self: *Agent, arena: std.mem.Allocator, action: Action, input: []const u8) policy.Decision {
        switch (policy.evaluateTool(.write, self.policy_mode)) {
            .deny => |reason| return .{ .deny = reason },
            .allow => {},
        }
        if (!self.confine_writes) return .allow;
        const path: ?[]const u8 = switch (action) {
            .file_write => if (parseToolArgs(FileWriteArgs, arena, input)) |a| a.path else |_| null,
            .file_edit => if (parseToolArgs(FileEditArgs, arena, input)) |a| a.path else |_| null,
            else => null,
        };
        const p = path orelse return .{ .deny = "已开启写入项目根约束：无法解析写路径，已拒绝" };
        switch (policy.evaluateWritePath(p, self.policy_mode, self.confine_writes)) {
            .deny => |reason| return .{ .deny = reason },
            .allow => {},
        }
        // 词法检查（禁绝对 / `..`）只是前置过滤，写入会跟随 symlink。对写入目标父目录做 realpath，
        // 确认仍落在项目根（cwd）内，挡住项目内预置 `link -> /etc` 这类 symlink 逃逸（issue #52，
        // 与 #41 技能读取对齐）。仅在 guarded + confine_writes 生效，与 evaluateWritePath 语义一致。
        if (self.policy_mode == .guarded and pathsafe.writeEscapesBase(self.io, arena, ".", p))
            return .{ .deny = "写入项目根约束：路径经 symlink 解析后逃逸项目目录，已拒绝" };
        return .allow;
    }

    fn guardParallel(self: *Agent, arena: std.mem.Allocator, input: []const u8) policy.Decision {
        const args = parseToolArgs(ParallelArgs, arena, input) catch
            return .{ .deny = "parallel 的 action_input 必须是 {\"calls\":[...]} JSON" };
        if (args.calls.len == 0) return .{ .deny = "parallel 至少需要 1 个调用" };
        if (args.calls.len > max_parallel_calls) return .{ .deny = "parallel 超过最大并发调用数 4" };

        for (args.calls, 0..) |call, idx| {
            const child = std.meta.stringToEnum(Action, call.action) orelse
                return .{ .deny = "parallel 包含未知 action" };
            const child_input = parallelCallInput(call);
            if (child_input.len == 0)
                return .{ .deny = "parallel 子调用缺少 input" };
            switch (child) {
                .file_read, .grep, .glob, .outline => {},
                .http_request => {
                    const http_args = parseToolArgs(HttpArgs, arena, child_input) catch
                        return .{ .deny = "parallel 无法解析 http_request 参数" };
                    const method = tools.http.methodFromString(http_args.method) orelse
                        return .{ .deny = "parallel http_request method 无法识别" };
                    if (tools.http.isWrite(method))
                        return .{ .deny = "parallel 只允许 HTTP GET/HEAD，不允许写类 HTTP 方法" };
                },
                .bash => return .{ .deny = "parallel 禁止 bash；请使用结构化只读工具" },
                .file_write, .file_edit => return .{ .deny = "parallel 禁止写文件或编辑文件" },
                .skill => return .{ .deny = "parallel 禁止 skill；请用独立的 skill 动作读取技能指令" },
                .parallel => return .{ .deny = "parallel 禁止嵌套 parallel" },
                .final => return .{ .deny = "parallel 子调用不能是 final" },
            }
            switch (self.guard(arena, child, child_input)) {
                .allow => {},
                .deny => |reason| return .{
                    .deny = std.fmt.allocPrint(arena, "parallel 子调用 #{d} 被拒绝：{s}", .{ idx + 1, reason }) catch reason,
                },
            }
        }
        return .allow;
    }

    /// 执行一个已过护栏的工具动作，返回回灌给模型的「观察」文本（arena 拥有）。
    /// 任何失败（参数畸形 / IO 错误 / 超时）都以 error 上抛，由调用处转成观察回灌，
    /// 全程不 panic（铁律 #4）。
    fn execTool(self: *Agent, arena: std.mem.Allocator, action: Action, input: []const u8) ![]const u8 {
        return switch (action) {
            .bash => try self.runBash(arena, input),
            .file_read => blk: {
                const args = try parseToolArgs(FileReadArgs, arena, input);
                break :blk try fileReadObservation(arena, self.io, args);
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
                break :blk try grepObservation(arena, self.io, args);
            },
            .glob => blk: {
                const args = try parseToolArgs(GlobArgs, arena, input);
                const paths = try tools.search.glob(arena, self.io, args.pattern, args.root, tools.search.default_max_results);
                break :blk try formatGlobPaths(arena, args.pattern, paths);
            },
            .outline => blk: {
                const args = try parseToolArgs(OutlineArgs, arena, input);
                break :blk try outlineObservation(arena, self.io, args);
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
            .parallel => try self.execParallel(arena, input),
            .skill => blk: {
                const args = try parseToolArgs(SkillArgs, arena, input);
                break :blk try self.readSkill(arena, args.name, args.path);
            },
            // 调用方契约：`run` 在调用 execTool 前已就地处理 .final。降级为 error 而非
            // unreachable：契约被破坏时 run 会把它转成「工具执行失败」观察回灌，不 panic。
            .final => error.UnexpectedAction,
        };
    }

    /// `skill` 动作的执行：把技能名解析为已装载技能目录，只读其内的指令/资源文件。
    /// 这是 Scoot 的**原生只读能力**，刻意置于执行策略之外（guard 对 `.skill` 恒 allow）：
    /// 技能清单本就由 Scoot 主动发现并注入 system 上下文，模型读取其 SKILL.md / 资源不
    /// 构成新的越权面；真正受策略约束的是技能里**让模型去执行**的 bash/写/网络动作，
    /// 它们仍各走自身护栏。读取面的边界改由此处把关，而非交给 policy：
    ///   - 技能名必须在已装载清单中（否则回灌可纠错的观察，并列出可用技能）；
    ///   - 相对路径禁绝对路径、禁 `..`，确保读取不逃逸该技能目录。
    /// 任何读取失败均收口为可回灌的观察文本，不上抛、不 panic（铁律 #4）。
    fn readSkill(self: *Agent, arena: std.mem.Allocator, name: []const u8, rel: []const u8) ![]const u8 {
        const dir = for (self.skills) |s| {
            if (std.mem.eql(u8, s.name, name)) break s.dir;
        } else return try self.skillNotFoundObservation(arena, name);

        const trimmed = std.mem.trim(u8, rel, " \t\r\n");
        const sub = if (trimmed.len == 0) "SKILL.md" else trimmed;
        if (std.fs.path.isAbsolute(sub) or pathHasDotDot(sub))
            return try std.fmt.allocPrint(arena, "[观察] 技能读取被拒：path 必须是技能目录内的相对路径，且不得含 `..`（收到：{s}）。", .{sub});

        const full = try std.fs.path.join(arena, &.{ dir, sub });
        // 符号链接逃逸防护（issue #41）：词法检查（绝对路径 / ..）只是快速前置过滤，
        // 而 file.read 会跟随 symlink——技能目录内一个指向外部的 symlink 会把这条
        // 「策略豁免」的只读路径变成任意文件读。读取前用 realpath 规范化 dir 与目标，
        // 确认目标仍落在技能目录内，否则拒绝（供应链/纵深防御）。
        if (self.skillPathEscapes(arena, dir, full))
            return try std.fmt.allocPrint(arena, "[观察] 技能 {s} 的 {s} 读取被拒：解析后逃逸技能目录（疑似 symlink 越权）。", .{ name, sub });
        const content = tools.file.read(arena, self.io, full, skill_read_limit) catch |err|
            return try std.fmt.allocPrint(arena, "[观察] 技能 {s} 的 {s} 读取失败：{s}。", .{ name, sub, @errorName(err) });
        return try std.fmt.allocPrint(
            arena,
            "[观察] 技能 {s} 的 {s}（{d} 字节）：\n{s}",
            .{ name, sub, content.len, try clipTo(arena, content, skill_observation_tokens) },
        );
    }

    /// 技能读取的符号链接逃逸判定（issue #41）：把技能目录 `dir` 与目标 `full` 都 realpath 规范化，
    /// 目标不在 dir 之内（symlink 指向外部）即判逃逸。无法解析（如文件不存在 / 平台不支持 realpath）
    /// 时返回 false 不在此拦截——交由后续 read 给出失败观察；不存在的文件本就无内容可泄露。
    fn skillPathEscapes(self: *Agent, arena: std.mem.Allocator, dir: []const u8, full: []const u8) bool {
        return pathsafe.realPathEscapes(self.io, arena, dir, full);
    }

    /// 技能名未命中已装载清单时的可纠错观察：列出可用技能名，引导模型重选。
    fn skillNotFoundObservation(self: *Agent, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(arena);
        const w = &aw.writer;
        try w.print("[观察] 技能 {s} 未装载。", .{name});
        if (self.skills.len == 0) {
            try w.writeAll("当前没有任何已装载技能。");
        } else {
            try w.writeAll("可用技能：");
            for (self.skills, 0..) |s, i| {
                if (i != 0) try w.writeAll("、");
                try w.writeAll(s.name);
            }
            try w.writeAll("。");
        }
        return aw.written();
    }

    fn execParallel(self: *Agent, arena: std.mem.Allocator, input: []const u8) ![]const u8 {
        const args = try parseToolArgs(ParallelArgs, arena, input);
        if (args.calls.len == 0 or args.calls.len > max_parallel_calls) return error.MalformedArgs;

        var workers = try arena.alloc(ParallelWorker, args.calls.len);
        var threads = try arena.alloc(std.Thread, args.calls.len);
        var spawned: usize = 0;
        errdefer {
            for (threads[0..spawned]) |t| t.join();
            for (workers[0..spawned]) |*w| w.arena_state.deinit();
        }

        for (args.calls, 0..) |call, idx| {
            const action = std.meta.stringToEnum(Action, call.action) orelse return error.UnknownAction;
            const child_input = parallelCallInput(call);
            workers[idx] = ParallelWorker{
                .io = self.io,
                .action = action,
                .input = child_input,
                .tool_timeout_ms = self.tool_timeout_ms,
                .ca_file = self.ca_file,
                .arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
            if (self.audit) |lg| {
                const line = try std.fmt.allocPrint(arena, "parallel[{d}] {s} {s}", .{ idx + 1, @tagName(action), child_input });
                lg.log(.tool_call, line) catch {};
            }
            self.traceParallelCall(idx + 1, action, child_input);
            threads[idx] = try std.Thread.spawn(.{}, runParallelWorker, .{&workers[idx]});
            spawned += 1;
        }
        for (threads[0..spawned]) |t| t.join();
        // 线程已全部 join：把 spawned 归零让上面的 spawn 阶段 errdefer 失活，
        // 否则它会与下面的 defer 重叠——在结果组装失败（OOM）时对同一批 worker
        // 二次 join 线程、二次 deinit arena（双重 free / 重复 join，均为未定义行为）。
        spawned = 0;
        defer for (workers) |*w| w.arena_state.deinit();

        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "[观察] parallel 完成 {d} 个只读调用：\n", .{args.calls.len}));
        for (workers, 0..) |*w, idx| {
            const obs_text = w.observation;
            if (self.audit) |lg| lg.log(.observation, obs_text) catch {};
            self.traceParallelResult(idx + 1, obs_text);
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "\n[{d}] {s}\n", .{ idx + 1, @tagName(w.action) }));
            try buf.appendSlice(arena, obs_text);
            try buf.append(arena, '\n');
        }
        return clipTo(arena, buf.items, parallel_observation_tokens);
    }

    /// 执行一条 bash 命令（带硬超时）并格式化成「观察」文本（arena 拥有）。
    fn runBash(self: *Agent, arena: std.mem.Allocator, command: []const u8) ![]u8 {
        const result = try tools.bash.run(arena, self.io, command, .{ .timeout_ms = self.tool_timeout_ms });
        return formatObservation(arena, result);
    }

    /// 「推理中」进度标记（在调用后端推理前打印并即时刷出）：让 trace 在等待模型期间也有
    /// 实时输出，反映 agent 当前正在推理，而非卡死。
    fn traceThinking(self: *Agent, turn: u32) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] thinking: 调用后端推理中…\n", .{turn}) catch return;
        w.flush() catch {};
    }

    /// 「执行中」进度标记（在执行工具前打印并即时刷出）：标明当前正在执行哪个工具，
    /// 使等待工具返回的这段时间也有实时反馈。
    fn traceRunning(self: *Agent, turn: u32, action: Action) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] running: {s}（执行中，等待结果）…\n", .{ turn, @tagName(action) }) catch return;
        w.flush() catch {};
    }

    fn traceMalformed(self: *Agent, turn: u32) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] malformed model step; retrying\n", .{turn}) catch return;
        w.flush() catch {};
    }

    /// 「历史压缩」进度标记：超预算时压缩旧上下文后继续（issue #71），让长 run 不卡死也不暴毙。
    fn traceCompacted(self: *Agent, turn: u32, used_bytes: usize) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] compacted history: 现 {d} 字节（保留 system+任务+最近 {d} 条）\n", .{ turn, used_bytes, history_keep_recent }) catch return;
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

    fn traceParallelCall(self: *Agent, idx: usize, action: Action, input: []const u8) void {
        const w = self.trace orelse return;
        w.print("[trace parallel {d}] action: {s} ", .{ idx, @tagName(action) }) catch return;
        traceClipped(w, input, trace_action_input_cap) catch return;
        w.writeAll("\n") catch return;
        w.flush() catch {};
    }

    fn traceParallelResult(self: *Agent, idx: usize, observation: []const u8) void {
        const w = self.trace orelse return;
        w.print("[trace parallel {d}] observe: ", .{idx}) catch return;
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
const malformed_hint = "[观察] 你上一条输出不是合法的步骤 JSON。请严格按 schema 只输出一个含 thought/action/action_input 的 JSON 对象；不要输出 Markdown 代码块，也不要一次连续输出多个 JSON 对象。";

/// 历史压缩（issue #71）触发时保留的「最近消息」条数。每回合约产出 2 条（assistant 动作 +
/// user 观察），8 条 ≈ 最近 4 个回合，足以让模型续上当前进度，同时把更早的工具原文压成摘要。
const history_keep_recent = 8;

/// 观察截断预算一律以 **token 估算**为口径（issue #75）：字节口径会让 CJK（≈1 token/字、
/// 占 3 字节）与 ASCII 的预算严重不一致。下列数值约为旧字节上限的 1/4（ASCII 字节/token 比），
/// 使 ASCII 场景体量基本不变，CJK 场景按 token 收敛到一致预算。

/// 单条流（bash stdout/stderr 等）观察的最大 token 数，超出走「头+尾」截断，挡住脏/海量输出。
const observation_stream_tokens = 500;

/// file_read 观察的截断上限：比 bash 流更宽（文件内容是模型主动读取、相对结构化，
/// 给更大窗口便于后续 file_edit 看清确切文本），但仍设上限挡住超大文件撑爆上下文。
const file_read_observation_tokens = 2000;

/// 单个技能指令/资源文件的读取上限（1 MiB；指令文件实际仅几 KiB，留足冗余防失控）。
const skill_read_limit: std.Io.Limit = .limited(1 << 20);
/// 技能内容回灌观察的截断上限：比普通 file_read 更宽——SKILL.md 是模型按需取回的
/// 完整操作指令，截断会丢失步骤；但仍设硬上限挡住异常大文件撑爆上下文。
const skill_observation_tokens = 8000;

/// parallel v0 是显式 fan-out，不是 DAG 执行器。小上限避免拖垮本地 runtime。
const max_parallel_calls = 4;
const parallel_observation_tokens = 3000;

/// CLI trace 只展示执行轨迹摘要，避免海量工具输出刷屏。
const trace_reason_cap = 240;
const trace_action_input_cap = 240;
const trace_observation_cap = 600;
const trace_final_cap = 240;

/// 把已解析的步骤压缩成**不含 thought** 的 assistant 历史记录（arena 拥有）：
/// `{"action":"<名>","action_input":"<原样输入>"}`。thought 是模型本回合的私有推理，
/// 对后续回合无复用价值；持久化它只会让历史逐回合膨胀、每次全量重发（issue #70）。
/// 字符串经 jsonio 转义，保证回灌历史仍是合法 JSON。
fn compactStepJson(arena: std.mem.Allocator, action_name: []const u8, action_input: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"action\":");
    try jsonio.writeString(w, action_name);
    try w.writeAll(",\"action_input\":");
    try jsonio.writeString(w, action_input);
    try w.writeByte('}');
    return aw.writer.buffered();
}

pub fn parseStep(arena: std.mem.Allocator, content: []const u8) !Step {
    const Raw = struct {
        thought: []const u8 = "",
        action: []const u8,
        action_input: []const u8 = "",
    };
    const step_json = firstStepJsonObject(content) orelse return error.MalformedStep;
    const v = std.json.parseFromSliceLeaky(Raw, arena, step_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedStep;

    // 按 enum tag 名映射动作；新增动作只需扩 Action enum，无需改这里（反过载）。
    const action = std.meta.stringToEnum(Action, v.action) orelse return error.UnknownAction;
    return .{ .thought = v.thought, .action = action, .action_input = v.action_input };
}

/// 取模型输出中的第一个完整顶层 JSON 对象。部分兼容后端会无视 strict schema，
/// 偶发把多个步骤连续吐在一条消息里；Scoot 仍只执行第一步，保持单步 ReACT 语义。
fn firstStepJsonObject(content: []const u8) ?[]const u8 {
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

/// 估算会话历史的提示体量（字节）：所有消息 content 长度之和。token 体量的粗略代理。
/// 纯函数，便于防弹单测；run() 在每次后端调用前据此对累计历史设硬上限（issue #28）。
fn historyBytes(messages: []const llm.Message) usize {
    var total: usize = 0;
    for (messages) |m| total += m.content.len;
    return total;
}

/// 把工具执行 / 参数解析的错误转成回灌给模型的「观察」文本（arena 拥有）。
/// 对常见错误给出可操作的纠正提示，引导模型自我修复（铁律 #4：失败即反馈而非中断）。
fn toolErrorObservation(arena: std.mem.Allocator, err: anyerror) ![]u8 {
    const hint = switch (err) {
        error.MalformedArgs => "action_input 不是合法的参数 JSON。file_read 用 {\"path\":\"...\"}；file_write 用 {\"path\":\"...\",\"content\":\"...\"}；file_edit 用 {\"path\":\"...\",\"old\":\"...\",\"new\":\"...\"}；grep 用 {\"pattern\":\"...\",\"path\":\"...\"}；glob 用 {\"pattern\":\"...\"}；http_request 用 {\"method\":\"GET\",\"url\":\"...\"}。",
        error.UnknownMethod => "http_request 的 method 无法识别。请用 GET/POST/PUT/DELETE/HEAD/PATCH 之一。",
        error.ParallelWriteHttp => "parallel 只允许 HTTP GET/HEAD，不允许 POST/PUT/PATCH/DELETE。",
        error.UnsupportedParallelAction => "parallel 只允许 file_read / grep / glob / HTTP GET 或 HEAD。",
        error.PatternNotFound => "file_edit 的 old 文本未在文件中找到。请先用 file_read 读出确切文本再编辑。",
        error.AmbiguousMatch => "file_edit 的 old 文本在文件中出现多次。请提供更长、唯一的上下文片段以定位。",
        error.EmptyPattern => "file_edit 的 old 不能为空。",
        error.InvalidPattern => "grep 的正则非法。支持子集：. ^ $ * + ? [] () | \\d \\w \\s；不支持捕获组/反向引用/lookaround/惰性量词。请简化模式。",
        error.PatternTooLong => "正则模式过长，请缩短。",
        error.FileNotFound => "目标文件不存在。请确认路径，或先用 file_write 创建它。",
        error.AccessDenied => "对目标路径没有访问权限。",
        error.IsDir => "目标路径是目录而非文件。",
        error.UnexpectedAction => "内部错误：动作被路由到了错误的执行分支（不应发生）。请重试或换一种动作。",
        else => @errorName(err),
    };
    return std.fmt.allocPrint(arena, "[观察] 工具执行失败：{s}", .{hint});
}

/// 把 file_read 动作格式化成「观察」文本（arena 拥有）。
/// 省略 offset/limit → 整读（受 file_read_observation_tokens 截断）；
/// 给出任一 → 行窗口分页读（与 grep 行号配合，省 token）。execTool 与并发 worker 共用。
fn fileReadObservation(arena: std.mem.Allocator, io: std.Io, args: FileReadArgs) ![]const u8 {
    if (args.offset == null and args.limit == null) {
        const content = try tools.file.read(arena, io, args.path, tools.file.default_read_limit);
        return std.fmt.allocPrint(
            arena,
            "[观察] 读取 {s}（{d} 字节）：\n{s}",
            .{ args.path, content.len, try clipTo(arena, content, file_read_observation_tokens) },
        );
    }
    const off = args.offset orelse 1;
    const win = try tools.file.readLineRange(arena, io, args.path, tools.file.default_read_limit, off, args.limit);
    if (win.total_lines == 0)
        return std.fmt.allocPrint(arena, "[观察] 读取 {s}：文件为空。", .{args.path});
    if (win.start_line == 0)
        return std.fmt.allocPrint(
            arena,
            "[观察] 读取 {s}：offset {d} 超出文件总行数 {d}。",
            .{ args.path, off, win.total_lines },
        );
    return std.fmt.allocPrint(
        arena,
        "[观察] 读取 {s}（第 {d}-{d} 行 / 共 {d} 行）：\n{s}",
        .{ args.path, win.start_line, win.end_line, win.total_lines, try clipTo(arena, win.text, file_read_observation_tokens) },
    );
}

/// 执行 outline 动作并产出「观察」文本（arena 拥有）。execTool 与并发 worker 共用。
/// 读入整文件 → 按扩展名识别语言 → 抽结构骨架 → 紧凑成「行号: 签名」概览，让模型先看
/// 结构再决定是否窗口读细节（issue #77，零依赖行启发式）。受 file_read 上限截断。
fn outlineObservation(arena: std.mem.Allocator, io: std.Io, args: OutlineArgs) ![]const u8 {
    const content = try tools.file.read(arena, io, args.path, tools.file.default_read_limit);
    const lang = tools.outline.detectLang(args.path);
    const result = try tools.outline.extract(arena, content, lang);
    if (result.entries.len == 0) {
        return std.fmt.allocPrint(
            arena,
            "[结构] {s}（lang={s}）：未识别到结构行（函数/类型/标题）。如需内容请用 file_read。",
            .{ args.path, @tagName(lang) },
        );
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "[结构] {s}（lang={s}，{d} 项{s}）：\n",
        .{ args.path, @tagName(lang), result.entries.len, if (result.truncated) "，已截断" else "" },
    ));
    for (result.entries) |e| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}: {s}\n", .{ e.line, e.text }));
    }
    try buf.appendSlice(arena, "提示：用 file_read 的 offset/limit 按行号窗口读取所需片段。");
    return clipTo(arena, buf.items, file_read_observation_tokens);
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
    return clipTo(arena, buf.items, file_read_observation_tokens);
}

/// 执行 grep 动作并产出「观察」文本（arena 拥有）。execTool 与并发 worker 共用。
/// 无 context（或 0）→ 仅命中行（formatGrepHits，旧行为）；context>0 → 命中行 ±N 上下文块
/// （formatGrepBlocks），让模型一次拿到命中点周边，省掉随后的整文件读（issue #76）。
fn grepObservation(arena: std.mem.Allocator, io: std.Io, args: GrepArgs) ![]const u8 {
    const ctx = args.context orelse 0;
    if (ctx == 0) {
        const hits = try tools.search.grepFile(arena, io, args.pattern, args.path, tools.search.default_max_hits);
        return formatGrepHits(arena, args.path, hits);
    }
    const blocks = try tools.search.grepFileContext(arena, io, args.pattern, args.path, tools.search.default_max_hits, ctx);
    return formatGrepBlocks(arena, args.path, blocks, @min(ctx, tools.search.max_grep_context));
}

/// 把带上下文的 grep 块格式化成「观察」文本（arena 拥有）：命中行 `行号:原文`、
/// 上下文行 `行号-原文`（grep -C 约定），块间以 `--` 分隔。受 file_read 上限截断。
fn formatGrepBlocks(arena: std.mem.Allocator, path: []const u8, blocks: []const tools.search.ContextBlock, context: usize) ![]const u8 {
    if (blocks.len == 0) {
        return std.fmt.allocPrint(arena, "[观察] grep 在 {s} 中无命中。", .{path});
    }
    var hit_count: usize = 0;
    for (blocks) |b| for (b.hit_mask) |h| {
        if (h) hit_count += 1;
    };
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "[观察] grep {s} 命中 {d} 行（含上下文 ±{d} 行）：\n", .{ path, hit_count, context }));
    for (blocks, 0..) |b, bi| {
        if (bi != 0) try buf.appendSlice(arena, "--\n");
        for (b.lines, b.hit_mask, 0..) |line, is_hit, k| {
            const sep: u8 = if (is_hit) ':' else '-';
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}{c}{s}\n", .{ b.start_line + k, sep, line }));
        }
    }
    return clipTo(arena, buf.items, file_read_observation_tokens);
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
    return clipTo(arena, buf.items, file_read_observation_tokens);
}

/// 把 http 响应格式化成「观察」文本（arena 拥有）。超时 / 传输失败亦明示。受上限截断。
fn formatHttpResponse(arena: std.mem.Allocator, url: []const u8, resp: tools.http.Response) ![]const u8 {
    if (resp.timed_out) {
        return std.fmt.allocPrint(arena, "[观察] http {s} 超过硬超时被取消，无响应。请改用更快的端点或缩短请求。", .{url});
    }
    if (resp.err) |e| {
        return std.fmt.allocPrint(arena, "[观察] http {s} 请求失败：{s}（连接/TLS/DNS）。", .{ url, e });
    }
    const clipped = try clipTo(arena, resp.body, file_read_observation_tokens);
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

/// 命令流（bash stdout/stderr）观察瘦身：剥 ANSI、折叠空白、按 token 头+尾截断（arena 拥有）。
fn clip(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return obs.optimizeStream(arena, s, observation_stream_tokens);
}

/// 保真内容（file_read/grep/glob/skill/http 等）按 token 头+尾截断：窗口内逐字节保真，
/// 不剥 ANSI、不折叠空白，避免破坏后续 file_edit 的精确匹配（arena 拥有；未超预算原样返回）。
fn clipTo(arena: std.mem.Allocator, s: []const u8, max_tokens: usize) ![]const u8 {
    return obs.truncateTokens(arena, s, max_tokens);
}

/// 往 trace writer 写入限长文本；超出时附带剩余字节数。
fn traceClipped(w: *std.Io.Writer, s: []const u8, cap: usize) !void {
    const n = if (s.len > cap) cap else s.len;
    try w.writeAll(s[0..n]);
    if (s.len > n) {
        try w.print(" ...(+{d} bytes)", .{s.len - n});
    }
}

fn parallelCallInput(call: ParallelCallArgs) []const u8 {
    return if (call.input.len != 0) call.input else call.action_input;
}

/// 路径是否含 `..` 组件（按 `/` 与 `\` 切分）。用于 `skill` 读取的目录逃逸防护。
fn pathHasDotDot(p: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

const ParallelWorker = struct {
    io: std.Io,
    action: Action,
    input: []const u8,
    tool_timeout_ms: u64,
    ca_file: ?[]const u8,
    arena_state: std.heap.ArenaAllocator,
    observation: []const u8 = "[观察] parallel 子调用未执行。",
};

fn runParallelWorker(worker: *ParallelWorker) void {
    const arena = worker.arena_state.allocator();
    worker.observation = execReadTool(arena, worker.io, worker.action, worker.input, worker.tool_timeout_ms, worker.ca_file) catch |err|
        toolErrorObservation(arena, err) catch "[观察] 工具执行失败，且错误格式化失败。";
}

fn execReadTool(
    arena: std.mem.Allocator,
    io: std.Io,
    action: Action,
    input: []const u8,
    tool_timeout_ms: u64,
    ca_file: ?[]const u8,
) ![]const u8 {
    return switch (action) {
        .file_read => blk: {
            const args = try parseToolArgs(FileReadArgs, arena, input);
            break :blk try fileReadObservation(arena, io, args);
        },
        .grep => blk: {
            const args = try parseToolArgs(GrepArgs, arena, input);
            break :blk try grepObservation(arena, io, args);
        },
        .glob => blk: {
            const args = try parseToolArgs(GlobArgs, arena, input);
            const paths = try tools.search.glob(arena, io, args.pattern, args.root, tools.search.default_max_results);
            break :blk try formatGlobPaths(arena, args.pattern, paths);
        },
        .outline => blk: {
            const args = try parseToolArgs(OutlineArgs, arena, input);
            break :blk try outlineObservation(arena, io, args);
        },
        .http_request => blk: {
            const args = try parseToolArgs(HttpArgs, arena, input);
            const method = tools.http.methodFromString(args.method) orelse return error.UnknownMethod;
            if (tools.http.isWrite(method)) return error.ParallelWriteHttp;
            const resp = try tools.http.request(arena, io, method, args.url, args.body, .{
                .timeout_ms = tool_timeout_ms,
                .ca_file = ca_file,
            });
            break :blk try formatHttpResponse(arena, args.url, resp);
        },
        else => error.UnsupportedParallelAction,
    };
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

    const p = try parseStep(arena, "{\"thought\":\"并发读\",\"action\":\"parallel\",\"action_input\":\"{\\\"calls\\\":[]}\"}");
    try std.testing.expectEqual(Action.parallel, p.action);
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

test "parseStep 容忍兼容后端连续输出多个 JSON 对象" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try parseStep(
        arena,
        "{\"thought\":\"先读\",\"action\":\"file_read\",\"action_input\":\"{\\\"path\\\":\\\"README.md\\\"}\"}\n" ++
            "{\"thought\":\"再答\",\"action\":\"final\",\"action_input\":\"done\"}",
    );
    try std.testing.expectEqual(Action.file_read, s.action);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", s.action_input);
}

test "parseStep 容忍 JSON 代码块包裹" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try parseStep(
        arena,
        "```json\n{\"thought\":\"完成\",\"action\":\"final\",\"action_input\":\"ok\"}\n```",
    );
    try std.testing.expectEqual(Action.final, s.action);
    try std.testing.expectEqualStrings("ok", s.action_input);
}

test "动作集合唯一真相源：schema 与 system_prompt 覆盖每个 Action（防漂移，issue #27）" {
    // schema 的 enum 由 Action 在 comptime 生成，必然逐一覆盖；这里再断言一次，
    // 并强制 system_prompt 也提到每个动作名——新增 Action 却忘了写进提示词即测试失败。
    inline for (@typeInfo(Action).@"enum".fields) |f| {
        const quoted = "\"" ++ f.name ++ "\"";
        try std.testing.expect(std.mem.indexOf(u8, react_schema, quoted) != null);
        try std.testing.expect(std.mem.indexOf(u8, system_prompt, quoted) != null);
    }
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

    const big = try arena.alloc(u8, observation_stream_tokens * 4 + 1000);
    @memset(big, 'x');
    const clipped = try formatObservation(arena, .{ .stdout = big, .exit_code = 0 });
    try std.testing.expect(std.mem.indexOf(u8, clipped, "省略中段") != null);
}

test "fileReadObservation：整读 vs 行窗口（#74）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_fileread_obs";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const path = dir ++ "/big.txt";
    try tools.file.write(io, path, "a1\na2\na3\na4\na5\n");

    // 整读：无 offset/limit → 字节计数路径
    const whole = try fileReadObservation(arena, io, .{ .path = path });
    try std.testing.expect(std.mem.indexOf(u8, whole, "字节") != null);
    try std.testing.expect(std.mem.indexOf(u8, whole, "a3") != null);

    // 行窗口：offset=2,limit=2 → 标注「第 2-3 行 / 共 5 行」，且只含 a2/a3
    const win = try fileReadObservation(arena, io, .{ .path = path, .offset = 2, .limit = 2 });
    try std.testing.expect(std.mem.indexOf(u8, win, "第 2-3 行 / 共 5 行") != null);
    try std.testing.expect(std.mem.indexOf(u8, win, "a2\na3") != null);
    try std.testing.expect(std.mem.indexOf(u8, win, "a5") == null);

    // offset 越界 → 明示超出
    const oob = try fileReadObservation(arena, io, .{ .path = path, .offset = 99 });
    try std.testing.expect(std.mem.indexOf(u8, oob, "超出文件总行数 5") != null);
}

test "grepObservation：无 context 仅命中行，有 context 带 ±N 上下文（#76）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_grep_ctx_obs";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const path = dir ++ "/src.txt";
    try tools.file.write(io, path, "l1\nl2\nfn target\nl4\nl5\n");

    // 无 context：仅命中行，命中行以 `行号:原文`。
    const plain = try grepObservation(arena, io, .{ .pattern = "target", .path = path });
    try std.testing.expect(std.mem.indexOf(u8, plain, "3:fn target") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "l2") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "含上下文") == null);

    // context=1：命中行 `:`，上下文行 `-`，头部标注 ±1。
    const ctx = try grepObservation(arena, io, .{ .pattern = "target", .path = path, .context = 1 });
    try std.testing.expect(std.mem.indexOf(u8, ctx, "含上下文 ±1 行") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "2-l2") != null); // 上下文行
    try std.testing.expect(std.mem.indexOf(u8, ctx, "3:fn target") != null); // 命中行
    try std.testing.expect(std.mem.indexOf(u8, ctx, "4-l4") != null); // 上下文行
    try std.testing.expect(std.mem.indexOf(u8, ctx, "l5") == null); // 窗口外
}

test "outlineObservation：抽出结构骨架并提示窗口读（#77）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_outline_obs";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    // 有结构的 .zig：命中函数 / 顶层类型，输出含行号与「结构」头、窗口读提示。
    const zig_path = dir ++ "/sample.zig";
    try tools.file.write(io, zig_path,
        \\const std = @import("std");
        \\pub const Foo = struct {
        \\    pub fn bar(self: *Foo) void {
        \\        _ = self;
        \\    }
        \\};
        \\fn helper() void {}
        \\
    );
    const skeleton = try outlineObservation(arena, io, .{ .path = zig_path });
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "[结构]") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "lang=zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "pub const Foo = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "pub fn bar(self: *Foo) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "fn helper() void") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "@import") == null); // import 噪声被跳过
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "file_read") != null); // 窗口读提示

    // 无结构的纯文本：明示未识别并引导 file_read。
    const txt_path = dir ++ "/plain.txt";
    try tools.file.write(io, txt_path, "just some prose\nno definitions here\n");
    const empty = try outlineObservation(arena, io, .{ .path = txt_path });
    try std.testing.expect(std.mem.indexOf(u8, empty, "未识别到结构行") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "file_read") != null);
}

test "ReadCache.dedup：同读未变→引用占位，内容变/体量小/非读动作→照常回灌（issue #73）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache = ReadCache{ .store = arena };

    const big_a = "A" ** 300; // ≥ dedup_min_bytes
    const big_b = "B" ** 300;
    const input = "{\"path\":\"README.md\"}";

    // 首次：登记并保留全文（null）。
    try std.testing.expect((try cache.dedup(arena, 1, .file_read, input, big_a)) == null);
    // 重复同读且内容未变：返回去重占位，引用第 1 回合。
    const ref = (try cache.dedup(arena, 3, .file_read, input, big_a)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, ref, "去重") != null);
    try std.testing.expect(std.mem.indexOf(u8, ref, "第 1 回合") != null);
    // 内容已变：刷新记录并照常回灌（null）。
    try std.testing.expect((try cache.dedup(arena, 4, .file_read, input, big_b)) == null);
    // 现未变内容为 big_b（第 4 回合）：再读 big_b → 引用第 4 回合（证明「上次全文回合」会刷新）。
    const ref2 = (try cache.dedup(arena, 5, .file_read, input, big_b)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, ref2, "第 4 回合") != null);
    // 体量过小（< dedup_min_bytes）：不去重。
    try std.testing.expect((try cache.dedup(arena, 6, .grep, "{\"pattern\":\"x\",\"path\":\"a\"}", "tiny")) == null);
    // 非读动作（bash 有副作用）：永不去重，即便重复同样大的观察。
    try std.testing.expect((try cache.dedup(arena, 7, .bash, "ls", big_a)) == null);
    try std.testing.expect((try cache.dedup(arena, 8, .bash, "ls", big_a)) == null);
    // 不同键（带 offset 的窗口读）独立计账，不与整读串味。
    try std.testing.expect((try cache.dedup(arena, 9, .file_read, "{\"path\":\"README.md\",\"offset\":10}", big_a)) == null);
}

test "run: 重复 file_read 同文件内容未变时第二次去重回灌引用（issue #73）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_run_read_dedup";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    // 内容须 ≥ dedup_min_bytes 才触发去重；用唯一 marker 便于断言全文出现次数。
    try cwd.writeFile(io, .{ .sub_path = root ++ "/note.txt", .data = "UNIQUE-DEDUP-MARKER-Q7\n" ** 20 });

    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"读一次\",\"action\":\"file_read\",\"action_input\":\"{\\\"path\\\":\\\"/tmp/scoot_run_read_dedup/note.txt\\\"}\"}",
        "{\"thought\":\"再读一次\",\"action\":\"file_read\",\"action_input\":\"{\\\"path\\\":\\\"/tmp/scoot_run_read_dedup/note.txt\\\"}\"}",
        "{\"thought\":\"完成\",\"action\":\"final\",\"action_input\":\"done\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, system_prompt);
    try sess.append(gpa, .user, "go");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    // 全文 marker 仅应在历史中出现一次（首次观察）；第二次被替换为去重引用。
    var full_obs: usize = 0;
    var saw_dedup = false;
    for (sess.items()) |m| {
        const has_marker = std.mem.indexOf(u8, m.content, "UNIQUE-DEDUP-MARKER-Q7") != null;
        const is_dedup = std.mem.indexOf(u8, m.content, "去重") != null;
        if (m.role == .user and has_marker and !is_dedup) full_obs += 1;
        if (is_dedup) saw_dedup = true;
    }
    try std.testing.expectEqual(@as(usize, 1), full_obs);
    try std.testing.expect(saw_dedup);
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

test "护栏/执行：契约外动作降级为 deny/error 而非 panic（硬化）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var brain = ScriptedBrain{ .steps = &.{} };
    var ag = testAgent(&brain, 16);

    // guard(.final)：终态不应过护栏；若被误路由，降级为 deny。
    switch (ag.guard(arena, .final, "")) {
        .deny => {},
        .allow => return error.ShouldHaveDenied,
    }

    // guardLocalRead(非读动作)：只读档下走 else 分支，降级为 deny 而非 unreachable。
    ag.policy_mode = .readonly;
    switch (ag.guardLocalRead(arena, .bash, "")) {
        .deny => {},
        .allow => return error.ShouldHaveDenied,
    }

    // execTool(.final)：终态被误路由时返回 error.UnexpectedAction，由 run 转成观察回灌。
    try std.testing.expectError(error.UnexpectedAction, ag.execTool(arena, .final, ""));
}

test "historyBytes：累加各消息 content 字节数（issue #28 纯函数）" {
    const msgs = [_]llm.Message{
        .{ .role = .system, .content = "abc" }, // 3
        .{ .role = .user, .content = "de" }, // 2
        .{ .role = .assistant, .content = "" }, // 0
        .{ .role = .user, .content = "fghij" }, // 5
    };
    try std.testing.expectEqual(@as(usize, 10), historyBytes(&msgs));
}

test "run：上下文预算超限时在调用后端前 fail-fast（issue #28）" {
    const gpa = std.testing.allocator;

    // 若预算闸失效而调用了后端，会吐出 final——测试据此反证「后端从未被调用」。
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"x\",\"action\":\"final\",\"action_input\":\"never\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "0123456789"); // 10 字节历史
    ag.context_budget_bytes = 4; // 10 > 4：超限

    try std.testing.expectError(error.ContextBudgetExceeded, ag.run(gpa, &sess));
    try std.testing.expectEqual(@as(usize, 0), brain.idx); // 后端从未被调用（fail-fast）
}

test "run：预算为 0 表示关闭，历史照常运行（issue #28 默认行为）" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"x\",\"action\":\"final\",\"action_input\":\"ok\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "0123456789");
    ag.context_budget_bytes = 0; // 关闭：仅受 max_turns 约束

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("ok", reply);
}

test "护栏：opt-in 写约束 + SSRF 防护仅在开启时收紧 guarded（issue #32）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var brain = ScriptedBrain{ .steps = &.{} };
    var ag = testAgent(&brain, 16); // guarded 默认，两项加固默认关闭

    const bad_write =
        \\{"path":"/etc/passwd","content":"x"}
    ;
    const bad_edit =
        \\{"path":"../escape","old":"a","new":"b"}
    ;
    const ok_write =
        \\{"path":"src/out.txt","content":"x"}
    ;
    const meta_get =
        \\{"method":"GET","url":"http://169.254.169.254/latest/"}
    ;
    const local_get =
        \\{"method":"GET","url":"http://localhost:8080/"}
    ;
    const pub_get =
        \\{"method":"GET","url":"https://example.com/"}
    ;
    const par_internal =
        \\{"calls":[{"action":"http_request","input":"{\"method\":\"GET\",\"url\":\"http://127.0.0.1/\"}"}]}
    ;

    // 默认（flags off）：guarded 放行越界写与内网 GET（保持「绊线非沙箱」立场）。
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .file_write, bad_write));
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .http_request, meta_get));

    // 开启写约束：越界写 / `..` 逃逸被拒，项目内写放行。
    ag.confine_writes = true;
    try expectDeny(ag.guard(arena, .file_write, bad_write));
    try expectDeny(ag.guard(arena, .file_edit, bad_edit));
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .file_write, ok_write));

    // 开启 SSRF 防护：内网 / 元数据 / 主机名 GET 被拒，公网 GET 放行。
    ag.block_internal_http = true;
    try expectDeny(ag.guard(arena, .http_request, meta_get));
    try expectDeny(ag.guard(arena, .http_request, local_get));
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .http_request, pub_get));

    // parallel 子调用里的内网 GET 也应被 SSRF 防护拦下（guard 对子调用递归覆盖）。
    try expectDeny(ag.guard(arena, .parallel, par_internal));
}

fn expectDeny(d: policy.Decision) !void {
    switch (d) {
        .deny => {},
        .allow => return error.ShouldHaveDenied,
    }
}

test "skill 动作：原生只读，readonly 下也能按名读取技能指令，且收口在技能目录内" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_skill_action_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/demo/references");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/demo/SKILL.md", .data = "# Demo\nMAGIC-INSTRUCTION-7" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/demo/references/extra.md", .data = "REF-BODY-9" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var brain = ScriptedBrain{ .steps = &.{} };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly; // 关键：最严档下技能读取仍须畅通（原生能力，不过策略门）。
    ag.skills = &.{.{ .name = "demo", .dir = root ++ "/demo" }};

    // 1) guard 对 skill 恒放行——即便 readonly（readonly 禁 bash / 拒写 / 拒网，但不挡技能读取）。
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .skill, "{\"name\":\"demo\"}"));

    // 2) 默认读 SKILL.md 正文，内容如实回灌。
    const md = try ag.execTool(arena, .skill, "{\"name\":\"demo\"}");
    try std.testing.expect(std.mem.indexOf(u8, md, "MAGIC-INSTRUCTION-7") != null);

    // 3) 可按相对 path 读技能目录内其它资源。
    const ref = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"references/extra.md\"}");
    try std.testing.expect(std.mem.indexOf(u8, ref, "REF-BODY-9") != null);

    // 4) 目录逃逸收口：`..` 与绝对路径被拒（返回可纠错观察，不读到目录外）。
    const esc = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"../../etc/passwd\"}");
    try std.testing.expect(std.mem.indexOf(u8, esc, "被拒") != null);
    const abs = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"/etc/passwd\"}");
    try std.testing.expect(std.mem.indexOf(u8, abs, "被拒") != null);

    // 5) 未装载技能名：回灌「未装载」观察并列出可用技能，便于模型纠错（不报错、不 panic）。
    const miss = try ag.execTool(arena, .skill, "{\"name\":\"nope\"}");
    try std.testing.expect(std.mem.indexOf(u8, miss, "未装载") != null);
    try std.testing.expect(std.mem.indexOf(u8, miss, "demo") != null);
}

test "skill 动作：技能目录内 symlink 不得逃逸读外部文件（issue #41）" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_skill_symlink_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/demo");
    try cwd.createDirPath(io, root ++ "/outside");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/demo/SKILL.md", .data = "# Demo\nLEGIT-BODY" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/outside/secret.txt", .data = "TOP-SECRET-LEAK" });
    // 技能目录内放一个指向目录外部的 symlink（模拟被污染/恶意技能包）。
    cwd.symLink(io, root ++ "/outside/secret.txt", root ++ "/demo/leak", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };
    // 目录内合法 symlink（仍落在技能目录内）：应放行。
    try cwd.symLink(io, root ++ "/demo/SKILL.md", root ++ "/demo/alias.md", .{});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var brain = ScriptedBrain{ .steps = &.{} };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly;
    ag.skills = &.{.{ .name = "demo", .dir = root ++ "/demo" }};

    // 越权 symlink：拒绝，且绝不回灌外部文件内容。
    const leak = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"leak\"}");
    try std.testing.expect(std.mem.indexOf(u8, leak, "被拒") != null);
    try std.testing.expect(std.mem.indexOf(u8, leak, "TOP-SECRET-LEAK") == null);

    // 目录内 symlink：realpath 仍在技能目录内，放行并读到正文。
    const ok = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"alias.md\"}");
    try std.testing.expect(std.mem.indexOf(u8, ok, "LEGIT-BODY") != null);
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

test "run: thought 不落历史，只持久化紧凑步骤（issue #70）" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"SECRET-THOUGHT-X9\",\"action\":\"bash\",\"action_input\":\"printf OK\"}",
        "{\"thought\":\"ANOTHER-THOUGHT-Z\",\"action\":\"final\",\"action_input\":\"done\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, system_prompt);
    try sess.append(gpa, .user, "go");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    // thought 文本绝不出现在任何历史消息中（不随回合重发）。
    for (sess.items()) |m| {
        try std.testing.expect(std.mem.indexOf(u8, m.content, "SECRET-THOUGHT-X9") == null);
        try std.testing.expect(std.mem.indexOf(u8, m.content, "ANOTHER-THOUGHT-Z") == null);
    }
    // 但紧凑步骤（action，无 thought 字段）确实入了历史。
    var saw_compact = false;
    for (sess.items()) |m| {
        if (m.role == .assistant and
            std.mem.indexOf(u8, m.content, "\"action\":\"bash\"") != null and
            std.mem.indexOf(u8, m.content, "\"thought\"") == null) saw_compact = true;
    }
    try std.testing.expect(saw_compact);
}

test "compactStepJson：去 thought、转义合法、保留 action_input（issue #70）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try compactStepJson(arena, "grep", "{\"pattern\":\"a\\\"b\",\"path\":\"f\"}");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"thought\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"action\":\"grep\"") != null);

    // 产物本身必须是合法 JSON，且 action_input 解析回原字符串（转义未丢失）。
    const Raw = struct { action: []const u8, action_input: []const u8 };
    const v = try std.json.parseFromSliceLeaky(Raw, arena, out, .{});
    try std.testing.expectEqualStrings("grep", v.action);
    try std.testing.expectEqualStrings("{\"pattern\":\"a\\\"b\",\"path\":\"f\"}", v.action_input);
}

test "run: 超预算时压缩历史而非中止，run 仍完成（issue #71）" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"done\",\"action\":\"final\",\"action_input\":\"FINAL-OK\"}",
    } };
    var ag = testAgent(&brain, 16);
    ag.context_budget_bytes = 4000; // 低于预填体量、但高于最小保留集

    var sess = session.Session.init("t-compact");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, "SYS-PROMPT");
    try sess.append(gpa, .user, "ORIGINAL-TASK");

    // 预填大量较早消息，使历史远超预算（30 回合，每条观察 200B）。
    var filler: [200]u8 = undefined;
    @memset(&filler, 'F');
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try sess.append(gpa, .assistant, "{\"action\":\"bash\",\"action_input\":\"x\"}");
        try sess.append(gpa, .user, &filler);
    }
    try std.testing.expect(historyBytes(sess.items()) > ag.context_budget_bytes);

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    // 没有中止：run 正常拿到最终答复。
    try std.testing.expectEqualStrings("FINAL-OK", reply);

    // 压缩生效：体量回落到预算内，出现压缩标记，system 与原始任务仍保留。
    try std.testing.expect(historyBytes(sess.items()) <= ag.context_budget_bytes);
    var saw_marker = false;
    var saw_task = false;
    var saw_sys = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "历史压缩") != null) saw_marker = true;
        if (std.mem.indexOf(u8, m.content, "ORIGINAL-TASK") != null) saw_task = true;
        if (std.mem.indexOf(u8, m.content, "SYS-PROMPT") != null) saw_sys = true;
    }
    try std.testing.expect(saw_marker);
    try std.testing.expect(saw_task);
    try std.testing.expect(saw_sys);
}

test "run: 预算过小、压缩后仍超限则 fail-fast（issue #71）" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"x\",\"action\":\"final\",\"action_input\":\"never\"}",
    } };
    var ag = testAgent(&brain, 16);
    ag.context_budget_bytes = 50; // 连 system+任务+最近 K 都放不下

    var sess = session.Session.init("t-compact-fail");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, "SYSTEM-PROMPT-THAT-ALONE-EXCEEDS-THE-TINY-BUDGET");
    try sess.append(gpa, .user, "ORIGINAL-TASK-LONG-ENOUGH-TO-OVERFLOW");
    var i: usize = 0;
    while (i < 12) : (i += 1) try sess.append(gpa, .user, "observation-payload-block");

    try std.testing.expectError(error.ContextBudgetExceeded, ag.run(gpa, &sess));
}

test "run: parallel 并发执行本地只读工具并按输入顺序回灌" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_agent_parallel";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{ .sub_path = root ++ "/a.txt", .data = "alpha-A" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/b.txt", .data = "first\nneedle-B\nlast" });

    const step =
        \\{"thought":"并发读取","action":"parallel","action_input":"{\"calls\":[{\"action\":\"file_read\",\"input\":\"{\\\"path\\\":\\\"/tmp/scoot_agent_parallel/a.txt\\\"}\"},{\"action\":\"grep\",\"input\":\"{\\\"pattern\\\":\\\"needle\\\",\\\"path\\\":\\\"/tmp/scoot_agent_parallel/b.txt\\\"}\"}]}"}
    ;

    var brain = ScriptedBrain{ .steps = &.{
        step,
        "{\"thought\":\"已读完\",\"action\":\"final\",\"action_input\":\"done\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "并发读两个文件");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    var observation: []const u8 = "";
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "parallel 完成 2 个只读调用") != null) {
            observation = m.content;
            break;
        }
    }
    try std.testing.expect(observation.len > 0);
    const first = std.mem.indexOf(u8, observation, "[1] file_read") orelse return error.MissingFirstObservation;
    const second = std.mem.indexOf(u8, observation, "[2] grep") orelse return error.MissingSecondObservation;
    try std.testing.expect(first < second);
    try std.testing.expect(std.mem.indexOf(u8, observation, "alpha-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "needle-B") != null);
}

test "guard: parallel 只允许受策略约束的只读子调用" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var brain = ScriptedBrain{ .steps = &.{} };
    var ag = testAgent(&brain, 1);

    const write_call =
        \\{"calls":[{"action":"file_write","input":"{\"path\":\"x\",\"content\":\"y\"}"}]}
    ;
    switch (ag.guard(arena, .parallel, write_call)) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }

    const nested_call =
        \\{"calls":[{"action":"parallel","input":"{\"calls\":[]}"}]}
    ;
    switch (ag.guard(arena, .parallel, nested_call)) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }

    const http_get =
        \\{"calls":[{"action":"http_request","input":"{\"method\":\"GET\",\"url\":\"https://example.com\"}"}]}
    ;
    ag.policy_mode = .readonly;
    switch (ag.guard(arena, .parallel, http_get)) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }

    const http_post =
        \\{"calls":[{"action":"http_request","input":"{\"method\":\"POST\",\"url\":\"https://example.com\"}"}]}
    ;
    ag.policy_mode = .guarded;
    switch (ag.guard(arena, .parallel, http_post)) {
        .deny => {},
        .allow => return error.ExpectedDeny,
    }
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
    var logger = audit.Logger.init(&lw, std.testing.io);
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

    // 进度标记（防前端卡死）：每回合进入后端推理前应先有 thinking；工具回合执行前应有 running。
    const think1 = std.mem.indexOf(u8, trace, "[trace 1] thinking:") orelse return error.MissingThinking;
    const reason1 = std.mem.indexOf(u8, trace, "[trace 1] reason:").?;
    const running1 = std.mem.indexOf(u8, trace, "[trace 1] running: bash") orelse return error.MissingRunning;
    const observe1 = std.mem.indexOf(u8, trace, "[trace 1] observe:").?;
    // thinking 必须早于 reason（推理前），running 必须早于 observe（执行前）。
    try std.testing.expect(think1 < reason1);
    try std.testing.expect(running1 < observe1);
    // 第二回合（final）也应先打印 thinking。
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 2] thinking:") != null);
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
    var logger = audit.Logger.init(&lw, std.testing.io);
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
    var logger = audit.Logger.init(&lw, std.testing.io);
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

test "run: readonly 安全档拒绝项目外 file_read 路径（不读取敏感文件）" {
    const gpa = std.testing.allocator;
    const s_read =
        \\{"thought":"读系统文件","action":"file_read","action_input":"{\"path\":\"/etc/passwd\"}"}
    ;
    const s_final =
        \\{"thought":"改道","action":"final","action_input":"只读模式无法读取项目外路径"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_read, s_final } };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly;

    var logbuf: [4096]u8 = undefined;
    var lw = std.Io.Writer.fixed(&logbuf);
    var logger = audit.Logger.init(&lw, std.testing.io);
    ag.audit = &logger;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "读系统文件");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("只读模式无法读取项目外路径", reply);

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
    const dir = ".zig-cache/scoot_agent_search_flow";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    try cwd.createDirPath(io, dir ++ "/src");
    try tools.file.write(io, dir ++ "/src/main.zig", "const x = 1;\npub fn main() void {}\n");
    try tools.file.write(io, dir ++ "/README.md", "# doc\n");

    const s_glob =
        \\{"thought":"找 zig 文件","action":"glob","action_input":"{\"pattern\":\"**/*.zig\",\"root\":\".zig-cache/scoot_agent_search_flow\"}"}
    ;
    const s_grep =
        \\{"thought":"搜 main","action":"grep","action_input":"{\"pattern\":\"pub fn \\\\w+\",\"path\":\".zig-cache/scoot_agent_search_flow/src/main.zig\"}"}
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
    var logger = audit.Logger.init(&lw, std.testing.io);
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
    var logger = audit.Logger.init(&lw, std.testing.io);
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
