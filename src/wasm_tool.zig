//! Minimal Wasm tool package boundary.
//!
//! This module intentionally validates package shape only. It does not load or
//! execute Wasm, grant permissions, or depend on MCP/Wassette. The goal is a
//! small reviewable boundary Scoot can own before adding any runtime.
const std = @import("std");
const toml = @import("toml.zig");
const skill = @import("skill.zig");
const pathsafe = @import("paths.zig");

const manifest_read_limit: std.Io.Limit = .limited(64 * 1024);
const policy_read_limit: std.Io.Limit = .limited(64 * 1024);
const schema_read_limit: std.Io.Limit = .limited(256 * 1024);

pub const Manifest = struct {
    name: []const u8,
    description: []const u8,
    entry: []const u8,
    component: []const u8 = "component.wasm",
    input_schema: []const u8,
    output_schema: []const u8,
    capabilities: []const []const u8,
};

pub const Policy = struct {
    capabilities: []const []const u8,
};

pub const Summary = struct {
    name: []const u8,
    description: []const u8,
    entry: []const u8,
    component: []const u8,
    input_schema: []const u8,
    output_schema: []const u8,
    capabilities: []const []const u8,
    policy_capabilities: []const []const u8,
};

pub const Validation = union(enum) {
    valid: Summary,
    invalid: []const u8,
};

/// Validate a local Wasm tool package without executing anything.
pub fn validatePackage(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Validation {
    const cwd = std.Io.Dir.cwd();

    const manifest_path = try std.fs.path.join(arena, &.{ dir, "manifest.toml" });
    const manifest_bytes = cwd.readFileAlloc(io, manifest_path, arena, manifest_read_limit) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{ .invalid = "missing manifest.toml" },
        error.FileTooBig => return .{ .invalid = "manifest.toml exceeds 64 KiB" },
        else => return .{ .invalid = try std.fmt.allocPrint(arena, "cannot read manifest.toml: {s}", .{@errorName(err)}) },
    };
    const manifest_value = toml.parse(arena, manifest_bytes) catch return .{
        .invalid = "manifest.toml is not valid supported TOML",
    };
    const manifest = std.json.parseFromValueLeaky(Manifest, arena, manifest_value, .{
        .ignore_unknown_fields = true,
    }) catch return .{
        .invalid = "manifest.toml is missing required fields or has invalid field types",
    };
    if (validateManifest(arena, manifest)) |msg| return .{ .invalid = msg };

    const policy_path = try std.fs.path.join(arena, &.{ dir, "policy.toml" });
    const policy_bytes = cwd.readFileAlloc(io, policy_path, arena, policy_read_limit) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{ .invalid = "missing policy.toml" },
        error.FileTooBig => return .{ .invalid = "policy.toml exceeds 64 KiB" },
        else => return .{ .invalid = try std.fmt.allocPrint(arena, "cannot read policy.toml: {s}", .{@errorName(err)}) },
    };
    const policy_value = toml.parse(arena, policy_bytes) catch return .{
        .invalid = "policy.toml is not valid supported TOML",
    };
    const policy = std.json.parseFromValueLeaky(Policy, arena, policy_value, .{
        .ignore_unknown_fields = true,
    }) catch return .{
        .invalid = "policy.toml is missing required fields or has invalid field types",
    };
    if (validatePolicy(arena, manifest, policy)) |msg| return .{ .invalid = msg };

    const component_path = try std.fs.path.join(arena, &.{ dir, manifest.component });
    if (validateComponent(arena, io, dir, component_path)) |msg| return .{ .invalid = msg };

    if (validateJsonSchema(arena, io, dir, manifest.input_schema, "input schema")) |msg| return .{ .invalid = msg };
    if (validateJsonSchema(arena, io, dir, manifest.output_schema, "output schema")) |msg| return .{ .invalid = msg };

    return .{ .valid = .{
        .name = manifest.name,
        .description = manifest.description,
        .entry = manifest.entry,
        .component = manifest.component,
        .input_schema = manifest.input_schema,
        .output_schema = manifest.output_schema,
        .capabilities = manifest.capabilities,
        .policy_capabilities = policy.capabilities,
    } };
}

fn validateManifest(arena: std.mem.Allocator, m: Manifest) ?[]const u8 {
    if (!skill.isValidName(m.name)) return "name must use only ASCII letters, digits, '.', '_' or '-'";
    if (m.description.len == 0) return "description is required";
    if (!isValidEntry(m.entry)) return "entry must be a non-empty ASCII identifier";
    if (!isSafeRelativePath(m.component)) return "component path must be a safe relative path";
    if (!std.mem.endsWith(u8, m.component, ".wasm")) return "component path must end with .wasm";
    if (!isSafeRelativePath(m.input_schema)) return "input_schema must be a safe relative path";
    if (!isSafeRelativePath(m.output_schema)) return "output_schema must be a safe relative path";
    if (validateCapabilityList(arena, m.capabilities, "manifest capabilities")) |msg| return msg;
    return null;
}

fn validatePolicy(arena: std.mem.Allocator, manifest: Manifest, p: Policy) ?[]const u8 {
    if (validateCapabilityList(arena, p.capabilities, "policy capabilities")) |msg| return msg;
    for (p.capabilities) |cap| {
        if (!hasCapability(manifest.capabilities, cap)) {
            return std.fmt.allocPrint(
                arena,
                "policy capability `{s}` is not declared in manifest.toml",
                .{cap},
            ) catch "policy grants undeclared capability";
        }
    }
    return null;
}

fn validateJsonSchema(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    rel_path: []const u8,
    label: []const u8,
) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const path = std.fs.path.join(arena, &.{ dir, rel_path }) catch return "cannot build schema path";
    // symlink 逃逸防护（issue #54，与 #41 对齐）：isSafeRelativePath 只做词法过滤，后续
    // readFileAlloc 会跟随 symlink。对已存在目标做 realpath，确认仍落在包目录内。
    if (pathsafe.realPathEscapes(io, arena, dir, path))
        return std.fmt.allocPrint(arena, "{s} resolves outside the package directory (symlink escape)", .{label}) catch "schema resolves outside package directory";
    const bytes = cwd.readFileAlloc(io, path, arena, schema_read_limit) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return std.fmt.allocPrint(arena, "{s} file is missing", .{label}) catch "schema file is missing",
        error.FileTooBig => return std.fmt.allocPrint(arena, "{s} exceeds 256 KiB", .{label}) catch "schema file is too large",
        else => return std.fmt.allocPrint(arena, "cannot read {s}: {s}", .{ label, @errorName(err) }) catch "cannot read schema",
    };
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return std.fmt.allocPrint(
        arena,
        "{s} is not valid JSON",
        .{label},
    ) catch "schema is not valid JSON";
    return null;
}

fn validateComponent(arena: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    // symlink 逃逸防护（issue #54）：component 路径虽过 isSafeRelativePath 词法检查，但
    // statFile/openFile 会跟随 symlink。对已存在目标做 realpath，确认仍落在包目录内。
    if (pathsafe.realPathEscapes(io, arena, dir, path))
        return "component wasm file resolves outside the package directory (symlink escape)";
    const component_stat = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return "component wasm file is missing",
        else => return std.fmt.allocPrint(arena, "cannot stat component wasm file: {s}", .{@errorName(err)}) catch "cannot stat component wasm file",
    };
    if (component_stat.size == 0) return "component wasm file is empty";
    if (component_stat.size < 4) return "component wasm file is too small";

    var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return "component wasm file is missing",
        else => return std.fmt.allocPrint(arena, "cannot open component wasm file: {s}", .{@errorName(err)}) catch "cannot open component wasm file",
    };
    defer file.close(io);

    var magic: [4]u8 = undefined;
    const read = file.readPositionalAll(io, &magic, 0) catch |err| return std.fmt.allocPrint(
        arena,
        "cannot read component wasm file: {s}",
        .{@errorName(err)},
    ) catch "cannot read component wasm file";
    if (read != magic.len) return "component wasm file is too small";
    if (!std.mem.eql(u8, &magic, "\x00asm")) return "component wasm file must start with wasm magic bytes";
    return null;
}

fn validateCapabilityList(arena: std.mem.Allocator, caps: []const []const u8, label: []const u8) ?[]const u8 {
    if (caps.len == 0) return std.fmt.allocPrint(arena, "{s} must not be empty", .{label}) catch "capability list must not be empty";
    for (caps) |cap| {
        if (!isSupportedCapability(cap)) {
            return std.fmt.allocPrint(arena, "{s} contains unsupported capability `{s}`", .{ label, cap }) catch "unsupported capability";
        }
    }
    return null;
}

fn isSupportedCapability(cap: []const u8) bool {
    return std.mem.eql(u8, cap, "compute") or
        std.mem.eql(u8, cap, "read") or
        std.mem.eql(u8, cap, "write") or
        std.mem.eql(u8, cap, "net_read") or
        std.mem.eql(u8, cap, "net_write");
}

fn hasCapability(caps: []const []const u8, needle: []const u8) bool {
    for (caps) |cap| {
        if (std.mem.eql(u8, cap, needle)) return true;
    }
    return false;
}

fn isValidEntry(entry: []const u8) bool {
    if (entry.len == 0 or entry.len > 64) return false;
    for (entry) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') continue;
        return false;
    }
    return true;
}

fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (std.mem.endsWith(u8, path, "/") or std.mem.endsWith(u8, path, "\\")) return false;

    var segments = std.mem.splitAny(u8, path, "/\\");
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        if (segment[0] == '.') return false;
    }
    return true;
}

test "validatePackage: accepts minimal static wasm tool package" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_wasm_tool_validate_good";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, root ++ "/schema");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/manifest.toml",
        .data =
        \\name = "calculator"
        \\description = "Evaluate simple math expressions."
        \\entry = "call"
        \\component = "component.wasm"
        \\input_schema = "schema/input.json"
        \\output_schema = "schema/output.json"
        \\capabilities = ["compute"]
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/policy.toml",
        .data = "capabilities = [\"compute\"]\n",
    });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/component.wasm", .data = "\x00asm" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/schema/input.json", .data = "{\"type\":\"object\"}\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/schema/output.json", .data = "{\"type\":\"object\"}\n" });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const res = try validatePackage(arena.allocator(), io, root);
    const summary = switch (res) {
        .valid => |s| s,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("calculator", summary.name);
    try std.testing.expectEqualStrings("component.wasm", summary.component);
    try std.testing.expectEqual(@as(usize, 1), summary.policy_capabilities.len);
}

test "validatePackage: rejects missing files and unsafe manifest paths" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_wasm_tool_validate_bad";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const missing = try validatePackage(arena.allocator(), io, root);
    switch (missing) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expectEqualStrings("missing manifest.toml", msg),
    }

    try cwd.createDirPath(io, root ++ "/schema");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/manifest.toml",
        .data =
        \\name = "bad"
        \\description = "Bad package."
        \\entry = "call"
        \\component = "../component.wasm"
        \\input_schema = "schema/input.json"
        \\output_schema = "schema/output.json"
        \\capabilities = ["compute"]
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/policy.toml",
        .data = "capabilities = [\"compute\"]\n",
    });
    const unsafe = try validatePackage(arena.allocator(), io, root);
    switch (unsafe) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expectEqualStrings("component path must be a safe relative path", msg),
    }
}

test "validatePackage: rejects symlink that escapes the package directory (issue #54)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_wasm_tool_validate_symlink";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, root ++ "/pkg/schema");
    try cwd.createDirPath(io, root ++ "/outside");
    // 包外的“机密” JSON：词法安全的相对路径 + 包内 symlink 即可逃逸读取。
    try cwd.writeFile(io, .{ .sub_path = root ++ "/outside/secret.json", .data = "{\"leak\":true}\n" });
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/pkg/manifest.toml",
        .data =
        \\name = "escaper"
        \\description = "Tries to escape via symlink."
        \\entry = "call"
        \\component = "component.wasm"
        \\input_schema = "schema/input.json"
        \\output_schema = "schema/output.json"
        \\capabilities = ["compute"]
        \\
        ,
    });
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/pkg/policy.toml",
        .data = "capabilities = [\"compute\"]\n",
    });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/pkg/component.wasm", .data = "\x00asm" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/pkg/schema/output.json", .data = "{\"type\":\"object\"}\n" });
    // input.json 是指向包外机密文件的 symlink（词法上仍是安全相对路径）。
    cwd.symLink(io, root ++ "/outside/secret.json", root ++ "/pkg/schema/input.json", .{}) catch |e| {
        if (e == error.AccessDenied or e == error.PermissionDenied) return error.SkipZigTest;
        return e;
    };

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const res = try validatePackage(arena.allocator(), io, root ++ "/pkg");
    switch (res) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "outside the package directory") != null),
    }
}

test "validatePackage: rejects unsupported or undeclared policy capabilities" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_wasm_tool_validate_policy";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, root ++ "/schema");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/manifest.toml",
        .data =
        \\name = "cap-test"
        \\description = "Capability test."
        \\entry = "call"
        \\component = "component.wasm"
        \\input_schema = "schema/input.json"
        \\output_schema = "schema/output.json"
        \\capabilities = ["compute"]
        \\
        ,
    });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/component.wasm", .data = "\x00asm" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/schema/input.json", .data = "{\"type\":\"object\"}\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/schema/output.json", .data = "{\"type\":\"object\"}\n" });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    try cwd.writeFile(io, .{
        .sub_path = root ++ "/policy.toml",
        .data = "capabilities = [\"net_read\"]\n",
    });
    const undeclared = try validatePackage(arena.allocator(), io, root);
    switch (undeclared) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "not declared") != null),
    }

    try cwd.writeFile(io, .{
        .sub_path = root ++ "/policy.toml",
        .data = "capabilities = [\"ambient_power\"]\n",
    });
    const unsupported = try validatePackage(arena.allocator(), io, root);
    switch (unsupported) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "unsupported capability") != null),
    }
}

test {
    std.testing.refAllDecls(@This());
}
