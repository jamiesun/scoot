//! 零依赖结构骨架（outline）：用按语言的轻量**行启发式**从源码 / Markdown 抽出函数与
//! 类型签名、标题层级，给 agent 一份「先看结构再决定要不要窗口读」的低 token 概览
//! （issue #77）。
//!
//! 取向（铁律：自包含单二进制）：刻意**不**引入 AST / 外部 ast-grep——那与零依赖单二进制
//! 冲突。故本模块是 best-effort：求「够用的骨架」而非精确解析。Zig / Markdown 走精确规则
//! （仓库自身语言 + 文档），其余语言走一组关键字前缀的通用启发式（不可避免有漏/误）。
const std = @import("std");

/// 骨架行数上限：超大文件也不让概览本身爆 token（超出即截断并在观察里注明）。
pub const max_entries: usize = 400;

pub const Lang = enum { zig, markdown, generic };

/// 一条结构行：1 起行号 + 精简文本（指向输入 `text`，零拷贝；调用方须保证 text 生命周期）。
pub const Entry = struct {
    line: usize,
    text: []const u8,
};

pub const Result = struct {
    lang: Lang,
    entries: []const Entry,
    /// 命中数达到 max_entries 被截断（仍是有用骨架，只是不完整）。
    truncated: bool = false,
};

/// 按扩展名猜测语言；未知 → generic。
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

/// 从已读入的文本抽结构行。`Entry.text` 指向 `text` 的切片（零拷贝）。
pub fn extract(arena: std.mem.Allocator, text: []const u8, lang: Lang) !Result {
    var list: std.ArrayList(Entry) = .empty;
    var truncated = false;
    var in_fence = false; // 仅 markdown：围栏代码块内不当标题。

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

/// 去掉签名行尾部的 ` {}` / ` {` 与尾随空白，让骨架更紧凑（不改变可读性）。
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

/// Zig：函数 / 测试（任意缩进，含 struct 内方法）+ 顶层（缩进 0）类型与公开声明。
/// 跳过顶层 `... = @import(...)` 导入行（低价值噪声）。
fn zigMatch(indent: usize, trimmed: []const u8) ?[]const u8 {
    if (startsWithAny(trimmed, &.{
        "pub fn ",     "fn ",        "pub inline fn ", "inline fn ",
        "export fn ",  "pub export fn ", "test ",
    })) return cleanSig(trimmed);
    if (indent == 0) {
        if (std.mem.indexOf(u8, trimmed, "= @import(") != null) return null;
        if (startsWithAny(trimmed, &.{ "pub const ", "const ", "pub var ", "var ", "comptime " }))
            return cleanSig(trimmed);
    }
    return null;
}

/// Markdown：ATX 标题（`#`..`######` 后跟空格），围栏代码块（``` / ~~~）内不计。
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

/// 通用启发式：按一组定义关键字前缀匹配（覆盖 Python/JS/TS/Go/Rust/Java/C# 等关键字引导
/// 的语言）。限缩进 ≤ 4（顶层 + 一层嵌套，如类内方法）压噪。对 C/C++ 这类「类型引导」定义
/// 会漏，属已知取舍。
fn genericMatch(indent: usize, trimmed: []const u8) ?[]const u8 {
    if (indent > 4) return null;
    if (startsWithAny(trimmed, &.{
        "def ",       "class ",     "func ",      "function ", "fn ",
        "pub fn ",    "struct ",    "type ",      "interface ", "impl ",
        "trait ",     "enum ",      "module ",    "namespace ", "package ",
        "export ",    "public ",    "private ",   "protected ", "async ",
    })) return cleanSig(trimmed);
    return null;
}

test "detectLang：按扩展名识别 zig / markdown / 其它" {
    try std.testing.expectEqual(Lang.zig, detectLang("src/main.zig"));
    try std.testing.expectEqual(Lang.markdown, detectLang("README.md"));
    try std.testing.expectEqual(Lang.markdown, detectLang("docs/X.MARKDOWN"));
    try std.testing.expectEqual(Lang.generic, detectLang("a/b.py"));
    try std.testing.expectEqual(Lang.generic, detectLang("Makefile"));
}

test "extract zig：抓函数 / 测试 / 顶层类型，跳过 import 与局部 const" {
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

    // 期望命中：Agent 类型、run 方法、helper、test；不含 import 与局部 const。
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

test "extract markdown：抓 ATX 标题，围栏代码块内的 # 不计" {
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

test "extract generic：关键字引导的定义命中，深缩进忽略" {
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
    // 深缩进（>4 空格）的嵌套 def 被忽略，import 不是定义关键字。
    for (r.entries) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.text, "deeply_nested") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.text, "import os") == null);
    }
}

test "extract：超过 max_entries 截断并置位" {
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
