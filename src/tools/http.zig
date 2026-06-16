//! http_request 工具：发起网络请求，带硬超时。
const std = @import("std");
const Result = @import("tools.zig").Result;

pub const Method = enum { GET, POST, PUT, DELETE, HEAD, PATCH };

/// 发起一次 HTTP 请求。
/// TODO: 实现请求 + 硬超时；超时置 timed_out=true，绝不挂死主循环。
pub fn request(arena: std.mem.Allocator, method: Method, url: []const u8, body: ?[]const u8) !Result {
    _ = arena;
    _ = method;
    _ = url;
    _ = body;
    return error.NotImplemented;
}

test {
    std.testing.refAllDecls(@This());
}
