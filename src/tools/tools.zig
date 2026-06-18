//! 执行沙盒：Agent 可调用的底层原语。
//! 每个工具都必须具备硬超时；绝不直接执行未经校验的模型输出。
const std = @import("std");

pub const bash = @import("bash.zig");
pub const file = @import("file.zig");
pub const search = @import("search.zig");
pub const http = @import("http.zig");
pub const outline = @import("outline.zig");

/// 工具执行的统一结果。
pub const Result = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: i32 = 0,
    /// 是否因硬超时被强制终止。
    timed_out: bool = false,
};

test {
    std.testing.refAllDecls(@This());
}
