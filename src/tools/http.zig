//! http_request tool: performs HTTP/HTTPS requests with hard timeouts and a
//! configurable CA bundle.
//!
//! Self-contained rationale matches file/search: trimmed or embedded Linux may
//! lack curl/wget. Use `std.http.Client.fetch` directly, sharing the same stack
//! as llm.zig, with TLS negotiated by the standard library.
//!
//! Hard timeout: `std.http.Client` does not expose a whole-request timeout, so
//! `std.Io.Select` races fetch against a timed sleeper. The loser is canceled
//! and joined with `cancelDiscard`. Fetch is cancelable at blocking socket/TLS
//! reads, so timeouts interrupt hung connections instead of stalling the agent.
//! If concurrency is unavailable, this falls back to synchronous fetch, keeping
//! functionality while losing the hard timeout.
//!
//! CA: by default, `std.http.Client` scans system roots. Embedded systems may
//! not have them, so `ca_file` accepts an absolute PEM bundle path. Preloading
//! `ca_bundle` and setting `now` suppresses system scanning, trusting only the
//! user-provided CA.
const std = @import("std");

pub const Method = enum { GET, POST, PUT, DELETE, HEAD, PATCH };

/// Result for one request. `status==0` means a transport failure such as
/// connection, TLS, or DNS; `err` carries the error name. `timed_out=true`
/// means the hard timeout canceled the request.
pub const Response = struct {
    status: u16 = 0,
    body: []const u8 = "",
    timed_out: bool = false,
    err: ?[]const u8 = null,
};

pub const Options = struct {
    /// Hard timeout in milliseconds.
    timeout_ms: u64 = 30_000,
    /// Optional absolute PEM CA bundle path; null uses system root scanning.
    ca_file: ?[]const u8 = null,
    /// Reported response-body byte limit; larger bodies are truncated.
    max_body: usize = 1 << 20,
};

/// Performs one HTTP(S) request with hard timeout. Failures and timeouts are
/// represented in `Response` fields and never panic.
pub fn request(
    arena: std.mem.Allocator,
    io: std.Io,
    method: Method,
    url: []const u8,
    body: ?[]const u8,
    opts: Options,
) !Response {
    if (opts.timeout_ms == 0)
        return doFetch(arena, io, method, url, body, opts);

    const Outcome = union(enum) { done: Response, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);

    // Run fetch concurrently; if concurrency is unavailable, fall back to sync.
    sel.concurrent(.done, doFetch, .{ arena, io, method, url, body, opts }) catch {
        return doFetch(arena, io, method, url, body, opts);
    };
    // Timed sleeper wins when the request times out.
    sel.concurrent(.timed_out, sleepDeadline, .{ io, opts.timeout_ms }) catch {
        sel.cancelDiscard();
        return doFetch(arena, io, method, url, body, opts);
    };

    const winner = sel.await() catch {
        sel.cancelDiscard();
        return error.Canceled;
    };
    sel.cancelDiscard(); // Cancel and join the loser; timeout interrupts fetch.

    return switch (winner) {
        .done => |r| r,
        .timed_out => .{ .timed_out = true },
    };
}

/// Performs fetch, normally in a concurrent task. All transport errors are
/// folded into `Response.err` instead of being thrown.
fn doFetch(
    arena: std.mem.Allocator,
    io: std.Io,
    method: Method,
    url: []const u8,
    body: ?[]const u8,
    opts: Options,
) Response {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    if (opts.ca_file) |path| {
        const now = std.Io.Clock.real.now(io);
        client.ca_bundle.addCertsFromFilePathAbsolute(arena, io, now, path) catch |e|
            return .{ .err = @errorName(e) };
        client.now = now; // Suppress system root scanning and trust only user CA.
    }

    var resp: std.Io.Writer.Allocating = .init(arena);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = httpMethod(method),
        .payload = body,
        .headers = .{ .content_type = if (body != null) .{ .override = "application/json" } else .default },
        .response_writer = &resp.writer,
    }) catch |e| return .{ .err = @errorName(e) };

    var out = resp.writer.buffered();
    if (out.len > opts.max_body) out = out[0..opts.max_body];
    return .{ .status = @intFromEnum(result.status), .body = out };
}

/// Race sleeper: returns after timeout_ms, or silently returns early on cancel.
fn sleepDeadline(io: std.Io, timeout_ms: u64) void {
    const d: std.Io.Clock.Duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    };
    d.sleep(io) catch {};
}

fn httpMethod(m: Method) std.http.Method {
    return switch (m) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
        .HEAD => .HEAD,
        .PATCH => .PATCH,
    };
}

/// Parses a method name case-insensitively; unknown values return null.
pub fn methodFromString(s: []const u8) ?Method {
    var buf: [8]u8 = undefined;
    if (s.len == 0 or s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return std.meta.stringToEnum(Method, buf[0..s.len]);
}

/// Whether the method is write-like: POST/PUT/DELETE/PATCH are net_write;
/// GET/HEAD are net_read.
pub fn isWrite(m: Method) bool {
    return switch (m) {
        .GET, .HEAD => false,
        .POST, .PUT, .DELETE, .PATCH => true,
    };
}

test "methodFromString case-insensitive and unknown method handling" {
    try std.testing.expectEqual(Method.GET, methodFromString("get").?);
    try std.testing.expectEqual(Method.POST, methodFromString("POST").?);
    try std.testing.expectEqual(Method.PATCH, methodFromString("Patch").?);
    try std.testing.expect(methodFromString("FETCH") == null);
    try std.testing.expect(methodFromString("") == null);
}

test "isWrite capability classification" {
    try std.testing.expect(!isWrite(.GET));
    try std.testing.expect(!isWrite(.HEAD));
    try std.testing.expect(isWrite(.POST));
    try std.testing.expect(isWrite(.PUT));
    try std.testing.expect(isWrite(.DELETE));
    try std.testing.expect(isWrite(.PATCH));
}

test "request hard timeout returns timed_out for blackhole address without hanging" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    // Non-routable address: connect hangs, so the hard timeout must interrupt it.
    const t0 = std.Io.Clock.awake.now(io);
    const resp = try request(a, io, .GET, "http://10.255.255.1/", null, .{ .timeout_ms = 300 });
    const t1 = std.Io.Clock.awake.now(io);
    const dt_ns = t0.durationTo(t1).nanoseconds;

    try std.testing.expect(resp.timed_out);
    // Should be far below the kernel connect timeout; 5s allows CI jitter.
    try std.testing.expect(dt_ns < 5 * std.time.ns_per_s);
}

test "request timeout_ms zero disables hard timeout instead of immediate timeout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    const resp = try request(a, io, .GET, "http://127.0.0.1:1/", null, .{ .timeout_ms = 0 });
    try std.testing.expect(!resp.timed_out);
}

test {
    std.testing.refAllDecls(@This());
}
