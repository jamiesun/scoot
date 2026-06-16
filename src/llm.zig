//! LLM 后端适配：仅对接 OpenAI `/v1/chat/completions`（见 ROADMAP 非目标）。
//!
//! 铁律落地：
//!   #2 仅 OpenAI 协议；提供 schema 时强制 `response_format=json_schema` + `strict:true`。
//!   #4 绝不信任模型输出：响应一律走 std.json 防弹解析，脏数据返回错误（由上层包装成
//!      System Error 回灌重试），**绝不 panic**。
//! 内存：所有临时分配走调用方传入的 per-call arena；返回的 `content` 指向 arena，
//!       调用方需在 arena 释放前把它复制到长寿命存储（见 session.append）。
const std = @import("std");
const jsonio = @import("jsonio.zig");

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

/// 一次 chat/completions 的可选参数。
pub const ChatOptions = struct {
    /// JSON Schema 对象（原始 JSON 文本）。非 null 时强制结构化输出（铁律 #2）。
    json_schema: ?[]const u8 = null,
    /// json_schema 的名称（OpenAI 要求）。
    schema_name: []const u8 = "scoot_output",
    /// 采样温度；null 表示用后端默认。
    temperature: ?f32 = null,
};

/// 一次 chat/completions 的结果（已通过防弹 JSON 解析）。
pub const Completion = struct {
    content: []const u8,
    finish_reason: []const u8 = "",
};

pub const Client = struct {
    io: std.Io,
    base_url: []const u8,
    model: []const u8,
    /// API token；空串表示不带 Authorization（本地无鉴权后端）。明文仅在内存短暂存活。
    api_key: []const u8 = "",
    /// 自定义 CA bundle（PEM）绝对路径；null = 系统根证书自动扫描（嵌入式可指定）。
    ca_file: ?[]const u8 = null,
    /// 动态扩展请求体参数（透传）：原样合并进请求体顶层。见 config.Backend.extra_body。
    /// 仅接受 JSON 对象；非对象忽略。每个成员经 std.json 序列化，故请求体始终合法。
    extra_body: ?std.json.Value = null,

    pub fn init(io: std.Io, base_url: []const u8, model: []const u8, api_key: []const u8) Client {
        return .{ .io = io, .base_url = base_url, .model = model, .api_key = api_key };
    }

    /// 发起一次 chat/completions 请求并返回防弹解析后的结果。
    /// 失败（连接 / 非 2xx / 脏响应）返回错误而非 panic，交由上层决定重试或提示。
    pub fn chat(
        self: *Client,
        arena: std.mem.Allocator,
        messages: []const Message,
        opts: ChatOptions,
    ) !Completion {
        const body = try buildRequestBody(arena, self.model, messages, opts, self.extra_body);
        const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{self.base_url});

        var http_client: std.http.Client = .{ .allocator = arena, .io = self.io };
        defer http_client.deinit();

        // 自定义 CA：预填 bundle 并置 now 抑制系统扫描覆盖（嵌入式 HTTPS 后端）。
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
        if (code == 401 or code == 403) return error.Unauthorized;
        if (code < 200 or code >= 300) return error.BackendError;

        return parseCompletion(arena, resp.writer.buffered());
    }
};

/// 组装 OpenAI 请求体（紧凑 JSON）。提供 schema 时强制 response_format=json_schema/strict。
/// `extra_body` 非 null 时把其对象成员透传合并进顶层（动态扩展参数，如 service_tier）。
pub fn buildRequestBody(
    arena: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    opts: ChatOptions,
    extra_body: ?std.json.Value,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try jsonio.writeString(w, model);
    try w.writeAll(",\"stream\":false");
    if (opts.temperature) |t| try w.print(",\"temperature\":{d}", .{t});

    try w.writeAll(",\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"role\":\"");
        try w.writeAll(@tagName(m.role));
        try w.writeAll("\",\"content\":");
        try jsonio.writeString(w, m.content);
        try w.writeByte('}');
    }
    try w.writeByte(']');

    if (opts.json_schema) |schema| {
        try w.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try jsonio.writeString(w, opts.schema_name);
        try w.writeAll(",\"strict\":true,\"schema\":");
        try w.writeAll(schema); // 调用方提供的合法 JSON Schema 对象，原样注入
        try w.writeAll("}}");
    }

    if (extra_body) |extra| try writeExtraBody(w, extra);

    try w.writeByte('}');
    return aw.writer.buffered();
}

/// 把用户配置的 extra_body 对象成员注入请求体顶层（动态扩展参数）。
/// **防弹**：仅接受 JSON 对象，非对象一律忽略（坏配置不致畸形请求体）；
/// 每个成员值经 std.json 序列化为合法 JSON，故拼出的请求体始终合法。
/// 注入位置在末尾，故同名键由 extra_body 覆盖——配置方不应重定义 model/messages 等核心字段。
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

/// 防弹解析 chat/completions 响应，提取首个 choice 的 message.content。
/// 任何结构不符（非 JSON、无 choices、无 content）都返回 MalformedResponse，绝不 panic。
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

test "buildRequestBody 产出合法 JSON 且强制 json_schema/strict" {
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
    }, null);

    // 必须是合法 JSON
    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
    // 强制结构化输出
    try std.testing.expect(std.mem.indexOf(u8, body, "\"response_format\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"qwen2.5\"") != null);
}

test "buildRequestBody 注入 extra_body 扩展参数（动态透传）" {
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
    const body = try buildRequestBody(arena, "gpt-5.5", &msgs, .{}, parsed.value);

    // 扩展参数已透传进请求体
    try std.testing.expect(std.mem.indexOf(u8, body, "\"service_tier\":\"priority\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    // 仍是合法 JSON，核心字段未被破坏
    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5.5\"") != null);
}

test "buildRequestBody 忽略非对象 extra_body（防弹）" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "42", .{});
    defer parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msgs = [_]Message{.{ .role = .user, .content = "hi" }};
    const body = try buildRequestBody(arena, "m", &msgs, .{}, parsed.value);

    // 非对象被静默忽略：请求体仍合法，未把裸值 42 拼进去
    const v = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer v.deinit();
    try std.testing.expect(v.value == .object);
    try std.testing.expect(std.mem.indexOf(u8, body, ",42") == null);
}

test "parseCompletion 提取 content（正常响应）" {
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

test "parseCompletion 防弹：脏数据返回 MalformedResponse 而非 panic" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "not json <<<"));
    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "{\"choices\":[]}"));
    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "{}"));
    try std.testing.expectError(error.MalformedResponse, parseCompletion(arena, "{\"choices\":[{\"message\":{}}]}"));
}

test {
    std.testing.refAllDecls(@This());
}
