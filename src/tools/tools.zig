//! Execution sandbox: low-level primitives callable by the agent.
//! Every tool must have a hard timeout, and unvalidated model output must never
//! execute directly.
const std = @import("std");

pub const bash = @import("bash.zig");
pub const file = @import("file.zig");
pub const search = @import("search.zig");
pub const http = @import("http.zig");
pub const outline = @import("outline.zig");
pub const mcp = @import("mcp.zig");
pub const wasm = @import("wasm.zig");

/// Unified tool execution result.
pub const Result = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: i32 = 0,
    /// Whether execution was force-terminated by a hard timeout.
    timed_out: bool = false,
};

test {
    std.testing.refAllDecls(@This());
}
