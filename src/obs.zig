//! Observation optimizer (issue #75): a pure shrinking layer before tool output
//! enters session history.
//!
//! The goal is a better useful-information-per-token ratio and a unified policy:
//!   1. Command-like output, such as bash/http failures, strips ANSI, collapses
//!      whitespace and blank lines, and keeps both head and tail. Key signals
//!      such as exit codes and error stacks often sit in the tail, so head-only
//!      truncation loses them.
//!   2. All observation truncation moves from raw bytes to token estimates. CJK
//!      is roughly one token per character but three bytes, so byte budgets make
//!      Chinese and ASCII observations inconsistent.
//!
//! Important constraint: `stripAnsi` and `collapseBlank` rewrite bytes, so they
//! must never touch byte-exact content such as file_read/grep output that later
//! file_edit may need to match exactly. Those paths only use `truncateTokens`,
//! which preserves bytes inside retained windows. Command output uses
//! `optimizeStream`.
const std = @import("std");

/// Rough token estimate with a zero-dependency heuristic, not tokenizer parity:
/// each multibyte UTF-8 starter (CJK, emoji, etc.) counts as one token, while
/// ASCII text is approximated as four bytes per token. This only gives head/tail
/// truncation a stabler budget than raw bytes.
pub fn estimateTokens(s: []const u8) usize {
    var tokens: usize = 0;
    var ascii_bytes: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (seq == 1) {
            ascii_bytes += 1;
            i += 1;
        } else {
            tokens += 1;
            i += if (i + seq <= s.len) seq else 1;
        }
    }
    tokens += (ascii_bytes + 3) / 4;
    return tokens;
}

/// Consumes tokens from the start of `s` and returns the byte index where
/// `target` tokens have been reached, or s.len if insufficient. Uses the same
/// estimate as estimateTokens.
fn forwardByteAtTokens(s: []const u8, target: usize) usize {
    if (target == 0) return 0;
    var i: usize = 0;
    var tokens: usize = 0;
    var ascii_run: usize = 0;
    while (i < s.len) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (seq == 1) {
            ascii_run += 1;
            i += 1;
            if (ascii_run == 4) {
                tokens += 1;
                ascii_run = 0;
            }
        } else {
            tokens += 1;
            i += if (i + seq <= s.len) seq else 1;
        }
        if (tokens >= target) return i;
    }
    return s.len;
}

/// Strips ANSI/VT escape sequences: CSI (`ESC [ ... final`), OSC
/// (`ESC ] ... BEL|ST`), and other two-byte ESC sequences. Command-output only:
/// do not use for byte-exact content. If no ESC exists, returns the original
/// slice without allocation.
pub fn stripAnsi(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, 0x1b) == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b != 0x1b) {
            try out.append(arena, b);
            i += 1;
            continue;
        }
        // Lone trailing ESC is dropped.
        if (i + 1 >= s.len) break;
        const n = s[i + 1];
        if (n == '[') {
            // CSI: parameter bytes followed by a 0x40-0x7e final byte.
            i += 2;
            while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1;
            if (i < s.len) i += 1;
        } else if (n == ']') {
            // OSC: terminated by BEL(0x07) or ST(ESC \).
            i += 2;
            while (i < s.len) {
                if (s[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
        } else {
            // Other two-byte escapes (ESC + one byte) are dropped.
            i += 2;
        }
    }
    return out.items;
}

/// Collapses whitespace: for each line, keep content after the last carriage
/// return to model terminal overwrite semantics, trim trailing whitespace,
/// compress consecutive blank lines to at most one, and drop leading/trailing
/// blank lines. Command-output only because it rewrites bytes.
pub fn collapseBlank(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_blank = false;
    var wrote_any = false;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        // Progress bars and spinners use \r in-place overwrites; keep the final segment.
        const after_cr = if (std.mem.lastIndexOfScalar(u8, raw, '\r')) |cr| raw[cr + 1 ..] else raw;
        const line = std.mem.trimEnd(u8, after_cr, " \t");
        if (line.len == 0) {
            if (wrote_any) pending_blank = true;
            continue;
        }
        if (wrote_any) try out.append(arena, '\n');
        if (pending_blank) {
            try out.append(arena, '\n');
            pending_blank = false;
        }
        try out.appendSlice(arena, line);
        wrote_any = true;
    }
    return out.items;
}

/// Token-friendly head/tail truncation. If estimated tokens fit `max_tokens`,
/// returns the original slice. Otherwise keeps roughly 60% head and 40% tail,
/// where key signals often live, replacing the middle with a placeholder line.
/// Cuts on line boundaries to avoid half-lines. Does not strip ANSI or collapse
/// whitespace, preserving bytes inside retained windows for file_read/grep.
pub fn truncateTokens(arena: std.mem.Allocator, s: []const u8, max_tokens: usize) ![]const u8 {
    if (max_tokens == 0) return s;
    const total = estimateTokens(s);
    if (total <= max_tokens) return s;

    const head_tokens = max_tokens * 6 / 10;
    const tail_tokens = max_tokens - head_tokens;

    // Head: consume head_tokens, then extend to the end of the line.
    var head_end = forwardByteAtTokens(s, head_tokens);
    if (std.mem.indexOfScalarPos(u8, s, head_end, '\n')) |nl| head_end = nl + 1;

    // Tail: skip (total - tail_tokens) tokens, then retreat to the line start.
    const skip = if (total > tail_tokens) total - tail_tokens else 0;
    var tail_start = forwardByteAtTokens(s, skip);
    if (std.mem.lastIndexOfScalar(u8, s[0..tail_start], '\n')) |nl| tail_start = nl + 1;

    // Overlap or inversion means truncation is not worthwhile.
    if (tail_start <= head_end) return s;

    const omitted = tail_start - head_end;
    return std.fmt.allocPrint(
        arena,
        "{s}...(omitted middle {d} bytes)\n{s}",
        .{ s[0..head_end], omitted, s[tail_start..] },
    );
}

/// One-stop command-output shrinking: strip ANSI, collapse blanks, then head/tail
/// token truncation. Only for command streams such as bash; byte-exact content
/// such as file_read/grep uses truncateTokens only.
pub fn optimizeStream(arena: std.mem.Allocator, s: []const u8, max_tokens: usize) ![]const u8 {
    const no_ansi = try stripAnsi(arena, s);
    const collapsed = try collapseBlank(arena, no_ansi);
    return truncateTokens(arena, collapsed, max_tokens);
}

const testing = std.testing;

test "estimateTokens:ASCII ~len/4 and multibyte ~char count" {
    try testing.expectEqual(@as(usize, 0), estimateTokens(""));
    // Eight ASCII characters -> 2 tokens.
    try testing.expectEqual(@as(usize, 2), estimateTokens("abcdefgh"));
    // Three Chinese characters, three bytes each -> 3 tokens, not 9.
    try testing.expectEqual(@as(usize, 3), estimateTokens("ééé"));
}

test "stripAnsi:strips colors and cursor sequences; no ESC uses fast path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No ESC: returns the same underlying slice.
    const plain = "hello world";
    try testing.expectEqual(plain.ptr, (try stripAnsi(arena, plain)).ptr);

    const out = try stripAnsi(arena, "\x1b[31mERROR\x1b[0m: boom\x1b[1G");
    try testing.expectEqualStrings("ERROR: boom", out);
}

test "stripAnsi:OSC title sequences terminated by BEL/ST are stripped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("tail", try stripAnsi(arena, "\x1b]0;title\x07tail"));
    try testing.expectEqualStrings("link", try stripAnsi(arena, "\x1b]8;;http://x\x1b\\link"));
}

test "collapseBlank normalizes blank lines, spaces, and carriage returns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("a\n\nb", try collapseBlank(arena, "\n\na   \t\n\n\n\nb\n\n"));
    try testing.expectEqualStrings("100% done", try collapseBlank(arena, "10%\r50%\r100% done\n"));
}

test "truncateTokens:returns original slice under budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = "line1\nline2\nline3";
    try testing.expectEqual(s.ptr, (try truncateTokens(arena, s, 100)).ptr);
}

test "truncateTokens:keeps head and tail when over budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "HEAD-MARKER\n");
    var k: usize = 0;
    while (k < 400) : (k += 1) try buf.appendSlice(arena, "filler-line-xxxxxxxx\n");
    try buf.appendSlice(arena, "EXIT-CODE-7-TAIL\n");

    const out = try truncateTokens(arena, buf.items, 80);
    try testing.expect(out.len < buf.items.len);
    try testing.expect(std.mem.indexOf(u8, out, "HEAD-MARKER") != null);
    try testing.expect(std.mem.indexOf(u8, out, "EXIT-CODE-7-TAIL") != null);
    try testing.expect(std.mem.indexOf(u8, out, "omitted middle") != null);
}

test "optimizeStream strips ANSI noise, handles tail signal, and preserves tail exit_code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "\x1b[32mstart\x1b[0m\n\n\n");
    var k: usize = 0;
    while (k < 400) : (k += 1) try buf.appendSlice(arena, "\x1b[31mnoise\x1b[0m    \n");
    try buf.appendSlice(arena, "exit=42\n");

    const out = try optimizeStream(arena, buf.items, 80);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null); // ANSI stripped.
    try testing.expect(std.mem.indexOf(u8, out, "exit=42") != null); // Tail signal retained.
    try testing.expect(out.len < buf.items.len);
}
