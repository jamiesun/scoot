//! http_request 工具：发起 HTTP/HTTPS 请求，带**硬超时**与可配置 CA。
//!
//! 自包含动机同 file/search：裁剪 / 嵌入式 Linux 可能无 curl/wget。直接用
//! `std.http.Client.fetch`（与 llm.zig 同源），TLS 由标准库协商。
//!
//! 硬超时（铁律：工具必有硬超时）：`std.http.Client` 不暴露整体请求超时，
//! 故用 `std.Io.Select` 把 fetch 与一个定时 sleeper **并发竞速**——谁先完成谁
//! 胜出，落败者经 `cancelDiscard` 取消并 join。fetch 在阻塞的 socket/TLS 读处
//! 是取消点，故超时能真正中断挂死连接，不会拖死 Agent 主循环。并发不可用时
//! 退化为同步 fetch（功能不阻断，仅失去硬超时）。
//!
//! CA：默认走 `std.http.Client` 的系统根证书自动扫描；嵌入式上系统证书可能缺失，
//! 故支持 `ca_file`（PEM bundle 绝对路径）——预填 `ca_bundle` 并置 `now` 抑制系统
//! 扫描覆盖，从而只信任用户提供的 CA。
const std = @import("std");

pub const Method = enum { GET, POST, PUT, DELETE, HEAD, PATCH };

/// 一次请求的结果。`status==0` 表示传输层失败（连接 / TLS / DNS），错误名见 `err`。
/// `timed_out=true` 表示超过硬超时被取消（绝不挂死主循环）。
pub const Response = struct {
    status: u16 = 0,
    body: []const u8 = "",
    timed_out: bool = false,
    err: ?[]const u8 = null,
};

pub const Options = struct {
    /// 硬超时（毫秒）。
    timeout_ms: u64 = 30_000,
    /// 可选自定义 CA bundle（PEM）绝对路径；null = 用系统根证书自动扫描。
    ca_file: ?[]const u8 = null,
    /// 响应体上报上限（字节），超出截断，挡住超大响应撑爆上下文 / 内存。
    max_body: usize = 1 << 20,
};

/// 发起一次 HTTP(S) 请求，带硬超时。失败 / 超时均以 `Response` 字段表达，绝不 panic。
pub fn request(
    arena: std.mem.Allocator,
    io: std.Io,
    method: Method,
    url: []const u8,
    body: ?[]const u8,
    opts: Options,
) !Response {
    const Outcome = union(enum) { done: Response, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel = std.Io.Select(Outcome).init(io, &buf);

    // fetch 任务并发跑；并发不可用则退化为同步直跑（不阻断功能，仅失去硬超时）。
    sel.concurrent(.done, doFetch, .{ arena, io, method, url, body, opts }) catch {
        return doFetch(arena, io, method, url, body, opts);
    };
    // 定时 sleeper：到点则胜出，表示超时。
    sel.concurrent(.timed_out, sleepDeadline, .{ io, opts.timeout_ms }) catch {
        sel.cancelDiscard();
        return doFetch(arena, io, method, url, body, opts);
    };

    const winner = sel.await() catch {
        sel.cancelDiscard();
        return error.Canceled;
    };
    sel.cancelDiscard(); // 取消并 join 落败任务（超时则中断阻塞的 fetch）

    return switch (winner) {
        .done => |r| r,
        .timed_out => .{ .timed_out = true },
    };
}

/// 实际执行 fetch（在并发任务里运行）。所有传输错误收敛进 `Response.err`，不外抛。
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
        client.now = now; // 抑制系统根证书扫描覆盖 → 只信任用户 CA
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

/// 竞速用 sleeper：睡满 timeout_ms 后返回（被取消则提前以 Canceled 返回，吞掉）。
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

/// 解析方法名（不区分大小写）；未知 → null。
pub fn methodFromString(s: []const u8) ?Method {
    var buf: [8]u8 = undefined;
    if (s.len == 0 or s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return std.meta.stringToEnum(Method, buf[0..s.len]);
}

/// 是否为写类方法（POST/PUT/DELETE/PATCH→net_write；GET/HEAD→net_read）。
pub fn isWrite(m: Method) bool {
    return switch (m) {
        .GET, .HEAD => false,
        .POST, .PUT, .DELETE, .PATCH => true,
    };
}

test "methodFromString 大小写与未知" {
    try std.testing.expectEqual(Method.GET, methodFromString("get").?);
    try std.testing.expectEqual(Method.POST, methodFromString("POST").?);
    try std.testing.expectEqual(Method.PATCH, methodFromString("Patch").?);
    try std.testing.expect(methodFromString("FETCH") == null);
    try std.testing.expect(methodFromString("") == null);
}

test "isWrite 能力分类" {
    try std.testing.expect(!isWrite(.GET));
    try std.testing.expect(!isWrite(.HEAD));
    try std.testing.expect(isWrite(.POST));
    try std.testing.expect(isWrite(.PUT));
    try std.testing.expect(isWrite(.DELETE));
    try std.testing.expect(isWrite(.PATCH));
}

test "request 硬超时：黑洞地址在超时内返回 timed_out（不挂死）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    // 非路由地址：connect 会长时间挂起；硬超时须在 ~300ms 内中断它。
    const t0 = std.Io.Clock.awake.now(io);
    const resp = try request(a, io, .GET, "http://10.255.255.1/", null, .{ .timeout_ms = 300 });
    const t1 = std.Io.Clock.awake.now(io);
    const dt_ns = t0.durationTo(t1).nanoseconds;

    try std.testing.expect(resp.timed_out);
    // 应远小于内核默认 connect 超时（数十秒）；给宽松上界 5s 防 CI 抖动。
    try std.testing.expect(dt_ns < 5 * std.time.ns_per_s);
}

test {
    std.testing.refAllDecls(@This());
}
