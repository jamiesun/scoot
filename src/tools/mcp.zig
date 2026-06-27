//! MCP client tool support. The agent exposes one stable meta-action,
//! `mcp_call`, while transports stay behind this module so stdio can ship first
//! and Streamable HTTP / legacy SSE can be added without changing agent flow.
const std = @import("std");
const jsonio = @import("../jsonio.zig");
const obs = @import("../obs.zig");

pub const protocol_version = "2025-06-18";

pub const TransportKind = enum {
    stdio,
    http,
    sse,

    pub fn fromString(s: []const u8) ?TransportKind {
        if (std.mem.eql(u8, s, "stdio")) return .stdio;
        if (std.mem.eql(u8, s, "http") or std.mem.eql(u8, s, "streamable_http")) return .http;
        if (std.mem.eql(u8, s, "sse")) return .sse;
        return null;
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Header = struct {
    name: []const u8,
    /// Literal non-secret value. Prefer value_env for credentials.
    value: ?[]const u8 = null,
    /// Environment variable containing the value. Missing or empty env fails closed.
    value_env: ?[]const u8 = null,
    /// Optional prefix prepended to either value source, e.g. "Bearer ".
    prefix: []const u8 = "",
};

pub const Server = struct {
    name: []const u8 = "",
    transport: []const u8 = "stdio",
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    env: []const EnvVar = &.{},
    allowed_tools: []const []const u8 = &.{},
    /// Declarative human-readable posture for future policy expansion. The MVP
    /// still requires `allowed_tools` and global policy guard approval.
    policy: []const u8 = "readonly",
    /// Reserved for Streamable HTTP / legacy SSE transports.
    url: ?[]const u8 = null,
    /// Extra HTTP headers for remote transports. Use value_env for secrets.
    headers: []const Header = &.{},
};

pub const CallArgs = struct {
    server: []const u8,
    tool: []const u8,
    args: ?std.json.Value = null,
};

pub const Options = struct {
    timeout_ms: u64 = 30_000,
    stdout_limit: usize = 1 << 20,
    stderr_limit: usize = 1 << 20,
    ca_file: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
};

pub fn findServer(servers: []const Server, name: []const u8) ?Server {
    for (servers) |server| {
        if (std.mem.eql(u8, server.name, name)) return server;
    }
    return null;
}

pub fn toolAllowed(server: Server, tool: []const u8) bool {
    if (server.allowed_tools.len == 0) return false;
    for (server.allowed_tools) |allowed| {
        if (std.mem.eql(u8, allowed, tool)) return true;
    }
    return false;
}

pub fn call(
    arena: std.mem.Allocator,
    io: std.Io,
    server: Server,
    tool: []const u8,
    args: ?std.json.Value,
    opts: Options,
) ![]const u8 {
    if (server.name.len == 0) return error.McpServerNotFound;
    if (!toolAllowed(server, tool)) return error.McpToolNotAllowed;
    if (args) |v| if (v != .object) return error.McpArgsMustBeObject;

    const kind = TransportKind.fromString(server.transport) orelse return error.UnsupportedMcpTransport;
    const transport: Transport = switch (kind) {
        .stdio => .{ .stdio = .{} },
        .http => .{ .http = .{} },
        .sse => .{ .sse = .{} },
    };
    return transport.call(arena, io, server, tool, args, opts);
}

const Transport = union(TransportKind) {
    stdio: StdioTransport,
    http: HttpTransport,
    sse: SseTransport,

    fn call(
        self: Transport,
        arena: std.mem.Allocator,
        io: std.Io,
        server: Server,
        tool: []const u8,
        args: ?std.json.Value,
        opts: Options,
    ) ![]const u8 {
        return switch (self) {
            .stdio => |t| t.call(arena, io, server, tool, args, opts),
            .http => |t| t.call(arena, io, server, tool, args, opts),
            .sse => |t| t.call(arena, io, server, tool, args, opts),
        };
    }
};

const HttpTransport = struct {
    fn call(
        _: HttpTransport,
        arena: std.mem.Allocator,
        io: std.Io,
        server: Server,
        tool: []const u8,
        args: ?std.json.Value,
        opts: Options,
    ) ![]const u8 {
        const url = server.url orelse return error.McpMissingUrl;
        var session_id: ?[]const u8 = null;

        const init = try initializeRequest(arena);
        const init_resp = try postJson(arena, io, server, url, init, session_id, opts);
        if (!statusOk(init_resp.status)) return error.McpHttpStatus;
        session_id = init_resp.session_id orelse session_id;
        _ = try responseValue(arena, init_resp.body, 1);

        const initialized = try initializedNotification(arena);
        const initialized_resp = try postJson(arena, io, server, url, initialized, session_id, opts);
        if (!statusOkOrAccepted(initialized_resp.status)) return error.McpHttpStatus;

        const list = try toolsListRequest(arena);
        const list_resp = try postJson(arena, io, server, url, list, session_id, opts);
        if (!statusOk(list_resp.status)) return error.McpHttpStatus;
        _ = try responseValue(arena, list_resp.body, 2);

        const call_req = try toolsCallRequest(arena, tool, args);
        const call_resp = try postJson(arena, io, server, url, call_req, session_id, opts);
        if (!statusOk(call_resp.status)) return error.McpHttpStatus;
        return try formatResponse(arena, server.name, tool, call_resp.body, "");
    }
};

const SseTransport = struct {
    fn call(
        _: SseTransport,
        arena: std.mem.Allocator,
        io: std.Io,
        server: Server,
        tool: []const u8,
        args: ?std.json.Value,
        opts: Options,
    ) ![]const u8 {
        // One cumulative deadline bounds the whole SSE session: connection setup,
        // receiveHead, every POST, and every event read. Per-operation timeouts
        // alone let the initial GET/receiveHead block forever and let
        // readSseResponse re-arm a fresh per-event timeout indefinitely against a
        // slow or hostile server. Running the inner session with timeout_ms = 0
        // keeps it blocking (no nested Select); the deadline arm cancels it.
        if (opts.timeout_ms == 0) return sseSession(arena, io, server, tool, args, opts);

        var inner_opts = opts;
        inner_opts.timeout_ms = 0;

        const Outcome = union(enum) { done: SseCallAttempt, timed_out: void };
        var buf: [2]Outcome = undefined;
        var sel = std.Io.Select(Outcome).init(io, &buf);
        sel.concurrent(.done, sseSessionAttempt, .{ arena, io, server, tool, args, inner_opts }) catch {
            return sseSession(arena, io, server, tool, args, opts);
        };
        sel.concurrent(.timed_out, sleepDeadline, .{ io, opts.timeout_ms }) catch {
            sel.cancelDiscard();
            return sseSession(arena, io, server, tool, args, opts);
        };

        const winner = sel.await() catch {
            sel.cancelDiscard();
            return error.Canceled;
        };
        sel.cancelDiscard();
        return switch (winner) {
            .done => |r| switch (r) {
                .ok => |body| body,
                .err => |err| err,
            },
            .timed_out => error.Timeout,
        };
    }
};

const SseCallAttempt = union(enum) {
    ok: []const u8,
    err: anyerror,
};

fn sseSessionAttempt(
    arena: std.mem.Allocator,
    io: std.Io,
    server: Server,
    tool: []const u8,
    args: ?std.json.Value,
    opts: Options,
) SseCallAttempt {
    return .{ .ok = sseSession(arena, io, server, tool, args, opts) catch |err| return .{ .err = err } };
}

fn sseSession(
    arena: std.mem.Allocator,
    io: std.Io,
    server: Server,
    tool: []const u8,
    args: ?std.json.Value,
    opts: Options,
) ![]const u8 {
    const sse_url = server.url orelse return error.McpMissingUrl;

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    try configureCa(arena, io, &client, opts.ca_file);

    const uri = try std.Uri.parse(sse_url);
    var req = try client.request(.GET, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = try extraHeaders(arena, server, null, "text/event-stream", opts),
        .keep_alive = false,
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (!statusOk(@intFromEnum(response.head.status))) return error.McpHttpStatus;

    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    const endpoint_event = try readSseEvent(arena, io, reader, opts);
    if (!std.mem.eql(u8, endpoint_event.event, "endpoint")) return error.McpProtocolError;
    const endpoint = try resolveEndpoint(arena, sse_url, endpoint_event.data);

    const init = try initializeRequest(arena);
    try postSseMessage(arena, io, server, endpoint, init, opts);
    _ = try readSseResponse(arena, io, reader, 1, opts);

    const initialized = try initializedNotification(arena);
    try postSseMessage(arena, io, server, endpoint, initialized, opts);

    const list = try toolsListRequest(arena);
    try postSseMessage(arena, io, server, endpoint, list, opts);
    _ = try readSseResponse(arena, io, reader, 2, opts);

    const call_req = try toolsCallRequest(arena, tool, args);
    try postSseMessage(arena, io, server, endpoint, call_req, opts);
    const body = try readSseResponse(arena, io, reader, 3, opts);
    return try formatResponse(arena, server.name, tool, body, "");
}

const StdioTransport = struct {
    fn call(
        _: StdioTransport,
        arena: std.mem.Allocator,
        io: std.Io,
        server: Server,
        tool: []const u8,
        args: ?std.json.Value,
        opts: Options,
    ) ![]const u8 {
        if (server.command.len == 0) return error.McpMissingCommand;

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, server.command);
        for (server.args) |arg| try argv.append(arena, arg);

        var env_map: ?std.process.Environ.Map = null;
        defer if (env_map) |*m| m.deinit();
        if (server.env.len != 0) {
            env_map = std.process.Environ.Map.init(arena);
            for (server.env) |kv| {
                if (kv.name.len == 0) return error.McpInvalidEnv;
                try env_map.?.put(kv.name, kv.value);
            }
        }

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .environ_map = if (env_map) |*m| m else null,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        defer child.kill(io);

        const input = try requestStream(arena, tool, args);
        try writeStdinWithTimeout(io, child.stdin.?, input, opts.timeout_ms);
        child.stdin.?.close(io);
        child.stdin = null;

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(arena, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();

        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);
        const timeout = deadline(io, opts.timeout_ms);
        while (multi_reader.fill(64, timeout)) |_| {
            if (opts.stdout_limit != 0 and stdout_reader.buffered().len > opts.stdout_limit)
                return error.McpOutputTooLarge;
            if (opts.stderr_limit != 0 and stderr_reader.buffered().len > opts.stderr_limit)
                return error.McpOutputTooLarge;
        } else |err| switch (err) {
            error.EndOfStream => {},
            error.Timeout => return error.Timeout,
            else => |e| return e,
        }

        try multi_reader.checkAnyError();

        const stdout = try multi_reader.toOwnedSlice(0);
        const stderr = try multi_reader.toOwnedSlice(1);
        return try formatResponse(arena, server.name, tool, stdout, stderr);
    }
};

const StdinWriteAttempt = union(enum) {
    ok: void,
    err: anyerror,
};

fn writeStdin(io: std.Io, file: std.Io.File, input: []const u8) !void {
    file.writeStreamingAll(io, input) catch |err| switch (err) {
        // The server closed its stdin read end: it does not consume the request
        // (or exited early). That is not fatal here; fall through and read
        // whatever it produced so the response/error path stays authoritative.
        error.BrokenPipe => {},
        else => return error.McpWriteFailed,
    };
}

fn writeStdinAttempt(io: std.Io, file: std.Io.File, input: []const u8) StdinWriteAttempt {
    writeStdin(io, file, input) catch |err| return .{ .err = err };
    return .{ .ok = {} };
}

// Bound the stdin write with a hard timeout. Without it a server that stays
// alive but never drains its stdin blocks writeStreamingAll forever once the OS
// pipe buffer fills (the request is model-controlled and uncapped), and the
// `defer child.kill` can never run because we are stuck inside the write.
fn writeStdinWithTimeout(io: std.Io, file: std.Io.File, input: []const u8, timeout_ms: u64) !void {
    if (timeout_ms == 0) return writeStdin(io, file, input);

    const Outcome = union(enum) { done: StdinWriteAttempt, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.done, writeStdinAttempt, .{ io, file, input }) catch {
        return writeStdin(io, file, input);
    };
    sel.concurrent(.timed_out, sleepDeadline, .{ io, timeout_ms }) catch {
        sel.cancelDiscard();
        return writeStdin(io, file, input);
    };

    const winner = sel.await() catch {
        sel.cancelDiscard();
        return error.Canceled;
    };
    sel.cancelDiscard();
    return switch (winner) {
        .done => |r| switch (r) {
            .ok => {},
            .err => |err| err,
        },
        .timed_out => error.Timeout,
    };
}

fn deadline(io: std.Io, timeout_ms: u64) std.Io.Timeout {
    if (timeout_ms == 0) return .none;
    const base: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
    } };
    return base.toDeadline(io);
}

fn requestStream(arena: std.mem.Allocator, tool: []const u8, args: ?std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll(try initializeRequest(arena));
    try w.writeByte('\n');
    try w.writeAll(try initializedNotification(arena));
    try w.writeByte('\n');
    try w.writeAll(try toolsListRequest(arena));
    try w.writeByte('\n');
    try w.writeAll(try toolsCallRequest(arena, tool, args));
    try w.writeByte('\n');

    return aw.written();
}

fn initializeRequest(arena: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":");
    try jsonio.writeString(w, protocol_version);
    try w.writeAll(",\"capabilities\":{},\"clientInfo\":{\"name\":\"scoot\",\"version\":\"0\"}}}");
    return aw.written();
}

fn initializedNotification(arena: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{{}}}}", .{});
}

fn toolsListRequest(arena: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{{}}}}", .{});
}

fn toolsCallRequest(arena: std.mem.Allocator, tool: []const u8, args: ?std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":");
    try jsonio.writeString(w, tool);
    try w.writeAll(",\"arguments\":");
    if (args) |v| {
        try w.print("{f}", .{std.json.fmt(v, .{})});
    } else {
        try w.writeAll("{}");
    }
    try w.writeAll("}}");
    return aw.written();
}

const HttpExchange = struct {
    status: u16,
    body: []const u8,
    session_id: ?[]const u8 = null,
};

fn postJson(
    arena: std.mem.Allocator,
    io: std.Io,
    server: Server,
    url: []const u8,
    payload: []const u8,
    session_id: ?[]const u8,
    opts: Options,
) !HttpExchange {
    if (opts.timeout_ms == 0) return doPostJson(arena, io, server, url, payload, session_id, opts);

    const Outcome = union(enum) { done: PostAttempt, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.done, doPostJsonAttempt, .{ arena, io, server, url, payload, session_id, opts }) catch {
        return doPostJson(arena, io, server, url, payload, session_id, opts);
    };
    sel.concurrent(.timed_out, sleepDeadline, .{ io, opts.timeout_ms }) catch {
        sel.cancelDiscard();
        return doPostJson(arena, io, server, url, payload, session_id, opts);
    };

    const winner = sel.await() catch {
        sel.cancelDiscard();
        return error.Canceled;
    };
    sel.cancelDiscard();
    return switch (winner) {
        .done => |r| switch (r) {
            .ok => |exchange| exchange,
            .err => |err| err,
        },
        .timed_out => error.Timeout,
    };
}

const PostAttempt = union(enum) {
    ok: HttpExchange,
    err: anyerror,
};

fn doPostJsonAttempt(
    arena: std.mem.Allocator,
    io: std.Io,
    server: Server,
    url: []const u8,
    payload: []const u8,
    session_id: ?[]const u8,
    opts: Options,
) PostAttempt {
    return .{ .ok = doPostJson(arena, io, server, url, payload, session_id, opts) catch |err| return .{ .err = err } };
}

fn doPostJson(
    arena: std.mem.Allocator,
    io: std.Io,
    server: Server,
    url: []const u8,
    payload: []const u8,
    session_id: ?[]const u8,
    opts: Options,
) !HttpExchange {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    try configureCa(arena, io, &client, opts.ca_file);

    const uri = try std.Uri.parse(url);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = try extraHeaders(arena, server, session_id, "application/json, text/event-stream", opts),
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    const sid = try responseSessionId(arena, response.head);

    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    if (opts.stdout_limit != 0 and out.written().len > opts.stdout_limit) return error.McpOutputTooLarge;
    return .{ .status = status, .body = out.written(), .session_id = sid };
}

fn postSseMessage(arena: std.mem.Allocator, io: std.Io, server: Server, url: []const u8, payload: []const u8, opts: Options) !void {
    const resp = try postJson(arena, io, server, url, payload, null, opts);
    if (!statusOkOrAccepted(resp.status)) return error.McpHttpStatus;
}

fn responseSessionId(arena: std.mem.Allocator, head: std.http.Client.Response.Head) !?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "mcp-session-id"))
            return @as(?[]const u8, try arena.dupe(u8, h.value));
    }
    return null;
}

fn extraHeaders(
    arena: std.mem.Allocator,
    server: Server,
    session_id: ?[]const u8,
    accept: []const u8,
    opts: Options,
) ![]const std.http.Header {
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(arena, .{ .name = "Accept", .value = accept });
    try headers.append(arena, .{ .name = "MCP-Protocol-Version", .value = protocol_version });
    if (session_id) |sid| try headers.append(arena, .{ .name = "Mcp-Session-Id", .value = sid });

    for (server.headers) |h| {
        try validateUserHeader(h);
        try headers.append(arena, .{
            .name = h.name,
            .value = try resolveHeaderValue(arena, h, opts.env),
        });
    }
    return headers.items;
}

fn validateUserHeader(h: Header) !void {
    if (!validHeaderName(h.name)) return error.McpInvalidHeader;
    if (isReservedHeaderName(h.name)) return error.McpInvalidHeader;
    const has_value = h.value != null;
    const has_env = h.value_env != null;
    if (has_value == has_env) return error.McpInvalidHeader;
    if (h.value_env) |name| if (name.len == 0) return error.McpInvalidHeader;
    if (headerValueHasNewline(h.prefix)) return error.McpInvalidHeader;
    if (h.value) |value| if (headerValueHasNewline(value)) return error.McpInvalidHeader;
}

fn resolveHeaderValue(arena: std.mem.Allocator, h: Header, env: ?*const std.process.Environ.Map) ![]const u8 {
    const raw = if (h.value) |value|
        value
    else blk: {
        const map = env orelse return error.McpMissingHeaderEnv;
        const name = h.value_env orelse return error.McpInvalidHeader;
        const value = map.get(name) orelse return error.McpMissingHeaderEnv;
        if (value.len == 0) return error.McpMissingHeaderEnv;
        break :blk value;
    };
    // Env-sourced values never pass through validateUserHeader, so re-check the
    // resolved value here. Without this an environment variable carrying CRLF
    // could split the header and inject additional request headers.
    if (headerValueHasNewline(raw)) return error.McpInvalidHeader;
    if (h.prefix.len == 0) return raw;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ h.prefix, raw });
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c <= 0x20 or c >= 0x7f or c == ':') return false;
    }
    return true;
}

fn headerValueHasNewline(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '\r') != null or
        std.mem.indexOfScalar(u8, value, '\n') != null;
}

fn isReservedHeaderName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "accept") or
        std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "mcp-protocol-version") or
        std.ascii.eqlIgnoreCase(name, "mcp-session-id");
}

fn configureCa(arena: std.mem.Allocator, io: std.Io, client: *std.http.Client, ca_file: ?[]const u8) !void {
    if (ca_file) |path| {
        const now = std.Io.Clock.real.now(io);
        try client.ca_bundle.addCertsFromFilePathAbsolute(arena, io, now, path);
        client.now = now;
    }
}

fn sleepDeadline(io: std.Io, timeout_ms: u64) void {
    const d: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    };
    d.sleep(io) catch {};
}

fn statusOk(status: u16) bool {
    return status >= 200 and status < 300 and status != 202;
}

fn statusOkOrAccepted(status: u16) bool {
    return status >= 200 and status < 300;
}

fn responseValue(arena: std.mem.Allocator, body: []const u8, want_id: i64) !std.json.Value {
    return findResponse(arena, body, want_id);
}

fn formatResponse(
    arena: std.mem.Allocator,
    server: []const u8,
    tool: []const u8,
    stdout: []const u8,
    stderr: []const u8,
) ![]const u8 {
    const response = findResponse(arena, stdout, 3) catch |err| switch (err) {
        error.McpProtocolError => return std.fmt.allocPrint(
            arena,
            "[Observation] mcp {s}/{s} protocol error: did not find a JSON-RPC response for tools/call id=3. stderr:\n{s}\nstdout sample:\n{s}",
            .{ server, tool, try obs.truncateTokens(arena, stderr, 200), try obs.truncateTokens(arena, stdout, 500) },
        ),
        else => return err,
    };

    if (response.object.get("error")) |err_value| {
        return std.fmt.allocPrint(
            arena,
            "[Observation] mcp {s}/{s} JSON-RPC error: {s}\nstderr:\n{s}",
            .{ server, tool, try jsonValueString(arena, err_value), try obs.truncateTokens(arena, stderr, 200) },
        );
    }

    const result = response.object.get("result") orelse return error.McpProtocolError;
    const body = try toolResultText(arena, result);
    if (stderr.len == 0) {
        return std.fmt.allocPrint(arena, "[Observation] mcp {s}/{s} returned:\n{s}", .{ server, tool, body });
    }
    return std.fmt.allocPrint(
        arena,
        "[Observation] mcp {s}/{s} returned:\n{s}\n--- stderr ---\n{s}",
        .{ server, tool, body, try obs.truncateTokens(arena, stderr, 200) },
    );
}

fn findResponse(arena: std.mem.Allocator, stdout: []const u8, want_id: i64) !std.json.Value {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (value != .object) continue;
        const idv = value.object.get("id") orelse continue;
        if (idMatches(idv, want_id)) return value;
    }
    if (findSseResponse(arena, stdout, want_id)) |value| return value else |err| switch (err) {
        error.McpProtocolError => {},
        else => |e| return e,
    }
    return error.McpProtocolError;
}

const SseEvent = struct {
    event: []const u8 = "message",
    data: []const u8,
};

fn findSseResponse(arena: std.mem.Allocator, text: []const u8, want_id: i64) !std.json.Value {
    var data: std.ArrayList(u8) = .empty;
    var saw_data = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) {
            if (saw_data) {
                if (try parseMaybeWantedResponse(arena, data.items, want_id)) |value| return value;
                data.clearRetainingCapacity();
                saw_data = false;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            if (data.items.len != 0) try data.append(arena, '\n');
            try data.appendSlice(arena, std.mem.trim(u8, line["data:".len..], " "));
            saw_data = true;
        }
    }
    if (saw_data) {
        if (try parseMaybeWantedResponse(arena, data.items, want_id)) |value| return value;
    }
    return error.McpProtocolError;
}

fn parseMaybeWantedResponse(arena: std.mem.Allocator, data: []const u8, want_id: i64) !?std.json.Value {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (value != .object) return null;
    const idv = value.object.get("id") orelse return null;
    return if (idMatches(idv, want_id)) value else null;
}

fn readSseResponse(
    arena: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    want_id: i64,
    opts: Options,
) ![]const u8 {
    while (true) {
        const event = try readSseEvent(arena, io, reader, opts);
        if (event.data.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, event.data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (value != .object) continue;
        const idv = value.object.get("id") orelse continue;
        if (idMatches(idv, want_id)) return event.data;
    }
}

fn readSseEvent(
    arena: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    opts: Options,
) !SseEvent {
    if (opts.timeout_ms == 0) return readSseEventBlocking(arena, reader, opts.stdout_limit);

    const Outcome = union(enum) { event: SseAttempt, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);
    sel.concurrent(.event, readSseEventAttempt, .{ arena, reader, opts.stdout_limit }) catch {
        return readSseEventBlocking(arena, reader, opts.stdout_limit);
    };
    sel.concurrent(.timed_out, sleepDeadline, .{ io, opts.timeout_ms }) catch {
        sel.cancelDiscard();
        return readSseEventBlocking(arena, reader, opts.stdout_limit);
    };

    const winner = sel.await() catch {
        sel.cancelDiscard();
        return error.Canceled;
    };
    sel.cancelDiscard();
    return switch (winner) {
        .event => |attempt| switch (attempt) {
            .ok => |event| event,
            .err => |err| err,
        },
        .timed_out => error.Timeout,
    };
}

const SseAttempt = union(enum) {
    ok: SseEvent,
    err: anyerror,
};

fn readSseEventAttempt(arena: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) SseAttempt {
    return .{ .ok = readSseEventBlocking(arena, reader, limit) catch |err| return .{ .err = err } };
}

fn readSseEventBlocking(arena: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) !SseEvent {
    var event_name: []const u8 = "message";
    var data: std.ArrayList(u8) = .empty;
    while (true) {
        const maybe_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.McpOutputTooLarge,
            else => |e| return e,
        };
        const raw = maybe_line orelse {
            if (data.items.len == 0) return error.McpProtocolError;
            return .{ .event = event_name, .data = data.items };
        };
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) {
            if (data.items.len == 0) continue;
            return .{ .event = event_name, .data = data.items };
        }
        if (std.mem.startsWith(u8, line, "event:")) {
            event_name = try arena.dupe(u8, std.mem.trim(u8, line["event:".len..], " \t"));
        } else if (std.mem.startsWith(u8, line, "data:")) {
            if (data.items.len != 0) try data.append(arena, '\n');
            try data.appendSlice(arena, std.mem.trim(u8, line["data:".len..], " "));
            if (limit != 0 and data.items.len > limit) return error.McpOutputTooLarge;
        }
    }
}

fn resolveEndpoint(arena: std.mem.Allocator, base: []const u8, endpoint_raw: []const u8) ![]const u8 {
    const endpoint = std.mem.trim(u8, endpoint_raw, " \t\r\n");
    if (std.mem.startsWith(u8, endpoint, "http://") or std.mem.startsWith(u8, endpoint, "https://"))
        return arena.dupe(u8, endpoint);

    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return error.McpProtocolError;
    const authority_start = scheme_end + "://".len;
    const path_start = std.mem.indexOfScalarPos(u8, base, authority_start, '/') orelse base.len;
    if (std.mem.startsWith(u8, endpoint, "/")) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ base[0..path_start], endpoint });
    }
    const dir_end = if (std.mem.lastIndexOfScalar(u8, base[path_start..], '/')) |rel|
        path_start + rel + 1
    else
        base.len;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ base[0..dir_end], endpoint });
}

fn idMatches(v: std.json.Value, want: i64) bool {
    return switch (v) {
        .integer => |n| n == want,
        .number_string => |s| blk: {
            const n = std.fmt.parseInt(i64, s, 10) catch break :blk false;
            break :blk n == want;
        },
        else => false,
    };
}

fn toolResultText(arena: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    if (result != .object) return jsonValueString(arena, result);
    const is_error = if (result.object.get("isError")) |v| v == .bool and v.bool else false;
    if (result.object.get("content")) |content| {
        if (content == .array) {
            var out: std.ArrayList(u8) = .empty;
            if (is_error) try out.appendSlice(arena, "[MCP tool reported isError=true]\n");
            for (content.array.items, 0..) |item, idx| {
                if (idx != 0) try out.append(arena, '\n');
                try out.appendSlice(arena, try contentItemText(arena, item));
            }
            return obs.truncateTokens(arena, out.items, 1200);
        }
    }
    return obs.truncateTokens(arena, try jsonValueString(arena, result), 1200);
}

fn contentItemText(arena: std.mem.Allocator, item: std.json.Value) ![]const u8 {
    if (item == .object) {
        const ty = item.object.get("type");
        const text = item.object.get("text");
        if (ty != null and text != null and ty.? == .string and text.? == .string and std.mem.eql(u8, ty.?.string, "text"))
            return text.?.string;
    }
    return jsonValueString(arena, item);
}

fn jsonValueString(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.print("{f}", .{std.json.fmt(value, .{})});
    return aw.written();
}

test "mcp: stdio request stream contains initialize/list/call" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"x\":1}", .{});
    const got = try requestStream(arena, "echo", args);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"method\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"method\":\"tools/list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"method\":\"tools/call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"arguments\":{\"x\":1}") != null);
}

test "mcp: HTTP request builders emit single JSON-RPC messages" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"city\":\"London\"}", .{});

    const init = try initializeRequest(arena);
    try std.testing.expect(std.mem.indexOf(u8, init, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, init, "\"method\":\"initialize\"") != null);

    const call_req = try toolsCallRequest(arena, "weather", args);
    try std.testing.expect(std.mem.indexOf(u8, call_req, "\"id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_req, "\"method\":\"tools/call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_req, "\"arguments\":{\"city\":\"London\"}") != null);
}

test "mcp: remote headers resolve env credentials and reject protocol overrides" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("REMOTE_MCP_TOKEN", "sekret");

    const headers = try extraHeaders(arena, .{
        .name = "remote",
        .headers = &.{
            .{ .name = "Authorization", .value_env = "REMOTE_MCP_TOKEN", .prefix = "Bearer " },
            .{ .name = "X-Client", .value = "scoot-test" },
        },
    }, "sid-1", "application/json", .{ .env = &env });
    try std.testing.expectEqual(@as(usize, 5), headers.len);
    try std.testing.expectEqualStrings("Mcp-Session-Id", headers[2].name);
    try std.testing.expectEqualStrings("Authorization", headers[3].name);
    try std.testing.expectEqualStrings("Bearer sekret", headers[3].value);
    try std.testing.expectEqualStrings("X-Client", headers[4].name);
    try std.testing.expectEqualStrings("scoot-test", headers[4].value);

    try std.testing.expectError(error.McpInvalidHeader, extraHeaders(arena, .{
        .name = "remote",
        .headers = &.{.{ .name = "MCP-Protocol-Version", .value = "bad" }},
    }, null, "application/json", .{}));
    try std.testing.expectError(error.McpMissingHeaderEnv, extraHeaders(arena, .{
        .name = "remote",
        .headers = &.{.{ .name = "Authorization", .value_env = "MISSING", .prefix = "Bearer " }},
    }, null, "application/json", .{ .env = &env }));
}

test "mcp: env-sourced header values with CRLF are rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    // A CRLF in an env-resolved value must not be able to inject extra headers.
    try env.put("CRLF_TOKEN", "sekret\r\nX-Injected: 1");
    try std.testing.expectError(error.McpInvalidHeader, extraHeaders(arena, .{
        .name = "remote",
        .headers = &.{.{ .name = "Authorization", .value_env = "CRLF_TOKEN", .prefix = "Bearer " }},
    }, null, "application/json", .{ .env = &env }));

    // A bare newline (no carriage return) is rejected too.
    try env.put("LF_TOKEN", "a\nb");
    try std.testing.expectError(error.McpInvalidHeader, extraHeaders(arena, .{
        .name = "remote",
        .headers = &.{.{ .name = "X-Custom", .value_env = "LF_TOKEN" }},
    }, null, "application/json", .{ .env = &env }));

    // A clean env value still resolves normally.
    try env.put("OK_TOKEN", "clean-value");
    const headers = try extraHeaders(arena, .{
        .name = "remote",
        .headers = &.{.{ .name = "X-Custom", .value_env = "OK_TOKEN" }},
    }, null, "application/json", .{ .env = &env });
    try std.testing.expectEqualStrings("clean-value", headers[headers.len - 1].value);
}

// Each stdio test spawns `/bin/sh <script>`, and the shell opens the script
// asynchronously at exec time. A shared /tmp path lets a concurrently-running
// test binary's deleteTree remove the script first, so the parallel test
// artifacts race (issue #122). Make every temp dir unique per process.
fn testTmpDir(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const pid: i64 = @intCast(std.posix.system.getpid());
    return std.fmt.allocPrint(arena, "/tmp/{s}_{d}", .{ name, pid });
}

test "mcp: stdio fake server formats tools/call result" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const dir = try testTmpDir(arena, "scoot_mcp_fake");
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const script = try std.fmt.allocPrint(arena, "{s}/server.sh", .{dir});
    try cwd.writeFile(io, .{ .sub_path = script, .data =
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"id":1'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}' ;;
        \\    *'"id":2'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}' ;;
        \\    *'"id":3'*) printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"pong"}],"isError":false}}' ;;
        \\  esac
        \\done
        \\
    });

    const out = try call(arena, io, .{
        .name = "fake",
        .transport = "stdio",
        .command = "/bin/sh",
        .args = &.{script},
        .allowed_tools = &.{"echo"},
    }, "echo", null, .{ .timeout_ms = 5_000 });
    try std.testing.expect(std.mem.indexOf(u8, out, "mcp fake/echo returned") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pong") != null);
}

test "mcp: JSON-RPC error and missing call response become observations" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rpc_error = try formatResponse(
        arena,
        "fake",
        "lookup",
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        \\not json
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"bad args"}}
        \\
    ,
        "server warned",
    );
    try std.testing.expect(std.mem.indexOf(u8, rpc_error, "JSON-RPC error") != null);
    try std.testing.expect(std.mem.indexOf(u8, rpc_error, "\"message\":\"bad args\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rpc_error, "server warned") != null);

    const missing = try formatResponse(
        arena,
        "fake",
        "lookup",
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}
        \\
    ,
        "stderr marker",
    );
    try std.testing.expect(std.mem.indexOf(u8, missing, "protocol error") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "stderr marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"id\":2") != null);
}

test "mcp: tool result preserves isError and non-text content" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"content":[{"type":"text","text":"first"},{"type":"image","data":"abc"}],"isError":true}
    , .{});
    const out = try toolResultText(arena, value);
    try std.testing.expect(std.mem.indexOf(u8, out, "[MCP tool reported isError=true]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"image\"") != null);
}

test "mcp: stdio passes configured environment and rejects invalid env" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    try std.testing.expectError(error.McpInvalidEnv, call(arena, io, .{
        .name = "fake",
        .transport = "stdio",
        .command = "/bin/true",
        .allowed_tools = &.{"echo"},
        .env = &.{.{ .name = "", .value = "bad" }},
    }, "echo", null, .{ .timeout_ms = 5_000 }));

    const dir = try testTmpDir(arena, "scoot_mcp_env_fake");
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const script = try std.fmt.allocPrint(arena, "{s}/server.sh", .{dir});
    try cwd.writeFile(io, .{ .sub_path = script, .data =
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"id":1'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}' ;;
        \\    *'"id":2'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}' ;;
        \\    *'"id":3'*) printf '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"%s"}],"isError":false}}\n' "$MCP_TEST_VALUE" ;;
        \\  esac
        \\done
        \\
    });

    const out = try call(arena, io, .{
        .name = "fake",
        .transport = "stdio",
        .command = "/bin/sh",
        .args = &.{script},
        .allowed_tools = &.{"echo"},
        .env = &.{.{ .name = "MCP_TEST_VALUE", .value = "from-env" }},
    }, "echo", null, .{ .timeout_ms = 5_000 });
    try std.testing.expect(std.mem.indexOf(u8, out, "from-env") != null);
}

test "mcp: stdio enforces output limits and timeout" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const noisy_dir = try testTmpDir(arena, "scoot_mcp_noisy_fake");
    cwd.deleteTree(io, noisy_dir) catch {};
    defer cwd.deleteTree(io, noisy_dir) catch {};
    try cwd.createDirPath(io, noisy_dir);
    const noisy_script = try std.fmt.allocPrint(arena, "{s}/server.sh", .{noisy_dir});
    try cwd.writeFile(io, .{ .sub_path = noisy_script, .data =
        \\#!/bin/sh
        \\printf '%s\n' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        \\
    });
    try std.testing.expectError(error.McpOutputTooLarge, call(arena, io, .{
        .name = "fake",
        .transport = "stdio",
        .command = "/bin/sh",
        .args = &.{noisy_script},
        .allowed_tools = &.{"echo"},
    }, "echo", null, .{ .timeout_ms = 5_000, .stdout_limit = 8 }));

    const sleepy_dir = try testTmpDir(arena, "scoot_mcp_sleepy_fake");
    cwd.deleteTree(io, sleepy_dir) catch {};
    defer cwd.deleteTree(io, sleepy_dir) catch {};
    try cwd.createDirPath(io, sleepy_dir);
    const sleepy_script = try std.fmt.allocPrint(arena, "{s}/server.sh", .{sleepy_dir});
    try cwd.writeFile(io, .{ .sub_path = sleepy_script, .data =
        \\#!/bin/sh
        \\sleep 1
        \\
    });
    try std.testing.expectError(error.Timeout, call(arena, io, .{
        .name = "fake",
        .transport = "stdio",
        .command = "/bin/sh",
        .args = &.{sleepy_script},
        .allowed_tools = &.{"echo"},
    }, "echo", null, .{ .timeout_ms = 20 }));
}

test "mcp: stdio stdin write times out when the server never reads stdin" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const pid = std.posix.system.getpid();
    const dir = try std.fmt.allocPrint(arena, "/tmp/scoot_mcp_write_block_{d}", .{pid});
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const script = try std.fmt.allocPrint(arena, "{s}/server.sh", .{dir});
    // Stays alive but never reads stdin, so once the OS pipe buffer fills the
    // client's stdin write blocks indefinitely.
    try cwd.writeFile(io, .{ .sub_path = script, .data =
        \\#!/bin/sh
        \\sleep 5
        \\
    });

    // Oversized, model-controlled arguments that exceed any default pipe buffer.
    const big = try arena.alloc(u8, 2 * 1024 * 1024);
    @memset(big, 'a');
    const args_json = try std.fmt.allocPrint(arena, "{{\"data\":\"{s}\"}}", .{big});
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{});

    try std.testing.expectError(error.Timeout, call(arena, io, .{
        .name = "fake",
        .transport = "stdio",
        .command = "/bin/sh",
        .args = &.{script},
        .allowed_tools = &.{"echo"},
    }, "echo", args, .{ .timeout_ms = 100 }));
}

test "mcp: allowed tools fail closed and streamable_http aliases http" {
    try std.testing.expect(!toolAllowed(.{ .name = "s" }, "read"));
    try std.testing.expect(toolAllowed(.{ .name = "s", .allowed_tools = &.{"read"} }, "read"));
    try std.testing.expectEqual(TransportKind.http, TransportKind.fromString("streamable_http").?);
    try std.testing.expectError(error.McpToolNotAllowed, call(std.testing.allocator, std.testing.io, .{
        .name = "s",
        .transport = "stdio",
        .command = "/bin/true",
    }, "read", null, .{}));
    try std.testing.expectError(error.UnsupportedMcpTransport, call(std.testing.allocator, std.testing.io, .{
        .name = "s",
        .transport = "websocket",
        .allowed_tools = &.{"read"},
    }, "read", null, .{}));
}

test "mcp: SSE response body can carry JSON-RPC tools/call result" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = "event: message\r\n" ++
        "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"from-sse\"}],\"isError\":false}}\r\n" ++
        "\r\n";
    const out = try formatResponse(arena, "remote", "lookup", body, "");
    try std.testing.expect(std.mem.indexOf(u8, out, "mcp remote/lookup returned") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "from-sse") != null);
}

test "mcp: legacy SSE endpoint resolves relative URLs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "https://example.test/messages?session=1",
        try resolveEndpoint(arena, "https://example.test/mcp/sse", "/messages?session=1"),
    );
    try std.testing.expectEqualStrings(
        "https://example.test/mcp/messages",
        try resolveEndpoint(arena, "https://example.test/mcp/sse", "messages"),
    );
}

test "mcp: SSE transport times out when server never sends response headers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    // Listen but never accept: the kernel completes the TCP handshake from its
    // backlog, so the client connects and sends the GET, then blocks forever in
    // receiveHead waiting for response headers. The session deadline must fire.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/sse", .{port});
    try std.testing.expectError(error.Timeout, call(arena, io, .{
        .name = "remote",
        .transport = "sse",
        .url = url,
        .allowed_tools = &.{"lookup"},
    }, "lookup", null, .{ .timeout_ms = 100 }));
}

test {
    std.testing.refAllDecls(@This());
}
