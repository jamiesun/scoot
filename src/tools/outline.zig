//! Zero-dependency structure outline: lightweight language-specific line
//! heuristics extract functions, type signatures, and heading hierarchy from
//! source or Markdown, giving the agent a low-token "inspect structure first"
//! overview (issue #77).
//!
//! Design stance: intentionally avoid ASTs or external ast-grep because they
//! conflict with a self-contained single binary. This module is best-effort:
//! enough structure, not exact parsing. Zig and Markdown use precise rules for
//! this repo's own code and docs; other languages use generic keyword-prefix
//! heuristics with unavoidable misses and false positives.
const std = @import("std");

/// Outline entry cap; huge files cannot make the overview itself explode.
pub const max_entries: usize = 400;

pub const Lang = enum { zig, markdown, generic };

/// One structure line: 1-based line number plus compact text borrowed from input.
pub const Entry = struct {
    line: usize,
    text: []const u8,
};

pub const Result = struct {
    lang: Lang,
    entries: []const Entry,
    /// True when entries hit max_entries and the useful outline is incomplete.
    truncated: bool = false,
};

/// Guesses language by extension; unknown paths are generic.
pub fn detectLang(path: []const u8) Lang {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return .generic;
    const ext = path[dot + 1 ..];
    if (std.ascii.eqlIgnoreCase(ext, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(ext, "md") or
        std.ascii.eqlIgnoreCase(ext, "markdown") or
        std.ascii.eqlIgnoreCase(ext, "mdown") or
        std.ascii.eqlIgnoreCase(ext, "mkd")) return .markdown;
    return .generic;
}

/// Extracts structure lines from already-read text. `Entry.text` borrows `text`.
pub fn extract(arena: std.mem.Allocator, text: []const u8, lang: Lang) !Result {
    var list: std.ArrayList(Entry) = .empty;
    var truncated = false;
    var in_fence = false; // Markdown only: ignore headings inside fenced code.

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_with_cr| {
        line_no += 1;
        const raw = std.mem.trimEnd(u8, raw_with_cr, "\r");
        const trimmed = std.mem.trimStart(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        const indent = raw.len - trimmed.len;

        const hit: ?[]const u8 = switch (lang) {
            .zig => zigMatch(indent, trimmed),
            .markdown => mdMatch(&in_fence, trimmed),
            .generic => genericMatch(indent, trimmed),
        };
        if (hit) |sig| {
            if (list.items.len >= max_entries) {
                truncated = true;
                break;
            }
            try list.append(arena, .{ .line = line_no, .text = sig });
        }
    }

    return .{ .lang = lang, .entries = try list.toOwnedSlice(arena), .truncated = truncated };
}

/// Removes trailing ` {}` / ` {` and whitespace to keep outlines compact.
fn cleanSig(trimmed: []const u8) []const u8 {
    var s = std.mem.trimEnd(u8, trimmed, " \t");
    if (std.mem.endsWith(u8, s, "{}")) {
        s = std.mem.trimEnd(u8, s[0 .. s.len - 2], " \t");
    } else if (s.len > 0 and s[s.len - 1] == '{') {
        s = std.mem.trimEnd(u8, s[0 .. s.len - 1], " \t");
    }
    return s;
}

fn startsWithAny(s: []const u8, comptime prefixes: []const []const u8) bool {
    inline for (prefixes) |p| {
        if (std.mem.startsWith(u8, s, p)) return true;
    }
    return false;
}

/// Zig: functions/tests at any indentation, including struct methods, plus
/// top-level types and public declarations. Skips top-level imports as noise.
fn zigMatch(indent: usize, trimmed: []const u8) ?[]const u8 {
    if (startsWithAny(trimmed, &.{
        "pub fn ",    "fn ",            "pub inline fn ", "inline fn ",
        "export fn ", "pub export fn ", "test ",
    })) return cleanSig(trimmed);
    if (indent == 0) {
        if (std.mem.indexOf(u8, trimmed, "= @import(") != null) return null;
        if (startsWithAny(trimmed, &.{ "pub const ", "const ", "pub var ", "var ", "comptime " }))
            return cleanSig(trimmed);
    }
    return null;
}

/// Markdown: ATX headings (`#`..`######` followed by space), excluding fences.
fn mdMatch(in_fence: *bool, trimmed: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
        in_fence.* = !in_fence.*;
        return null;
    }
    if (in_fence.*) return null;
    var h: usize = 0;
    while (h < trimmed.len and trimmed[h] == '#') : (h += 1) {}
    if (h >= 1 and h <= 6 and h < trimmed.len and trimmed[h] == ' ') return trimmed;
    return null;
}

/// Generic heuristic: match definition keyword prefixes across Python, JS/TS,
/// Go, Rust, Java, C#, and similar languages. Indentation is capped at <= 4
/// spaces to reduce noise from deep blocks. Type-led C/C++ definitions are a
/// known miss.
fn genericMatch(indent: usize, trimmed: []const u8) ?[]const u8 {
    if (indent > 4) return null;
    if (startsWithAny(trimmed, &.{
        "def ",    "class ",  "func ",    "function ",  "fn ",
        "pub fn ", "struct ", "type ",    "interface ", "impl ",
        "trait ",  "enum ",   "module ",  "namespace ", "package ",
        "export ", "public ", "private ", "protected ", "async ",
    })) return cleanSig(trimmed);
    return null;
}

test "detectLang:detects zig / markdown / other by extension" {
    try std.testing.expectEqual(Lang.zig, detectLang("src/main.zig"));
    try std.testing.expectEqual(Lang.markdown, detectLang("README.md"));
    try std.testing.expectEqual(Lang.markdown, detectLang("docs/X.MARKDOWN"));
    try std.testing.expectEqual(Lang.generic, detectLang("a/b.py"));
    try std.testing.expectEqual(Lang.generic, detectLang("Makefile"));
}

test "extract zig:extracts functions / tests / top-level types and skips imports/local consts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\const std = @import("std");
        \\pub const Agent = struct {
        \\    io: std.Io,
        \\    pub fn run(self: *Agent) !void {
        \\        const local = 1;
        \\        _ = local;
        \\    }
        \\};
        \\fn helper() void {}
        \\test "something" {}
    ;
    const r = try extract(arena, src, .zig);
    try std.testing.expectEqual(Lang.zig, r.lang);

    // Expected hits: Agent type, run method, helper, test; no import or local const.
    try std.testing.expect(hasLineText(r.entries, "pub const Agent = struct"));
    try std.testing.expect(hasLineText(r.entries, "pub fn run(self: *Agent) !void"));
    try std.testing.expect(hasLineText(r.entries, "fn helper() void"));
    try std.testing.expect(hasLineText(r.entries, "test \"something\""));
    for (r.entries) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.text, "@import") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.text, "const local") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.text, "io: std.Io") == null);
    }
}

test "extract markdown:extracts ATX headings and ignores # inside fenced code blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const md =
        \\# Title
        \\intro text
        \\## Section A
        \\```sh
        \\# not a heading (in fence)
        \\```
        \\### Subsection
        \\#nospace is not a heading
    ;
    const r = try extract(arena, md, .markdown);
    try std.testing.expectEqual(@as(usize, 3), r.entries.len);
    try std.testing.expect(hasLineText(r.entries, "# Title"));
    try std.testing.expect(hasLineText(r.entries, "## Section A"));
    try std.testing.expect(hasLineText(r.entries, "### Subsection"));
}

test "extract generic symbols and headings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const py =
        \\import os
        \\class Foo:
        \\    def method(self):
        \\        def deeply_nested():
        \\            pass
        \\def top_level():
        \\    return 1
    ;
    const r = try extract(arena, py, .generic);
    try std.testing.expect(hasLineText(r.entries, "class Foo:"));
    try std.testing.expect(hasLineText(r.entries, "def method(self):"));
    try std.testing.expect(hasLineText(r.entries, "def top_level():"));
    // Deeply indented nested def is ignored; import is not a definition keyword.
    for (r.entries) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.text, "deeply_nested") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.text, "import os") == null);
    }
}

test "extract:sets truncated when exceeding max_entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < max_entries + 50) : (i += 1) try buf.appendSlice(arena, "fn f() void {}\n");
    const r = try extract(arena, buf.items, .zig);
    try std.testing.expectEqual(max_entries, r.entries.len);
    try std.testing.expect(r.truncated);
}

fn hasLineText(entries: []const Entry, want: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e.text, want)) return true;
    }
    return false;
}
