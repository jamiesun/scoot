//! 调度引擎（北极星方向三）：让 Scoot 在无人值守下到点唤起 Agent 执行 job.goal，
//! 把"AI 能力 + 传统定时任务"融合成可审计的智能 Cronjob 中枢。
//!
//! 安全前置（铁律 #1「安全可控」，不可妥协）：
//!   被调度的 job 是**无人在场**的自主执行，因此默认强制 `readonly` 策略门
//!   （fail-closed 只读白名单），而非交互用的 `guarded` 绊线。`guarded` 是"有人盯着"
//!   时拦灾难命令的绊线，对无人值守毫无意义——故任何 job 的 `guarded` 一律被
//!   `effectiveMode` 矫正为 `readonly`；用户可显式把某 job 设为 `unrestricted`
//!   （自担风险，仍全程审计）。**绝不把无人值守执行架在 guarded 之上。**
//!
//! 可测性设计（时间循环与判定分离）：
//!   - `dueAt(now_unix)` 是**纯函数**（注入时间），便于防弹单测；
//!   - `tick(now_unix, ctx, runFn)` 用注入时间触发到期 job，经回调跑 Agent——
//!     调度器不依赖 agent.zig，避免依赖环，也让测试能注入计数桩；
//!   - `runForever` 是薄壳：取真实时钟 now → tick → sleep，`max_ticks` 支持有界运行。
//!
//! 反过载边界：`cron` 暂不支持（`dueAt` 返回 false），不半实现一个会出错的解析器；
//!   长期记忆 / plan-mode DAG 不在此实现。长效守护零泄漏由调用方的 per-job 可重置
//!   arena 承载（见 main 的 runner），调度器自身不驻留每次运行的临时内存。
const std = @import("std");
const policy = @import("policy.zig");

/// 触发器：三类调度。every/at 已实现，cron 为预留（暂不支持）。
pub const Trigger = union(enum) {
    /// 固定间隔（秒）。
    every_sec: u64,
    /// 固定时间点（Unix 秒）。
    at_unix: i64,
    /// Cron 表达式（暂不支持，`dueAt` 返回 false）。
    cron: []const u8,
};

/// 一个调度任务。`mode` 是该 job 的执行策略档，默认 `readonly`（无人值守安全档）。
/// `last_run_unix` / `fired` 是运行时状态，不来自配置。
pub const Job = struct {
    id: []const u8,
    trigger: Trigger,
    goal: []const u8,
    mode: policy.Mode = .readonly,
    last_run_unix: i64 = 0,
    fired: bool = false,

    /// 矫正后的有效策略：`guarded`（人在场绊线）对无人值守无意义 → 降为 `readonly`。
    /// 这是铁律 #1 的结构性保证：被调度 job 永远不可能跑在 guarded 之上。
    pub fn effectiveMode(self: Job) policy.Mode {
        return switch (self.mode) {
            .guarded => .readonly,
            else => self.mode,
        };
    }

    /// 纯函数：在 `now_unix` 时该 job 是否到点。
    ///   every_sec：距上次触发 >= 间隔（从未跑过则立即首跑）；间隔 0 视作不触发（防自旋）。
    ///   at_unix：到点且未触发过（一次性）。
    ///   cron：暂不支持，恒 false。
    pub fn dueAt(self: Job, now_unix: i64) bool {
        return switch (self.trigger) {
            .every_sec => |sec| blk: {
                if (sec == 0) break :blk false;
                if (self.last_run_unix == 0) break :blk true;
                break :blk now_unix - self.last_run_unix >= @as(i64, @intCast(sec));
            },
            .at_unix => |t| !self.fired and now_unix >= t,
            .cron => false,
        };
    }
};

/// 调度器：持有一组 job，按注入时间扫描触发。
/// `jobs` 由传入的 `gpa` 拥有（元素内容的生命周期由调用方保证 >= Scheduler）。
pub const Scheduler = struct {
    jobs: std.ArrayList(Job) = .empty,

    /// 触发回调：调度器只判"到点"，怎么跑 job 由调用方注入（解耦 agent 依赖）。
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

    /// 单次扫描：把所有在 `now_unix` 到点的 job 触发——先更新 last_run/fired，再调 runFn。
    /// 返回本次触发的 job 数。时间注入使其逻辑可单测，不碰真实时钟。
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

    /// 守护循环：周期性「取真实 now → tick → sleep」。
    /// `max_ticks == 0` 表示无限运行（真实守护）；> 0 跑够即返回（测试 / 有界运行）。
    /// 返回累计触发的 job 次数。sleep 被取消（如收到中断）即优雅结束。
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
            if (max_ticks != 0 and ticks + 1 >= max_ticks) break; // 末次 tick 不再睡
            io.sleep(std.Io.Duration.fromMilliseconds(@intCast(poll_ms)), .awake) catch break;
        }
        return total;
    }

    pub fn deinit(self: *Scheduler, gpa: std.mem.Allocator) void {
        self.jobs.deinit(gpa);
    }
};

test "effectiveMode: guarded 被矫正为 readonly，其余保持" {
    const j_guard = Job{ .id = "a", .trigger = .{ .every_sec = 60 }, .goal = "", .mode = .guarded };
    try std.testing.expectEqual(policy.Mode.readonly, j_guard.effectiveMode());
    const j_ro = Job{ .id = "b", .trigger = .{ .every_sec = 60 }, .goal = "", .mode = .readonly };
    try std.testing.expectEqual(policy.Mode.readonly, j_ro.effectiveMode());
    const j_un = Job{ .id = "c", .trigger = .{ .every_sec = 60 }, .goal = "", .mode = .unrestricted };
    try std.testing.expectEqual(policy.Mode.unrestricted, j_un.effectiveMode());
}

test "dueAt: every_sec 间隔判定" {
    var j = Job{ .id = "x", .trigger = .{ .every_sec = 300 }, .goal = "" };
    try std.testing.expect(j.dueAt(1000)); // 从未跑过 → 立即首跑
    j.last_run_unix = 1000;
    try std.testing.expect(!j.dueAt(1299)); // 未到间隔
    try std.testing.expect(j.dueAt(1300)); // 刚好到点
    try std.testing.expect(j.dueAt(5000)); // 早已超过

    var zero = Job{ .id = "z", .trigger = .{ .every_sec = 0 }, .goal = "" };
    try std.testing.expect(!zero.dueAt(1)); // 0 间隔不触发，防自旋
    zero.last_run_unix = 0;
}

test "dueAt: at_unix 一次性触发" {
    var j = Job{ .id = "y", .trigger = .{ .at_unix = 2000 }, .goal = "" };
    try std.testing.expect(!j.dueAt(1999)); // 未到
    try std.testing.expect(j.dueAt(2000)); // 到点
    j.fired = true;
    try std.testing.expect(!j.dueAt(3000)); // 已触发，不再重复
}

test "dueAt: cron 暂不支持恒 false" {
    const j = Job{ .id = "c", .trigger = .{ .cron = "* * * * *" }, .goal = "" };
    try std.testing.expect(!j.dueAt(123456));
}

const TickCounter = struct {
    fired_ids: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,
    fn cb(ctx: *anyopaque, job: *Job) void {
        const self: *TickCounter = @ptrCast(@alignCast(ctx));
        self.fired_ids.append(self.gpa, job.id) catch {};
    }
};

test "tick: 只触发到点 job，并推进其状态" {
    const gpa = std.testing.allocator;
    var sch: Scheduler = .{};
    defer sch.deinit(gpa);
    try sch.add(gpa, .{ .id = "due", .trigger = .{ .every_sec = 10 }, .goal = "g1" });
    try sch.add(gpa, .{ .id = "future", .trigger = .{ .at_unix = 9999 }, .goal = "g2" });

    var counter = TickCounter{ .gpa = gpa };
    defer counter.fired_ids.deinit(gpa);

    const n = sch.tick(100, &counter, TickCounter.cb);
    try std.testing.expectEqual(@as(usize, 1), n); // 只有 due 到点
    try std.testing.expectEqual(@as(usize, 1), counter.fired_ids.items.len);
    try std.testing.expectEqualStrings("due", counter.fired_ids.items[0]);

    // due 的状态已推进：紧接着同一时刻不应再触发
    try std.testing.expectEqual(@as(usize, 0), sch.tick(100, &counter, TickCounter.cb));
    // 过了间隔后再次触发
    try std.testing.expectEqual(@as(usize, 1), sch.tick(120, &counter, TickCounter.cb));
}

test {
    std.testing.refAllDecls(@This());
}
