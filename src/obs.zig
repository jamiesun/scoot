//! 观察优化器（issue #75）：工具输出进入会话历史前的纯函数瘦身层。
//!
//! 目标是提高「有效信息 / token」比，统一两件事：
//!   1. 命令类输出（bash/http 失败栈等）：剥 ANSI、折叠空白/空行、按「头+尾」双向保留——
//!      关键信号（退出码、错误栈）常在尾部，head-only 截断会把它吃掉。
//!   2. 所有观察的截断口径从**字节**改为**token 估算**：CJK ≈1 token/字但占 3 字节，
//!      字节口径会让中文与 ASCII 的预算严重不一致。
//!
//! 重要约束：`stripAnsi` / `collapseBlank` 会改写字节，**绝不可**用于 file_read/grep 等
//! 需要逐字节匹配（供后续 file_edit 的 old_str 精确命中）的内容；那类内容只走
//! `truncateTokens`（窗口内逐字节保真）。命令输出才走 `optimizeStream`。
const std = @import("std");

/// 粗略 token 估算（零依赖启发式，不追求与具体 tokenizer 对齐）：
/// 多字节 UTF-8 起始字节（CJK/emoji 等，≈1 token/字）按 1 计；ASCII 文本约 4 字节/token。
/// 仅用于给「头+尾」截断一个比纯字节更稳的预算口径。
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

/// 从 `s` 开头消费 token，返回累计达到 `target` 个 token 时的字节下标（不足则返回 s.len）。
/// 与 estimateTokens 同口径：每 4 个 ASCII 字节算 1 token，每个多字节字算 1 token。
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

/// 剥除 ANSI/VT 转义序列：CSI（`ESC [ … final`）、OSC（`ESC ] … BEL|ST`）、以及其它双字节 ESC。
/// **命令输出专用**——切勿用于需逐字节匹配的内容。无 ESC 时走快路径原样返回（不分配）。
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
        // ESC：单独结尾直接丢弃。
        if (i + 1 >= s.len) break;
        const n = s[i + 1];
        if (n == '[') {
            // CSI：参数字节后跟一个 0x40–0x7e 的 final 字节。
            i += 2;
            while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1;
            if (i < s.len) i += 1;
        } else if (n == ']') {
            // OSC：以 BEL(0x07) 或 ST(ESC \) 终止。
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
            // 其它两字节转义（ESC + 单字节）整体丢弃。
            i += 2;
        }
    }
    return out.items;
}

/// 折叠空白：每行先取最后一个回车（`\r`，终端覆盖语义）之后的内容、去尾随空白；
/// 连续空行压成至多一个空行；丢弃首尾空行。**命令输出专用**（会改写字节）。
pub fn collapseBlank(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_blank = false;
    var wrote_any = false;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        // 进度条/spinner 用 \r 原地覆盖：只保留最后一段。
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

/// token 友好的「头+尾」截断：估算 token ≤ `max_tokens` 时原样返回；否则保留头部（~60%）
/// 与尾部（~40%，关键信号常在此），中间替换为占位行。按行边界裁剪以免割裂半行。
/// 不剥 ANSI、不折叠空白——窗口内逐字节保真，可安全用于 file_read/grep 内容。
pub fn truncateTokens(arena: std.mem.Allocator, s: []const u8, max_tokens: usize) ![]const u8 {
    if (max_tokens == 0) return s;
    const total = estimateTokens(s);
    if (total <= max_tokens) return s;

    const head_tokens = max_tokens * 6 / 10;
    const tail_tokens = max_tokens - head_tokens;

    // 头：消费 head_tokens，向后吸到行尾（含换行）。
    var head_end = forwardByteAtTokens(s, head_tokens);
    if (std.mem.indexOfScalarPos(u8, s, head_end, '\n')) |nl| head_end = nl + 1;

    // 尾：跳过 (total - tail_tokens) 个 token，落点回退到所在行行首。
    const skip = if (total > tail_tokens) total - tail_tokens else 0;
    var tail_start = forwardByteAtTokens(s, skip);
    if (std.mem.lastIndexOfScalar(u8, s[0..tail_start], '\n')) |nl| tail_start = nl + 1;

    // 头尾重叠/逆序：截断不划算，原样返回。
    if (tail_start <= head_end) return s;

    const omitted = tail_start - head_end;
    return std.fmt.allocPrint(
        arena,
        "{s}…（省略中段 {d} 字节）\n{s}",
        .{ s[0..head_end], omitted, s[tail_start..] },
    );
}

/// 命令输出一站式瘦身：剥 ANSI → 折叠空白 → 头+尾 token 截断。
/// 仅用于 bash 等命令流；file_read/grep 等保真内容只用 truncateTokens。
pub fn optimizeStream(arena: std.mem.Allocator, s: []const u8, max_tokens: usize) ![]const u8 {
    const no_ansi = try stripAnsi(arena, s);
    const collapsed = try collapseBlank(arena, no_ansi);
    return truncateTokens(arena, collapsed, max_tokens);
}

const testing = std.testing;

test "estimateTokens：ASCII ~len/4，CJK ~字数" {
    try testing.expectEqual(@as(usize, 0), estimateTokens(""));
    // 8 个 ASCII 字符 → 2 token。
    try testing.expectEqual(@as(usize, 2), estimateTokens("abcdefgh"));
    // 3 个汉字（各 3 字节）→ 3 token，而非 9。
    try testing.expectEqual(@as(usize, 3), estimateTokens("中文字"));
}

test "stripAnsi：剥除颜色与光标序列，无 ESC 走快路径" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 无 ESC：返回同一底层切片。
    const plain = "hello world";
    try testing.expectEqual(plain.ptr, (try stripAnsi(arena, plain)).ptr);

    const out = try stripAnsi(arena, "\x1b[31mERROR\x1b[0m: boom\x1b[1G");
    try testing.expectEqualStrings("ERROR: boom", out);
}

test "stripAnsi：OSC 标题序列以 BEL/ST 终止均被剥除" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("tail", try stripAnsi(arena, "\x1b]0;title\x07tail"));
    try testing.expectEqualStrings("link", try stripAnsi(arena, "\x1b]8;;http://x\x1b\\link"));
}

test "collapseBlank：折叠空行、去尾随空白、\\r 覆盖" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("a\n\nb", try collapseBlank(arena, "\n\na   \t\n\n\n\nb\n\n"));
    try testing.expectEqualStrings("100% done", try collapseBlank(arena, "10%\r50%\r100% done\n"));
}

test "truncateTokens：未超预算原样返回（同切片）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = "line1\nline2\nline3";
    try testing.expectEqual(s.ptr, (try truncateTokens(arena, s, 100)).ptr);
}

test "truncateTokens：超预算保留头与尾，丢中段" {
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
    try testing.expect(std.mem.indexOf(u8, out, "省略中段") != null);
}

test "optimizeStream：ANSI+空白+尾部信号一起处理且尾部退出码保留" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "\x1b[32mstart\x1b[0m\n\n\n");
    var k: usize = 0;
    while (k < 400) : (k += 1) try buf.appendSlice(arena, "\x1b[31mnoise\x1b[0m    \n");
    try buf.appendSlice(arena, "exit=42\n");

    const out = try optimizeStream(arena, buf.items, 80);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null); // ANSI 已剥
    try testing.expect(std.mem.indexOf(u8, out, "exit=42") != null); // 尾部信号保留
    try testing.expect(out.len < buf.items.len);
}
