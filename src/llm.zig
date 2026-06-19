//! LLM backend adapter: only targets OpenAI `/v1/chat/completions`.
//!
//! Hard rules implemented here:
//!   #2 Only OpenAI protocol; when a schema is provided, force
//!      `response_format=json_schema` with `strict:true`.
//!   #4 Never trust model output: all responses go through defensive std.json
//!      parsing. Bad data returns errors for upper layers to wrap into System
//!      Error feedback and retry, never panic.
//! Memory: all temporary allocations use the per-call arena supplied by the
//! caller. Returned `content` points into that arena and must be copied to
//! long-lived storage before the arena is released.
const std = @import("std");
const jsonio = @import("jsonio.zig");

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

/// Backend prompt-cache hint mode (issue #72).
/// - `off` by default: sends no cache markers and preserves old byte-for-byte
///   request bodies. Backends such as OpenAI, vLLM, and SGLang that auto-cache
///   stable prefixes do not need extra fields, and strict backends avoid unknown
///   field errors.
/// - `anthropic`: adds an Anthropic-style `cache_control:{type:ephemeral}`
///   breakpoint on the stable instruction prefix, the last leading system
///   message, so the fixed prefix can be billed or computed as cached. Enable
///   only on Anthropic-compatible gateways.
pub const PromptCache = enum {
    off,
    anthropic,

    /// Parses a config string; unknown values fall back to `off`, leaving body unchanged.
    pub fn parse(s: []const u8) PromptCache {
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        return .off;
    }
};

/// Optional parameters for one chat/completions call.
pub const ChatOptions = struct {
    /// JSON Schema object as raw JSON text. Non-null forces structured output.
    json_schema: ?[]const u8 = null,
    /// json_schema name required by OpenAI.
    schema_name: []const u8 = "scoot_output",
    /// Sampling temperature; null uses backend default.
    temperature: ?f32 = null,
};

/// Result of one chat/completions call after defensive JSON parsing.
pub const Completion = struct {
    content: []const u8,
    finish_reason: []const u8 = "",
};

pub const Client = struct {
    io: std.Io,
    base_url: []const u8,
    model: []const u8,
    /// API token. Empty means no Authorization header for local unauthenticated backends.
    api_key: []const u8 = "",
    /// Absolute custom CA bundle path (PEM); null scans system roots.
    ca_file: ?[]const u8 = null,
    /// Dynamic extra request-body fields, merged into the top-level body. See
    /// config.Backend.extra_body. Only objects are accepted; non-objects are
    /// ignored. Each value is serialized through std.json, so the body stays valid.
    extra_body: ?std.json.Value = null,
    /// Prompt-cache hint mode (issue #72). Default `off` leaves request bodies unchanged.
    prompt_cache: PromptCache = .off,
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

    /// Performs one chat/completions request and returns defensively parsed output.
    /// Connection failures, non-2xx statuses, and malformed responses return
    /// errors instead of panicking; upper layers decide retry or user feedback.
    pub fn chat(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const Message,
        opts: ChatOptions,
    ) !Completion {
        self.clearLastError();
        const body = try buildRequestBody(arena, self.model, messages, opts, self.extra_body, self.prompt_cache);
        const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{self.base_url});

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

        const result = try http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (has_key) .{ .override = auth } else .default,
            },
            .response_writer = &resp.writer,
        });

        const code = @intFromEnum(result.status);
        const response_body = resp.writer.buffered();
        if (code < 200 or code >= 300) self.rememberBackendResponse(code, response_body);
        if (code == 401 or code == 403) return error.Unauthorized;
        if (code < 200 or code >= 300) return error.BackendError;

        return parseCompletion(arena, response_body) catch |err| {
            self.rememberBackendResponse(code, response_body);
            return err;
        };
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

/// Builds a compact OpenAI request body. Providing schema forces
/// response_format=json_schema/strict. Non-null `extra_body` merges its object
/// members into the top level for dynamic fields such as service_tier.
/// `prompt_cache=anthropic` adds Anthropic-style cache breakpoints to stable
/// instruction prefixes; `off` preserves old byte-for-byte behavior.
pub fn buildRequestBody(
    arena: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    opts: ChatOptions,
    extra_body: ?std.json.Value,
    prompt_cache: PromptCache,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    // Cache breakpoint index (issue #72): computed only for anthropic; off keeps
    // content as plain strings.
    const cache_idx: ?usize = if (prompt_cache == .anthropic) cacheBreakpointIndex(messages) else null;

    try w.writeAll("{\"model\":");
    try jsonio.writeString(w, model);
    try w.writeAll(",\"stream\":false");
    if (opts.temperature) |t| try w.print(",\"temperature\":{d}", .{t});

    try w.writeAll(",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"role\":\"");
        try w.writeAll(@tagName(m.role));
        if (cache_idx == i) {
            // Cache breakpoint: content uses content-parts carrying Anthropic
            // cache_control. This is still a valid OpenAI content-parts shape;
            // send only when explicitly enabled because unsupported backends may
            // ignore or reject the extension.
            try w.writeAll("\",\"content\":[{\"type\":\"text\",\"text\":");
            try jsonio.writeString(w, m.content);
            try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}]}");
        } else {
            try w.writeAll("\",\"content\":");
            try jsonio.writeString(w, m.content);
            try w.writeByte('}');
        }
    }
    try w.writeByte(']');

    if (opts.json_schema) |schema| {
        try w.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try jsonio.writeString(w, opts.schema_name);
        try w.writeAll(",\"strict\":true,\"schema\":");
        try w.writeAll(schema); // Caller-provided valid JSON Schema object.
        try w.writeAll("}}");
    }

    if (extra_body) |extra| try writeExtraBody(w, extra);

    try w.writeByte('}');
    return aw.writer.buffered();
}

/// Injects user-configured extra_body object members into the top-level request
/// body. Defensive behavior: only JSON objects are accepted; non-objects are
/// ignored so bad config cannot create malformed request bodies. Values are
/// serialized through std.json. Injection at the end means extra_body overwrites
/// duplicate keys; config should not redefine core fields like model/messages.
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

/// Cache breakpoint for the stable instruction prefix (issue #72): pick the last
/// message in the leading consecutive system segment. system_prompt, tool
/// descriptions, and skill manifest live there and stay byte-stable across the
/// loop. Marking it with cache_control caches the fixed prefix. No system message
/// returns null, making this a no-op.
fn cacheBreakpointIndex(messages: []const Message) ?usize {
    var last: ?usize = null;
    for (messages, 0..) |m, i| {
        if (m.role != .system) break;
        last = i;
    }
    return last;
}

/// Defensively parses a chat/completions response and extracts first choice
/// message.content. Any structural mismatch returns MalformedResponse, never panic.
pub fn parseCompletion(arena: std.mem.Allocator, body: []const u8) error{MalformedResponse}!Completion {
    const Resp = struct {
        choices: []const struct {
            message: struct {
                content: ?[]const u8 = null,
            } = .{},
            finish_reason: ?[]const u8 = null,
        } = &.{},
    };
    const parsed = std.json.parseFromSliceLeaky(Resp, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedResponse;

    if (parsed.choices.len == 0) return error.MalformedResponse;
    const content = parsed.choices[0].message.content orelse return error.MalformedResponse;
    return .{
        .content = content,
        .finish_reason = parsed.choices[0].finish_reason orelse "",
    };
}

test "buildRequestBody emits valid JSON and forces json_schema/strict" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hi \"there\"\n" },
    };
    const body = try buildRequestBody(arena, "qwen2.5", &msgs, .{
        .json_schema = "{\"type\":\"object\"}",
        .schema_name = "scoot_reply",
    }, null, .off);

    // Must be valid JSON.
    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
    // Forces structured output.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"qwen2.5\"") != null);
}

test "buildRequestBody injects extra_body extra fields(dynamic passthrough)" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"service_tier\":\"priority\",\"reasoning_effort\":\"high\"}",
        .{},
    );
    defer parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{.{ .role = .user, .content = "hi" }};
    const body = try buildRequestBody(arena, "gpt-5.5", &msgs, .{}, parsed.value, .off);

    // Extra fields are passed through into the request body.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"service_tier\":\"priority\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    // Still valid JSON with core fields intact.
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
    const body = try buildRequestBody(arena, "m", &msgs, .{}, parsed.value, .off);

    // Non-objects are ignored; request remains valid and does not splice raw 42.
    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
    try std.testing.expect(std.mem.indexOf(u8, body, ",42") == null);
}

test "buildRequestBody: prompt_cache=off writes no cache markers(zero side effects,issue #72)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hi" },
    };
    const body = try buildRequestBody(arena, "m", &msgs, .{}, null, .off);

    // Default mode: content remains plain strings with no cache_control or parts.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"sys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "cache_control") == null);
}

test "buildRequestBody: prompt_cache=anthropic adds cache_control breakpoint to system prefix(issue #72)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{
        .{ .role = .system, .content = "sys-PFX" },
        .{ .role = .user, .content = "u" },
        .{ .role = .assistant, .content = "a" },
    };
    const body = try buildRequestBody(arena, "m", &msgs, .{}, null, .anthropic);

    // System prefix becomes content-parts with an ephemeral breakpoint.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\",\"text\":\"sys-PFX\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
    // Non-prefix messages remain plain strings without breakpoints or extra weight.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"u\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"a\"") != null);
    // Still valid JSON.
    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
}

test "cacheBreakpointIndex chooses final initial system message and returns null without system (issue #72)" {
    const a = [_]Message{
        .{ .role = .system, .content = "s0" },
        .{ .role = .system, .content = "s1" },
        .{ .role = .user, .content = "u" },
        .{ .role = .system, .content = "later-sys-ignored" },
    };
    try std.testing.expectEqual(@as(?usize, 1), cacheBreakpointIndex(&a));

    const b = [_]Message{.{ .role = .user, .content = "u" }};
    try std.testing.expectEqual(@as(?usize, null), cacheBreakpointIndex(&b));

    try std.testing.expectEqual(@as(?usize, null), cacheBreakpointIndex(&[_]Message{}));
}

test "PromptCache.parse: anthropic / off / unknown falls back to off(issue #72)" {
    try std.testing.expectEqual(PromptCache.anthropic, PromptCache.parse("anthropic"));
    try std.testing.expectEqual(PromptCache.off, PromptCache.parse("off"));
    try std.testing.expectEqual(PromptCache.off, PromptCache.parse("bogus"));
    try std.testing.expectEqual(PromptCache.off, PromptCache.parse(""));
}

test "parseCompletion extracts content(normal response)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{"total_tokens":3}}
    ;
    const c = try parseCompletion(arena, body);
    try std.testing.expectEqualStrings("hello", c.content);
    try std.testing.expectEqualStrings("stop", c.finish_reason);
}

test "parseCompletion defensive failures return MalformedResponse without panic" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "not json <<<"));
    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "{\"choices\":[]}"));
    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "{}"));
    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "{\"choices\":[{\"message\":{}}]}"));
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

test {
    std.testing.refAllDecls(@This());
}
