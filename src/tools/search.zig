//! Search tools: grep for content using the local ReDoS-immune regex engine,
//! and glob for paths with independent wildcard matching.
//!
//! Self-contained rationale matches file.zig: trimmed or embedded Linux may not
//! have system grep/find. grep reuses `regex.zig`, which is linear-time so
//! model-generated regexes cannot pin the CPU. glob does not reuse regex because
//! path wildcard semantics differ: `*` does not cross `/`, while `**` does.
const std = @import("std");
const regex = @import("../regex.zig");

/// Grep hit: 1-based line number plus original line text borrowed from input.
pub const Hit = struct {
    line: usize,
    text: []const u8,
};

/// Default single-read limit (1 MiB), aligned with file.read.
pub const default_read_limit: std.Io.Limit = .limited(1 << 20);

/// Glob traversal guardrails: maximum depth and collected result count.
pub const max_glob_depth: usize = 32;
pub const default_max_results: usize = 500;
/// Default maximum reported grep hits to keep context bounded.
pub const default_max_hits: usize = 200;
/// Glob pattern length cap, aligned with regex.max_pattern_len (issue #37).
pub const max_glob_pattern_len: usize = 4096;
/// Maximum directory entries visited by one glob. This bounds time and arena
/// memory by tree size, including node_modules, rather than hit count
/// (issue #38). Hitting the cap returns already-collected partial results.
pub const max_glob_entries: usize = 100_000;
/// Backtracking step budget for globRec, hard-capping CPU per match and blocking
/// superlinear pathological patterns such as `*a*a*...*b` (issue #37).
const glob_match_budget: u64 = 5_000_000;
/// Heavy directory names skipped by glob traversal; dotfiles are skipped in walk.
const ignored_dir_names = [_][]const u8{"node_modules"};

/// Runs line-by-line regex matching over text and returns hits with line numbers.
/// The pattern is compiled once and the matcher is reused across lines.
pub fn grepText(arena: std.mem.Allocator, pattern: []const u8, text: []const u8, max_hits: usize) ![]Hit {
    var re = try regex.Regex.compile(arena, pattern);
    var m = try regex.Matcher.init(arena, &re);

    var hits: std.ArrayList(Hit) = .empty;
    var ln: usize = 1;
    var start: usize = 0;
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        if (text[idx] == '\n') {
            if (m.matches(text[start..idx])) {
                try hits.append(arena, .{ .line = ln, .text = text[start..idx] });
                if (hits.items.len >= max_hits) return hits.toOwnedSlice(arena);
            }
            start = idx + 1;
            ln += 1;
        }
    }
    if (start < text.len and hits.items.len < max_hits) {
        if (m.matches(text[start..])) {
            try hits.append(arena, .{ .line = ln, .text = text[start..] });
        }
    }
    return hits.toOwnedSlice(arena);
}

/// Reads a file and greps its content. Path is relative to cwd.
pub fn grepFile(
    arena: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
    path: []const u8,
    max_hits: usize,
) ![]Hit {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, default_read_limit);
    return grepText(arena, pattern, text, max_hits);
}

/// Grep context block (issue #76): one continuous line range, with adjacent or
/// overlapping hits merged, plus a mask for hit lines. Line slices borrow from
/// the searched text, whose source is arena-owned. This lets the agent receive
/// nearby context without a follow-up whole-file read.
pub const ContextBlock = struct {
    start_line: usize, // 1-based first line in the block.
    lines: []const []const u8, // Original block lines, without newlines.
    hit_mask: []const bool, // Same length as lines: true=hit, false=context.
};

/// Context line cap to prevent one large context request from consuming budget.
pub const max_grep_context: usize = 20;

/// Grep with context: returns blocks containing each hit plus `context` lines
/// before and after. Adjacent/overlapping blocks are merged like grep -C.
/// `max_hits` limits hit lines, not blocks or total lines. `context` is clamped.
pub fn grepTextContext(
    arena: std.mem.Allocator,
    pattern: []const u8,
    text: []const u8,
    max_hits: usize,
    context: usize,
) ![]ContextBlock {
    const ctx = @min(context, max_grep_context);

    // Split lines without newlines; trailing newline does not add an empty line.
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        if (text[idx] == '\n') {
            try lines.append(arena, text[start..idx]);
            start = idx + 1;
        }
    }
    if (start < text.len) try lines.append(arena, text[start..]);
    const total = lines.items.len;
    if (total == 0) return &.{};

    // 0-based hit line numbers, capped by max_hits.
    var re = try regex.Regex.compile(arena, pattern);
    var m = try regex.Matcher.init(arena, &re);
    var hit_idx: std.ArrayList(usize) = .empty;
    for (lines.items, 0..) |line, i| {
        if (m.matches(line)) {
            try hit_idx.append(arena, i);
            if (hit_idx.items.len >= max_hits) break;
        }
    }
    if (hit_idx.items.len == 0) return &.{};

    // Expand each hit to [hit-ctx, hit+ctx] and merge adjacent/overlapping ranges.
    var blocks: std.ArrayList(ContextBlock) = .empty;
    var bi: usize = 0;
    while (bi < hit_idx.items.len) {
        const first = hit_idx.items[bi];
        const lo = if (first >= ctx) first - ctx else 0;
        var hi = @min(total - 1, first + ctx);
        var bj = bi + 1;
        while (bj < hit_idx.items.len) : (bj += 1) {
            const h = hit_idx.items[bj];
            const h_lo = if (h >= ctx) h - ctx else 0;
            if (h_lo > hi + 1) break; // Gap: start another block.
            hi = @min(total - 1, h + ctx);
        }
        const n = hi - lo + 1;
        const blk_lines = try arena.alloc([]const u8, n);
        const blk_mask = try arena.alloc(bool, n);
        for (0..n) |k| {
            blk_lines[k] = lines.items[lo + k];
            blk_mask[k] = false;
        }
        for (hit_idx.items[bi..bj]) |h| blk_mask[h - lo] = true;
        try blocks.append(arena, .{ .start_line = lo + 1, .lines = blk_lines, .hit_mask = blk_mask });
        bi = bj;
    }
    return blocks.toOwnedSlice(arena);
}

/// Reads a file and performs contextual grep. Path is relative to cwd.
pub fn grepFileContext(
    arena: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
    path: []const u8,
    max_hits: usize,
    context: usize,
) ![]ContextBlock {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, default_read_limit);
    return grepTextContext(arena, pattern, text, max_hits, context);
}

/// Matches paths under `root` with a glob pattern and returns cwd-relative paths
/// usable by file_read. The pattern is relative to `root`; `*`/`?`/`[]` do not
/// cross `/`, while `**` crosses directories. Hidden files are skipped.
pub fn glob(
    arena: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
    root: []const u8,
    max_results: usize,
) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    // Pathologically long patterns produce no matches without traversal.
    if (pattern.len > max_glob_pattern_len) return results.toOwnedSlice(arena);
    var visited: usize = 0;
    try walk(arena, io, &results, pattern, root, "", 0, max_results, &visited);
    return results.toOwnedSlice(arena);
}

/// Recursively walks directories, tests each relative path against the glob, and
/// collects usable paths under the root prefix. `visited` counts entries across
/// the whole subtree and stops at `max_glob_entries`, bounding cost by tree size.
fn walk(
    arena: std.mem.Allocator,
    io: std.Io,
    results: *std.ArrayList([]const u8),
    pattern: []const u8,
    root: []const u8,
    rel: []const u8,
    depth: usize,
    max_results: usize,
    visited: *usize,
) !void {
    if (results.items.len >= max_results) return;
    if (depth > max_glob_depth) return;

    const here = if (rel.len == 0) root else try std.fs.path.join(arena, &.{ root, rel });
    var dir = std.Io.Dir.cwd().openDir(io, here, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue; // Skip hidden entries.
        visited.* += 1;
        if (visited.* > max_glob_entries) return; // Entry budget exhausted; return partial results.
        const child_rel = if (rel.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fs.path.join(arena, &.{ rel, entry.name });

        if (globMatch(pattern, child_rel)) {
            const full = if (std.mem.eql(u8, root, ".") or root.len == 0)
                child_rel
            else
                try std.fs.path.join(arena, &.{ root, child_rel });
            try results.append(arena, full);
            if (results.items.len >= max_results) return;
        }
        // Recurse into `.directory` directly. `.unknown`, such as DT_UNKNOWN on
        // some filesystems, needs stat to avoid silently skipping real
        // directories (issue #40). Do not follow symlinks; only plain
        // directories recurse, preserving loop and escape protection.
        const is_dir = switch (entry.kind) {
            .directory => true,
            .unknown => blk: {
                const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch break :blk false;
                break :blk st.kind == .directory;
            },
            else => false,
        };
        if (is_dir and !isIgnoredDir(entry.name)) {
            try walk(arena, io, results, pattern, root, child_rel, depth + 1, max_results, visited);
        }
    }
}

/// Whether a directory is heavy enough to skip (issue #38).
fn isIgnoredDir(name: []const u8) bool {
    for (ignored_dir_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Full-path glob match: `*`/`?`/`[]` do not cross `/`; `**` crosses directories
/// and `**/` also matches zero directory levels.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (pattern.len > max_glob_pattern_len) return false; // Pathologically long pattern.
    var budget: u64 = glob_match_budget;
    return globRec(pattern, 0, path, 0, &budget);
}

fn globRec(pat: []const u8, p0: usize, str: []const u8, s0: usize, budget: *u64) bool {
    // Hard cap backtracking to prevent pathological superlinear behavior. Real
    // matches are found greedily within budget; exhaustion only occurs on
    // unsatisfiable pathological backtracking.
    if (budget.* == 0) return false;
    budget.* -= 1;
    var pi = p0;
    var si = s0;
    while (pi < pat.len) {
        const pc = pat[pi];
        switch (pc) {
            '*' => {
                if (pi + 1 < pat.len and pat[pi + 1] == '*') {
                    // '**' crosses directories. When followed by '/', '**/' can
                    // match zero levels or any '<dirs>/' prefix.
                    if (pi + 2 < pat.len and pat[pi + 2] == '/') {
                        const rest = pi + 3;
                        if (globRec(pat, rest, str, si, budget)) return true; // Zero directory levels.
                        var k = si;
                        while (k < str.len) : (k += 1) {
                            if (str[k] == '/' and globRec(pat, rest, str, k + 1, budget)) return true;
                        }
                        return false;
                    }
                    // Trailing '**' or '**' before non-'/' matches any chars, including '/'.
                    const rest = pi + 2;
                    var k = si;
                    while (k <= str.len) : (k += 1) {
                        if (globRec(pat, rest, str, k, budget)) return true;
                    }
                    return false;
                }
                // Single '*' matches any non-'/' span in this path segment, including empty.
                const rest = pi + 1;
                var k = si;
                while (true) {
                    if (globRec(pat, rest, str, k, budget)) return true;
                    if (k >= str.len or str[k] == '/') return false;
                    k += 1;
                }
            },
            '?' => {
                if (si >= str.len or str[si] == '/') return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                if (si >= str.len or str[si] == '/') return false;
                var npi: usize = undefined;
                if (!classMatch(pat, pi, str[si], &npi)) return false;
                pi = npi;
                si += 1;
            },
            else => {
                if (si >= str.len or str[si] != pc) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == str.len;
}

/// Matches a glob character class `[...]` with pi at '['. Writes match status
/// and sets `next_pi` after ']'. If parsing fails, treats '[' as a literal.
fn classMatch(pat: []const u8, pi: usize, ch: u8, next_pi: *usize) bool {
    var i = pi + 1;
    var negated = false;
    if (i < pat.len and pat[i] == '^') {
        negated = true;
        i += 1;
    }
    var matched = false;
    var has_close = false;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) {
            has_close = true;
            i += 1;
            break;
        }
        first = false;
        // Range a-z.
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            if (ch >= pat[i] and ch <= pat[i + 2]) matched = true;
            i += 3;
        } else {
            if (ch == pat[i]) matched = true;
            i += 1;
        }
    }
    if (!has_close) {
        // Invalid class: treat '[' as a literal and consume one character.
        next_pi.* = pi + 1;
        return ch == '[';
    }
    next_pi.* = i;
    return matched != negated;
}

// ---- Tests ----

test "grepText line numbers and matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text = "foo\nbar baz\nqux\nbar end";
    const hits = try grepText(a, "bar", text, default_max_hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(@as(usize, 2), hits[0].line);
    try std.testing.expectEqualStrings("bar baz", hits[0].text);
    try std.testing.expectEqual(@as(usize, 4), hits[1].line);
    try std.testing.expectEqualStrings("bar end", hits[1].text);
}

test "grepText regex, anchors, and no matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text = "k1 = 1\nk2=2\n key = v\n";
    const hits = try grepText(a, "^\\w+ = ", text, default_max_hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(usize, 1), hits[0].line);

    const none = try grepText(a, "zzz", text, default_max_hits);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "grepText max_hits truncation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "x\nx\nx\nx\nx";
    const hits = try grepText(a, "x", text, 2);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "grepText max_hits handles line endings (issue #39)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Exactly max_hits newline-terminated hits plus a final hit without newline.
    const text = "x\nx\nx"; // Three hits; final line has no '\n'.
    const hits = try grepText(a, "x", text, 2);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "grepTextContext hit lines include +/-N context and hit markers(issue #76)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "l1\nl2\nNEEDLE\nl4\nl5";
    const blocks = try grepTextContext(a, "NEEDLE", text, 100, 1);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const b = blocks[0];
    try std.testing.expectEqual(@as(usize, 2), b.start_line); // l2..l4
    try std.testing.expectEqual(@as(usize, 3), b.lines.len);
    try std.testing.expectEqualStrings("l2", b.lines[0]);
    try std.testing.expectEqualStrings("NEEDLE", b.lines[1]);
    try std.testing.expectEqualStrings("l4", b.lines[2]);
    try std.testing.expectEqual(false, b.hit_mask[0]);
    try std.testing.expectEqual(true, b.hit_mask[1]);
    try std.testing.expectEqual(false, b.hit_mask[2]);
}

test "grepTextContext adjacent hit context blocks merge(issue #76)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Hits on lines 2 and 4 with +/-1 context merge adjacent windows [1..3] and [3..5].
    const text = "a\nHIT\nc\nHIT\ne";
    const blocks = try grepTextContext(a, "HIT", text, 100, 1);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].start_line);
    try std.testing.expectEqual(@as(usize, 5), blocks[0].lines.len);
    // Two hit lines are marked; the rest are context.
    var hits: usize = 0;
    for (blocks[0].hit_mask) |h| {
        if (h) hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), hits);
}

test "grepTextContext distant hits form separate blocks(issue #76)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "HIT\nb\nc\nd\ne\nf\nHIT";
    const blocks = try grepTextContext(a, "HIT", text, 100, 1);
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
}

test "globMatch pathological pattern does not time out(issue #37)" {
    // Many '*' with no matching suffix must hit the backtracking cap quickly.
    try std.testing.expect(!globMatch("*a*a*a*a*a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaa"));
    // Matchable alignment still succeeds within budget.
    try std.testing.expect(globMatch("*a*a*b", "aaaab"));
    // Overlong pattern is rejected as no-match.
    const long = "*" ** (max_glob_pattern_len + 1);
    try std.testing.expect(!globMatch(long, "x"));
}

test "globMatch basic wildcard where * and ? do not cross /" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(!globMatch("*.zig", "src/main.zig")); // * does not cross /.
    try std.testing.expect(globMatch("src/*.zig", "src/main.zig"));
    try std.testing.expect(globMatch("?.txt", "a.txt"));
    try std.testing.expect(!globMatch("?.txt", "ab.txt"));
    try std.testing.expect(!globMatch("*.zig", "main.zigx"));
}

test "globMatch double star matches directories" {
    try std.testing.expect(globMatch("**/*.zig", "main.zig")); // Zero directory levels.
    try std.testing.expect(globMatch("**/*.zig", "src/tools/bash.zig"));
    try std.testing.expect(globMatch("src/**/*.zig", "src/a/b/c.zig"));
    try std.testing.expect(globMatch("src/**", "src/a/b"));
    try std.testing.expect(!globMatch("src/**/*.zig", "lib/a.zig"));
}

test "globMatch character classes" {
    try std.testing.expect(globMatch("[abc].zig", "a.zig"));
    try std.testing.expect(!globMatch("[abc].zig", "d.zig"));
    try std.testing.expect(globMatch("v[0-9].txt", "v3.txt"));
    try std.testing.expect(globMatch("[^x].txt", "a.txt"));
    try std.testing.expect(!globMatch("[^x].txt", "x.txt"));
}

test "glob walks directories" {
    const a_gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_glob_test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    try cwd.createDirPath(io, dir ++ "/sub");

    // Write two .zig files and one .txt.
    const file = @import("file.zig");
    try file.write(io, dir ++ "/a.zig", "x");
    try file.write(io, dir ++ "/sub/b.zig", "y");
    try file.write(io, dir ++ "/sub/c.txt", "z");

    var arena_state = std.heap.ArenaAllocator.init(a_gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const zigs = try glob(a, io, "**/*.zig", dir, default_max_results);
    try std.testing.expectEqual(@as(usize, 2), zigs.len);
    // Results include the root prefix and can be fed directly to file_read.
    var saw_a = false;
    var saw_b = false;
    for (zigs) |p| {
        if (std.mem.endsWith(u8, p, "a.zig")) saw_a = true;
        if (std.mem.endsWith(u8, p, "sub/b.zig")) saw_b = true;
        try std.testing.expect(std.mem.startsWith(u8, p, dir));
    }
    try std.testing.expect(saw_a and saw_b);
}

test {
    std.testing.refAllDecls(@This());
}
