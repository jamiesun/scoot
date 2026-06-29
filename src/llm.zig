//! LLM backend adapter for the OpenAI Responses API (`/v1/responses`).
//!
//! Hard rules implemented here:
//!   #2 Only the OpenAI Responses protocol. Structured ReACT steps use
//!      `text.format=json_schema` with `strict:true` when a schema is provided.
//!      Chat Completions transport was removed (issue #110); a backend that only
//!      speaks Chat Completions must sit behind a Responses-compatible gateway.
//!   #4 Never trust model output: every response goes through defensive std.json
//!      parsing. Bad data returns errors for upper layers to wrap into System
//!      Error feedback and retry, never panic.
//! Transport is stateless by default: each call resends the full input, so scoot
//! keeps local ownership of context (local compaction, audit, recovery). The
//! model-side storage/chaining mechanics (response ids, `previous_response_id`,
//! `store`) live in `ModelContext` at this transport boundary and never leak into
//! agent or tool execution modules.
//! Memory: all temporary allocations use the per-call arena supplied by the
//! caller. Returned `content` points into that arena and must be copied to
//! long-lived storage before the arena is released.
const std = @import("std");
const jsonio = @import("jsonio.zig");
const proc = @import("tools/proc.zig");

pub const Role = enum { system, user, assistant, tool };
pub const default_timeout_ms: u64 = 120_000;

pub const Message = struct {
    role: Role,
    content: []const u8,
};

/// Optional parameters for one model API call.
pub const ChatOptions = struct {
    /// JSON Schema object as raw JSON text. Non-null forces structured output.
    json_schema: ?[]const u8 = null,
    /// json_schema name required by OpenAI.
    schema_name: []const u8 = "scoot_output",
    /// Sampling temperature; null uses backend default.
    temperature: ?f32 = null,
};

/// Result of one model API call after defensive JSON parsing.
pub const Completion = struct {
    content: []const u8,
    finish_reason: []const u8 = "",
    /// Responses object id (e.g. `resp_...`); empty when absent. Captured to
    /// enable opt-in `previous_response_id` chaining owned by `ModelContext`.
    id: []const u8 = "",
};

/// Model-side context owned at the transport boundary (issue #110). It holds the
/// OpenAI Responses storage/chaining mechanics so they never leak into agent or
/// tool execution modules.
///
/// Default is fully stateless: `store=false` and no `previous_response_id`, so
/// each call resends the full input and scoot keeps local ownership of context.
/// `last_response_id` is captured from each response so future opt-in chaining is
/// possible without shipping a half-working toggle. Tool code never reads this.
pub const ModelContext = struct {
    /// Whether to ask the backend to persist the response server-side. Off by
    /// default to keep model context local and auditable.
    store: bool = false,
    /// Explicit chaining pointer. Null (default) means stateless: send the full
    /// input every turn. Set only by an opt-in chaining policy, never by tools.
    previous_response_id: ?[]const u8 = null,
    /// Last response id captured from the backend, kept in a fixed buffer so it
    /// survives the per-call arena.
    last_response_id_buf: [128]u8 = undefined,
    last_response_id_len: usize = 0,

    pub fn lastResponseId(self: *const ModelContext) []const u8 {
        return self.last_response_id_buf[0..self.last_response_id_len];
    }

    fn rememberResponseId(self: *ModelContext, id: []const u8) void {
        const n = @min(id.len, self.last_response_id_buf.len);
        @memcpy(self.last_response_id_buf[0..n], id[0..n]);
        self.last_response_id_len = n;
    }
};

pub const Client = struct {
    io: std.Io,
    base_url: []const u8,
    model: []const u8,
    /// API token. Empty means no Authorization header for local unauthenticated backends.
    api_key: []const u8 = "",
    /// Hard timeout for one backend request. 0 means use the module default.
    timeout_ms: u64 = default_timeout_ms,
    /// Absolute custom CA bundle path (PEM); null scans system roots.
    ca_file: ?[]const u8 = null,
    /// Dynamic extra request-body fields, merged into the top-level body. See
    /// config.Backend.extra_body. Only objects are accepted; non-objects are
    /// ignored. Each value is serialized through std.json, so the body stays valid.
    extra_body: ?std.json.Value = null,
    /// Model-side storage/chaining context (issue #110).
    model_ctx: ModelContext = .{},
    /// Last backend failure response summary, stored in a fixed buffer because
    /// the per-call arena may be gone after errors propagate.
    last_error_status: u16 = 0,
    last_error_body_buf: [2048]u8 = undefined,
    last_error_body_len: usize = 0,
    last_error_body_truncated: bool = false,

    pub fn init(io: std.Io, base_url: []const u8, model: []const u8, api_key: []const u8) Client {
        return .{ .io = io, .base_url = base_url, .model = model, .api_key = api_key };
    }

    pub fn lastErrorBody(self: *const Client) []const u8 {
        return self.last_error_body_buf[0..self.last_error_body_len];
    }

    /// Performs one OpenAI Responses request and returns defensively parsed output.
    /// Connection failures, non-2xx statuses, and malformed responses return
    /// errors instead of panicking; upper layers decide retry or user feedback.
    pub fn chat(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const Message,
        opts: ChatOptions,
    ) !Completion {
        self.clearLastError();
        const body = try buildRequestBody(
            arena,
            self.model,
            messages,
            opts,
            self.extra_body,
            self.model_ctx.store,
            self.model_ctx.previous_response_id,
        );
        const url = try std.fmt.allocPrint(arena, "{s}/responses", .{self.base_url});

        var http_client: std.http.Client = .{ .allocator = arena, .io = self.io };
        defer http_client.deinit();

        // Custom CA: preload bundle and set now to suppress system root scanning.
        if (self.ca_file) |path| {
            const ca_now = std.Io.Clock.real.now(self.io);
            http_client.ca_bundle.addCertsFromFilePathAbsolute(arena, self.io, ca_now, path) catch
                return error.CertificateBundleLoadFailure;
            http_client.now = ca_now;
        }

        var resp: std.Io.Writer.Allocating = .init(arena);
        const has_key = self.api_key.len > 0;
        const auth: []const u8 = if (has_key)
            try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key})
        else
            "";

        const fetched = fetchResponsesWithTimeout(
            self.io,
            &http_client,
            url,
            body,
            has_key,
            auth,
            &resp,
            self.timeout_ms,
        );
        if (fetched.timed_out) {
            self.rememberBackendResponse(0, "backend request exceeded hard timeout");
            return error.BackendError;
        }
        if (fetched.err) |e| {
            self.rememberBackendResponse(0, e);
            return error.BackendError;
        }

        const code = fetched.status;
        const response_body = fetched.body;
        if (code < 200 or code >= 300) self.rememberBackendResponse(code, response_body);
        if (code == 401 or code == 403) return error.Unauthorized;
        if (code < 200 or code >= 300) return error.BackendError;

        const completion = parseCompletion(arena, response_body) catch |err| {
            self.rememberBackendResponse(code, response_body);
            return err;
        };
        if (completion.id.len > 0) self.model_ctx.rememberResponseId(completion.id);
        return completion;
    }

    fn clearLastError(self: *Client) void {
        self.last_error_status = 0;
        self.last_error_body_len = 0;
        self.last_error_body_truncated = false;
    }

    fn rememberBackendResponse(self: *Client, status: u16, body: []const u8) void {
        self.last_error_status = status;
        const n = if (body.len > self.last_error_body_buf.len) self.last_error_body_buf.len else body.len;
        @memcpy(self.last_error_body_buf[0..n], body[0..n]);
        self.last_error_body_len = n;
        self.last_error_body_truncated = body.len > n;
    }
};

const FetchResult = struct {
    status: u16 = 0,
    body: []const u8 = "",
    timed_out: bool = false,
    err: ?[]const u8 = null,
};

fn fetchResponsesWithTimeout(
    io: std.Io,
    http_client: *std.http.Client,
    url: []const u8,
    body: []const u8,
    has_key: bool,
    auth: []const u8,
    resp: *std.Io.Writer.Allocating,
    timeout_ms: u64,
) FetchResult {
    const effective_timeout_ms = proc.effectiveTimeoutMs(timeout_ms, default_timeout_ms);

    const Outcome = union(enum) { done: FetchResult, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);

    sel.concurrent(.done, doFetchResponses, .{ http_client, url, body, has_key, auth, resp }) catch |err| {
        return .{ .err = @errorName(err) };
    };
    sel.concurrent(.timed_out, sleepDeadline, .{ io, effective_timeout_ms }) catch |err| {
        sel.cancelDiscard();
        return .{ .err = @errorName(err) };
    };

    const winner = sel.await() catch |err| {
        sel.cancelDiscard();
        return .{ .err = @errorName(err) };
    };
    sel.cancelDiscard();

    return switch (winner) {
        .done => |r| r,
        .timed_out => .{ .timed_out = true },
    };
}

fn doFetchResponses(
    http_client: *std.http.Client,
    url: []const u8,
    body: []const u8,
    has_key: bool,
    auth: []const u8,
    resp: *std.Io.Writer.Allocating,
) FetchResult {
    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = if (has_key) .{ .override = auth } else .default,
        },
        .response_writer = &resp.writer,
    }) catch |e| return .{ .err = @errorName(e) };

    return .{
        .status = @intFromEnum(result.status),
        .body = resp.writer.buffered(),
    };
}

fn sleepDeadline(io: std.Io, timeout_ms: u64) void {
    const d: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    };
    d.sleep(io) catch {};
}

/// Builds an OpenAI Responses request body. Leading consecutive `system` messages
/// map to the top-level `instructions` field (the stable instruction prefix the
/// backend caches natively); the remaining messages become typed `input` items.
/// Providing a schema forces `text.format=json_schema/strict`. `store` controls
/// server-side persistence; non-null `previous_response_id` chains from a prior
/// response. Non-null `extra_body` merges its object members into the top level
/// for dynamic fields such as reasoning controls.
pub fn buildRequestBody(
    arena: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    opts: ChatOptions,
    extra_body: ?std.json.Value,
    store: bool,
    previous_response_id: ?[]const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try jsonio.writeString(w, model);
    try w.writeAll(if (store) ",\"store\":true" else ",\"store\":false");
    if (previous_response_id) |pid| {
        try w.writeAll(",\"previous_response_id\":");
        try jsonio.writeString(w, pid);
    }
    if (opts.temperature) |t| try w.print(",\"temperature\":{d}", .{t});

    // Stable instruction prefix: the leading system segment carries system_prompt,
    // tool descriptions, and the skill manifest, which stay byte-stable across the
    // loop. Sending it as `instructions` lets the backend cache the fixed prefix.
    const sys_end = leadingSystemEnd(messages);
    if (sys_end > 0) {
        try w.writeAll(",\"instructions\":");
        try writeJoinedSystem(w, arena, messages[0..sys_end]);
    }

    try w.writeAll(",\"input\":[");
    var first = true;
    for (messages[sys_end..]) |m| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"role\":\"");
        try w.writeAll(@tagName(m.role));
        try w.writeAll("\",\"content\":");
        try jsonio.writeString(w, m.content);
        try w.writeByte('}');
    }
    try w.writeByte(']');

    if (opts.json_schema) |schema| {
        try w.writeAll(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":");
        try jsonio.writeString(w, opts.schema_name);
        try w.writeAll(",\"strict\":true,\"schema\":");
        try w.writeAll(schema); // Caller-provided valid JSON Schema object.
        try w.writeAll("}}");
    }

    if (extra_body) |extra| try writeExtraBody(w, extra);

    try w.writeByte('}');
    return aw.writer.buffered();
}

/// Counts the leading consecutive `system` messages, the stable instruction
/// prefix mapped to `instructions`. No leading system message returns 0.
fn leadingSystemEnd(messages: []const Message) usize {
    var i: usize = 0;
    while (i < messages.len and messages[i].role == .system) : (i += 1) {}
    return i;
}

/// Writes the system segment as one JSON string. Multiple system messages are
/// joined with blank lines so the instruction prefix stays a single field.
fn writeJoinedSystem(w: *std.Io.Writer, arena: std.mem.Allocator, sys: []const Message) !void {
    if (sys.len == 1) {
        try jsonio.writeString(w, sys[0].content);
        return;
    }
    var joined: std.Io.Writer.Allocating = .init(arena);
    for (sys, 0..) |m, i| {
        if (i != 0) try joined.writer.writeAll("\n\n");
        try joined.writer.writeAll(m.content);
    }
    try jsonio.writeString(w, joined.writer.buffered());
}

/// Injects user-configured extra_body object members into the top-level request
/// body. Defensive behavior: only JSON objects are accepted; non-objects are
/// ignored so bad config cannot create malformed request bodies. Values are
/// serialized through std.json. Injection at the end means extra_body overwrites
/// duplicate keys; config should not redefine core fields like model/input.
fn writeExtraBody(w: *std.Io.Writer, extra: std.json.Value) !void {
    if (extra != .object) return;
    var it = extra.object.iterator();
    while (it.next()) |entry| {
        try w.writeByte(',');
        try jsonio.writeString(w, entry.key_ptr.*);
        try w.writeByte(':');
        try w.print("{f}", .{std.json.fmt(entry.value_ptr.*, .{})});
    }
}

/// Defensively parses a Responses API response. Prefers a top-level `output_text`
/// convenience field when present; otherwise concatenates `output[].content[]`
/// entries with type `output_text`. A `refusal` part with no text output is
/// surfaced as content with finish_reason `refusal` so upper layers can feed it
/// back through the standard correction path instead of treating it as malformed.
/// Any structural mismatch returns MalformedResponse, never panics.
pub fn parseCompletion(arena: std.mem.Allocator, body: []const u8) !Completion {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedResponse;
    if (parsed != .object) return error.MalformedResponse;
    const obj = parsed.object;

    const id = if (obj.get("id")) |v|
        (if (v == .string) v.string else "")
    else
        "";
    const finish_reason = if (obj.get("status")) |status|
        (if (status == .string) status.string else "")
    else
        "";

    if (obj.get("output_text")) |value| {
        if (value == .string and value.string.len > 0) {
            return .{ .content = value.string, .finish_reason = finish_reason, .id = id };
        }
    }

    const output = obj.get("output") orelse return error.MalformedResponse;
    if (output != .array) return error.MalformedResponse;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var found = false;
    var refusal: ?[]const u8 = null;
    for (output.array.items) |item| {
        if (item != .object) continue;
        const content = item.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (part != .object) continue;
            const typ = part.object.get("type") orelse continue;
            if (typ != .string) continue;
            if (std.mem.eql(u8, typ.string, "output_text")) {
                const text = part.object.get("text") orelse continue;
                if (text != .string) continue;
                try w.writeAll(text.string);
                found = true;
            } else if (std.mem.eql(u8, typ.string, "refusal")) {
                const text = part.object.get("refusal") orelse continue;
                if (text == .string) refusal = text.string;
            }
        }
    }
    if (found) return .{ .content = aw.writer.buffered(), .finish_reason = finish_reason, .id = id };
    if (refusal) |r| return .{ .content = r, .finish_reason = "refusal", .id = id };
    return error.MalformedResponse;
}

test "buildRequestBody emits Responses input and forces text.format json_schema/strict" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hi \"there\"\n" },
    };
    const body = try buildRequestBody(arena, "gpt-5.1", &msgs, .{
        .json_schema = "{\"type\":\"object\"}",
        .schema_name = "scoot_step",
    }, null, false, null);

    // Must be valid JSON.
    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
    // Responses shape: input array, text.format strict schema, model echoed.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":{\"format\":{\"type\":\"json_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5.1\"") != null);
    // No Chat Completions leftovers.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "response_format") == null);
}

test "buildRequestBody maps leading system messages to instructions, not input" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{
        .{ .role = .system, .content = "SYS-PROMPT" },
        .{ .role = .system, .content = "SKILL-MANIFEST" },
        .{ .role = .user, .content = "do it" },
        .{ .role = .assistant, .content = "step" },
    };
    const body = try buildRequestBody(arena, "m", &msgs, .{}, null, false, null);

    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    // Both system messages are joined into the single instructions string.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"SYS-PROMPT\\n\\nSKILL-MANIFEST\"") != null);
    // Only non-system turns remain in input; no system role item is emitted.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\",\"content\":\"do it\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\",\"content\":\"step\"") != null);
}

test "buildRequestBody store flag and previous_response_id chaining" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{.{ .role = .user, .content = "hi" }};

    const stateless = try buildRequestBody(arena, "m", &msgs, .{}, null, false, null);
    try std.testing.expect(std.mem.indexOf(u8, stateless, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stateless, "previous_response_id") == null);

    const chained = try buildRequestBody(arena, "m", &msgs, .{}, null, true, "resp_123");
    try std.testing.expect(std.mem.indexOf(u8, chained, "\"store\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, chained, "\"previous_response_id\":\"resp_123\"") != null);
}

test "buildRequestBody injects extra_body extra fields(dynamic passthrough)" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"reasoning\":{\"effort\":\"high\"},\"service_tier\":\"priority\"}",
        .{},
    );
    defer parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{.{ .role = .user, .content = "hi" }};
    const body = try buildRequestBody(arena, "gpt-5.5", &msgs, .{}, parsed.value, false, null);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"service_tier\":\"priority\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\"}") != null);
    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5.5\"") != null);
}

test "buildRequestBody ignores non-object extra_body(defensive)" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "42", .{});
    defer parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{.{ .role = .user, .content = "hi" }};
    const body = try buildRequestBody(arena, "m", &msgs, .{}, parsed.value, false, null);

    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
    try std.testing.expect(std.mem.indexOf(u8, body, ",42") == null);
}

test "parseCompletion extracts output_text, nested message content, and id" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const direct = try parseCompletion(arena,
        \\{"id":"resp_1","status":"completed","output_text":"{\"action\":\"final\"}"}
    );
    try std.testing.expectEqualStrings("{\"action\":\"final\"}", direct.content);
    try std.testing.expectEqualStrings("completed", direct.finish_reason);
    try std.testing.expectEqualStrings("resp_1", direct.id);

    const nested = try parseCompletion(arena,
        \\{"id":"resp_2","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}]}
    );
    try std.testing.expectEqualStrings("hello", nested.content);
    try std.testing.expectEqualStrings("resp_2", nested.id);
}

test "parseCompletion surfaces refusal and rejects malformed without panic" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refused = try parseCompletion(arena,
        \\{"id":"resp_3","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"I cannot help with that."}]}]}
    );
    try std.testing.expectEqualStrings("I cannot help with that.", refused.content);
    try std.testing.expectEqualStrings("refusal", refused.finish_reason);

    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "not json <<<"));
    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "{\"output\":[]}"));
    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "{}"));
}

test "ModelContext captures last response id within fixed buffer" {
    var mc: ModelContext = .{};
    try std.testing.expectEqualStrings("", mc.lastResponseId());
    mc.rememberResponseId("resp_abc");
    try std.testing.expectEqualStrings("resp_abc", mc.lastResponseId());

    const long = "resp_" ++ ("x" ** 200);
    mc.rememberResponseId(long);
    try std.testing.expectEqual(mc.last_response_id_buf.len, mc.lastResponseId().len);
}

test "Client reports backend failure response" {
    var c = Client.init(std.testing.io, "http://example.invalid/v1", "m", "");
    const body = "backend rejected this request";
    c.rememberBackendResponse(400, body);
    try std.testing.expectEqual(@as(u16, 400), c.last_error_status);
    try std.testing.expectEqualStrings(body, c.lastErrorBody());
    try std.testing.expect(!c.last_error_body_truncated);

    const long = try std.testing.allocator.alloc(u8, c.last_error_body_buf.len + 8);
    defer std.testing.allocator.free(long);
    @memset(long, 'x');
    c.rememberBackendResponse(500, long);
    try std.testing.expectEqual(c.last_error_body_buf.len, c.lastErrorBody().len);
    try std.testing.expect(c.last_error_body_truncated);

    c.clearLastError();
    try std.testing.expectEqual(@as(u16, 0), c.last_error_status);
    try std.testing.expectEqual(@as(usize, 0), c.lastErrorBody().len);
    try std.testing.expect(!c.last_error_body_truncated);
}

test "Client backend request timeout returns BackendError without hanging" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var c = Client.init(io, "http://10.255.255.1/v1", "m", "");
    c.timeout_ms = 300;
    const msgs = [_]Message{.{ .role = .user, .content = "hi" }};

    const t0 = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.BackendError, c.chat(arena, &msgs, .{}));
    const t1 = std.Io.Clock.awake.now(io);
    const dt_ns = t0.durationTo(t1).nanoseconds;

    try std.testing.expectEqual(@as(u16, 0), c.last_error_status);
    try std.testing.expect(c.lastErrorBody().len > 0);
    try std.testing.expect(dt_ns < 5 * std.time.ns_per_s);
}

test {
    std.testing.refAllDecls(@This());
}
