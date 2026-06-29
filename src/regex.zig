//! Local regex engine: Thompson NFA with no backtracking and linear O(n*m) time.
//!
//! Why this is local instead of a dependency:
//!   - Trimmed or embedded Linux deployments cannot rely on system grep regex;
//!     the pure-Zig third-party option, mvzr, only targets 0.15 and documents no
//!     hostile-input resistance.
//!   - Decisive reason: ReDoS immunity. Model-generated regexes, including from
//!     small local models on embedded devices, can pin a backtracking engine with
//!     patterns such as `(a+)+$`. Thompson NFA advances state sets in parallel
//!     instead of backtracking, making all patterns structurally linear.
//!
//! Deliberate scope boundary:
//!   Supported: literals, `. ^ $ * + ? | ()`, character classes `[...]`
//!   including `a-z` ranges and `[^...]` negation, and escapes such as
//!   `\d \w \s \D \W \S \n \t \r \\ \.`.
//!   Not supported: capture extraction, backreferences, lookaround, lazy or
//!   possessive quantifiers, `{n,m}` counted repetition, or `\p{}`. These either
//!   invite backtracking or exceed grep needs and require separate review.
//!
//! Byte-level matching: patterns and text are processed as bytes. Literal
//! multibyte substrings, such as Chinese text, match correctly because the byte
//! sequences are equal. `.` matches one byte, not one Unicode scalar; this is an
//! accepted tradeoff for grep-like use.
const std = @import("std");

/// Pattern length cap: bounds compiled output and addThread recursion depth.
pub const max_pattern_len: usize = 4096;

pub const CompileError = error{
    InvalidPattern,
    PatternTooLong,
    OutOfMemory,
};

/// Compiled instruction for the Thompson NFA / regex VM. Epsilon instructions
/// such as split/jmp/bol/eol expand inside addThread closure; only char, any,
/// and class consume bytes.
const Inst = union(enum) {
    char: u8,
    any,
    class: u32, // Index into classes.
    split: [2]u32,
    jmp: u32,
    bol, // ^: beginning of line, position 0.
    eol, // $: end of line, position == len.
    match,
};

const Range = struct { lo: u8, hi: u8 };

/// Character class: byte ranges plus a negation flag.
const Class = struct {
    ranges: []const Range,
    negated: bool,
};

/// A compiled regex. `insts` and `classes` are owned by the provided arena.
pub const Regex = struct {
    insts: []const Inst,
    classes: []const Class,

    /// Compiles a pattern to NFA instructions. Invalid pattern -> InvalidPattern;
    /// overlong pattern -> PatternTooLong.
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

/// Matcher with reusable state-set scratch allocated once to insts.len and reused
/// across lines. Monotonic `gen` acts as the visited marker for the current pass,
/// avoiding per-line clearing and preserving linear-time behavior.
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

    /// Whether this line matches the pattern. Semantics are unanchored substring
    /// matching, so matching may start at any offset; `^` and `$` constrain that.
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
            // Unanchored matching: seed another start thread at the next offset.
            self.addThread(self.nlist, &self.nlen, 0, i + 1, text);

            std.mem.swap([]u32, &self.clist, &self.nlist);
            const tmp = self.clen;
            self.clen = self.nlen;
            self.nlen = tmp;
            i += 1;
        }
    }

    /// Adds pc to the thread set and closes over epsilon instructions
    /// (split/jmp/bol/eol). `gen` deduplicates and prevents cycles.
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

/// Convenience one-shot match; compiles then matches with arena-owned scratch.
/// Reuse Matcher for repeated matches.
pub fn matchOnce(arena: std.mem.Allocator, pattern: []const u8, text: []const u8) !bool {
    var re = try Regex.compile(arena, pattern);
    var m = try Matcher.init(arena, &re);
    return m.matches(text);
}

// ---- AST ----

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

// ---- Recursive descent parser ----

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
        if (self.pos != self.src.len) return error.InvalidPattern; // Trailing residue, e.g. extra `)`.
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
            '*', '+', '?' => return error.InvalidPattern, // Quantifier without atom.
            ')' => return error.InvalidPattern,
            else => {
                self.pos += 1;
                return self.node(.{ .lit = c });
            },
        }
    }

    fn parseEscape(self: *Parser) CompileError!*const Ast {
        self.pos += 1; // Consume backslash.
        const c = self.peek() orelse return error.InvalidPattern; // Lone trailing backslash.
        self.pos += 1;
        switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                const id = try self.addPredefClass(c);
                return self.node(.{ .class = id });
            },
            'n' => return self.node(.{ .lit = '\n' }),
            't' => return self.node(.{ .lit = '\t' }),
            'r' => return self.node(.{ .lit = '\r' }),
            else => return self.node(.{ .lit = c }), // Escaped metacharacter or normal char.
        }
    }

    fn parseClass(self: *Parser) CompileError!*const Ast {
        self.pos += 1; // Consume '['.
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(self.arena);

        var first = true;
        while (true) {
            const c = self.peek() orelse return error.InvalidPattern; // Unclosed ']'.
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
            // Range a-z only when '-' is followed by a non-']' char; otherwise literal '-'.
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1; // Consume '-'.
                const hi = self.src[self.pos];
                self.pos += 1;
                if (hi < c) return error.InvalidPattern; // Reversed range.
                try ranges.append(self.arena, .{ .lo = c, .hi = hi });
            } else {
                try ranges.append(self.arena, .{ .lo = c, .hi = c });
            }
        }
        if (ranges.items.len == 0) return error.InvalidPattern; // Empty class [].

        const id: u32 = @intCast(self.classes.items.len);
        try self.classes.append(self.arena, .{
            .ranges = try ranges.toOwnedSlice(self.arena),
            .negated = negated,
        });
        return self.node(.{ .class = id });
    }

    /// Expands class-internal escapes (`\d \w \s`, `\n \t \r`, or escaped
    /// literals) into appended ranges.
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

    /// Registers a predefined class (`\d \w \s` and uppercase negations) and
    /// returns its id.
    fn addPredefClass(self: *Parser, kind: u8) !u32 {
        const negated = std.ascii.isUpper(kind);
        const ranges: []const Range = switch (std.ascii.toLower(kind)) {
            'd' => &.{.{ .lo = '0', .hi = '9' }},
            'w' => &predef_word,
            's' => &predef_space,
            else => return error.InvalidPattern, // Forward-proof: callers only pass d/w/s.
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
    .{ .lo = 0x0b, .hi = 0x0c }, // Vertical tab / form feed.
};

// ---- AST -> Instruction compilation ----

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

// ---- Tests ----

fn expectMatch(pattern: []const u8, text: []const u8, want: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try matchOnce(arena_state.allocator(), pattern, text);
    try std.testing.expectEqual(want, got);
}

test "literal substring match independent of position (unanchored)" {
    try expectMatch("abc", "abc", true);
    try expectMatch("abc", "xxabcyy", true);
    try expectMatch("abc", "ab", false);
    try expectMatch("", "anything", true); // Empty pattern matches anything.
}

test "anchors ^ and $" {
    try expectMatch("^abc", "abcdef", true);
    try expectMatch("^abc", "xabc", false);
    try expectMatch("abc$", "xxabc", true);
    try expectMatch("abc$", "abcx", false);
    try expectMatch("^abc$", "abc", true);
    try expectMatch("^abc$", "abcd", false);
    try expectMatch("^$", "", true);
}

test "quantifiers * + ?" {
    try expectMatch("ab*c", "ac", true);
    try expectMatch("ab*c", "abbbc", true);
    try expectMatch("ab+c", "ac", false);
    try expectMatch("ab+c", "abc", true);
    try expectMatch("ab?c", "ac", true);
    try expectMatch("ab?c", "abc", true);
    try expectMatch("ab?c", "abbc", false);
}

test "wildcard . and escaping" {
    try expectMatch("a.c", "axc", true);
    try expectMatch("a.c", "ac", false);
    try expectMatch("a\\.c", "a.c", true);
    try expectMatch("a\\.c", "axc", false);
}

test "groups and alternation () |" {
    try expectMatch("(ab|cd)+", "abcdab", true);
    try expectMatch("gr(a|e)y", "gray", true);
    try expectMatch("gr(a|e)y", "grey", true);
    try expectMatch("gr(a|e)y", "groy", false);
    try expectMatch("^(foo|bar)$", "bar", true);
    try expectMatch("^(foo|bar)$", "baz", false);
}

test "character classes [] with ranges and negation" {
    try expectMatch("[a-z]+", "hello", true);
    try expectMatch("[a-z]+", "123", false);
    try expectMatch("[^0-9]", "a", true);
    try expectMatch("[^0-9]", "5", false);
    try expectMatch("[abc]x", "bx", true);
    try expectMatch("[-a]", "-", true); // Trailing '-' is literal.
    try expectMatch("a[0-9]+b", "a123b", true);
}

test "predefined classes \\d \\w \\s and negation" {
    try expectMatch("\\d+", "abc123", true);
    try expectMatch("^\\d+$", "123", true);
    try expectMatch("^\\d+$", "12a", false);
    try expectMatch("\\w+", "_foo9", true);
    try expectMatch("a\\sb", "a b", true);
    try expectMatch("a\\sb", "a\tb", true);
    try expectMatch("\\D", "x", true);
    try expectMatch("\\D", "5", false);
}

test "bytes match expected ranges" {
    try expectMatch("world", "helloworld", true);
    try expectMatch("world", "hellowor", false);
}

test "ReDoS pathological pattern remains linear and does not hang" {
    // Backtracking engines explode here; Thompson NFA stays linear and returns false.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!"; // 30 a's plus a mismatching tail.
    const got = try matchOnce(arena_state.allocator(), "(a+)+$", text);
    try std.testing.expectEqual(false, got);
}

test "invalid pattern returns error instead of panic" {
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

test "Matcher supports repeated matches" {
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
