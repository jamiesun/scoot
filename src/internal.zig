//! Internal module root for the Scoot CLI and repository tests.
//!
//! External embedders should import the package root (`src/root.zig`) instead.
//! That root intentionally exposes a smaller, semver-managed API. This module
//! keeps the executable free to use private subsystems without making them part
//! of the public contract.
const std = @import("std");

pub const api = @import("api.zig");

pub const version = api.version;

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
pub const policy_hook = @import("policy_hook.zig");
pub const regex = @import("regex.zig");

test {
    std.testing.refAllDecls(@This());
}
