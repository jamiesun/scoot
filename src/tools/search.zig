//! 搜索工具：grep（内容，走自研 ReDoS 免疫正则）与 glob（路径，独立通配匹配）。
//!
//! 自包含动机同 file.zig：裁剪 / 嵌入式 Linux 可能无系统 grep/find。
//! grep 复用 `regex.zig`（线性时间，模型生成的正则不会把设备 CPU 拖死）。
//! glob 不复用正则引擎——路径通配（`* ? [] **`）语义与正则不同（`*` 不跨 `/`，
//! `**` 才跨目录），单独实现更清晰。
const std = @import("std");
const regex = @import("../regex.zig");

/// grep 命中：1 起的行号 + 该行原文（指向被搜文本，arena 拥有其来源）。
pub const Hit = struct {
    line: usize,
    text: []const u8,
};

/// 单次读取的默认上限（1 MiB），与 file.read 一致，挡住超大文件读爆内存。
pub const default_read_limit: std.Io.Limit = .limited(1 << 20);

/// glob 遍历的护栏：最大目录深度与最多收集结果数，防止超大树拖垮工具。
pub const max_glob_depth: usize = 32;
pub const default_max_results: usize = 500;
/// grep 默认最多回报命中行数，避免海量命中挤爆上下文。
pub const default_max_hits: usize = 200;
/// glob 模式长度上限：与 regex.max_pattern_len 对齐，挡住病态超长模式（issue #37）。
pub const max_glob_pattern_len: usize = 4096;
/// 单次 glob 最多访问的目录项：挡住超大/无界目录树（含 node_modules 等）导致的
/// 时间与 arena 内存随树规模膨胀，而非随命中数膨胀（issue #38）。达到上限即返回已收集的部分结果。
pub const max_glob_entries: usize = 100_000;
/// globRec 的回溯步数预算：把单次匹配的 CPU 硬封顶，杜绝病态模式（如 `*a*a*…*b`）的超线性回溯（issue #37）。
const glob_match_budget: u64 = 5_000_000;
/// glob 遍历跳过的重型目录名（dotfile 已由 walk 单独跳过）：常见且通常不应纳入搜索（issue #38）。
const ignored_dir_names = [_][]const u8{"node_modules"};

/// 在一段文本里按行做正则匹配，返回命中行（含行号）。compile 一次、跨行复用 Matcher。
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

/// 读取文件后在其内容上做 grep（路径相对 cwd）。
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

/// 在 `root` 子树下按 glob 模式匹配路径，返回匹配到的路径（相对 cwd，可直接喂 file_read）。
/// 模式相对 `root` 匹配；`*`/`?`/`[]` 不跨 `/`，`**` 跨目录层级。隐藏文件（`.` 开头）跳过。
pub fn glob(
    arena: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
    root: []const u8,
    max_results: usize,
) ![][]const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    // 病态超长模式直接判空，不触发遍历（issue #37）。
    if (pattern.len > max_glob_pattern_len) return results.toOwnedSlice(arena);
    var visited: usize = 0;
    try walk(arena, io, &results, pattern, root, "", 0, max_results, &visited);
    return results.toOwnedSlice(arena);
}

/// 递归遍历目录，对每个相对路径测试 glob，命中则收集（root 前缀后的可用路径）。
/// `visited` 跨整棵子树累计已访问的目录项，达到 `max_glob_entries` 即停止，
/// 使时间与内存随树规模有界，而非随命中数（issue #38）。
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
        if (entry.name.len == 0 or entry.name[0] == '.') continue; // 跳过隐藏项
        visited.* += 1;
        if (visited.* > max_glob_entries) return; // 访问项预算耗尽：返回已收集的部分结果（issue #38）
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
        // 是否递归进入：`.directory` 直接进；`.unknown`（部分文件系统的 DT_UNKNOWN，
        // 如某些 NFS）需 stat 确认是否真为目录，否则真实子目录会被静默漏掉（issue #40）。
        // stat 不跟随符号链接，沿用「仅普通目录才递归」的防环/防逃逸语义。
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

/// 是否为应跳过的重型目录（issue #38）。
fn isIgnoredDir(name: []const u8) bool {
    for (ignored_dir_names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// glob 全路径匹配：`*`/`?`/`[]` 不跨 `/`，`**` 跨目录（`**/` 亦匹配零层目录）。
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (pattern.len > max_glob_pattern_len) return false; // 病态超长模式：判不匹配（issue #37）
    var budget: u64 = glob_match_budget;
    return globRec(pattern, 0, path, 0, &budget);
}

fn globRec(pat: []const u8, p0: usize, str: []const u8, s0: usize, budget: *u64) bool {
    // 回溯步数预算耗尽：硬封顶，杜绝病态模式的超线性回溯（issue #37）。
    // 真正能匹配的对齐会在预算内被贪心命中并提前返回 true；耗尽只发生在无解的病态回溯上。
    if (budget.* == 0) return false;
    budget.* -= 1;
    var pi = p0;
    var si = s0;
    while (pi < pat.len) {
        const pc = pat[pi];
        switch (pc) {
            '*' => {
                if (pi + 1 < pat.len and pat[pi + 1] == '*') {
                    // '**'：跨目录。若紧跟 '/'，'**/' 可匹配零层目录或任意 '<dirs>/'。
                    if (pi + 2 < pat.len and pat[pi + 2] == '/') {
                        const rest = pi + 3;
                        if (globRec(pat, rest, str, si, budget)) return true; // 零层目录
                        var k = si;
                        while (k < str.len) : (k += 1) {
                            if (str[k] == '/' and globRec(pat, rest, str, k + 1, budget)) return true;
                        }
                        return false;
                    }
                    // '**' 在末尾或后接非 '/'：匹配任意字符（含 '/'）。
                    const rest = pi + 2;
                    var k = si;
                    while (k <= str.len) : (k += 1) {
                        if (globRec(pat, rest, str, k, budget)) return true;
                    }
                    return false;
                }
                // 单 '*'：匹配本段内任意非 '/' 串（含空）。
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

/// 匹配 glob 字符类 `[...]`（pi 指向 '['）。命中与否写回，`next_pi` 置为 ']' 之后。
/// 解析失败（无闭合 ']'）时把 '[' 当字面量处理。
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
        // 区间 a-z
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            if (ch >= pat[i] and ch <= pat[i + 2]) matched = true;
            i += 3;
        } else {
            if (ch == pat[i]) matched = true;
            i += 1;
        }
    }
    if (!has_close) {
        // 非法类：把 '[' 当字面量，仅当 ch == '[' 时算匹配，消费一个字符。
        next_pi.* = pi + 1;
        return ch == '[';
    }
    next_pi.* = i;
    return matched != negated;
}

// ---- 测试 ----

test "grepText 行号与命中" {
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

test "grepText 正则与锚点、无命中" {
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

test "grepText max_hits 截断" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "x\nx\nx\nx\nx";
    const hits = try grepText(a, "x", text, 2);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "grepText max_hits 含无换行尾行不越界（issue #39）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 恰好 max_hits 个带换行的命中 + 一个无换行的尾行命中：尾行不得绕过上限。
    const text = "x\nx\nx"; // 三处命中，末行无 '\n'
    const hits = try grepText(a, "x", text, 2);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
}

test "globMatch 病态模式不超时（issue #37）" {
    // 多 '*' 且无匹配后缀的病态模式：受回溯预算硬封顶，必须很快返回 false 而非超线性回溯。
    try std.testing.expect(!globMatch("*a*a*a*a*a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaa"));
    // 能匹配的对齐仍在预算内命中。
    try std.testing.expect(globMatch("*a*a*b", "aaaab"));
    // 超长模式直接判不匹配。
    const long = "*" ** (max_glob_pattern_len + 1);
    try std.testing.expect(!globMatch(long, "x"));
}

test "globMatch 基础通配（* ? 不跨 /）" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(!globMatch("*.zig", "src/main.zig")); // * 不跨 /
    try std.testing.expect(globMatch("src/*.zig", "src/main.zig"));
    try std.testing.expect(globMatch("?.txt", "a.txt"));
    try std.testing.expect(!globMatch("?.txt", "ab.txt"));
    try std.testing.expect(!globMatch("*.zig", "main.zigx"));
}

test "globMatch ** 跨目录（含零层）" {
    try std.testing.expect(globMatch("**/*.zig", "main.zig")); // 零层目录
    try std.testing.expect(globMatch("**/*.zig", "src/tools/bash.zig"));
    try std.testing.expect(globMatch("src/**/*.zig", "src/a/b/c.zig"));
    try std.testing.expect(globMatch("src/**", "src/a/b"));
    try std.testing.expect(!globMatch("src/**/*.zig", "lib/a.zig"));
}

test "globMatch 字符类" {
    try std.testing.expect(globMatch("[abc].zig", "a.zig"));
    try std.testing.expect(!globMatch("[abc].zig", "d.zig"));
    try std.testing.expect(globMatch("v[0-9].txt", "v3.txt"));
    try std.testing.expect(globMatch("[^x].txt", "a.txt"));
    try std.testing.expect(!globMatch("[^x].txt", "x.txt"));
}

test "glob 真实目录遍历" {
    const a_gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = "/tmp/scoot_glob_test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    try cwd.createDirPath(io, dir ++ "/sub");

    // 写两个 .zig 与一个 .txt。
    const file = @import("file.zig");
    try file.write(io, dir ++ "/a.zig", "x");
    try file.write(io, dir ++ "/sub/b.zig", "y");
    try file.write(io, dir ++ "/sub/c.txt", "z");

    var arena_state = std.heap.ArenaAllocator.init(a_gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const zigs = try glob(a, io, "**/*.zig", dir, default_max_results);
    try std.testing.expectEqual(@as(usize, 2), zigs.len);
    // 结果应带 root 前缀，可直接 file_read。
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
