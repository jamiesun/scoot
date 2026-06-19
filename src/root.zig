//! Scoot — 轻量级 AI Agent 守护进程 (Daemon / CLI)。
//! 本文件是 `scoot` 库模块的根：汇总并再导出各子系统命名空间，
//! 既供 CLI (src/main.zig) 使用，也便于未来被其他可执行文件嵌入。
const std = @import("std");

/// 语义化版本号。单一事实源为 build.zig.zon 的 `.version`，经 build.zig 通过 build_options
/// 注入；发布时由 release 工作流用 `-Dversion=<tag>` 覆盖，确保二进制版本与 git tag 一致。
pub const version = @import("build_options").version;

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
pub const compressor = @import("compressor.zig");
pub const agent = @import("agent.zig");
pub const obs = @import("obs.zig");
pub const schedule = @import("schedule.zig");
pub const daemon = @import("daemon.zig");
pub const audit = @import("audit.zig");
pub const policy = @import("policy.zig");
pub const regex = @import("regex.zig");

test {
    std.testing.refAllDecls(@This());
}
