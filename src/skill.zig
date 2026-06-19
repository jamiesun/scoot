//! Skill mechanism: mounts packaged capabilities and instructions as directories
//! for the agent, so Scoot can gain domain-specific operating knowledge without
//! code changes.
//!
//! A skill is a directory:
//!   <skill>/
//!     SKILL.md       Required: YAML front matter plus Markdown instructions.
//!     scripts/       Optional resources; execution still uses the bash sandbox.
//!     references/    Optional reference material loaded on demand.
//!
//! Progressive disclosure keeps context small:
//!   1) Discovery scans skill paths and parses only front matter, building a
//!      lightweight name+description index.
//!   2) Injection renders available skills as name+description+path into system
//!      context.
//!   3) Activation uses the native `skill` action to read SKILL.md by name when
//!      the model decides a skill is relevant. Full instructions are never
//!      preloaded, keeping context bounded.
//!   4) Execution of skill-provided scripts goes through the same bash tool
//!      sandbox, policy gate, and hard timeout as ordinary commands. Skills get
//!      no privileged execution channel.
//!
//! Design tradeoff: reading skill instructions is a native read-only agent
//! capability, implemented by the `skill` action in agent.zig, and intentionally
//! not execution-policy-gated. This keeps activation available in readonly and
//! other fail-closed modes. Scripts or commands that a skill asks the model to
//! execute still go through the global policy gate with no privileges. Reads are
//! audited as tool_call events. Per-skill `capabilities`, `allowed_tools`, and
//! `scope` are review declarations, not permission grants.
const std = @import("std");

/// Per-SKILL.md read limit: 1 MiB, far above typical instruction files.
const skill_read_limit: std.Io.Limit = .limited(1 << 20);

/// Lightweight metadata for one skill from SKILL.md front matter. Body text is
/// not resident here; progressive disclosure reads it only on activation.
pub const Skill = struct {
    /// Skill name from front-matter `name`.
    name: []const u8,
    /// One-line description from front-matter `description`.
    description: []const u8,
    /// Skill directory path; SKILL.md under it contains full instructions.
    dir: []const u8,
    /// Optional review declaration: capability types provided by the skill.
    capabilities: []const u8 = "",
    /// Optional review declaration: expected tool actions, not permission grants.
    allowed_tools: []const u8 = "",
    /// Optional review declaration: documentation scope.
    scope: []const u8 = "",
};

/// Parsed front-matter result. Slices borrow from the source text, with no allocation.
pub const Meta = struct {
    name: []const u8,
    description: []const u8,
    capabilities: []const u8 = "",
    allowed_tools: []const u8 = "",
    scope: []const u8 = "",
    compatibility_key: []const u8 = "",
    compatibility: []const u8 = "",
};

pub const Validation = union(enum) {
    valid: Meta,
    invalid: []const u8,
};

/// Parses SKILL.md YAML front matter and extracts only lightweight metadata that
/// Scoot cares about. Null means no valid front matter or missing name, so the
/// directory is not a skill and callers should skip it. Returned slices borrow
/// from `src`; callers must keep it alive. Malformed or truncated input returns
/// null and never panics.
pub fn parseFrontMatter(src: []const u8) ?Meta {
    // After leading whitespace/blank lines, the first line must be exactly "---".
    const after_open = stripOpenFence(std.mem.trimStart(u8, src, " \t\r\n")) orelse return null;

    var name: []const u8 = "";
    var description: []const u8 = "";
    var capabilities: []const u8 = "";
    var allowed_tools: []const u8 = "";
    var scope: []const u8 = "";
    var compatibility_key: []const u8 = "";
    var compatibility: []const u8 = "";
    var closed = false;

    var lines = std.mem.splitScalar(u8, after_open, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "---")) {
            closed = true;
            break;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = stripQuotes(std.mem.trim(u8, line[colon + 1 ..], " \t"));
        if (std.ascii.eqlIgnoreCase(key, "name")) {
            name = val;
        } else if (std.ascii.eqlIgnoreCase(key, "description")) {
            description = val;
        } else if (std.ascii.eqlIgnoreCase(key, "capabilities")) {
            capabilities = val;
        } else if (std.ascii.eqlIgnoreCase(key, "allowed_tools")) {
            allowed_tools = val;
        } else if (std.ascii.eqlIgnoreCase(key, "scope")) {
            scope = val;
        } else if (std.ascii.eqlIgnoreCase(key, "scoot_version") or
            std.ascii.eqlIgnoreCase(key, "compatibility") or
            std.ascii.eqlIgnoreCase(key, "requires_scoot"))
        {
            compatibility_key = key;
            compatibility = val;
        }
    }

    if (!closed) return null; // Missing closing fence invalidates front matter.
    if (name.len == 0) return null; // Nameless skills cannot be selected.
    return .{
        .name = name,
        .description = description,
        .capabilities = capabilities,
        .allowed_tools = allowed_tools,
        .scope = scope,
        .compatibility_key = compatibility_key,
        .compatibility = compatibility,
    };
}

/// Strictly validates a skill directory for authors/reviewers, with clear errors.
pub fn validateDir(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Validation {
    const cwd = std.Io.Dir.cwd();
    const md_path = try std.fs.path.join(arena, &.{ dir, "SKILL.md" });
    const bytes = cwd.readFileAlloc(io, md_path, arena, skill_read_limit) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{ .invalid = "missing SKILL.md" },
        else => return .{ .invalid = try std.fmt.allocPrint(arena, "cannot read SKILL.md: {s}", .{@errorName(err)}) },
    };
    const meta = parseFrontMatter(bytes) orelse return .{
        .invalid = "SKILL.md must start with YAML front matter containing a non-empty name",
    };
    if (!isValidName(meta.name)) return .{
        .invalid = "name must use only ASCII letters, digits, '.', '_' or '-'",
    };
    if (meta.description.len == 0) return .{
        .invalid = "description is required",
    };
    if (validateCapabilities(arena, meta.capabilities)) |msg| return .{ .invalid = msg };
    if (validateAllowedTools(arena, meta.allowed_tools)) |msg| return .{ .invalid = msg };
    if (validateScope(meta.scope)) |msg| return .{ .invalid = msg };
    if (meta.compatibility_key.len != 0) return .{
        .invalid = try std.fmt.allocPrint(
            arena,
            "unsupported compatibility declaration `{s}`; omit it until Scoot defines skill compatibility gates",
            .{meta.compatibility_key},
        ),
    };
    return .{ .valid = meta };
}

pub fn parseInlineList(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return &.{};
    if (s[0] == '[') {
        if (s.len < 2 or s[s.len - 1] != ']') return error.InvalidSkillList;
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
    }
    if (s.len == 0) return &.{};

    var items: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, s, ',');
    while (parts.next()) |part| {
        const item = stripQuotes(std.mem.trim(u8, part, " \t\r\n"));
        if (item.len == 0) return error.InvalidSkillList;
        try items.append(arena, item);
    }
    return items.items;
}

fn validateCapabilities(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const items = parseInlineList(arena, raw) catch return "capabilities must be an inline list such as [instructions, scripts]";
    for (items) |item| {
        if (std.mem.eql(u8, item, "instructions") or
            std.mem.eql(u8, item, "scripts") or
            std.mem.eql(u8, item, "references"))
        {
            continue;
        }
        return std.fmt.allocPrint(
            arena,
            "unsupported capability `{s}`; use instructions, scripts, or references",
            .{item},
        ) catch "unsupported capability";
    }
    return null;
}

fn validateAllowedTools(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const items = parseInlineList(arena, raw) catch return "allowed_tools must be an inline list such as [file_read, grep]";
    for (items) |item| {
        if (isKnownToolAction(item)) continue;
        return std.fmt.allocPrint(
            arena,
            "unknown allowed_tools entry `{s}`; use known tool action names",
            .{item},
        ) catch "unknown allowed_tools entry";
    }
    return null;
}

fn validateScope(raw: []const u8) ?[]const u8 {
    const scope = stripQuotes(std.mem.trim(u8, raw, " \t\r\n"));
    if (scope.len == 0) return null;
    if (std.mem.eql(u8, scope, "general") or
        std.mem.eql(u8, scope, "project") or
        std.mem.eql(u8, scope, "repository") or
        std.mem.eql(u8, scope, "domain") or
        std.mem.eql(u8, scope, "workflow"))
    {
        return null;
    }
    return "scope must be one of: general, project, repository, domain, workflow";
}

fn isKnownToolAction(name: []const u8) bool {
    return std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "file_read") or
        std.mem.eql(u8, name, "file_write") or
        std.mem.eql(u8, name, "file_edit") or
        std.mem.eql(u8, name, "grep") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "http_request") or
        std.mem.eql(u8, name, "parallel");
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

/// If `s` starts with a standalone "---" line, returns text after it.
fn stripOpenFence(s: []const u8) ?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return null;
    const first = std.mem.trimEnd(u8, s[0..nl], " \t\r");
    if (!std.mem.eql(u8, first, "---")) return null;
    return s[nl + 1 ..];
}

/// Removes paired leading/trailing quotes, common in YAML values.
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        const a = s[0];
        const b = s[s.len - 1];
        if ((a == '"' and b == '"') or (a == '\'' and b == '\'')) return s[1 .. s.len - 1];
    }
    return s;
}

/// Skill registry aggregating skills discovered from multiple search paths.
/// Metadata copies are owned by `gpa`; duplicate names keep the first discovery.
pub const Registry = struct {
    skills: std.ArrayList(Skill) = .empty,

    /// Scans one skill path by iterating direct subdirectories and registering
    /// those with SKILL.md and valid front matter. Missing/non-directory paths
    /// are silently skipped because skills are optional enhancements. A child
    /// without SKILL.md or with invalid front matter is skipped without affecting
    /// other entries.
    pub fn discover(self: *Registry, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue; // Skip hidden directories.

            const md_path = try std.fs.path.join(gpa, &.{ path, entry.name, "SKILL.md" });
            defer gpa.free(md_path);

            const bytes = cwd.readFileAlloc(io, md_path, gpa, skill_read_limit) catch |err| switch (err) {
                error.FileNotFound => continue, // This child is not a skill.
                else => return err,
            };
            defer gpa.free(bytes);

            const meta = parseFrontMatter(bytes) orelse continue;
            if (self.find(meta.name) != null) continue; // Duplicate name: first wins.

            const name = try gpa.dupe(u8, meta.name);
            errdefer gpa.free(name);
            const desc = try gpa.dupe(u8, meta.description);
            errdefer gpa.free(desc);
            const capabilities = try gpa.dupe(u8, meta.capabilities);
            errdefer gpa.free(capabilities);
            const allowed_tools = try gpa.dupe(u8, meta.allowed_tools);
            errdefer gpa.free(allowed_tools);
            const scope = try gpa.dupe(u8, meta.scope);
            errdefer gpa.free(scope);
            const skill_dir = try std.fs.path.join(gpa, &.{ path, entry.name });
            errdefer gpa.free(skill_dir);
            try self.skills.append(gpa, .{
                .name = name,
                .description = desc,
                .dir = skill_dir,
                .capabilities = capabilities,
                .allowed_tools = allowed_tools,
                .scope = scope,
            });
        }
    }

    /// Scans multiple search paths in order; later duplicate names are ignored.
    pub fn discoverAll(self: *Registry, gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8) !void {
        for (paths) |p| try self.discover(gpa, io, p);
    }

    /// Finds a discovered skill by name.
    pub fn find(self: *Registry, name: []const u8) ?*Skill {
        for (self.skills.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        return self.skills.items.len;
    }

    /// Renders discovered skills as a manifest for system context. Only
    /// name+description+path are included, not bodies. Returns "" when there are
    /// no skills. The manifest carries activation instructions itself.
    pub fn manifest(self: *const Registry, arena: std.mem.Allocator) ![]const u8 {
        if (self.skills.items.len == 0) return "";
        var aw = std.Io.Writer.Allocating.init(arena);
        const w = &aw.writer;
        try w.writeAll(
            \\## Available Skills
            \\The following skills are loaded for specialized tasks. Each skill directory contains SKILL.md with full instructions.
            \\Only when a skill is relevant, use action="skill" to read its instructions first: action_input={"name":"skill name"} (defaults to SKILL.md).
            \\Read other resources with {"name":"skill name","path":"references/xxx"}. Do not read irrelevant skills.
            \\Scripts or commands requested by skills still go through the normal tool sandbox, policy gate, and hard timeout.
            \\
            \\
        );
        for (self.skills.items) |s| {
            try w.print("- {s}: {s}\n  Read instructions: action=\"skill\", action_input={{\"name\":\"{s}\"}} (dir: {s})\n", .{ s.name, s.description, s.name, s.dir });
        }
        try w.writeAll("\nUnlisted skills do not exist; do not invent them.\n");
        return aw.written();
    }

    /// Frees all metadata copies and the list using the same `gpa` as discovery.
    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.skills.items) |s| {
            gpa.free(s.name);
            gpa.free(s.description);
            gpa.free(s.dir);
            gpa.free(s.capabilities);
            gpa.free(s.allowed_tools);
            gpa.free(s.scope);
        }
        self.skills.deinit(gpa);
    }
};

test "parseFrontMatter: parses name and description" {
    const src =
        \\---
        \\name: git-helper
        \\description: helps with git repository operations
        \\---
        \\# Body
        \\Some instructions.
    ;
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("git-helper", m.name);
    try std.testing.expectEqualStrings("helps with git repository operations", m.description);
}

test "parseFrontMatter: strips quotes, ignores unknown keys, and keeps colon in value" {
    const src =
        \\---
        \\name: "deploy"
        \\capabilities: [instructions, scripts]
        \\allowed_tools: [bash, file_read]
        \\scope: workflow
        \\description: 'deployment helper for ratio a:b'
        \\extra: ignore me
        \\---
        \\body
    ;
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("deploy", m.name);
    try std.testing.expectEqualStrings("deployment helper for ratio a:b", m.description);
    try std.testing.expectEqualStrings("[instructions, scripts]", m.capabilities);
    try std.testing.expectEqualStrings("[bash, file_read]", m.allowed_tools);
    try std.testing.expectEqualStrings("workflow", m.scope);
}

test "parseFrontMatter: recognizes compatibility declaration for validation rejection" {
    const src =
        \\---
        \\name: future
        \\description: future-version skill
        \\scoot_version: ">=1.0.0"
        \\---
        \\body
    ;
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("future", m.name);
    try std.testing.expectEqualStrings("scoot_version", m.compatibility_key);
    try std.testing.expectEqualStrings(">=1.0.0", m.compatibility);
}

test "parseFrontMatter: CRLF line ending" {
    const src = "---\r\nname: win\r\ndescription: handles Windows line endings\r\n---\r\nbody\r\n";
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("win", m.name);
    try std.testing.expectEqualStrings("handles Windows line endings", m.description);
}

test "parseFrontMatter: accepts minimal front matter" {
    const src = "\n\n  \n---\nname: lead\ndescription: has leading blank lines\n---\nbody";
    const m = parseFrontMatter(src) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("lead", m.name);
}

test "parseFrontMatter: malformed input returns null(defensive)" {
    try std.testing.expect(parseFrontMatter("") == null); // Empty.
    try std.testing.expect(parseFrontMatter("no front matter here") == null); // No fence.
    try std.testing.expect(parseFrontMatter("---\nname: x\ndescription: y\n") == null); // Missing close.
    try std.testing.expect(parseFrontMatter("---\ndescription: missing-name\n---\n") == null); // Missing name.
    try std.testing.expect(parseFrontMatter("---") == null); // Partial fence only.
    try std.testing.expect(parseFrontMatter("--- not a fence\nname: x\n---\n") == null); // Dirty open fence.
}

test "Registry: discover scans directories,parses,deduplicated,renders manifest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_skill_discover_test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // Valid alpha skill.
    try cwd.createDirPath(io, root ++ "/alpha");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/alpha/SKILL.md",
        .data = "---\nname: alpha\ndescription: first skill\n---\n# Alpha\nDo task A.",
    });
    // beta has no front matter and should be skipped.
    try cwd.createDirPath(io, root ++ "/beta");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/beta/SKILL.md", .data = "I have no front matter" });
    // gamma has no SKILL.md and should be skipped.
    try cwd.createDirPath(io, root ++ "/gamma");

    var reg: Registry = .{};
    defer reg.deinit(gpa);
    try reg.discover(gpa, io, root);

    try std.testing.expectEqual(@as(usize, 1), reg.count());
    const s = reg.find("alpha") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("first skill", s.description);
    try std.testing.expect(std.mem.endsWith(u8, s.dir, "/alpha"));
    try std.testing.expect(reg.find("beta") == null);

    // Duplicate name: scanning again still leaves one alpha.
    try reg.discover(gpa, io, root);
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try reg.manifest(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "first skill") != null);
    // The manifest guides the model to native `skill`, not bash cat, by name.
    try std.testing.expect(std.mem.indexOf(u8, text, "action=\"skill\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "{\"name\":\"alpha\"}") != null);
}

test "Registry: missing paths are skipped silently and manifest is empty" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var reg: Registry = .{};
    defer reg.deinit(gpa);
    try reg.discoverAll(gpa, io, &.{"/tmp/scoot_no_such_skill_dir_xyz"});
    try std.testing.expectEqual(@as(usize, 0), reg.count());
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqualStrings("", try reg.manifest(arena.allocator()));
}

test "validateDir: accepts minimal valid skill directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_skill_validate_good";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, root);
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/SKILL.md",
        .data = "---\nname: good-skill\ndescription: A valid local skill.\ncapabilities: [instructions, references]\nallowed_tools: [file_read, grep, glob]\nscope: workflow\n---\n# Good\n",
    });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const res = try validateDir(arena.allocator(), io, root);
    const meta = switch (res) {
        .valid => |m| m,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("good-skill", meta.name);
    try std.testing.expectEqualStrings("[instructions, references]", meta.capabilities);
    try std.testing.expectEqualStrings("[file_read, grep, glob]", meta.allowed_tools);
    try std.testing.expectEqualStrings("workflow", meta.scope);
}

test "validateDir: rejects missing description, invalid name, invalid metadata, and compatibility declarations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/scoot_skill_validate_bad";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    try cwd.createDirPath(io, root ++ "/no_desc");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/no_desc/SKILL.md",
        .data = "---\nname: no-desc\n---\n# Missing description\n",
    });
    try cwd.createDirPath(io, root ++ "/bad_name");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/bad_name/SKILL.md",
        .data = "---\nname: bad/name\ndescription: Invalid name.\n---\n# Bad\n",
    });
    try cwd.createDirPath(io, root ++ "/future");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/future/SKILL.md",
        .data = "---\nname: future\ndescription: Future gate.\nscoot_version: \">=1.0.0\"\n---\n# Future\n",
    });
    try cwd.createDirPath(io, root ++ "/bad_tool");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/bad_tool/SKILL.md",
        .data = "---\nname: bad-tool\ndescription: Bad tool.\nallowed_tools: [telepathy]\n---\n# Bad\n",
    });
    try cwd.createDirPath(io, root ++ "/bad_capability");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/bad_capability/SKILL.md",
        .data = "---\nname: bad-cap\ndescription: Bad capability.\ncapabilities: [network]\n---\n# Bad\n",
    });
    try cwd.createDirPath(io, root ++ "/bad_scope");
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/bad_scope/SKILL.md",
        .data = "---\nname: bad-scope\ndescription: Bad scope.\nscope: universal\n---\n# Bad\n",
    });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const no_desc = try validateDir(arena.allocator(), io, root ++ "/no_desc");
    switch (no_desc) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expectEqualStrings("description is required", msg),
    }

    const bad_name = try validateDir(arena.allocator(), io, root ++ "/bad_name");
    switch (bad_name) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "name must") != null),
    }

    const future = try validateDir(arena.allocator(), io, root ++ "/future");
    switch (future) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "unsupported compatibility") != null),
    }

    const bad_tool = try validateDir(arena.allocator(), io, root ++ "/bad_tool");
    switch (bad_tool) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "unknown allowed_tools") != null),
    }

    const bad_capability = try validateDir(arena.allocator(), io, root ++ "/bad_capability");
    switch (bad_capability) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "unsupported capability") != null),
    }

    const bad_scope = try validateDir(arena.allocator(), io, root ++ "/bad_scope");
    switch (bad_scope) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "scope must") != null),
    }
}

test "validateDir: missing SKILL.md gives a clear failure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const res = try validateDir(arena.allocator(), std.testing.io, "/tmp/scoot_skill_missing_xyz");
    switch (res) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expectEqualStrings("missing SKILL.md", msg),
    }
}

test {
    std.testing.refAllDecls(@This());
}
