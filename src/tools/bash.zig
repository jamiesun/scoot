//! bash 工具：在子进程中执行 shell 命令，带硬超时。
const std = @import("std");
const Result = @import("tools.zig").Result;

/// 执行一条 shell 命令。
/// TODO: spawn 子进程；超过 timeout_ms 则 SIGKILL 并置 timed_out=true，
///       绝不让单条命令卡死拖垮主循环（见 ROADMAP「可靠的硬超时干预」）。
pub fn run(arena: std.mem.Allocator, command: []const u8, timeout_ms: u64) !Result {
    _ = arena;
    _ = command;
    _ = timeout_ms;
    return error.NotImplemented;
}

test {
    std.testing.refAllDecls(@This());
}
