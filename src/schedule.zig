//! Scheduling engine: lets unattended Scoot wake an agent at the right time to
//! execute `job.goal`, combining AI capability with traditional scheduled tasks
//! into an auditable cron-like hub.
//!
//! Safety premise: scheduled jobs are autonomous and unattended, so they default
//! to the `readonly` policy gate, a fail-closed local-read allowlist, rather than
//! the interactive `guarded` tripwire. `guarded` is useful only when someone is
//! watching; for unattended jobs it is corrected to `readonly` by
//! `effectiveMode`. Users may explicitly choose `unrestricted` for a job at
//! their own risk, still fully audited. Unattended execution must never rest on
//! `guarded`.
//!
//! Testability: time-looping is separated from due decisions.
//!   - `dueAt(now_unix)` is a pure function with injected time.
//!   - `tick(now_unix, ctx, runFn)` triggers due jobs through a callback, so the
//!     scheduler does not depend on agent.zig and tests can inject counters.
//!   - `runForever` is a thin shell: read real now, tick, sleep. `max_ticks`
//!     enables bounded runs.
//!
//! Scope boundary: cron supports standard five-field, minute-level triggers
//! (minute/hour/day/month/weekday) without complex runtime state. Long-term
//! memory and plan-mode DAGs are not implemented here. Long-running zero-leak
//! behavior is owned by the caller's per-job resettable arena, while the
//! scheduler itself does not retain per-run scratch memory.
const std = @import("std");
const policy = @import("policy.zig");

/// Trigger type: three scheduling modes.
pub const Trigger = union(enum) {
    /// Fixed interval in seconds.
    every_sec: u64,
    /// Fixed Unix timestamp in seconds.
    at_unix: i64,
    /// Five-field UTC cron expression supporting `*`, `*/n`, `a`, `a-b`, and lists.
    cron: []const u8,
};

/// One scheduled job. `mode` is the execution policy, defaulting to unattended
/// safe `readonly`. `last_run_unix` and `fired` are runtime state, not config.
pub const Job = struct {
    id: []const u8,
    trigger: Trigger,
    goal: []const u8,
    mode: policy.Mode = .readonly,
    last_run_unix: i64 = 0,
    fired: bool = false,

    /// Corrected effective policy: unattended `guarded` is meaningless, so it is
    /// lowered to `readonly`. Scheduled jobs can never run on guarded.
    pub fn effectiveMode(self: Job) policy.Mode {
        return switch (self.mode) {
            .guarded => .readonly,
            else => self.mode,
        };
    }

    /// Pure function: whether this job is due at `now_unix`.
    ///   every_sec: last run is at least interval ago, or first run immediately;
    ///     interval 0 never triggers to prevent spinning.
    ///   at_unix: one-shot after the timestamp.
    ///   cron: minute-level match, at most once per matching minute.
    pub fn dueAt(self: Job, now_unix: i64) bool {
        return switch (self.trigger) {
            .every_sec => |sec| blk: {
                if (sec == 0) break :blk false;
                if (self.last_run_unix == 0) break :blk true;
                break :blk now_unix - self.last_run_unix >= @as(i64, @intCast(sec));
            },
            .at_unix => |t| !self.fired and now_unix >= t,
            .cron => |expr| cronDueAt(expr, now_unix, self.last_run_unix),
        };
    }
};

const CronTime = struct {
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    dow: u8,
};

fn cronDueAt(expr: []const u8, now_unix: i64, last_run_unix: i64) bool {
    if (now_unix < 0) return false;
    const now_minute = @divFloor(now_unix, 60);
    if (last_run_unix != 0 and @divFloor(last_run_unix, 60) == now_minute) return false;
    const t = utcCronTime(@intCast(now_unix));
    return cronMatches(expr, t);
}

pub fn cronValid(expr: []const u8) bool {
    var fields = std.mem.tokenizeAny(u8, expr, " \t");
    const minute = fields.next() orelse return false;
    const hour = fields.next() orelse return false;
    const day = fields.next() orelse return false;
    const month = fields.next() orelse return false;
    const dow = fields.next() orelse return false;
    if (fields.next() != null) return false;

    return cronFieldValid(minute, 0, 59, false) and
        cronFieldValid(hour, 0, 23, false) and
        cronFieldValid(day, 1, 31, false) and
        cronFieldValid(month, 1, 12, false) and
        cronFieldValid(dow, 0, 7, true);
}

fn utcCronTime(secs: u64) CronTime {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .minute = day_seconds.getMinutesIntoHour(),
        .hour = day_seconds.getHoursIntoDay(),
        .day = @intCast(month_day.day_index + 1),
        .month = @intCast(month_day.month.numeric()),
        .dow = @intCast(@mod(epoch_day.day + 4, 7)), // 1970-01-01 was Thursday; Sunday=0.
    };
}

fn cronMatches(expr: []const u8, t: CronTime) bool {
    var fields = std.mem.tokenizeAny(u8, expr, " \t");
    const minute = fields.next() orelse return false;
    const hour = fields.next() orelse return false;
    const day = fields.next() orelse return false;
    const month = fields.next() orelse return false;
    const dow = fields.next() orelse return false;
    if (fields.next() != null) return false;

    return cronFieldMatches(minute, t.minute, 0, 59, false) and
        cronFieldMatches(hour, t.hour, 0, 23, false) and
        cronFieldMatches(day, t.day, 1, 31, false) and
        cronFieldMatches(month, t.month, 1, 12, false) and
        cronFieldMatches(dow, t.dow, 0, 7, true);
}

fn cronFieldMatches(field: []const u8, value: u8, min: u8, max: u8, dow: bool) bool {
    if (field.len == 0) return false;
    var parts = std.mem.tokenizeScalar(u8, field, ',');
    var saw = false;
    while (parts.next()) |part| {
        saw = true;
        if (cronPartMatches(part, value, min, max, dow)) return true;
    }
    return !saw and false;
}

fn cronFieldValid(field: []const u8, min: u8, max: u8, dow: bool) bool {
    if (field.len == 0) return false;
    var parts = std.mem.tokenizeScalar(u8, field, ',');
    var saw = false;
    while (parts.next()) |part| {
        saw = true;
        if (!cronPartValid(part, min, max, dow)) return false;
    }
    return saw;
}

fn cronPartValid(part: []const u8, min: u8, max: u8, dow: bool) bool {
    if (part.len == 0) return false;
    const slash = std.mem.indexOfScalar(u8, part, '/');
    const base = if (slash) |idx| part[0..idx] else part;
    if (slash) |idx| {
        if (idx + 1 >= part.len) return false;
        const n = std.fmt.parseInt(u8, part[idx + 1 ..], 10) catch return false;
        if (n == 0) return false;
    }
    if (std.mem.eql(u8, base, "*")) return true;
    if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
        if (dash == 0 or dash + 1 >= base.len) return false;
        const start = parseCronNumber(base[0..dash], min, max, dow) orelse return false;
        const end = parseCronNumber(base[dash + 1 ..], min, max, dow) orelse return false;
        return start <= end;
    }
    _ = parseCronNumber(base, min, max, dow) orelse return false;
    return true;
}

fn cronPartMatches(part: []const u8, value: u8, min: u8, max: u8, dow: bool) bool {
    if (part.len == 0) return false;
    const slash = std.mem.indexOfScalar(u8, part, '/');
    const base = if (slash) |idx| part[0..idx] else part;
    const step: u8 = if (slash) |idx| blk: {
        if (idx + 1 >= part.len) return false;
        const n = std.fmt.parseInt(u8, part[idx + 1 ..], 10) catch return false;
        if (n == 0) return false;
        break :blk n;
    } else 1;

    var start: u8 = min;
    var end: u8 = max;
    if (!std.mem.eql(u8, base, "*")) {
        if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
            if (dash == 0 or dash + 1 >= base.len) return false;
            start = parseCronNumber(base[0..dash], min, max, dow) orelse return false;
            end = parseCronNumber(base[dash + 1 ..], min, max, dow) orelse return false;
            if (start > end and !(dow and start > end and end == 0)) return false;
        } else {
            start = parseCronNumber(base, min, max, dow) orelse return false;
            end = start;
        }
    }

    const raw_value: u8 = if (dow and value == 0 and end == 7 and start != 0) 7 else value;
    if (raw_value < start or raw_value > end) return false;
    return @mod(raw_value - start, step) == 0;
}

fn parseCronNumber(s: []const u8, min: u8, max: u8, dow: bool) ?u8 {
    const n = std.fmt.parseInt(u8, s, 10) catch return null;
    if (dow and n == 7) return 7;
    if (n < min or n > max) return null;
    return n;
}

/// Scheduler holding jobs and scanning them against injected time.
/// `jobs` is owned by the provided `gpa`; element contents must outlive Scheduler.
pub const Scheduler = struct {
    jobs: std.ArrayList(Job) = .empty,

    /// Run callback: the scheduler only decides due-ness; callers inject execution.
    pub const RunFn = *const fn (ctx: *anyopaque, job: *Job) void;

    pub fn add(self: *Scheduler, gpa: std.mem.Allocator, job: Job) !void {
        try self.jobs.append(gpa, job);
    }

    pub fn remove(self: *Scheduler, id: []const u8) bool {
        for (self.jobs.items, 0..) |job, idx| {
            if (std.mem.eql(u8, job.id, id)) {
                _ = self.jobs.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *const Scheduler) usize {
        return self.jobs.items.len;
    }

    /// Single scan: triggers all jobs due at `now_unix`, updating last_run/fired
    /// before invoking runFn. Returns number of fired jobs. Injected time keeps
    /// this testable without touching the real clock.
    pub fn tick(self: *Scheduler, now_unix: i64, ctx: *anyopaque, runFn: RunFn) usize {
        var fired: usize = 0;
        for (self.jobs.items) |*job| {
            if (!job.dueAt(now_unix)) continue;
            job.last_run_unix = now_unix;
            job.fired = true;
            runFn(ctx, job);
            fired += 1;
        }
        return fired;
    }

    /// Daemon loop: read real now, tick, then sleep. `max_ticks == 0` means run
    /// forever; values > 0 return after that many ticks for tests or bounded
    /// runs. Returns total fired job count. Canceled sleep ends gracefully.
    pub fn runForever(
        self: *Scheduler,
        io: std.Io,
        poll_ms: u64,
        max_ticks: usize,
        ctx: *anyopaque,
        runFn: RunFn,
    ) usize {
        var total: usize = 0;
        var ticks: usize = 0;
        while (max_ticks == 0 or ticks < max_ticks) : (ticks += 1) {
            const now_unix = std.Io.Timestamp.now(io, .real).toSeconds();
            total += self.tick(now_unix, ctx, runFn);
            if (max_ticks != 0 and ticks + 1 >= max_ticks) break; // Do not sleep after final tick.
            io.sleep(std.Io.Duration.fromMilliseconds(@intCast(poll_ms)), .awake) catch break;
        }
        return total;
    }

    pub fn deinit(self: *Scheduler, gpa: std.mem.Allocator) void {
        self.jobs.deinit(gpa);
    }
};

test "effectiveMode: guarded is corrected to readonly,others unchanged" {
    const j_guard = Job{ .id = "a", .trigger = .{ .every_sec = 60 }, .goal = "", .mode = .guarded };
    try std.testing.expectEqual(policy.Mode.readonly, j_guard.effectiveMode());
    const j_ro = Job{ .id = "b", .trigger = .{ .every_sec = 60 }, .goal = "", .mode = .readonly };
    try std.testing.expectEqual(policy.Mode.readonly, j_ro.effectiveMode());
    const j_un = Job{ .id = "c", .trigger = .{ .every_sec = 60 }, .goal = "", .mode = .unrestricted };
    try std.testing.expectEqual(policy.Mode.unrestricted, j_un.effectiveMode());
}

test "dueAt: every_sec interval predicate" {
    var j = Job{ .id = "x", .trigger = .{ .every_sec = 300 }, .goal = "" };
    try std.testing.expect(j.dueAt(1000)); // Never run -> immediate first run.
    j.last_run_unix = 1000;
    try std.testing.expect(!j.dueAt(1299)); // Interval not reached.
    try std.testing.expect(j.dueAt(1300)); // Exactly due.
    try std.testing.expect(j.dueAt(5000)); // Long overdue.

    var zero = Job{ .id = "z", .trigger = .{ .every_sec = 0 }, .goal = "" };
    try std.testing.expect(!zero.dueAt(1)); // 0 interval does not trigger.
    zero.last_run_unix = 0;
}

test "dueAt: at_unix one-shot trigger" {
    var j = Job{ .id = "y", .trigger = .{ .at_unix = 2000 }, .goal = "" };
    try std.testing.expect(!j.dueAt(1999)); // Not yet due.
    try std.testing.expect(j.dueAt(2000)); // Due.
    j.fired = true;
    try std.testing.expect(!j.dueAt(3000)); // Already fired; no repeat.
}

test "dueAt: cron minute-level trigger fires only once per minute" {
    var j = Job{ .id = "c", .trigger = .{ .cron = "* * * * *" }, .goal = "" };
    try std.testing.expect(j.dueAt(60));
    j.last_run_unix = 60;
    try std.testing.expect(!j.dueAt(61));
    try std.testing.expect(j.dueAt(120));
}

test "cronMatches: supports fixed values, ranges, lists, steps, and Sunday=7" {
    // 1970-01-01 00:01:00 UTC, Thursday.
    const t = utcCronTime(60);
    try std.testing.expect(cronMatches("1 0 1 1 4", t));
    try std.testing.expect(cronMatches("*/1 0-2 1,15 1 1-7", t));
    try std.testing.expect(!cronMatches("2 0 1 1 4", t));
    try std.testing.expect(!cronMatches("* * *", t));

    // 1970-01-04 is Sunday; both 0 and 7 should match.
    const sunday = utcCronTime(3 * 24 * 60 * 60);
    try std.testing.expect(cronMatches("0 0 4 1 0", sunday));
    try std.testing.expect(cronMatches("0 0 4 1 7", sunday));
}

test "cronValid: malformed expressions are rejected" {
    try std.testing.expect(cronValid("*/5 9-17 * * 1-5"));
    try std.testing.expect(!cronValid("* * *"));
    try std.testing.expect(!cronValid("60 * * * *"));
    try std.testing.expect(!cronValid("* 24 * * *"));
    try std.testing.expect(!cronValid("* * * * */0"));
}

const TickCounter = struct {
    fired_ids: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,
    fn cb(ctx: *anyopaque, job: *Job) void {
        const self: *TickCounter = @ptrCast(@alignCast(ctx));
        self.fired_ids.append(self.gpa, job.id) catch {};
    }
};

test "tick: fires only due jobs and advances state" {
    const gpa = std.testing.allocator;
    var sch: Scheduler = .{};
    defer sch.deinit(gpa);
    try sch.add(gpa, .{ .id = "due", .trigger = .{ .every_sec = 10 }, .goal = "g1" });
    try sch.add(gpa, .{ .id = "future", .trigger = .{ .at_unix = 9999 }, .goal = "g2" });

    var counter = TickCounter{ .gpa = gpa };
    defer counter.fired_ids.deinit(gpa);

    const n = sch.tick(100, &counter, TickCounter.cb);
    try std.testing.expectEqual(@as(usize, 1), n); // Only due fired.
    try std.testing.expectEqual(@as(usize, 1), counter.fired_ids.items.len);
    try std.testing.expectEqualStrings("due", counter.fired_ids.items[0]);

    // due state advanced: same timestamp should not trigger again.
    try std.testing.expectEqual(@as(usize, 0), sch.tick(100, &counter, TickCounter.cb));
    // Triggers again after the interval.
    try std.testing.expectEqual(@as(usize, 1), sch.tick(120, &counter, TickCounter.cb));
}

test {
    std.testing.refAllDecls(@This());
}
