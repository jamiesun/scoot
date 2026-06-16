//! 调度引擎：基于时间循环的触发器（见 ROADMAP 方向三）。
//! 通过类 IRC/Slack 指令管理：/schedule add | list | remove。
const std = @import("std");

pub const Trigger = union(enum) {
    /// 固定间隔（毫秒）。
    every: u64,
    /// 固定时间点（Unix 秒）。
    at: i64,
    /// Cron 表达式。
    cron: []const u8,
};

pub const Job = struct {
    id: []const u8,
    trigger: Trigger,
    goal: []const u8,
};

pub const Scheduler = struct {
    jobs: std.ArrayList(Job) = .empty,

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

    pub fn deinit(self: *Scheduler, gpa: std.mem.Allocator) void {
        self.jobs.deinit(gpa);
    }

    // TODO: tick()/run() 时间循环，到点唤起 Agent 执行 job.goal。
};

test {
    std.testing.refAllDecls(@This());
}
