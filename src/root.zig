//! Scoot — 轻量级 AI Agent 守护进程 (Daemon / CLI)。
//! 本文件是 `scoot` 库模块的根：汇总并再导出各子系统命名空间，
//! 既供 CLI (src/main.zig) 使用，也便于未来被其他可执行文件嵌入。
const std = @import("std");

/// 语义化版本号（与 build.zig.zon 保持一致）。
pub const version = "0.0.0";

pub const paths = @import("paths.zig");
pub const config = @import("config.zig");
pub const toml = @import("toml.zig");
pub const secret = @import("secret.zig");
pub const jsonio = @import("jsonio.zig");
pub const llm = @import("llm.zig");
pub const tools = @import("tools/tools.zig");
pub const skill = @import("skill.zig");
pub const wasm_tool = @import("wasm_tool.zig");
pub const session = @import("session.zig");
pub const agent = @import("agent.zig");
pub const schedule = @import("schedule.zig");
pub const audit = @import("audit.zig");
pub const policy = @import("policy.zig");
pub const regex = @import("regex.zig");

test {
    std.testing.refAllDecls(@This());
}
