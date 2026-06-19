//! Scoot stable library API.
//!
//! The package root is intentionally tiny: an opaque runtime lifecycle facade.
//! CLI-only and implementation modules live behind `internal.zig` and are not
//! part of the semver contract.
const std = @import("std");
const api = @import("api.zig");

pub const version = api.version;
pub const Runtime = api.Runtime;
pub const Options = api.Options;
pub const start = api.start;
pub const run = api.run;
pub const stop = api.stop;

fn publicApiAllowed(name: []const u8) bool {
    const allowed = [_][]const u8{
        "version",
        "Runtime",
        "Options",
        "start",
        "run",
        "stop",
    };
    for (allowed) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

test "public API decls stay whitelisted (issue #106)" {
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        try std.testing.expect(publicApiAllowed(decl.name));
    }
}

test {
    std.testing.refAllDecls(@This());
}
