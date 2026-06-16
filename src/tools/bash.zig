//! bash 工具：在子进程中执行 shell 命令，带硬超时与输出上限。
//! 硬超时由 std.process.run 的 timeout 提供：转成绝对 deadline 传入，超时即返回
//! error.Timeout，其内部 defer child.kill(io) 会强制终止子进程，绝不让单条命令
//! 卡死拖垮主循环（见 ROADMAP「可靠的硬超时干预」）。
const std = @import("std");
const Result = @import("tools.zig").Result;

/// bash 执行参数。默认值即沙盒护栏：限时、限输出量。
pub const Options = struct {
    /// 硬超时（毫秒），0 表示不限时（不建议）。
    timeout_ms: u64 = 30_000,
    /// stdout 上限（字节），超出即终止并报错。
    stdout_limit: usize = 1 << 20,
    /// stderr 上限（字节）。
    stderr_limit: usize = 1 << 20,
    /// 工作目录；null 表示继承当前进程的 cwd。
    cwd: ?[]const u8 = null,
};

/// 执行一条 shell 命令，返回统一结果（成功时 `stdout`/`stderr` 由 `gpa` 拥有）。
/// 超时被强制终止时返回 `Result{ .timed_out = true }`（无 stdout/stderr 所有权）；
/// 输出越限时 `exit_code = -1`。真正的底层 I/O 失败（如无法 spawn）原样向上抛出。
pub fn run(gpa: std.mem.Allocator, io: std.Io, command: []const u8, opts: Options) !Result {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };

    // 转成绝对 deadline：std.process.run 内部按此对每次读取设同一截止点，形成硬墙钟上限。
    // 用 .awake 单调时钟，避免系统时间被回拨时超时失效。
    const timeout: std.Io.Timeout = if (opts.timeout_ms == 0) blk: {
        break :blk .none;
    } else blk: {
        const base: std.Io.Timeout = .{ .duration = .{
            .clock = .awake,
            .raw = std.Io.Duration.fromMilliseconds(@intCast(opts.timeout_ms)),
        } };
        break :blk base.toDeadline(io);
    };

    const cwd: std.process.Child.Cwd = if (opts.cwd) |p| .{ .path = p } else .inherit;

    const res = std.process.run(gpa, io, .{
        .argv = &argv,
        .timeout = timeout,
        .stdout_limit = .limited(opts.stdout_limit),
        .stderr_limit = .limited(opts.stderr_limit),
        .cwd = cwd,
    }) catch |err| switch (err) {
        error.Timeout => return .{ .timed_out = true },
        error.StreamTooLong => return .{ .exit_code = -1, .stderr = "[scoot] 命令输出超出上限，已终止" },
        else => return err,
    };

    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = termToCode(res.term),
    };
}

/// 把子进程终止状态映射成整型退出码：正常退出取其码；被信号终止/停止/未知统一记 -1。
/// （信号编号在各平台类型不一，这里只保留「非正常退出」语义，不暴露具体信号号。）
fn termToCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        else => -1,
    };
}

test "bash: 正常输出与退出码" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, "printf 'hi 世界'", .{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqualStrings("hi 世界", r.stdout);
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
    try std.testing.expect(!r.timed_out);
}

test "bash: 失败命令返回非零退出码" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, "exit 3", .{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 3), r.exit_code);
    try std.testing.expect(!r.timed_out);
}

test "bash: 硬超时强制终止并快速返回" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    // sleep 5 远超 200ms 截止点；预期被强制终止并标记 timed_out。
    const r = try run(gpa, io, "sleep 5", .{ .timeout_ms = 200 });
    const elapsed_ms = start.untilNow(io).raw.toMilliseconds();
    try std.testing.expect(r.timed_out);
    try std.testing.expect(elapsed_ms < 3000); // 远早于 sleep 的 5s
    // 超时路径不返回所有权（stdout/stderr 为空字面量），无需释放。
}

test {
    std.testing.refAllDecls(@This());
}

