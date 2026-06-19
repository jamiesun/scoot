//! Cognitive-flow engine: thought-action-observation (ReACT) loop.
//!
//! Design stance:
//!   - Do not depend on backend-native tool_calls, because local small-model
//!     support varies. Each turn instead forces json_schema output for one
//!     structured step: {thought, action, action_input}. This preserves
//!     response_format=json_schema + strict, works with any OpenAI-compatible
//!     backend including basic local models, and reuses defensive parsing.
//!   - action in {bash, file_read, ..., parallel, final}: tools execute through a
//!     unified guardrail with hard timeouts, output returns as observation, and
//!     final is the terminal answer.
//!
//! Memory policy: each reasoning turn derives a local ArenaAllocator and resets
//! it at turn end, preventing long-lived fragmentation/leaks. Cross-turn
//! conversation history lives in `backing`, copied through Session, and is not
//! affected by the per-turn arena.
const std = @import("std");
const llm = @import("llm.zig");
const session = @import("session.zig");
const compressor = @import("compressor.zig");
const tools = @import("tools/tools.zig");
const audit = @import("audit.zig");
const policy = @import("policy.zig");
const pathsafe = @import("paths.zig");
const jsonio = @import("jsonio.zig");
const obs = @import("obs.zig");

pub const default_context_budget_bytes: usize = 80_000;

// Dual cognitive modes (goal / plan) are not implemented yet: the plan-mode
// execution DAG is not wired, so do not keep dead fields like the former Mode
// enum and Agent.mode that imply plan changes execution. Add them back only when
// plan mode is real.

/// Per-turn structured-output schema: forces the model to emit one ReACT step.
/// `action` is constrained to known enum values; additionalProperties:false plus
/// full required fields satisfy strict. The action enum array is derived from
/// `Action` at comptime, making the enum the single source of truth (issue #27).
const react_schema = "{\"type\":\"object\",\"properties\":{\"thought\":{\"type\":\"string\"}," ++
    "\"action\":{\"type\":\"string\",\"enum\":" ++ actionEnumArrayJson() ++ "}," ++
    "\"action_input\":{\"type\":\"string\"}}," ++
    "\"required\":[\"thought\",\"action\",\"action_input\"],\"additionalProperties\":false}";

/// Builds a JSON string array of `Action` tag names at comptime, e.g.
/// `["bash",...,"final"]`, so react_schema follows the enum automatically.
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

/// System prompt injected into the session to explain ReACT protocol and tool constraints.
pub const system_prompt =
    \\You are Scoot, an autonomous AI assistant running in a command-line environment. Complete user tasks through a thought-action-observation loop.
    \\
    \\Each step must output exactly one JSON object matching the given schema, with three fields:
    \\  - "thought": one sentence explaining your reasoning.
    \\  - "action": one of the actions below.
    \\  - "action_input": input for that action, formatted as described below.
    \\
    \\Available actions:
    \\  - "bash": run one shell command; action_input is the command string. The command runs under POSIX sh (/bin/sh) in a hard-timeout sandbox, and its output is returned as the next observation. Use only portable POSIX syntax; avoid bash-specific forms such as [[ ]], arrays, {1..10} brace expansion, and $'...'.
    \\  - "file_read": read file content; action_input is JSON {"path":"file path"}. For large files, prefer line windows: {"offset":start_line_1_based,"limit":line_count}. Omit offset/limit to read the whole file; long output is truncated.
    \\  - "file_write": overwrite a file, creating it if missing; action_input is JSON {"path":"file path","content":"complete new content"}.
    \\  - "file_edit": exactly replace one text span in a file; action_input is JSON {"path":"file path","old":"exact text that appears once","new":"replacement text"}.
    \\  - "grep": search a file line by line with a regex and return matching line numbers and text; action_input is JSON {"pattern":"regex","path":"file path"}. Optional {"context":N} returns N lines before and after each hit, like grep -C. Supported subset: . ^ $ * + ? [] () | \d \w \s. Capture groups, backreferences, lookaround, and lazy quantifiers are unsupported.
    \\  - "glob": list matching file paths under a directory subtree; action_input is JSON {"pattern":"glob pattern","root":"start directory, optional, default ."}. * ? [] do not cross /, while ** crosses directory levels. Returned paths can be passed to file_read / grep.
    \\  - "outline": retrieve a low-token structural outline of a file, such as source function/type signatures or Markdown headings; action_input is JSON {"path":"file path"}. This is a best-effort heuristic overview, not precise parsing.
    \\  - "http_request": make one HTTP/HTTPS request; action_input is JSON {"method":"GET","url":"https://...","body":"optional body"}. method is GET/POST/PUT/DELETE/HEAD/PATCH. Returns status code and response body with a hard timeout.
    \\  - "skill": read instructions or resources for a loaded skill. This is Scoot native read-only capability and works even in readonly mode; action_input is JSON {"name":"skill name","path":"relative path inside the skill directory, optional, default SKILL.md"}. Skill-requested bash/write/network actions still obey execution policy.
    \\  - "recall": recall original text from the current session transcript archive. action_input is JSON {"query":"keyword","limit":8} or {"seq":12,"context":2}. seq starts at 1.
    \\  - "parallel": run 1-4 independent read-only calls concurrently; action_input is JSON {"calls":[{"action":"file_read","input":"{\"path\":\"README.md\"}"},{"action":"grep","input":"{\"pattern\":\"Scoot\",\"path\":\"AGENT.md\"}"}]}. Only file_read / grep / glob / outline / HTTP GET or HEAD are allowed; bash, writes, skill, recall, final, and nested parallel are forbidden.
    \\  - "final": provide the final answer; action_input is the answer text for the user.
    \\
    \\Workflow:
    \\  - Prefer file_read / file_write / file_edit for file I/O; they do not depend on external commands.
    \\  - Use glob to find files and grep to search file contents; prefer them over system ls/find/grep.
    \\  - Use http_request for network access; it does not depend on curl/wget.
    \\  - Use bash for other system operations; run only non-interactive commands that exit by themselves, and avoid dangerous or destructive operations.
    \\  - file_edit old must appear exactly once; inspect exact content with file_read first if unsure.
    \\  - After enough information is collected, use final for a concise, direct answer.
    \\  - Do not output any extra text outside this JSON object.
;

/// Actions available to the model.
pub const Action = enum { bash, file_read, file_write, file_edit, grep, glob, outline, http_request, skill, recall, parallel, final };

/// One parsed ReACT step.
pub const Step = struct {
    thought: []const u8,
    action: Action,
    action_input: []const u8,
};

/// Multi-argument built-ins carry a JSON object string in action_input and parse
/// it per tool. Single-argument tools such as file_read also use JSON
/// (`{"path":...}`), keeping the rule "file-like tools use JSON args" uniform
/// and reducing model confusion about raw strings vs JSON. bash/final remain raw text.
const FileReadArgs = struct { path: []const u8, offset: ?usize = null, limit: ?usize = null };
const FileWriteArgs = struct { path: []const u8, content: []const u8 };
const FileEditArgs = struct { path: []const u8, old: []const u8, new: []const u8 };
const GrepArgs = struct { pattern: []const u8, path: []const u8, context: ?usize = null };
const GlobArgs = struct { pattern: []const u8, root: []const u8 = "." };
const OutlineArgs = struct { path: []const u8 };
const HttpArgs = struct { method: []const u8 = "GET", url: []const u8, body: ?[]const u8 = null };
const SkillArgs = struct { name: []const u8, path: []const u8 = "SKILL.md" };
const RecallArgs = struct { query: ?[]const u8 = null, seq: ?usize = null, context: ?usize = null, limit: ?usize = null };
const ParallelCallArgs = struct {
    action: []const u8,
    input: []const u8 = "",
    action_input: []const u8 = "",
};
const ParallelArgs = struct { calls: []const ParallelCallArgs };

/// Defensively parses tool argument JSON. Failures collapse to
/// error.MalformedArgs so callers can feed back corrections instead of panicking.
fn parseToolArgs(comptime T: type, arena: std.mem.Allocator, input: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, input, .{
        .ignore_unknown_fields = true,
    }) catch error.MalformedArgs;
}

/// Observations below this size are not deduplicated because the placeholder
/// itself is roughly hundreds of bytes and would increase small observations.
const dedup_min_bytes: usize = 256;

/// Deduplicates read-only observations within one run (issue #73). For
/// `(action, normalized args)`, store the last observation hash. If the same read
/// repeats and bytes are unchanged, feed back a short reference to the turn that
/// carried the full text instead of repeating it. This prevents duplicate
/// observations from stacking in history and being resent every turn. bash and
/// writes have side effects and are never deduplicated. Reads per run are bounded
/// by max_turns, so a linear scan is enough.
const ReadCache = struct {
    /// Run-lifetime allocator; keys/table live until the whole run ends.
    store: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: []const u8, hash: u64, turn: u32 };

    /// On duplicate same-key/same-hash, returns an `out`-owned placeholder for
    /// history. Otherwise returns null and caller keeps full observation.
    /// Non-dedup actions, malformed args, and too-small observations return null.
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
                    "[Observation] deduplicated: {s} result is identical to turn {d}; omitted this repeated observation ({d} bytes). Reuse the observation from turn {d}.",
                    .{ key, e.turn, observation.len, e.turn },
                );
            }
            // Content changed: refresh record and feed back the new full text.
            e.hash = h;
            e.turn = turn;
            return null;
        }
        try self.entries.append(self.store, .{ .key = try self.store.dupe(u8, key), .hash = h, .turn = turn });
        return null;
    }
};

/// Normalizes read-only actions into stable dedup keys and readable labels.
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

/// Abstraction for getting the next completion. Tests can inject a scripted
/// brain without a real backend. Default implementation calls `llm.Client.chat`.
pub const CompleteFn = *const fn (
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    messages: []const llm.Message,
    opts: llm.ChatOptions,
) anyerror!llm.Completion;

/// Lightweight loaded-skill handle: name -> directory. The `skill` action uses
/// it to resolve a skill name and read files inside that directory.
pub const SkillRef = struct { name: []const u8, dir: []const u8 };

pub const Agent = struct {
    io: std.Io,
    complete_ctx: *anyopaque,
    complete_fn: CompleteFn,
    /// Turn cap to prevent model tool-call loops from stalling the daemon.
    max_turns: u32 = 16,
    /// Context budget in bytes, 0 disabled. If accumulated prompt history exceeds
    /// this, `compactor` folds history so the run can continue instead of either
    /// aborting immediately or letting request bodies grow unbounded. Only if
    /// compaction still exceeds budget does the run fail fast.
    context_budget_bytes: usize = default_context_budget_bytes,
    /// Context compaction strategy. Default `extractive` keeps system, original
    /// task, and recent messages, replacing older middle messages with a
    /// deterministic navigation summary. `drop` remains the minimal fallback.
    compactor: compressor.Compressor = .{ .extractive = {} },
    /// Hard timeout per tool call, in milliseconds.
    tool_timeout_ms: u64 = 30_000,
    /// Optional audit log. Non-null records each thought/tool call/observation/
    /// final/error. Injected so tests can attach an in-memory writer. Audit write
    /// failure does not block the task and is surfaced at flush.
    audit: ?*audit.Logger = null,
    /// Execution policy mode; bash commands must pass before reaching the system.
    policy_mode: policy.Mode = .guarded,
    /// Opt-in hardening, default off and only active in guarded: confines
    /// file_write/file_edit to project root and rejects absolute paths, `..`
    /// escapes, and shell expansion (issue #32).
    confine_writes: bool = false,
    /// Opt-in hardening, default off and only active in guarded: rejects
    /// http_request to loopback/private/link-local/cloud metadata targets to
    /// narrow SSRF/exfiltration surface (issue #32).
    block_internal_http: bool = false,
    /// Absolute custom CA bundle path (PEM) for http_request; null uses system roots.
    ca_file: ?[]const u8 = null,
    /// Optional CLI trace output for explicit debugging; final answer stays caller-owned.
    trace: ?*std.Io.Writer = null,
    /// Loaded name->dir skill table injected by setupRun from Registry. Arena-owned
    /// for this run. Empty means no loaded skills.
    skills: []const SkillRef = &.{},

    /// Constructs an Agent backed by a real LLM client.
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

    /// Runs the ReACT loop around a session and returns the final backing-owned
    /// reply. `backing` is the long-lived allocator; each turn derives and frees
    /// a temporary arena. `sess` holds cross-turn history and must already contain
    /// initial system/user messages.
    pub fn run(self: *Agent, backing: std.mem.Allocator, sess: *session.Session) ![]const u8 {
        var turn: u32 = 0;
        // Read-only observation dedup cache (issue #73): run lifetime, surviving
        // across turns and released at end. A dedicated arena, not per-turn arena,
        // keeps keys/table alive through turn resets and keeps GPA tests leak-free.
        var cache_arena = std.heap.ArenaAllocator.init(backing);
        defer cache_arena.deinit();
        var read_cache = ReadCache{ .store = cache_arena.allocator() };
        while (turn < self.max_turns) : (turn += 1) {
            var arena_state = std.heap.ArenaAllocator.init(backing);
            defer arena_state.deinit(); // Turn-scoped memory is released as a whole.
            const arena = arena_state.allocator();

            // Context budget gate (issues #28 + #71): measure history before
            // sending to backend. If over budget, compact history before
            // continuing instead of aborting the run. Only fail fast when compacted
            // history is still too large. 0 disables the gate.
            if (self.context_budget_bytes != 0) {
                var used = historyBytes(sess.items());
                if (used > self.context_budget_bytes) {
                    const compacted = self.compactor.compact(backing, sess, .{ .keep_recent = history_keep_recent }) catch false;
                    if (compacted) {
                        used = historyBytes(sess.items());
                        self.traceCompacted(turn + 1, used);
                        if (self.audit) |lg| {
                            var b: [160]u8 = undefined;
                            const m = std.fmt.bufPrint(&b, "context budget exceeded: compacted history to {d} bytes / limit {d} before turn {d}", .{ used, self.context_budget_bytes, turn + 1 }) catch "context budget exceeded: compacted history";
                            lg.log(.system_error, m) catch {};
                        }
                    }
                    if (used > self.context_budget_bytes) {
                        if (self.audit) |lg| {
                            var b: [160]u8 = undefined;
                            const m = std.fmt.bufPrint(&b, "context budget exceeded after compaction: {d} bytes > limit {d}; stopped before backend call at turn {d}", .{ used, self.context_budget_bytes, turn + 1 }) catch "context budget exceeded after compaction; stopped before backend call";
                            lg.log(.system_error, m) catch {};
                        }
                        return error.ContextBudgetExceeded;
                    }
                }
            }

            // Emit a "thinking" trace before inference and flush immediately.
            // complete is the longest blocking point this turn; reason/action can
            // only print after it returns, so without this marker trace is silent
            // during backend wait and UIs look stalled.
            self.traceThinking(turn + 1);
            const completion = try self.complete(arena, sess.items(), .{
                .json_schema = react_schema,
                .schema_name = "scoot_step",
            });

            // Defensive parse: malformed model steps do not panic; feed back a
            // correction and retry.
            const step = parseStep(arena, completion.content) catch {
                if (self.audit) |lg| lg.log(.system_error, "model output was not valid step JSON; fed back a correction and retried") catch {};
                self.traceMalformed(turn + 1);
                // Keep malformed output in history so the model can see and fix it.
                try sess.append(backing, .assistant, completion.content);
                try sess.append(backing, .user, malformed_hint);
                continue;
            };
            if (self.audit) |lg| lg.log(.thought, step.thought) catch {};
            self.traceStep(turn + 1, step);

            // Write only compact steps without thought to history (issue #70).
            // thought is private per-turn reasoning with no reuse value in later
            // turns; persisting it grows history and resend cost roughly O(N^2).
            // thought is kept only for audit/trace; history keeps action/input.
            const compact = try compactStepJson(arena, @tagName(step.action), step.action_input);
            try sess.append(backing, .assistant, compact);

            switch (step.action) {
                .final => {
                    if (self.audit) |lg| lg.log(.final, step.action_input) catch {};
                    self.traceFinal(turn + 1, step.action_input);
                    return try backing.dupe(u8, step.action_input);
                },
                // All remaining actions are tool actions with common trace -> guard -> execute/feed back flow.
                else => {
                    if (self.audit) |lg| lg.log(.tool_call, step.action_input) catch {};
                    // Model-produced actions must pass the guard before reaching the system.
                    switch (self.guard(arena, step.action, step.action_input)) {
                        .deny => |reason| {
                            self.tracePolicyDeny(turn + 1, reason);
                            const denied = try std.fmt.allocPrint(
                                arena,
                                "[Observation] action denied by execution policy ({s} mode): {s}. Use a safer or read-only approach.",
                                .{ @tagName(self.policy_mode), reason },
                            );
                            if (self.audit) |lg| lg.log(.policy_deny, denied) catch {};
                            try sess.append(backing, .user, denied);
                        },
                        .allow => {
                            self.tracePolicyAllow(turn + 1);
                            // Tool execution is also blocking; bash/http_request may be
                            // slow. Mark which tool is running before results arrive.
                            self.traceRunning(turn + 1, step.action);
                            var observation: []const u8 = self.execToolWithSession(arena, sess, step.action, step.action_input) catch |err|
                                try toolErrorObservation(arena, err);
                            // Read-only dedup (issue #73): repeated unchanged reads
                            // use short references instead of stacking identical text.
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

    /// Selects guardrail by action class. bash parses command strings that can do
    /// arbitrary shell execution and must be reviewed per string. Built-in tool
    /// read/write/network semantics are statically known and classified by
    /// capability. readonly local reads also apply path policy.
    fn guard(self: *Agent, arena: std.mem.Allocator, action: Action, input: []const u8) policy.Decision {
        return switch (action) {
            .bash => policy.evaluate(arena, input, self.policy_mode),
            .file_read, .grep, .glob, .outline => self.guardLocalRead(arena, action, input),
            .file_write, .file_edit => self.guardWrite(arena, action, input),
            .http_request => self.guardHttp(arena, input),
            .skill => .allow, // Native read-only skill instruction read, outside execution policy.
            .recall => .allow, // Native read-only recall from this session transcript.
            .parallel => self.guardParallel(arena, input),
            // Caller contract: `run` handles .final before guard. Degrade to deny
            // instead of panic if future code routes .final here.
            .final => .{ .deny = "final is a terminal answer, not an executable tool action" },
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
                    break :blk .{ .deny = "readonly mode could not parse file_read path; denied" };
                break :blk policy.evaluateReadPath(args.path, self.policy_mode);
            },
            .grep => blk: {
                const args = parseToolArgs(GrepArgs, arena, input) catch
                    break :blk .{ .deny = "readonly mode could not parse grep path; denied" };
                break :blk policy.evaluateReadPath(args.path, self.policy_mode);
            },
            .glob => blk: {
                const args = parseToolArgs(GlobArgs, arena, input) catch
                    break :blk .{ .deny = "readonly mode could not parse glob args; denied" };
                const root_decision = policy.evaluateReadPath(args.root, self.policy_mode);
                if (root_decision != .allow) break :blk root_decision;
                break :blk policy.evaluateReadPath(args.pattern, self.policy_mode);
            },
            .outline => blk: {
                const args = parseToolArgs(OutlineArgs, arena, input) catch
                    break :blk .{ .deny = "readonly mode could not parse outline path; denied" };
                break :blk policy.evaluateReadPath(args.path, self.policy_mode);
            },
            // Caller contract: guardLocalRead is only for local read actions.
            // Degrade to deny rather than unreachable if future refactors break it.
            else => .{ .deny = "guardLocalRead received a non-local-read action; denied" },
        };
    }

    /// Classifies http_request by method: GET/HEAD -> net_read, write methods ->
    /// net_write. readonly denies both to avoid network exfiltration of local
    /// reads. Malformed args or unknown methods classify as strictest net_write.
    /// With SSRF hardening enabled, guarded also validates URL host (issue #32).
    fn guardHttp(self: *Agent, arena: std.mem.Allocator, input: []const u8) policy.Decision {
        const args = parseToolArgs(HttpArgs, arena, input) catch {
            // Malformed args: classify as strictest net_write. If guarded SSRF
            // protection is enabled, unparseable target fails closed.
            const d = policy.evaluateTool(.net_write, self.policy_mode);
            if (d == .deny) return d;
            if (self.block_internal_http and self.policy_mode == .guarded)
                return .{ .deny = "SSRF protection is enabled: could not parse http_request args; denied" };
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

    /// Guards file_write/file_edit: first capability check denies writes in
    /// readonly, then optional confine_writes checks the path stays in project root.
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
        const p = path orelse return .{ .deny = "write confinement is enabled: could not parse write path; denied" };
        switch (policy.evaluateWritePath(p, self.policy_mode, self.confine_writes)) {
            .deny => |reason| return .{ .deny = reason },
            .allow => {},
        }
        // Lexical checks are only a prefilter; writes follow symlinks. Realpath
        // the target parent directory to ensure it remains under cwd and block
        // preexisting `link -> /etc` escapes (issue #52, aligned with #41).
        if (self.policy_mode == .guarded and pathsafe.writeEscapesBase(self.io, arena, ".", p))
            return .{ .deny = "write confinement: symlink resolution escapes the project directory; denied" };
        return .allow;
    }

    fn guardParallel(self: *Agent, arena: std.mem.Allocator, input: []const u8) policy.Decision {
        const args = parseToolArgs(ParallelArgs, arena, input) catch
            return .{ .deny = "parallel action_input must be {\"calls\":[...]} JSON" };
        if (args.calls.len == 0) return .{ .deny = "parallel needs at least 1 call" };
        if (args.calls.len > max_parallel_calls) return .{ .deny = "parallel exceeds the maximum of 4 calls" };

        for (args.calls, 0..) |call, idx| {
            const child = std.meta.stringToEnum(Action, call.action) orelse
                return .{ .deny = "parallel contains an unknown action" };
            const child_input = parallelCallInput(call);
            if (child_input.len == 0)
                return .{ .deny = "parallel subcall is missing input" };
            switch (child) {
                .file_read, .grep, .glob, .outline => {},
                .http_request => {
                    const http_args = parseToolArgs(HttpArgs, arena, child_input) catch
                        return .{ .deny = "parallel could not parse http_request args" };
                    const method = tools.http.methodFromString(http_args.method) orelse
                        return .{ .deny = "parallel http_request method is unknown" };
                    if (tools.http.isWrite(method))
                        return .{ .deny = "parallel only allows HTTP GET/HEAD, not write HTTP methods" };
                },
                .bash => return .{ .deny = "parallel forbids bash; use structured read-only tools" },
                .file_write, .file_edit => return .{ .deny = "parallel forbids writing or editing files" },
                .skill => return .{ .deny = "parallel forbids skill; use a separate skill action to read skill instructions" },
                .recall => return .{ .deny = "parallel forbids recall; use a separate recall action to read the session transcript" },
                .parallel => return .{ .deny = "parallel forbids nested parallel" },
                .final => return .{ .deny = "parallel subcall cannot be final" },
            }
            switch (self.guard(arena, child, child_input)) {
                .allow => {},
                .deny => |reason| return .{
                    .deny = std.fmt.allocPrint(arena, "parallel subcall #{d} denied: {s}", .{ idx + 1, reason }) catch reason,
                },
            }
        }
        return .allow;
    }

    /// Executes a guarded tool action and returns arena-owned observation text.
    /// Failures such as malformed args, I/O errors, or timeouts are thrown and
    /// converted by callers into model feedback, with no panic.
    fn execTool(self: *Agent, arena: std.mem.Allocator, action: Action, input: []const u8) ![]const u8 {
        return self.execToolWithSession(arena, null, action, input);
    }

    fn execToolWithSession(self: *Agent, arena: std.mem.Allocator, sess: ?*const session.Session, action: Action, input: []const u8) ![]const u8 {
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
                    "[Observation] wrote {s} ({d} bytes).",
                    .{ args.path, args.content.len },
                );
            },
            .file_edit => blk: {
                const args = try parseToolArgs(FileEditArgs, arena, input);
                const out = try tools.file.edit(arena, self.io, args.path, args.old, args.new, tools.file.default_read_limit);
                break :blk try std.fmt.allocPrint(
                    arena,
                    "[Observation] edited {s}: replaced 1 occurrence; file is now {d} bytes.",
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
            .recall => blk: {
                const args = try parseToolArgs(RecallArgs, arena, input);
                const s = sess orelse return error.RecallUnavailable;
                break :blk try recallObservation(arena, s, args);
            },
            // Caller contract: `run` handles .final before execTool. Return an
            // error rather than unreachable so run can feed back a tool failure.
            .final => error.UnexpectedAction,
        };
    }

    /// Executes `skill`: resolve a skill name to a loaded directory and read its
    /// instruction/resource files. This is Scoot's native read-only capability
    /// and intentionally outside execution policy. The skill manifest is already
    /// discovered and injected by Scoot, so reading SKILL.md/resources adds no new
    /// privilege surface; bash/write/network actions that skills ask the model to
    /// perform still use their own guardrails. Read boundary is enforced here:
    ///   - skill name must be loaded, otherwise return a corrective observation;
    ///   - relative paths must not be absolute or contain `..`.
    /// Read failures are returned as model-feedback text, not thrown/panicked.
    fn readSkill(self: *Agent, arena: std.mem.Allocator, name: []const u8, rel: []const u8) ![]const u8 {
        const dir = for (self.skills) |s| {
            if (std.mem.eql(u8, s.name, name)) break s.dir;
        } else return try self.skillNotFoundObservation(arena, name);

        const trimmed = std.mem.trim(u8, rel, " \t\r\n");
        const sub = if (trimmed.len == 0) "SKILL.md" else trimmed;
        if (std.fs.path.isAbsolute(sub) or pathHasDotDot(sub))
            return try std.fmt.allocPrint(arena, "[Observation] skill read denied: path must stay inside the skill directory and must not contain `..` (got: {s}).", .{sub});

        const full = try std.fs.path.join(arena, &.{ dir, sub });
        // Symlink escape guard (issue #41): lexical checks are only a fast
        // prefilter, and file.read follows symlinks. A symlink inside a skill
        // directory could turn this policy-exempt read into arbitrary file read.
        // Realpath dir and target before reading and require the target to stay
        // inside the skill directory.
        if (self.skillPathEscapes(arena, dir, full))
            return try std.fmt.allocPrint(arena, "[Observation] skill {s} file {s} read denied: resolved path escapes the skill directory, possibly through a symlink.", .{ name, sub });
        const content = tools.file.read(arena, self.io, full, skill_read_limit) catch |err|
            return try std.fmt.allocPrint(arena, "[Observation] skill {s} file {s} read failed: {s}.", .{ name, sub, @errorName(err) });
        return try std.fmt.allocPrint(
            arena,
            "[Observation] skill {s} file {s} ({d} bytes):\n{s}",
            .{ name, sub, content.len, try clipTo(arena, content, skill_observation_tokens) },
        );
    }

    /// Symlink escape check for skill reads (issue #41): realpath the skill dir
    /// and target, and treat a target outside dir as escape. If realpath fails,
    /// e.g. missing file or unsupported platform, do not block here; the later
    /// read will fail and missing files leak no content.
    fn skillPathEscapes(self: *Agent, arena: std.mem.Allocator, dir: []const u8, full: []const u8) bool {
        return pathsafe.realPathEscapes(self.io, arena, dir, full);
    }

    /// Corrective observation for an unloaded skill name, listing available names.
    fn skillNotFoundObservation(self: *Agent, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(arena);
        const w = &aw.writer;
        try w.print("[Observation] skill {s} is not loaded. ", .{name});
        if (self.skills.len == 0) {
            try w.writeAll("No skills are loaded.");
        } else {
            try w.writeAll("Available skills:");
            for (self.skills, 0..) |s, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeAll(s.name);
            }
            try w.writeAll(".");
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
        // All threads are joined. Reset spawned so the spawn-phase errdefer is
        // inactive; otherwise it overlaps with the defer below and OOM during
        // result assembly could double-join and double-deinit worker arenas.
        spawned = 0;
        defer for (workers) |*w| w.arena_state.deinit();

        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "[Observation] parallel completed {d} read-only calls:\n", .{args.calls.len}));
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

    /// Runs one bash command with hard timeout and formats an arena-owned observation.
    fn runBash(self: *Agent, arena: std.mem.Allocator, command: []const u8) ![]u8 {
        const result = try tools.bash.run(arena, self.io, command, .{ .timeout_ms = self.tool_timeout_ms });
        return formatObservation(arena, result);
    }

    /// "Thinking" progress marker printed and flushed before backend inference,
    /// so trace remains live while waiting for the model.
    fn traceThinking(self: *Agent, turn: u32) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] thinking: calling backend...\n", .{turn}) catch return;
        w.flush() catch {};
    }

    /// "Running" progress marker printed and flushed before executing a tool,
    /// showing which tool is currently blocking.
    fn traceRunning(self: *Agent, turn: u32, action: Action) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] running: {s} (tool call may block)...\n", .{ turn, @tagName(action) }) catch return;
        w.flush() catch {};
    }

    fn traceMalformed(self: *Agent, turn: u32) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] malformed model step; retrying\n", .{turn}) catch return;
        w.flush() catch {};
    }

    /// History-compaction progress marker after over-budget old context is folded.
    fn traceCompacted(self: *Agent, turn: u32, used_bytes: usize) void {
        const w = self.trace orelse return;
        w.print("[trace {d}] compacted history: now {d} bytes (kept system, job, and {d} recent messages)\n", .{ turn, used_bytes, history_keep_recent }) catch return;
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

/// Default completion implementation calling the real backend.
fn clientComplete(
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    messages: []const llm.Message,
    opts: llm.ChatOptions,
) anyerror!llm.Completion {
    const client: *llm.Client = @ptrCast(@alignCast(ctx));
    return client.chat(arena, messages, opts);
}

/// Corrective observation when the model does not produce a valid step.
const malformed_hint = "[Observation] Your previous output was not valid step JSON. Output exactly one JSON object with thought/action/action_input matching the schema; do not use Markdown fences or emit multiple JSON objects.";

/// Number of recent messages preserved when history compaction triggers
/// (issue #71). Each turn produces roughly two messages, so 8 is about four
/// recent turns, enough for continuity while older tool text is summarized.
const history_keep_recent = 8;

/// Observation truncation budgets use token estimates (issue #75). Byte budgets
/// make CJK and ASCII inconsistent, so these values are roughly old byte limits
/// divided by four, preserving ASCII size while making CJK converge by tokens.
/// Maximum tokens for one stream observation, such as bash stdout/stderr; larger
/// outputs use head/tail truncation.
const observation_stream_tokens = 500;

/// file_read observation cap: wider than bash streams because file content is
/// model-requested and structured enough to support later exact file_edit, while
/// still bounding huge files.
const file_read_observation_tokens = 2000;

/// Read limit for one skill instruction/resource file.
const skill_read_limit: std.Io.Limit = .limited(1 << 20);
/// Skill-content observation cap: wider than file_read because SKILL.md contains
/// complete on-demand operating instructions, but still hard-capped.
const skill_observation_tokens = 8000;
/// recall returns raw current-session transcript text. Default window is small
/// to avoid re-inflating context saved by compaction.
const recall_default_limit = 8;
const recall_max_hits = 20;
const recall_max_context = 3;
const recall_observation_tokens = 4000;

/// parallel v0 is explicit fan-out, not a DAG executor; small cap protects runtime.
const max_parallel_calls = 4;
const parallel_observation_tokens = 3000;

/// CLI trace shows execution summaries only to avoid flooding with tool output.
const trace_reason_cap = 240;
const trace_action_input_cap = 240;
const trace_observation_cap = 600;
const trace_final_cap = 240;

/// Compresses a parsed step into an arena-owned assistant history record without
/// thought: `{"action":"<name>","action_input":"<raw input>"}`. thought is
/// private per-turn reasoning and adds no value to future turns; persisting it
/// grows history and full resend cost (issue #70). jsonio escaping keeps JSON valid.
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
    const step_json = jsonio.firstJsonObject(content) orelse return error.MalformedStep;
    const v = std.json.parseFromSliceLeaky(Raw, arena, step_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedStep;

    // Map action by enum tag; adding actions only extends Action enum.
    const action = std.meta.stringToEnum(Action, v.action) orelse return error.UnknownAction;
    return .{ .thought = v.thought, .action = action, .action_input = v.action_input };
}

/// Estimates prompt size in bytes as the sum of message content lengths, a rough
/// proxy for token size. Pure function used by run() before backend calls.
fn historyBytes(messages: []const llm.Message) usize {
    var total: usize = 0;
    for (messages) |m| total += m.content.len;
    return total;
}

/// Converts tool execution or argument parsing errors into arena-owned
/// observation text for model feedback. Common errors include actionable hints.
fn toolErrorObservation(arena: std.mem.Allocator, err: anyerror) ![]u8 {
    const hint = switch (err) {
        error.MalformedArgs => "action_input is not valid parameter JSON. Use file_read {\"path\":\"...\"}; file_write {\"path\":\"...\",\"content\":\"...\"}; file_edit {\"path\":\"...\",\"old\":\"...\",\"new\":\"...\"}; grep {\"pattern\":\"...\",\"path\":\"...\"}; glob {\"pattern\":\"...\"}; http_request {\"method\":\"GET\",\"url\":\"...\"}; recall {\"query\":\"...\"} or {\"seq\":1}.",
        error.UnknownMethod => "http_request method is unknown. Use one of GET/POST/PUT/DELETE/HEAD/PATCH.",
        error.ParallelWriteHttp => "parallel only allows HTTP GET/HEAD, not POST/PUT/PATCH/DELETE.",
        error.UnsupportedParallelAction => "parallel only allows file_read / grep / glob / outline / HTTP GET or HEAD.",
        error.PatternNotFound => "file_edit old text was not found. Use file_read to inspect exact text before editing.",
        error.AmbiguousMatch => "file_edit old text appears multiple times. Provide a longer unique context span.",
        error.EmptyPattern => "file_edit old text must not be empty.",
        error.InvalidPattern => "grep regex is invalid. Supported subset: . ^ $ * + ? [] () | \\d \\w \\s; capture groups, backreferences, lookaround, and lazy quantifiers are unsupported. Use a simpler pattern.",
        error.PatternTooLong => "regex pattern is too long; shorten it.",
        error.FileNotFound => "target file does not exist. Check the path, or create it first with file_write.",
        error.AccessDenied => "access denied for target path.",
        error.IsDir => "target path is a directory, not a file.",
        error.UnexpectedAction => "internal error: action was routed to the wrong execution branch. Retry or choose another action.",
        error.RecallUnavailable => "recall is only available inside a running session. Use file_read/grep or retry in the next step.",
        else => @errorName(err),
    };
    return std.fmt.allocPrint(arena, "[Observation] tool execution failed: {s}", .{hint});
}

/// Formats file_read into an arena-owned observation. Missing offset/limit reads
/// the whole file subject to cap; either value triggers line-window paging that
/// pairs with grep line numbers. Shared by execTool and parallel workers.
fn fileReadObservation(arena: std.mem.Allocator, io: std.Io, args: FileReadArgs) ![]const u8 {
    if (args.offset == null and args.limit == null) {
        const content = try tools.file.read(arena, io, args.path, tools.file.default_read_limit);
        return std.fmt.allocPrint(
            arena,
            "[Observation] read {s} ({d} bytes):\n{s}",
            .{ args.path, content.len, try clipTo(arena, content, file_read_observation_tokens) },
        );
    }
    const off = args.offset orelse 1;
    const win = try tools.file.readLineRange(arena, io, args.path, tools.file.default_read_limit, off, args.limit);
    if (win.total_lines == 0)
        return std.fmt.allocPrint(arena, "[Observation] read {s}: file is empty.", .{args.path});
    if (win.start_line == 0)
        return std.fmt.allocPrint(
            arena,
            "[Observation] read {s}: offset {d} exceeds total line count {d}.",
            .{ args.path, off, win.total_lines },
        );
    return std.fmt.allocPrint(
        arena,
        "[Observation] read {s} (lines {d}-{d} / {d}):\n{s}",
        .{ args.path, win.start_line, win.end_line, win.total_lines, try clipTo(arena, win.text, file_read_observation_tokens) },
    );
}

/// Runs the outline action and returns arena-owned observation text shared by execTool and parallel workers.
/// Reads the whole file, detects language by extension, extracts a structural skeleton, and compacts it
/// into a `line: signature` overview so the model can inspect structure before windowed reads.
/// Truncated by the file_read observation limit.
fn outlineObservation(arena: std.mem.Allocator, io: std.Io, args: OutlineArgs) ![]const u8 {
    const content = try tools.file.read(arena, io, args.path, tools.file.default_read_limit);
    const lang = tools.outline.detectLang(args.path);
    const result = try tools.outline.extract(arena, content, lang);
    if (result.entries.len == 0) {
        return std.fmt.allocPrint(
            arena,
            "[Outline] {s} (lang={s}): no structure lines found (functions/types/headings). Use file_read if content is needed.",
            .{ args.path, @tagName(lang) },
        );
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "[Outline] {s} (lang={s}, {d} items{s}):\n",
        .{ args.path, @tagName(lang), result.entries.len, if (result.truncated) ", truncated" else "" },
    ));
    for (result.entries) |e| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}: {s}\n", .{ e.line, e.text }));
    }
    try buf.appendSlice(arena, "Hint: use file_read offset/limit to read the required line window.");
    return clipTo(arena, buf.items, file_read_observation_tokens);
}

/// Formats grep hits as arena-owned observation text, including an explicit no-hit result.
/// Truncated by the file_read observation limit.
fn formatGrepHits(arena: std.mem.Allocator, path: []const u8, hits: []const tools.search.Hit) ![]const u8 {
    if (hits.len == 0) {
        return std.fmt.allocPrint(arena, "[Observation] grep found no matches in {s}.", .{path});
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "[Observation] grep {s} matched {d} lines:\n", .{ path, hits.len }));
    for (hits) |h| {
        try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}:{s}\n", .{ h.line, h.text }));
    }
    return clipTo(arena, buf.items, file_read_observation_tokens);
}

/// Runs the grep action and returns arena-owned observation text shared by execTool and parallel workers.
/// Without context, returns matching lines only; with context, returns +/-N context blocks
/// so the model can inspect the area around each match without a follow-up full-file read.
fn grepObservation(arena: std.mem.Allocator, io: std.Io, args: GrepArgs) ![]const u8 {
    const ctx = args.context orelse 0;
    if (ctx == 0) {
        const hits = try tools.search.grepFile(arena, io, args.pattern, args.path, tools.search.default_max_hits);
        return formatGrepHits(arena, args.path, hits);
    }
    const blocks = try tools.search.grepFileContext(arena, io, args.pattern, args.path, tools.search.default_max_hits, ctx);
    return formatGrepBlocks(arena, args.path, blocks, @min(ctx, tools.search.max_grep_context));
}

/// Formats grep context blocks as arena-owned observation text: matches use `line:text`,
/// context lines use `line-text` per grep -C, and blocks are separated by `--`.
/// Truncated by the file_read observation limit.
fn formatGrepBlocks(arena: std.mem.Allocator, path: []const u8, blocks: []const tools.search.ContextBlock, context: usize) ![]const u8 {
    if (blocks.len == 0) {
        return std.fmt.allocPrint(arena, "[Observation] grep found no matches in {s}.", .{path});
    }
    var hit_count: usize = 0;
    for (blocks) |b| for (b.hit_mask) |h| {
        if (h) hit_count += 1;
    };
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "[Observation] grep {s} matched {d} lines (with context +/-{d} lines):\n", .{ path, hit_count, context }));
    for (blocks, 0..) |b, bi| {
        if (bi != 0) try buf.appendSlice(arena, "--\n");
        for (b.lines, b.hit_mask, 0..) |line, is_hit, k| {
            const sep: u8 = if (is_hit) ':' else '-';
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}{c}{s}\n", .{ b.start_line + k, sep, line }));
        }
    }
    return clipTo(arena, buf.items, file_read_observation_tokens);
}

/// Formats glob matches as arena-owned observation text, including an explicit no-match result.
fn formatGlobPaths(arena: std.mem.Allocator, pattern: []const u8, paths: []const []const u8) ![]const u8 {
    if (paths.len == 0) {
        return std.fmt.allocPrint(arena, "[Observation] glob {s} found no matches.", .{pattern});
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "[Observation] glob {s} matched {d} paths:\n", .{ pattern, paths.len }));
    for (paths) |p| {
        try buf.appendSlice(arena, p);
        try buf.append(arena, '\n');
    }
    return clipTo(arena, buf.items, file_read_observation_tokens);
}

/// Formats HTTP responses as arena-owned observation text, including timeouts and transport failures.
/// Truncated by the observation limit.
fn formatHttpResponse(arena: std.mem.Allocator, url: []const u8, resp: tools.http.Response) ![]const u8 {
    if (resp.timed_out) {
        return std.fmt.allocPrint(arena, "[Observation] http {s} exceeded hard timeout and was cancelled with no response. Use a faster endpoint or shorter request.", .{url});
    }
    if (resp.err) |e| {
        return std.fmt.allocPrint(arena, "[Observation] http {s} request failed: {s} (connection/TLS/DNS).", .{ url, e });
    }
    const clipped = try clipTo(arena, resp.body, file_read_observation_tokens);
    return std.fmt.allocPrint(
        arena,
        "[Observation] http {s} status={d}, response body ({d} bytes):\n{s}",
        .{ url, resp.status, resp.body.len, clipped },
    );
}

fn recallObservation(arena: std.mem.Allocator, sess: *const session.Session, args: RecallArgs) ![]const u8 {
    const msgs = sess.archiveItems();
    if (msgs.len == 0)
        return arena.dupe(u8, "[Observation] recall transcript is empty.");

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const context = @min(args.context orelse 0, recall_max_context);
    const limit = normalizeRecallLimit(args.limit);

    if (args.seq) |seq| {
        if (seq == 0 or seq > msgs.len) {
            return std.fmt.allocPrint(arena, "[Observation] recall seq={d} is out of range; current transcript range is 1..{d}.", .{ seq, msgs.len });
        }
        const idx = seq - 1;
        const start = if (idx > context) idx - context else 0;
        const end = @min(msgs.len, idx + context + 1);
        try w.print("[Observation] recall transcript seq={d} (context +/-{d}, returned {d} messages):\n", .{ seq, context, end - start });
        var i = start;
        while (i < end) : (i += 1) try writeRecallJsonLine(w, i + 1, msgs[i]);
        return clipTo(arena, out.written(), recall_observation_tokens);
    }

    const raw_query = args.query orelse
        return arena.dupe(u8, "[Observation] recall needs query or seq, e.g. {\"query\":\"keyword\",\"limit\":8} or {\"seq\":12,\"context\":2}.");
    const query = std.mem.trim(u8, raw_query, " \t\r\n");
    if (query.len == 0)
        return arena.dupe(u8, "[Observation] recall query must not be empty; provide a keyword to search.");

    var selected = try arena.alloc(bool, msgs.len);
    @memset(selected, false);
    var hit_count: usize = 0;
    for (msgs, 0..) |m, i| {
        if (hit_count >= limit) break;
        if (!recallMatches(m, query)) continue;
        hit_count += 1;
        const start = if (i > context) i - context else 0;
        const end = @min(msgs.len, i + context + 1);
        var j = start;
        while (j < end) : (j += 1) selected[j] = true;
    }
    if (hit_count == 0)
        return std.fmt.allocPrint(arena, "[Observation] recall found no transcript matches for keyword: {s}", .{query});

    var returned: usize = 0;
    for (selected) |is_selected| {
        if (is_selected) returned += 1;
    }
    try w.print("[Observation] recall transcript query={s} matched {d} places (limit={d}, context +/-{d}, returned {d} messages):\n", .{ query, hit_count, limit, context, returned });
    for (selected, 0..) |is_selected, i| {
        if (is_selected) try writeRecallJsonLine(w, i + 1, msgs[i]);
    }
    return clipTo(arena, out.written(), recall_observation_tokens);
}

fn normalizeRecallLimit(limit: ?usize) usize {
    const v = limit orelse recall_default_limit;
    if (v == 0) return recall_default_limit;
    return @min(v, recall_max_hits);
}

fn recallMatches(m: llm.Message, query: []const u8) bool {
    return std.mem.indexOf(u8, m.content, query) != null or
        std.mem.indexOf(u8, @tagName(m.role), query) != null;
}

fn writeRecallJsonLine(w: *std.Io.Writer, seq: usize, m: llm.Message) !void {
    try w.writeAll("{\"seq\":");
    try w.print("{d}", .{seq});
    try w.writeAll(",\"role\":\"");
    try w.writeAll(@tagName(m.role));
    try w.writeAll("\",\"content\":");
    try jsonio.writeString(w, m.content);
    try w.writeAll("}\n");
}

/// Formats tool results as arena-owned observation text to feed back to the model.
fn formatObservation(arena: std.mem.Allocator, r: tools.Result) ![]u8 {
    if (r.timed_out) {
        return arena.dupe(u8, "[Observation] command exceeded hard timeout and was force-terminated with no output; use a faster command that exits by itself");
    }
    const out = try clip(arena, r.stdout);
    const err = try clip(arena, r.stderr);
    return std.fmt.allocPrint(
        arena,
        "[Observation] exit_code={d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}",
        .{ r.exit_code, out, err },
    );
}

/// Slims command stream observations by stripping ANSI, folding whitespace, and head/tail truncating.
fn clip(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    return obs.optimizeStream(arena, s, observation_stream_tokens);
}

/// Head/tail truncates fidelity-sensitive content by token while preserving bytes inside kept windows.
/// ANSI and whitespace are left intact so later file_edit exact matching is not broken.
fn clipTo(arena: std.mem.Allocator, s: []const u8, max_tokens: usize) ![]const u8 {
    return obs.truncateTokens(arena, s, max_tokens);
}

/// Writes capped text to the trace writer and appends the remaining byte count when truncated.
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

/// Returns whether a path contains a `..` component, split on `/` and `\`.
/// Used to prevent directory escape in skill reads.
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
    observation: []const u8 = "[Observation] parallel subcall was not executed.",
};

fn runParallelWorker(worker: *ParallelWorker) void {
    const arena = worker.arena_state.allocator();
    worker.observation = execReadTool(arena, worker.io, worker.action, worker.input, worker.tool_timeout_ms, worker.ca_file) catch |err|
        toolErrorObservation(arena, err) catch "[Observation] tool execution failed: unable to format error.";
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

test "parseStep parses actions" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try parseStep(arena, "{\"thought\":\"look at\",\"action\":\"bash\",\"action_input\":\"ls -a\"}");
    try std.testing.expectEqual(Action.bash, s.action);
    try std.testing.expectEqualStrings("ls -a", s.action_input);

    const f = try parseStep(arena, "{\"thought\":\"sample\",\"action\":\"final\",\"action_input\":\"sample\"}");
    try std.testing.expectEqual(Action.final, f.action);
    try std.testing.expectEqualStrings("sample", f.action_input);

    const p = try parseStep(arena, "{\"thought\":\"sample\",\"action\":\"parallel\",\"action_input\":\"{\\\"calls\\\":[]}\"}");
    try std.testing.expectEqual(Action.parallel, p.action);
}

test "parseStep defensive malformed JSON and unknown action" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.MalformedStep, parseStep(arena, "not json"));
    try std.testing.expectError(error.MalformedStep, parseStep(arena, "{\"action\":}"));
    try std.testing.expectError(error.UnknownAction, parseStep(arena, "{\"action\":\"rmrf\",\"action_input\":\"x\"}"));
}

test "parseStep extracts the first backend JSON object" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try parseStep(
        arena,
        "{\"thought\":\"sample\",\"action\":\"file_read\",\"action_input\":\"{\\\"path\\\":\\\"README.md\\\"}\"}\n" ++
            "{\"thought\":\"sample\",\"action\":\"final\",\"action_input\":\"done\"}",
    );
    try std.testing.expectEqual(Action.file_read, s.action);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", s.action_input);
}

test "parseStep accepts JSON inside Markdown fences" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try parseStep(
        arena,
        "```json\n{\"thought\":\"sample\",\"action\":\"final\",\"action_input\":\"ok\"}\n```",
    );
    try std.testing.expectEqual(Action.final, s.action);
    try std.testing.expectEqualStrings("ok", s.action_input);
}

test "Action schema and system_prompt include every action (issue #27)" {
    // The schema enum is generated from Action at comptime; assert prompt coverage as well.
    // Adding an Action without mentioning it in the prompt should fail this test.
    inline for (@typeInfo(Action).@"enum".fields) |f| {
        const quoted = "\"" ++ f.name ++ "\"";
        try std.testing.expect(std.mem.indexOf(u8, react_schema, quoted) != null);
        try std.testing.expect(std.mem.indexOf(u8, system_prompt, quoted) != null);
    }
}

test "formatObservation normal timeout and clipping" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const normal = try formatObservation(arena, .{ .stdout = "hi", .stderr = "", .exit_code = 0 });
    try std.testing.expect(std.mem.indexOf(u8, normal, "exit_code=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, normal, "hi") != null);

    const t = try formatObservation(arena, .{ .timed_out = true });
    try std.testing.expect(std.mem.indexOf(u8, t, "hard timeout") != null);

    const big = try arena.alloc(u8, observation_stream_tokens * 4 + 1000);
    @memset(big, 'x');
    const clipped = try formatObservation(arena, .{ .stdout = big, .exit_code = 0 });
    try std.testing.expect(std.mem.indexOf(u8, clipped, "omitted middle") != null);
}

test "fileReadObservation whole file vs line window (#74)" {
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

    // Whole-file read: no offset/limit uses the byte-count path.
    const whole = try fileReadObservation(arena, io, .{ .path = path });
    try std.testing.expect(std.mem.indexOf(u8, whole, "bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, whole, "a3") != null);

    // Line window: offset=2,limit=2 labels lines 2-3 of 5 and includes only a2/a3.
    const win = try fileReadObservation(arena, io, .{ .path = path, .offset = 2, .limit = 2 });
    try std.testing.expect(std.mem.indexOf(u8, win, "lines 2-3 / 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, win, "a2\na3") != null);
    try std.testing.expect(std.mem.indexOf(u8, win, "a5") == null);

    // Out-of-range offset reports the overflow explicitly.
    const oob = try fileReadObservation(arena, io, .{ .path = path, .offset = 99 });
    try std.testing.expect(std.mem.indexOf(u8, oob, "exceeds total line count 5") != null);
}

test "grepObservation without and with context windows (#76)" {
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

    // No context: only matching lines, formatted as `line:text`.
    const plain = try grepObservation(arena, io, .{ .pattern = "target", .path = path });
    try std.testing.expect(std.mem.indexOf(u8, plain, "3:fn target") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "l2") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "with context") == null);

    // context=1: matches use `:`, context lines use `-`, and the header marks +/-1.
    const ctx = try grepObservation(arena, io, .{ .pattern = "target", .path = path, .context = 1 });
    try std.testing.expect(std.mem.indexOf(u8, ctx, "with context +/-1 lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "2-l2") != null); // context line
    try std.testing.expect(std.mem.indexOf(u8, ctx, "3:fn target") != null); // matching line
    try std.testing.expect(std.mem.indexOf(u8, ctx, "4-l4") != null); // context line
    try std.testing.expect(std.mem.indexOf(u8, ctx, "l5") == null); // outside window
}

test "outlineObservation structural outline fallback (#77)" {
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

    // Structured .zig: finds functions and top-level types, with line numbers and a window-read hint.
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
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "[Outline]") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "lang=zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "pub const Foo = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "pub fn bar(self: *Foo) void") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "fn helper() void") != null);
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "@import") == null); // import noise is skipped
    try std.testing.expect(std.mem.indexOf(u8, skeleton, "file_read") != null); // window-read hint

    // Plain text without structure: report no structure and guide toward file_read.
    const txt_path = dir ++ "/plain.txt";
    try tools.file.write(io, txt_path, "just some prose\nno definitions here\n");
    const empty = try outlineObservation(arena, io, .{ .path = txt_path });
    try std.testing.expect(std.mem.indexOf(u8, empty, "no structure lines found") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "file_read") != null);
}

test "ReadCache.dedup references repeated read-only observations (issue #73)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cache = ReadCache{ .store = arena };

    const big_a = "A" ** 300; // >= dedup_min_bytes
    const big_b = "B" ** 300;
    const input = "{\"path\":\"README.md\"}";

    // First read: record and keep the full observation.
    try std.testing.expect((try cache.dedup(arena, 1, .file_read, input, big_a)) == null);
    // Repeated unchanged read: return a dedup placeholder referencing turn 1.
    const ref = (try cache.dedup(arena, 3, .file_read, input, big_a)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, ref, "deduplicated") != null);
    try std.testing.expect(std.mem.indexOf(u8, ref, "turn 1") != null);
    // Changed content: refresh the record and feed it back normally.
    try std.testing.expect((try cache.dedup(arena, 4, .file_read, input, big_b)) == null);
    // big_b is now unchanged from turn 4; reading it again references turn 4.
    const ref2 = (try cache.dedup(arena, 5, .file_read, input, big_b)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, ref2, "turn 4") != null);
    // Too small to dedup.
    try std.testing.expect((try cache.dedup(arena, 6, .grep, "{\"pattern\":\"x\",\"path\":\"a\"}", "tiny")) == null);
    // Non-read actions may have side effects and are never deduplicated.
    try std.testing.expect((try cache.dedup(arena, 7, .bash, "ls", big_a)) == null);
    try std.testing.expect((try cache.dedup(arena, 8, .bash, "ls", big_a)) == null);
    // Different keys, such as offset window reads, are tracked independently.
    try std.testing.expect((try cache.dedup(arena, 9, .file_read, "{\"path\":\"README.md\",\"offset\":10}", big_a)) == null);
}

test "run: repeated file_read is deduplicated (issue #73)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_run_read_dedup";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    // Content must meet dedup_min_bytes; use a unique marker to count full observations.
    try cwd.writeFile(io, .{ .sub_path = root ++ "/note.txt", .data = "UNIQUE-DEDUP-MARKER-Q7\n" ** 20 });

    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"sample\",\"action\":\"file_read\",\"action_input\":\"{\\\"path\\\":\\\"/tmp/scoot_run_read_dedup/note.txt\\\"}\"}",
        "{\"thought\":\"sample\",\"action\":\"file_read\",\"action_input\":\"{\\\"path\\\":\\\"/tmp/scoot_run_read_dedup/note.txt\\\"}\"}",
        "{\"thought\":\"sample\",\"action\":\"final\",\"action_input\":\"done\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, system_prompt);
    try sess.append(gpa, .user, "go");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    // The full marker should appear only once; the second read is replaced by a dedup reference.
    var full_obs: usize = 0;
    var saw_dedup = false;
    for (sess.items()) |m| {
        const has_marker = std.mem.indexOf(u8, m.content, "UNIQUE-DEDUP-MARKER-Q7") != null;
        const is_dedup = std.mem.indexOf(u8, m.content, "deduplicated") != null;
        if (m.role == .user and has_marker and !is_dedup) full_obs += 1;
        if (is_dedup) saw_dedup = true;
    }
    try std.testing.expectEqual(@as(usize, 1), full_obs);
    try std.testing.expect(saw_dedup);
}

/// Scripted test brain that emits preset step JSON in order without a real backend.
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

test "guard and execTool handle terminal action misuse without panic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var brain = ScriptedBrain{ .steps = &.{} };
    var ag = testAgent(&brain, 16);

    // guard(.final): terminal actions should not pass the guard; misrouting degrades to deny.
    switch (ag.guard(arena, .final, "")) {
        .deny => {},
        .allow => return error.ShouldHaveDenied,
    }

    // guardLocalRead(non-read): readonly mode should degrade to deny instead of unreachable.
    ag.policy_mode = .readonly;
    switch (ag.guardLocalRead(arena, .bash, "")) {
        .deny => {},
        .allow => return error.ShouldHaveDenied,
    }

    // execTool(.final): terminal misrouting returns UnexpectedAction for run to feed back.
    try std.testing.expectError(error.UnexpectedAction, ag.execTool(arena, .final, ""));
}

test "historyBytes sums message content bytes (issue #28)" {
    const msgs = [_]llm.Message{
        .{ .role = .system, .content = "abc" }, // 3
        .{ .role = .user, .content = "de" }, // 2
        .{ .role = .assistant, .content = "" }, // 0
        .{ .role = .user, .content = "fghij" }, // 5
    };
    try std.testing.expectEqual(@as(usize, 10), historyBytes(&msgs));
}

test "Agent defaults to extractive compaction (issue #96)" {
    var brain = ScriptedBrain{ .steps = &.{} };
    const ag = testAgent(&brain, 16);

    try std.testing.expectEqual(@as(usize, default_context_budget_bytes), ag.context_budget_bytes);
    try std.testing.expectEqual(compressor.Compressor.extractive, std.meta.activeTag(ag.compactor));
}

test "run: context budget fails fast before backend call (issue #28)" {
    const gpa = std.testing.allocator;

    // If the budget gate fails and calls the backend, it would emit final; this proves no call.
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"x\",\"action\":\"final\",\"action_input\":\"never\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "0123456789"); // 10-byte history
    ag.context_budget_bytes = 4; // 10 > 4: over budget

    try std.testing.expectError(error.ContextBudgetExceeded, ag.run(gpa, &sess));
    try std.testing.expectEqual(@as(usize, 0), brain.idx); // backend was never called
}

test "run: context budget 0 disables the gate (issue #28)" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"x\",\"action\":\"final\",\"action_input\":\"ok\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "0123456789");
    ag.context_budget_bytes = 0; // disabled: only max_turns constrains the loop

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("ok", reply);
}

test "guard: opt-in write confinement and SSRF hardening under guarded mode (issue #32)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var brain = ScriptedBrain{ .steps = &.{} };
    var ag = testAgent(&brain, 16); // guarded by default, both hardening flags off

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

    // Default flags off: guarded allows out-of-root writes and internal GETs.
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .file_write, bad_write));
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .http_request, meta_get));

    // Write confinement: out-of-root and `..` escapes are denied; project writes pass.
    ag.confine_writes = true;
    try expectDeny(ag.guard(arena, .file_write, bad_write));
    try expectDeny(ag.guard(arena, .file_edit, bad_edit));
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .file_write, ok_write));

    // SSRF protection: internal, metadata, and localhost GETs are denied; public GETs pass.
    ag.block_internal_http = true;
    try expectDeny(ag.guard(arena, .http_request, meta_get));
    try expectDeny(ag.guard(arena, .http_request, local_get));
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .http_request, pub_get));

    // Internal GETs inside parallel subcalls are also covered by recursive guard checks.
    try expectDeny(ag.guard(arena, .parallel, par_internal));
}

fn expectDeny(d: policy.Decision) !void {
    switch (d) {
        .deny => {},
        .allow => return error.ShouldHaveDenied,
    }
}

test "skill action reads loaded skill instructions in readonly and denies path escapes" {
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
    ag.policy_mode = .readonly; // Skill reads remain available even under the strictest mode.
    ag.skills = &.{.{ .name = "demo", .dir = root ++ "/demo" }};

    // 1) The guard always allows skill reads, even in readonly mode.
    try std.testing.expectEqual(policy.Decision.allow, ag.guard(arena, .skill, "{\"name\":\"demo\"}"));

    // 2) By default, read SKILL.md and feed back its content faithfully.
    const md = try ag.execTool(arena, .skill, "{\"name\":\"demo\"}");
    try std.testing.expect(std.mem.indexOf(u8, md, "MAGIC-INSTRUCTION-7") != null);

    // 3) Relative paths can read other resources inside the skill directory.
    const ref = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"references/extra.md\"}");
    try std.testing.expect(std.mem.indexOf(u8, ref, "REF-BODY-9") != null);

    // 4) Directory escapes via `..` or absolute paths are rejected with a corrective observation.
    const esc = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"../../etc/passwd\"}");
    try std.testing.expect(std.mem.indexOf(u8, esc, "denied") != null);
    const abs = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"/etc/passwd\"}");
    try std.testing.expect(std.mem.indexOf(u8, abs, "denied") != null);

    // 5) Unknown skills feed back a not-loaded observation and list available skills.
    const miss = try ag.execTool(arena, .skill, "{\"name\":\"nope\"}");
    try std.testing.expect(std.mem.indexOf(u8, miss, "is not loaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, miss, "demo") != null);
}

test "skill action denies symlink escape file (issue #41)" {
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
    // Place a symlink inside the skill directory that points outside it.
    cwd.symLink(io, root ++ "/outside/secret.txt", root ++ "/demo/leak", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };
    // A symlink that resolves inside the skill directory should be allowed.
    try cwd.symLink(io, root ++ "/demo/SKILL.md", root ++ "/demo/alias.md", .{});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var brain = ScriptedBrain{ .steps = &.{} };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly;
    ag.skills = &.{.{ .name = "demo", .dir = root ++ "/demo" }};

    // Escaping symlink: reject it and never feed back outside file content.
    const leak = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"leak\"}");
    try std.testing.expect(std.mem.indexOf(u8, leak, "denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, leak, "TOP-SECRET-LEAK") == null);

    // In-directory symlink: realpath stays inside the skill directory, so it is allowed.
    const ok = try ag.execTool(arena, .skill, "{\"name\":\"demo\",\"path\":\"alias.md\"}");
    try std.testing.expect(std.mem.indexOf(u8, ok, "LEGIT-BODY") != null);
}

test "run: ReACT can use bash before final answer" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"view\",\"action\":\"bash\",\"action_input\":\"printf RESULT-42\"}",
        "{\"thought\":\"finish\",\"action\":\"final\",\"action_input\":\"answer is RESULT-42\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, system_prompt);
    try sess.append(gpa, .user, "Run the command and answer.");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);

    try std.testing.expectEqualStrings("answer is RESULT-42", reply);
    try std.testing.expectEqual(@as(usize, 2), brain.idx); // exactly two completions

    // The session should retain one observation containing real command output.
    var saw_observation = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "RESULT-42") != null and
            std.mem.indexOf(u8, m.content, "exit_code=0") != null) saw_observation = true;
    }
    try std.testing.expect(saw_observation);
}

test "run: thought is audited but not stored in history (issue #70)" {
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

    // Thought text must never appear in history, so it is not resent across turns.
    for (sess.items()) |m| {
        try std.testing.expect(std.mem.indexOf(u8, m.content, "SECRET-THOUGHT-X9") == null);
        try std.testing.expect(std.mem.indexOf(u8, m.content, "ANOTHER-THOUGHT-Z") == null);
    }
    // The compact action step, without a thought field, is persisted in history.
    var saw_compact = false;
    for (sess.items()) |m| {
        if (m.role == .assistant and
            std.mem.indexOf(u8, m.content, "\"action\":\"bash\"") != null and
            std.mem.indexOf(u8, m.content, "\"thought\"") == null) saw_compact = true;
    }
    try std.testing.expect(saw_compact);
}

test "compactStepJson omits thought, escapes strings, and preserves action_input (issue #70)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try compactStepJson(arena, "grep", "{\"pattern\":\"a\\\"b\",\"path\":\"f\"}");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"thought\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"action\":\"grep\"") != null);

    // The result must be valid JSON and action_input must round-trip with escapes intact.
    const Raw = struct { action: []const u8, action_input: []const u8 };
    const v = try std.json.parseFromSliceLeaky(Raw, arena, out, .{});
    try std.testing.expectEqualStrings("grep", v.action);
    try std.testing.expectEqualStrings("{\"pattern\":\"a\\\"b\",\"path\":\"f\"}", v.action_input);
}

test "run: compacts history and continues (issue #71)" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"done\",\"action\":\"final\",\"action_input\":\"FINAL-OK\"}",
    } };
    var ag = testAgent(&brain, 16);
    ag.context_budget_bytes = 4000; // below the prefilled size, but above the minimal keep set

    var sess = session.Session.init("t-compact");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, "SYS-PROMPT");
    try sess.append(gpa, .user, "ORIGINAL-TASK");

    // Prefill many older messages so history is far over budget.
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
    // No abort: run reaches the final answer normally.
    try std.testing.expectEqualStrings("FINAL-OK", reply);

    // Compaction took effect: size is under budget, with marker, system, and original task preserved.
    try std.testing.expect(historyBytes(sess.items()) <= ag.context_budget_bytes);
    var saw_marker = false;
    var saw_task = false;
    var saw_sys = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "history compaction") != null) saw_marker = true;
        if (std.mem.indexOf(u8, m.content, "ORIGINAL-TASK") != null) saw_task = true;
        if (std.mem.indexOf(u8, m.content, "SYS-PROMPT") != null) saw_sys = true;
    }
    try std.testing.expect(saw_marker);
    try std.testing.expect(saw_task);
    try std.testing.expect(saw_sys);
}

test "run: still over budget after compaction fails fast (issue #71)" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"x\",\"action\":\"final\",\"action_input\":\"never\"}",
    } };
    var ag = testAgent(&brain, 16);
    ag.context_budget_bytes = 50; // too small for system, task, and recent keep set

    var sess = session.Session.init("t-compact-fail");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, "SYSTEM-PROMPT-THAT-ALONE-EXCEEDS-THE-TINY-BUDGET");
    try sess.append(gpa, .user, "ORIGINAL-TASK-LONG-ENOUGH-TO-OVERFLOW");
    var i: usize = 0;
    while (i < 12) : (i += 1) try sess.append(gpa, .user, "observation-payload-block");

    try std.testing.expectError(error.ContextBudgetExceeded, ag.run(gpa, &sess));
}

test "recallObservation returns transcript matches (issue #99)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sess = session.Session.init("t-recall");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, "SYS");
    try sess.append(gpa, .user, "GOAL");
    try sess.append(gpa, .assistant, "OLD-STEP");
    try sess.append(gpa, .user, "SECRET-RECALL-ORIGINAL");
    try sess.append(gpa, .assistant, "RECENT");

    try std.testing.expect(try compressor.default.compact(gpa, &sess, .{ .keep_recent = 1 }));
    for (sess.items()) |m| {
        try std.testing.expect(std.mem.indexOf(u8, m.content, "SECRET-RECALL-ORIGINAL") == null);
    }

    const obs_by_query = try recallObservation(arena, &sess, .{ .query = "SECRET-RECALL-ORIGINAL", .limit = 2 });
    try std.testing.expect(std.mem.indexOf(u8, obs_by_query, "\"seq\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, obs_by_query, "SECRET-RECALL-ORIGINAL") != null);

    const obs_by_seq = try recallObservation(arena, &sess, .{ .seq = 3, .context = 1 });
    try std.testing.expect(std.mem.indexOf(u8, obs_by_seq, "\"seq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, obs_by_seq, "\"seq\":4") != null);
}

test "run: recall can find hidden transcript content (issue #99)" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"sample\",\"action\":\"recall\",\"action_input\":\"{\\\"query\\\":\\\"NEEDLE-RECALL-HIDDEN\\\"}\"}",
        "{\"thought\":\"sample\",\"action\":\"final\",\"action_input\":\"done\"}",
    } };
    var ag = testAgent(&brain, 16);
    ag.compactor = compressor.default;
    ag.context_budget_bytes = 3000;

    var sess = session.Session.init("t-recall-run");
    defer sess.deinit(gpa);
    try sess.append(gpa, .system, "SYS");
    try sess.append(gpa, .user, "GOAL");

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try sess.append(gpa, .assistant, "{\"action\":\"bash\",\"action_input\":\"x\"}");
        try sess.append(gpa, .user, "old observation payload NEEDLE-RECALL-HIDDEN " ++ ("x" ** 200));
    }
    while (i < 16) : (i += 1) {
        try sess.append(gpa, .assistant, "{\"action\":\"bash\",\"action_input\":\"recent\"}");
        try sess.append(gpa, .user, "recent small observation");
    }
    try std.testing.expect(historyBytes(sess.items()) > ag.context_budget_bytes);

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    var saw_recall = false;
    for (sess.archiveItems()) |m| {
        if (std.mem.indexOf(u8, m.content, "[Observation] recall") != null and
            std.mem.indexOf(u8, m.content, "NEEDLE-RECALL-HIDDEN") != null) saw_recall = true;
    }
    try std.testing.expect(saw_recall);
}

test "run: parallel read-only calls" {
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
        \\{"thought":"read in parallel","action":"parallel","action_input":"{\"calls\":[{\"action\":\"file_read\",\"input\":\"{\\\"path\\\":\\\"/tmp/scoot_agent_parallel/a.txt\\\"}\"},{\"action\":\"grep\",\"input\":\"{\\\"pattern\\\":\\\"needle\\\",\\\"path\\\":\\\"/tmp/scoot_agent_parallel/b.txt\\\"}\"}]}"}
    ;

    var brain = ScriptedBrain{ .steps = &.{
        step,
        "{\"thought\":\"sample\",\"action\":\"final\",\"action_input\":\"done\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Read files.");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    var observation: []const u8 = "";
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "parallel completed 2 read-only calls") != null) {
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

test "guard: parallel validates each subcall policy" {
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

test "run: malformed backend step is corrected" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "not JSON",
        "{\"thought\":\"finish\",\"action\":\"final\",\"action_input\":\"ok\"}",
    } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Start.");

    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);

    try std.testing.expectEqualStrings("ok", reply);
    var saw_hint = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "not valid step JSON") != null) saw_hint = true;
    }
    try std.testing.expect(saw_hint);
}

test "run: max_turns returns MaxTurnsExceeded" {
    const gpa = std.testing.allocator;
    const bash_true = "{\"thought\":\"sample\",\"action\":\"bash\",\"action_input\":\"true\"}";
    var brain = ScriptedBrain{ .steps = &.{ bash_true, bash_true, bash_true, bash_true } };
    var ag = testAgent(&brain, 2);

    var sess = session.Session.init("test");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Loop.");

    try std.testing.expectError(error.MaxTurnsExceeded, ag.run(gpa, &sess));
    try std.testing.expectEqual(@as(usize, 2), brain.idx); // exactly uses both turns
}

test "run: audit logs thought/tool_call/observation/final events" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"view\",\"action\":\"bash\",\"action_input\":\"printf OK\"}",
        "{\"thought\":\"sample\",\"action\":\"final\",\"action_input\":\"done\"}",
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
    // Audit lines must be valid JSONL so they can be replayed.
    var it = std.mem.tokenizeScalar(u8, log, '\n');
    while (it.next()) |line| {
        const v = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        v.deinit();
    }
}

test "run: trace writes reason/action/policy/observation/final to injected writer" {
    const gpa = std.testing.allocator;
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"view\",\"action\":\"bash\",\"action_input\":\"printf OK\"}",
        "{\"thought\":\"sample\",\"action\":\"final\",\"action_input\":\"done\"}",
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
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 1] reason: view") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 1] action: bash printf OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 1] policy: allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 1] observe: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 2] action: final") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 2] final: done") != null);

    // Progress markers prevent UI stalls: thinking precedes backend calls, running precedes tools.
    const think1 = std.mem.indexOf(u8, trace, "[trace 1] thinking:") orelse return error.MissingThinking;
    const reason1 = std.mem.indexOf(u8, trace, "[trace 1] reason:").?;
    const running1 = std.mem.indexOf(u8, trace, "[trace 1] running: bash") orelse return error.MissingRunning;
    const observe1 = std.mem.indexOf(u8, trace, "[trace 1] observe:").?;
    // thinking must precede reason, and running must precede observe.
    try std.testing.expect(think1 < reason1);
    try std.testing.expect(running1 < observe1);
    // The second final turn should also print thinking first.
    try std.testing.expect(std.mem.indexOf(u8, trace, "[trace 2] thinking:") != null);
}

test "run: dangerous command is denied, audited, and fed back" {
    const gpa = std.testing.allocator;
    // First step emits a dangerous command denied by guarded mode; second step converges.
    var brain = ScriptedBrain{ .steps = &.{
        "{\"thought\":\"delete root\",\"action\":\"bash\",\"action_input\":\"rm -rf /\"}",
        "{\"thought\":\"finish\",\"action\":\"final\",\"action_input\":\"blocked\"}",
    } };
    var ag = testAgent(&brain, 16); // policy_mode defaults to .guarded

    var logbuf: [4096]u8 = undefined;
    var lw = std.Io.Writer.fixed(&logbuf);
    var logger = audit.Logger.init(&lw, std.testing.io);
    ag.audit = &logger;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Try a dangerous command.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);

    try std.testing.expectEqualStrings("blocked", reply);

    // Denial must be audited and fed back, with no real command output.
    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
    var saw_denied = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "action denied by execution policy") != null) saw_denied = true;
    }
    try std.testing.expect(saw_denied);
}

test "run: file_write to file_read to file_edit flow under guarded mode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_file_flow";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    // Use Zig multiline strings to hold JSON with escaped quotes; action_input is JSON text.
    const s_write =
        \\{"thought":"write file","action":"file_write","action_input":"{\"path\":\"/tmp/scoot_agent_file_flow/note.txt\",\"content\":\"hello world\"}"}
    ;
    const s_read =
        \\{"thought":"read file","action":"file_read","action_input":"{\"path\":\"/tmp/scoot_agent_file_flow/note.txt\"}"}
    ;
    const s_edit =
        \\{"thought":"edit file","action":"file_edit","action_input":"{\"path\":\"/tmp/scoot_agent_file_flow/note.txt\",\"old\":\"world\",\"new\":\"scoot\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"done"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_write, s_read, s_edit, s_final } };
    var ag = testAgent(&brain, 16); // guarded by default: built-in write tools are allowed

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Edit the file.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    // The on-disk file should be edited exactly to "hello scoot".
    const final_bytes = try cwd.readFileAlloc(io, dir ++ "/note.txt", gpa, .limited(1 << 16));
    defer gpa.free(final_bytes);
    try std.testing.expectEqualStrings("hello scoot", final_bytes);

    // The file_read observation should include written content for the later edit.
    var saw_read = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "hello world") != null and
            std.mem.indexOf(u8, m.content, "bytes") != null) saw_read = true;
    }
    try std.testing.expect(saw_read);
}

test "run: readonly file_write is denied and audited with no observation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_file_ro";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    const s_write =
        \\{"thought":"write denied file","action":"file_write","action_input":"{\"path\":\"/tmp/scoot_agent_file_ro/evil.txt\",\"content\":\"x\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"denied"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_write, s_final } };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly; // simulate forced unattended safety mode

    var logbuf: [4096]u8 = undefined;
    var lw = std.Io.Writer.fixed(&logbuf);
    var logger = audit.Logger.init(&lw, std.testing.io);
    ag.audit = &logger;

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Write a file.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("denied", reply);

    // The file must not be created; built-in write tools cannot bypass readonly.
    try std.testing.expectError(error.FileNotFound, cwd.readFileAlloc(io, dir ++ "/evil.txt", gpa, .limited(64)));

    // Audit policy_deny; because the write was denied and not executed, there is no observation.
    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
}

test "run: readonly absolute file_read is denied" {
    const gpa = std.testing.allocator;
    const s_read =
        \\{"thought":"read file","action":"file_read","action_input":"{\"path\":\"/etc/passwd\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"could not read"}
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
    try sess.append(gpa, .user, "Read a file.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("could not read", reply);

    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
}

test "run: malformed file arguments can be corrected defensively" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_file_malformed";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    // First action_input is not valid args JSON; execution fails and feeds back a correction.
    const s_bad =
        \\{"thought":"write file","action":"file_write","action_input":"not a json object"}
    ;
    const s_good =
        \\{"thought":"retry write","action":"file_write","action_input":"{\"path\":\"/tmp/scoot_agent_file_malformed/ok.txt\",\"content\":\"fixed\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"done"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_bad, s_good, s_final } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Write a file.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("done", reply);

    // The feedback should include a corrective hint for argument formatting.
    var saw_hint = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "parameter JSON") != null) saw_hint = true;
    }
    try std.testing.expect(saw_hint);

    // The model retries with valid args and writes the file successfully.
    const bytes = try cwd.readFileAlloc(io, dir ++ "/ok.txt", gpa, .limited(64));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("fixed", bytes);
}

test "run: glob file then grep function under readonly mode" {
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
        \\{"thought":"find zig file","action":"glob","action_input":"{\"pattern\":\"**/*.zig\",\"root\":\".zig-cache/scoot_agent_search_flow\"}"}
    ;
    const s_grep =
        \\{"thought":"grep main","action":"grep","action_input":"{\"pattern\":\"pub fn \\\\w+\",\"path\":\".zig-cache/scoot_agent_search_flow/src/main.zig\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"found"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_glob, s_grep, s_final } };
    var ag = testAgent(&brain, 16);
    ag.policy_mode = .readonly; // grep/glob are read actions and should pass readonly

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Find source files.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("found", reply);

    // The glob observation lists the matched .zig path; grep includes the "pub fn main" line number.
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

test "run: invalid grep regex can be corrected defensively" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_agent_grep_bad";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    try tools.file.write(io, dir ++ "/f.txt", "alpha\nbeta\n");

    // First regex is invalid; compile fails during execution and feeds back InvalidPattern.
    const s_bad =
        \\{"thought":"grep","action":"grep","action_input":"{\"pattern\":\"(alpha\",\"path\":\"/tmp/scoot_agent_grep_bad/f.txt\"}"}
    ;
    const s_good =
        \\{"thought":"retry grep","action":"grep","action_input":"{\"pattern\":\"alpha\",\"path\":\"/tmp/scoot_agent_grep_bad/f.txt\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"ok"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_bad, s_good, s_final } };
    var ag = testAgent(&brain, 16);

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Search file.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("ok", reply);

    var saw_hint = false;
    var saw_hit = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "regex is invalid") != null) saw_hint = true;
        if (std.mem.indexOf(u8, m.content, "1:alpha") != null) saw_hit = true;
    }
    try std.testing.expect(saw_hint);
    try std.testing.expect(saw_hit);
}

test "run: readonly http GET is denied with policy_deny and no observation" {
    const gpa = std.testing.allocator;
    const s_get =
        \\{"thought":"fetch url","action":"http_request","action_input":"{\"method\":\"GET\",\"url\":\"http://10.255.255.1/\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"no network"}
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
    try sess.append(gpa, .user, "Fetch URL.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("no network", reply);

    // GET is net_read and denied in readonly; audit policy_deny with no observation.
    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
}

test "run: readonly http POST is denied fail-closed with no observation" {
    const gpa = std.testing.allocator;
    const s_post =
        \\{"thought":"post url","action":"http_request","action_input":"{\"method\":\"POST\",\"url\":\"http://127.0.0.1:1/\",\"body\":\"x\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"post denied"}
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
    try sess.append(gpa, .user, "Post URL.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("post denied", reply);

    // POST is net_write and denied in readonly; audit policy_deny with no observation.
    const log = lw.buffered();
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"policy_deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"kind\":\"observation\"") == null);
}

test "run: unknown http method returns corrective feedback" {
    const gpa = std.testing.allocator;
    // Invalid methods fail in execTool parsing with UnknownMethod and never touch the network.
    const s_bad =
        \\{"thought":"fetch","action":"http_request","action_input":"{\"method\":\"FETCH\",\"url\":\"http://127.0.0.1:1/\"}"}
    ;
    const s_final =
        \\{"thought":"finish","action":"final","action_input":"ok"}
    ;
    var brain = ScriptedBrain{ .steps = &.{ s_bad, s_final } };
    var ag = testAgent(&brain, 16); // guarded allows it, then execution fails on the unknown method

    var sess = session.Session.init("t");
    defer sess.deinit(gpa);
    try sess.append(gpa, .user, "Fetch URL.");
    const reply = try ag.run(gpa, &sess);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("ok", reply);

    var saw_hint = false;
    for (sess.items()) |m| {
        if (std.mem.indexOf(u8, m.content, "method is unknown") != null) saw_hint = true;
    }
    try std.testing.expect(saw_hint);
}

test {
    std.testing.refAllDecls(@This());
}
