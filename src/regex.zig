//! 自研正则引擎：Thompson NFA（无回溯，线性时间 O(n·m)）。
//!
//! 为什么自己写而不引第三方（见审计结论 / busybox 驱动）：
//!   - 部署到裁剪 / 嵌入式 Linux，不能依赖系统 grep 的正则；纯 Zig 第三方
//!     (mvzr) 只适配 0.15 且作者声明不抗敌意输入。
//!   - **决定性理由：ReDoS 免疫**。模型（含本地小模型）在嵌入式设备上生成的
//!     正则若交给回溯引擎，`(a+)+$` 这类会指数级回溯把 CPU 拖死。Thompson NFA
//!     用「状态集合并行推进」取代回溯，对任意模式都是线性时间，结构性免疫。
//!
//! 刻意的降维边界（够用且可控，不做就是不做）：
//!   支持：字面量、`. ^ $ * + ? | ()`、字符类 `[...]`（含 `a-z` 区间、`[^...]` 取反）、
//!         转义 `\d \w \s \D \W \S \n \t \r \\ \.` 等。
//!   不做：捕获组提取、反向引用、lookaround、惰性 / 占有量词、`{n,m}` 计数重复、`\p{}`。
//!   （这些要么诱发回溯、要么远超 grep 需求；需要时再单独评审，不在此撑大爆炸半径。）
//!
//! 字节级匹配：模式与文本按字节处理。字面多字节（如中文）子串可正常匹配（字节序列相等）；
//!   `.` 匹配单字节，对多字节字符是「半个 rune」——这是已知取舍，grep 极少这样用。
const std = @import("std");

/// 模式长度上限：界定编译产物与 addThread 递归深度，挡住病态超长模式。
pub const max_pattern_len: usize = 4096;

pub const CompileError = error{
    InvalidPattern,
    PatternTooLong,
    OutOfMemory,
};

/// 编译后的指令（Thompson NFA / 正则 VM）。epsilon 类（split/jmp/bol/eol）在
/// addThread 的闭包里展开，消费字节的只有 char/any/class。
const Inst = union(enum) {
    char: u8,
    any,
    class: u32, // 索引进 classes
    split: [2]u32,
    jmp: u32,
    bol, // ^：行首（位置 0）
    eol, // $：行尾（位置 == len）
    match,
};

const Range = struct { lo: u8, hi: u8 };

/// 字符类：若干字节区间 + 是否取反。
const Class = struct {
    ranges: []const Range,
    negated: bool,
};

/// 一个编译好的正则。`insts` / `classes` 由传入的 arena 拥有。
pub const Regex = struct {
    insts: []const Inst,
    classes: []const Class,

    /// 编译模式为 NFA 指令序列。非法模式 → InvalidPattern；超长 → PatternTooLong。
    pub fn compile(arena: std.mem.Allocator, pattern: []const u8) CompileError!Regex {
        if (pattern.len > max_pattern_len) return error.PatternTooLong;

        var parser = Parser{ .arena = arena, .src = pattern };
        const ast = try parser.parse();

        var comp = Compiler{ .arena = arena };
        try comp.compile(ast);
        _ = try comp.emit(.match);

        return .{
            .insts = try comp.insts.toOwnedSlice(arena),
            .classes = try parser.classes.toOwnedSlice(arena),
        };
    }
};

/// 匹配器：持有可复用的状态集合暂存（按 insts.len 一次性分配，跨多行复用）。
/// `gen` 单调递增充当「本轮已访问」标记，免去每行清零（线性时间的关键工程化）。
pub const Matcher = struct {
    re: *const Regex,
    seen: []u64,
    clist: []u32,
    nlist: []u32,
    clen: usize = 0,
    nlen: usize = 0,
    gen: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, re: *const Regex) !Matcher {
        const n = re.insts.len;
        const seen = try gpa.alloc(u64, n);
        @memset(seen, 0);
        const clist = try gpa.alloc(u32, n);
        const nlist = try gpa.alloc(u32, n);
        return .{ .re = re, .seen = seen, .clist = clist, .nlist = nlist };
    }

    pub fn deinit(self: *Matcher, gpa: std.mem.Allocator) void {
        gpa.free(self.seen);
        gpa.free(self.clist);
        gpa.free(self.nlist);
    }

    /// 该行文本是否被模式匹配（非锚定子串语义：可在任意位置起匹，`^`/`$` 另行约束）。
    pub fn matches(self: *Matcher, text: []const u8) bool {
        self.gen += 1;
        self.clen = 0;
        self.addThread(self.clist, &self.clen, 0, 0, text);

        var i: usize = 0;
        while (true) {
            for (self.clist[0..self.clen]) |pc| {
                switch (self.re.insts[pc]) {
                    .match => return true,
                    else => {},
                }
            }
            if (i >= text.len) return false;

            const c = text[i];
            self.gen += 1;
            self.nlen = 0;
            for (self.clist[0..self.clen]) |pc| {
                switch (self.re.insts[pc]) {
                    .char => |ch| if (ch == c) self.addThread(self.nlist, &self.nlen, pc + 1, i + 1, text),
                    .any => self.addThread(self.nlist, &self.nlen, pc + 1, i + 1, text),
                    .class => |id| if (self.classMatch(id, c)) self.addThread(self.nlist, &self.nlen, pc + 1, i + 1, text),
                    else => {},
                }
            }
            // 非锚定：在下一位置再播一颗起始线程，使匹配可从任意偏移开始。
            self.addThread(self.nlist, &self.nlen, 0, i + 1, text);

            std.mem.swap([]u32, &self.clist, &self.nlist);
            const tmp = self.clen;
            self.clen = self.nlen;
            self.nlen = tmp;
            i += 1;
        }
    }

    /// 把 pc 加入线程集，沿 epsilon（split/jmp/bol/eol）做闭包；`gen` 去重防环、保线性。
    fn addThread(self: *Matcher, list: []u32, len: *usize, pc: u32, pos: usize, text: []const u8) void {
        if (self.seen[pc] == self.gen) return;
        self.seen[pc] = self.gen;
        switch (self.re.insts[pc]) {
            .jmp => |x| self.addThread(list, len, x, pos, text),
            .split => |xy| {
                self.addThread(list, len, xy[0], pos, text);
                self.addThread(list, len, xy[1], pos, text);
            },
            .bol => if (pos == 0) self.addThread(list, len, pc + 1, pos, text),
            .eol => if (pos == text.len) self.addThread(list, len, pc + 1, pos, text),
            else => {
                list[len.*] = pc;
                len.* += 1;
            },
        }
    }

    fn classMatch(self: *Matcher, id: u32, c: u8) bool {
        const cl = self.re.classes[id];
        var inside = false;
        for (cl.ranges) |r| {
            if (c >= r.lo and c <= r.hi) {
                inside = true;
                break;
            }
        }
        return inside != cl.negated;
    }
};

/// 便捷一次性匹配（编译 + 匹配；arena 拥有全部中间物）。多次匹配应复用 Matcher。
pub fn matchOnce(arena: std.mem.Allocator, pattern: []const u8, text: []const u8) !bool {
    var re = try Regex.compile(arena, pattern);
    var m = try Matcher.init(arena, &re);
    return m.matches(text);
}

// ---- 抽象语法树 ----

const Ast = union(enum) {
    empty,
    lit: u8,
    any,
    class: u32,
    bol,
    eol,
    cat: [2]*const Ast,
    alt: [2]*const Ast,
    star: *const Ast,
    plus: *const Ast,
    quest: *const Ast,
};

// ---- 递归下降解析器 ----

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    classes: std.ArrayList(Class) = .empty,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn eat(self: *Parser, c: u8) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn node(self: *Parser, v: Ast) !*const Ast {
        const p = try self.arena.create(Ast);
        p.* = v;
        return p;
    }

    fn parse(self: *Parser) CompileError!*const Ast {
        const a = try self.parseAlt();
        if (self.pos != self.src.len) return error.InvalidPattern; // 残留（如多余的 `)`）
        return a;
    }

    fn parseAlt(self: *Parser) CompileError!*const Ast {
        var left = try self.parseConcat();
        while (self.eat('|')) {
            const right = try self.parseConcat();
            left = try self.node(.{ .alt = .{ left, right } });
        }
        return left;
    }

    fn parseConcat(self: *Parser) CompileError!*const Ast {
        var nodes: std.ArrayList(*const Ast) = .empty;
        defer nodes.deinit(self.arena);
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try nodes.append(self.arena, try self.parseRepeat());
        }
        if (nodes.items.len == 0) return self.node(.empty);
        var acc = nodes.items[0];
        for (nodes.items[1..]) |n| acc = try self.node(.{ .cat = .{ acc, n } });
        return acc;
    }

    fn parseRepeat(self: *Parser) CompileError!*const Ast {
        var atom = try self.parseAtom();
        while (self.peek()) |c| {
            switch (c) {
                '*' => {
                    self.pos += 1;
                    atom = try self.node(.{ .star = atom });
                },
                '+' => {
                    self.pos += 1;
                    atom = try self.node(.{ .plus = atom });
                },
                '?' => {
                    self.pos += 1;
                    atom = try self.node(.{ .quest = atom });
                },
                else => break,
            }
        }
        return atom;
    }

    fn parseAtom(self: *Parser) CompileError!*const Ast {
        const c = self.peek() orelse return error.InvalidPattern;
        switch (c) {
            '(' => {
                self.pos += 1;
                const inner = try self.parseAlt();
                if (!self.eat(')')) return error.InvalidPattern;
                return inner;
            },
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.node(.any);
            },
            '^' => {
                self.pos += 1;
                return self.node(.bol);
            },
            '$' => {
                self.pos += 1;
                return self.node(.eol);
            },
            '\\' => return self.parseEscape(),
            '*', '+', '?' => return error.InvalidPattern, // 量词前无原子
            ')' => return error.InvalidPattern,
            else => {
                self.pos += 1;
                return self.node(.{ .lit = c });
            },
        }
    }

    fn parseEscape(self: *Parser) CompileError!*const Ast {
        self.pos += 1; // 吃掉反斜杠
        const c = self.peek() orelse return error.InvalidPattern; // 行尾孤立反斜杠
        self.pos += 1;
        switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                const id = try self.addPredefClass(c);
                return self.node(.{ .class = id });
            },
            'n' => return self.node(.{ .lit = '\n' }),
            't' => return self.node(.{ .lit = '\t' }),
            'r' => return self.node(.{ .lit = '\r' }),
            else => return self.node(.{ .lit = c }), // 转义元字符 / 普通字符
        }
    }

    fn parseClass(self: *Parser) CompileError!*const Ast {
        self.pos += 1; // 吃掉 '['
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(self.arena);

        var first = true;
        while (true) {
            const c = self.peek() orelse return error.InvalidPattern; // 未闭合 ']'
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;

            if (c == '\\') {
                self.pos += 1;
                const e = self.peek() orelse return error.InvalidPattern;
                self.pos += 1;
                try self.appendEscapeRanges(&ranges, e);
                continue;
            }

            self.pos += 1;
            // 区间 a-z：'-' 后还有非 ']' 字符才算区间，否则 '-' 当字面量。
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1; // 吃掉 '-'
                const hi = self.src[self.pos];
                self.pos += 1;
                if (hi < c) return error.InvalidPattern; // 逆序区间
                try ranges.append(self.arena, .{ .lo = c, .hi = hi });
            } else {
                try ranges.append(self.arena, .{ .lo = c, .hi = c });
            }
        }
        if (ranges.items.len == 0) return error.InvalidPattern; // 空类 []

        const id: u32 = @intCast(self.classes.items.len);
        try self.classes.append(self.arena, .{
            .ranges = try ranges.toOwnedSlice(self.arena),
            .negated = negated,
        });
        return self.node(.{ .class = id });
    }

    /// 把类内转义（`\d \w \s` 或 `\n \t \r` 或转义字面量）展开成区间追加。
    fn appendEscapeRanges(self: *Parser, ranges: *std.ArrayList(Range), e: u8) !void {
        switch (e) {
            'd' => try ranges.appendSlice(self.arena, &.{.{ .lo = '0', .hi = '9' }}),
            'w' => try ranges.appendSlice(self.arena, &predef_word),
            's' => try ranges.appendSlice(self.arena, &predef_space),
            'n' => try ranges.append(self.arena, .{ .lo = '\n', .hi = '\n' }),
            't' => try ranges.append(self.arena, .{ .lo = '\t', .hi = '\t' }),
            'r' => try ranges.append(self.arena, .{ .lo = '\r', .hi = '\r' }),
            else => try ranges.append(self.arena, .{ .lo = e, .hi = e }),
        }
    }

    /// 注册一个预定义类（`\d \w \s` 及其取反大写形式），返回其 id。
    fn addPredefClass(self: *Parser, kind: u8) !u32 {
        const negated = std.ascii.isUpper(kind);
        const ranges: []const Range = switch (std.ascii.toLower(kind)) {
            'd' => &.{.{ .lo = '0', .hi = '9' }},
            'w' => &predef_word,
            's' => &predef_space,
            else => unreachable,
        };
        const id: u32 = @intCast(self.classes.items.len);
        try self.classes.append(self.arena, .{
            .ranges = try self.arena.dupe(Range, ranges),
            .negated = negated,
        });
        return id;
    }
};

const predef_word = [_]Range{
    .{ .lo = '0', .hi = '9' },
    .{ .lo = 'a', .hi = 'z' },
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = '_', .hi = '_' },
};
const predef_space = [_]Range{
    .{ .lo = ' ', .hi = ' ' },
    .{ .lo = '\t', .hi = '\t' },
    .{ .lo = '\n', .hi = '\n' },
    .{ .lo = '\r', .hi = '\r' },
    .{ .lo = 0x0b, .hi = 0x0c }, // 垂直制表 / 换页
};

// ---- AST → 指令编译 ----

const Compiler = struct {
    arena: std.mem.Allocator,
    insts: std.ArrayList(Inst) = .empty,

    fn pc(self: *Compiler) u32 {
        return @intCast(self.insts.items.len);
    }

    fn emit(self: *Compiler, inst: Inst) !u32 {
        const p = self.pc();
        try self.insts.append(self.arena, inst);
        return p;
    }

    fn compile(self: *Compiler, n: *const Ast) CompileError!void {
        switch (n.*) {
            .empty => {},
            .lit => |c| _ = try self.emit(.{ .char = c }),
            .any => _ = try self.emit(.any),
            .class => |id| _ = try self.emit(.{ .class = id }),
            .bol => _ = try self.emit(.bol),
            .eol => _ = try self.emit(.eol),
            .cat => |ab| {
                try self.compile(ab[0]);
                try self.compile(ab[1]);
            },
            .alt => |ab| {
                const sp = try self.emit(.{ .split = .{ 0, 0 } });
                const l1 = self.pc();
                try self.compile(ab[0]);
                const jm = try self.emit(.{ .jmp = 0 });
                const l2 = self.pc();
                try self.compile(ab[1]);
                const l3 = self.pc();
                self.insts.items[sp].split = .{ l1, l2 };
                self.insts.items[jm].jmp = l3;
            },
            .star => |a| {
                const sp = try self.emit(.{ .split = .{ 0, 0 } });
                const l1 = self.pc();
                try self.compile(a);
                _ = try self.emit(.{ .jmp = sp });
                const l2 = self.pc();
                self.insts.items[sp].split = .{ l1, l2 };
            },
            .plus => |a| {
                const l1 = self.pc();
                try self.compile(a);
                const sp = try self.emit(.{ .split = .{ 0, 0 } });
                const l2 = self.pc();
                self.insts.items[sp].split = .{ l1, l2 };
            },
            .quest => |a| {
                const sp = try self.emit(.{ .split = .{ 0, 0 } });
                const l1 = self.pc();
                try self.compile(a);
                const l2 = self.pc();
                self.insts.items[sp].split = .{ l1, l2 };
            },
        }
    }
};

// ---- 测试 ----

fn expectMatch(pattern: []const u8, text: []const u8, want: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try matchOnce(arena_state.allocator(), pattern, text);
    try std.testing.expectEqual(want, got);
}

test "字面量与位置无关的子串匹配（非锚定）" {
    try expectMatch("abc", "abc", true);
    try expectMatch("abc", "xxabcyy", true);
    try expectMatch("abc", "ab", false);
    try expectMatch("", "anything", true); // 空模式匹配一切
}

test "锚点 ^ 与 $" {
    try expectMatch("^abc", "abcdef", true);
    try expectMatch("^abc", "xabc", false);
    try expectMatch("abc$", "xxabc", true);
    try expectMatch("abc$", "abcx", false);
    try expectMatch("^abc$", "abc", true);
    try expectMatch("^abc$", "abcd", false);
    try expectMatch("^$", "", true);
}

test "量词 * + ?" {
    try expectMatch("ab*c", "ac", true);
    try expectMatch("ab*c", "abbbc", true);
    try expectMatch("ab+c", "ac", false);
    try expectMatch("ab+c", "abc", true);
    try expectMatch("ab?c", "ac", true);
    try expectMatch("ab?c", "abc", true);
    try expectMatch("ab?c", "abbc", false);
}

test "通配 . 与转义" {
    try expectMatch("a.c", "axc", true);
    try expectMatch("a.c", "ac", false);
    try expectMatch("a\\.c", "a.c", true);
    try expectMatch("a\\.c", "axc", false);
}

test "分组与选择 () |" {
    try expectMatch("(ab|cd)+", "abcdab", true);
    try expectMatch("gr(a|e)y", "gray", true);
    try expectMatch("gr(a|e)y", "grey", true);
    try expectMatch("gr(a|e)y", "groy", false);
    try expectMatch("^(foo|bar)$", "bar", true);
    try expectMatch("^(foo|bar)$", "baz", false);
}

test "字符类 [] 含区间与取反" {
    try expectMatch("[a-z]+", "hello", true);
    try expectMatch("[a-z]+", "123", false);
    try expectMatch("[^0-9]", "a", true);
    try expectMatch("[^0-9]", "5", false);
    try expectMatch("[abc]x", "bx", true);
    try expectMatch("[-a]", "-", true); // '-' 在末尾作字面量
    try expectMatch("a[0-9]+b", "a123b", true);
}

test "预定义类 \\d \\w \\s 及取反" {
    try expectMatch("\\d+", "abc123", true);
    try expectMatch("^\\d+$", "123", true);
    try expectMatch("^\\d+$", "12a", false);
    try expectMatch("\\w+", "_foo9", true);
    try expectMatch("a\\sb", "a b", true);
    try expectMatch("a\\sb", "a\tb", true);
    try expectMatch("\\D", "x", true);
    try expectMatch("\\D", "5", false);
}

test "多字节（中文）字面子串按字节匹配" {
    try expectMatch("世界", "你好世界", true);
    try expectMatch("世界", "你好世", false);
}

test "ReDoS 病态模式仍线性返回（不回溯卡死）" {
    // 回溯引擎会在此指数级爆炸；Thompson NFA 线性，瞬时返回 false。
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!"; // 30 个 a + 不匹配尾
    const got = try matchOnce(arena_state.allocator(), "(a+)+$", text);
    try std.testing.expectEqual(false, got);
}

test "非法模式返回错误而非 panic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "(abc"));
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "abc)"));
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "*abc"));
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "[abc"));
    try std.testing.expectError(error.InvalidPattern, Regex.compile(a, "a\\"));
    try std.testing.expectError(error.PatternTooLong, Regex.compile(a, "a" ** (max_pattern_len + 1)));
}

test "Matcher 复用跨多次匹配正确（gen 单调不清零）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var re = try Regex.compile(a, "[0-9]+");
    var m = try Matcher.init(a, &re);
    try std.testing.expect(m.matches("abc1"));
    try std.testing.expect(!m.matches("abc"));
    try std.testing.expect(m.matches("9"));
    try std.testing.expect(!m.matches(""));
}

test {
    std.testing.refAllDecls(@This());
}
