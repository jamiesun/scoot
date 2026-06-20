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
        _: std.mem.Allocator,
        _: std.Io,
        _: Server,
        _: []const u8,
        _: ?std.json.Value,
        _: Options,
    ) ![]const u8 {
        return error.UnsupportedMcpTransport;
    }
};

const SseTransport = struct {
    fn call(
        _: SseTransport,
        _: std.mem.Allocator,
        _: std.Io,
        _: Server,
        _: []const u8,
        _: ?std.json.Value,
        _: Options,
    ) ![]const u8 {
        return error.UnsupportedMcpTransport;
    }
};

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
        child.stdin.?.writeStreamingAll(io, input) catch return error.McpWriteFailed;
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
        _ = try child.wait(io);

        const stdout = try multi_reader.toOwnedSlice(0);
        const stderr = try multi_reader.toOwnedSlice(1);
        return try formatResponse(arena, server.name, tool, stdout, stderr);
    }
};

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

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":");
    try jsonio.writeString(w, protocol_version);
    try w.writeAll(",\"capabilities\":{},\"clientInfo\":{\"name\":\"scoot\",\"version\":\"0\"}}}\n");
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}\n");
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n");
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":");
    try jsonio.writeString(w, tool);
    try w.writeAll(",\"arguments\":");
    if (args) |v| {
        try w.print("{f}", .{std.json.fmt(v, .{})});
    } else {
        try w.writeAll("{}");
    }
    try w.writeAll("}}\n");

    return aw.written();
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
    return error.McpProtocolError;
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

test "mcp: stdio fake server formats tools/call result" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const dir = "/tmp/scoot_mcp_fake";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const script = dir ++ "/server.sh";
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

test "mcp: allowed tools fail closed and http/sse are reserved" {
    try std.testing.expect(!toolAllowed(.{ .name = "s" }, "read"));
    try std.testing.expect(toolAllowed(.{ .name = "s", .allowed_tools = &.{"read"} }, "read"));
    try std.testing.expectEqual(TransportKind.http, TransportKind.fromString("streamable_http").?);
}

test {
    std.testing.refAllDecls(@This());
}
