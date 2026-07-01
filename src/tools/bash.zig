//! Bash tool: runs shell commands in subprocesses with hard timeout and output
//! limits. `std.process.run` provides the timeout; this module converts it to
//! an absolute deadline. On timeout, `error.Timeout` is returned and the child
//! is force-killed, so one command cannot stall the main loop.
const std = @import("std");
const proc = @import("proc.zig");
const Result = @import("tools.zig").Result;

pub const default_timeout_ms: u64 = 30_000;

/// Bash execution options. Defaults are sandbox guardrails: bounded time and output.
pub const Options = struct {
    /// Hard timeout in milliseconds. 0 means use the module default.
    timeout_ms: u64 = default_timeout_ms,
    /// Stdout byte limit; exceeding it terminates with an error.
    stdout_limit: usize = 1 << 20,
    /// Stderr byte limit.
    stderr_limit: usize = 1 << 20,
    /// Working directory; null inherits the current process cwd.
    cwd: ?[]const u8 = null,
    /// Replaces the child environment when set (issue #190). Null keeps the
    /// prior default of full inheritance from the parent process, which
    /// callers such as `secret.zig`'s credential-command source rely on. Callers
    /// that execute model-triggered commands should pass a scrubbed map so
    /// ambient secrets are not handed to the subprocess by default.
    environ_map: ?*const std.process.Environ.Map = null,
};

/// Runs one shell command and returns a unified result. On success, `stdout` and
/// `stderr` are owned by `gpa`. Forced timeouts return
/// `Result{ .timed_out = true }` with no stdout/stderr ownership. Output-limit
/// failures use `exit_code = -1`. Real lower-level I/O failures propagate.
pub fn run(gpa: std.mem.Allocator, io: std.Io, command: []const u8, opts: Options) !Result {
    const argv = [_][]const u8{ "/bin/sh", "-c", command };

    // Convert to an absolute deadline so every read in std.process.run shares
    // the same wall-clock cap. Use the .awake monotonic clock so clock changes
    // cannot disable the timeout.
    const effective_timeout_ms = proc.effectiveTimeoutMs(opts.timeout_ms, default_timeout_ms);
    const base: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(effective_timeout_ms)),
    } };
    const timeout = base.toDeadline(io);

    const cwd: std.process.Child.Cwd = if (opts.cwd) |p| .{ .path = p } else .inherit;

    const res = std.process.run(gpa, io, .{
        .argv = &argv,
        .timeout = timeout,
        .stdout_limit = .limited(opts.stdout_limit),
        .stderr_limit = .limited(opts.stderr_limit),
        .cwd = cwd,
        .environ_map = opts.environ_map,
    }) catch |err| switch (err) {
        error.Timeout => return .{ .timed_out = true },
        error.StreamTooLong => return .{ .exit_code = -1, .stderr = "[scoot] command output exceeded the limit and was terminated" },
        else => return err,
    };

    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = termToCode(res.term),
    };
}

/// Maps child termination to an integer exit code. Normal exits keep their code;
/// signal termination, stop, and unknown cases collapse to -1 because signal
/// numbers vary by platform and only the abnormal-exit meaning is exposed.
fn termToCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @as(i32, code),
        else => -1,
    };
}

test "bash: normal command returns exit_code" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, "printf 'hi world'", .{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqualStrings("hi world", r.stdout);
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
    try std.testing.expect(!r.timed_out);
}

test "bash: failed command returns nonzero exit_code" {
    const gpa = std.testing.allocator;
    const r = try run(gpa, std.testing.io, "exit 3", .{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(i32, 3), r.exit_code);
    try std.testing.expect(!r.timed_out);
}

test "bash: hard timeout force-terminates and returns quickly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    // sleep 5 far exceeds the 200ms deadline and should be force-terminated.
    const r = try run(gpa, io, "sleep 5", .{ .timeout_ms = 200 });
    const elapsed_ms = start.untilNow(io).raw.toMilliseconds();
    try std.testing.expect(r.timed_out);
    try std.testing.expect(elapsed_ms < 3000); // Much earlier than sleep's 5s.
    // Timeout results return string literals, so there is no ownership to free.
}

test "bash: environ_map is forwarded to the child process" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("SCOOT_BASH_ENV_TEST", "visible");

    // Note: this only proves the explicit map reaches the child. It does not
    // assert that ambient parent-process vars such as PATH are absent, because
    // /bin/sh on some platforms (e.g. macOS) synthesizes its own default PATH
    // when none is inherited, independent of std.process.RunOptions.environ_map
    // semantics. The replace-not-merge contract itself is documented and owned
    // by std.process.RunOptions; issue #190's scrub relies on it at the
    // agent.zig / secret.zig layer, covered by dedicated tests there.
    const r = try run(gpa, io, "printf \"$SCOOT_BASH_ENV_TEST\"", .{ .environ_map = &env });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqualStrings("visible", r.stdout);
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
}

test {
    std.testing.refAllDecls(@This());
}
