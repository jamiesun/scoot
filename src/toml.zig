//! Minimal TOML subset parser: parses config.toml text into a std.json.Value tree.
//! The result is fed to std.json.parseFromValueLeaky to map into typed FileConfig,
//! reusing all defaults, section merging, and extra_body passthrough logic. This
//! module only owns the TOML-to-Value step.
//!
//! It covers the TOML subset Scoot config actually needs:
//!   - `#` line comments
//!   - `[table]` / `[a.b]` headers with dotted nesting
//!   - `[[a.b]]` table arrays for schedule.jobs
//!   - `key = value`, with bare or quoted keys and dotted keys like `a.b = v`
//!   - values: basic strings `"..."` with escapes, literal strings `'...'`,
//!     integers with `_`, floats, bools, inline arrays `[..]`, and inline tables
//!     `{..}`
//!
//! Explicitly unsupported and rejected with `error.InvalidToml`: date-times,
//! multiline strings `"""` / `'''`, non-decimal integers (0x/0o/0b), inf, and
//! nan. Scoot config does not need these; use config.json if needed.
//!
//! Memory: all allocations use the caller-provided arena and live with the
//! Value. Input `src` must remain valid for the arena lifetime. Pointer stability:
//! no long-lived pointers into managed table internals are cached; every insert
//! navigates from root by cursor, avoiding dangling pointers after map/list growth.

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

/// Maximum inline array/table nesting; exceeding it returns error.InvalidToml
/// instead of risking stack overflow (issue #44).
const max_nesting_depth: usize = 64;

pub const Error = error{InvalidToml} || std.mem.Allocator.Error;

/// Parse failure position for upper layers to report file:line:column (issue #46).
pub const Diagnostic = struct {
    /// 1-based line number.
    line: usize,
    /// 1-based byte column.
    col: usize,
    /// Byte offset at the error.
    byte: usize,
};

/// Parses TOML text and returns the root table as Value.object.
pub fn parse(arena: std.mem.Allocator, src: []const u8) Error!Value {
    return parseDiag(arena, src, null);
}

/// Like `parse`, but writes parse failure position into `diag` when provided.
pub fn parseDiag(arena: std.mem.Allocator, src: []const u8, diag: ?*Diagnostic) Error!Value {
    var p: Parser = .{ .src = src, .arena = arena, .root = .empty };
    p.run() catch |err| {
        if (err == error.InvalidToml) {
            if (diag) |d| d.* = lineColAt(src, p.pos);
        }
        return err;
    };
    return .{ .object = p.root };
}

/// Computes 1-based line/column from byte offset for diagnostics.
fn lineColAt(src: []const u8, pos: usize) Diagnostic {
    const clamped = if (pos > src.len) src.len else pos;
    var line: usize = 1;
    var col: usize = 1;
    var i: usize = 0;
    while (i < clamped) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col, .byte = clamped };
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    root: ObjectMap,
    /// Dotted path of the current table header; empty means root table.
    cur_path: []const []const u8 = &.{},
    /// Whether the last cur_path segment is an array table ([[..]]); if true,
    /// insert into that array's last element.
    cur_is_array_elem: bool = false,
    /// Current value nesting depth for inline arrays/tables; prevents unbounded
    /// mutual recursion stack overflow (issue #44).
    depth: usize = 0,

    fn run(self: *Parser) Error!void {
        while (true) {
            self.skipTrivia();
            if (self.pos >= self.src.len) return;
            const c = self.src[self.pos];
            if (c == '[') {
                try self.parseHeader();
            } else {
                try self.parseKeyValue();
            }
        }
    }

    // ---- Lexical skeleton ------------------------------------------------

    /// Skips whitespace, newlines, and line comments between statements.
    fn skipTrivia(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                '#' => self.skipToLineEnd(),
                else => return,
            }
        }
    }

    /// Skips inline spaces and tabs only.
    fn skipInline(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t'))
            self.pos += 1;
    }

    fn skipToLineEnd(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
    }

    /// Statement end: after inline whitespace and optional comment, require EOL or EOF.
    fn expectLineEnd(self: *Parser) Error!void {
        self.skipInline();
        if (self.pos >= self.src.len) return;
        const c = self.src[self.pos];
        if (c == '#') {
            self.skipToLineEnd();
            return;
        }
        if (c == '\n' or c == '\r') return;
        return error.InvalidToml;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    // ---- Headers ---------------------------------------------------------

    fn parseHeader(self: *Parser) Error!void {
        // src[pos] is known to be '['.
        self.pos += 1;
        const is_array = self.pos < self.src.len and self.src[self.pos] == '[';
        if (is_array) self.pos += 1;

        const path = try self.parseDottedKey();
        if (path.len == 0) return error.InvalidToml;

        self.skipInline();
        // Closing bracket.
        if (self.pos >= self.src.len or self.src[self.pos] != ']') return error.InvalidToml;
        self.pos += 1;
        if (is_array) {
            if (self.pos >= self.src.len or self.src[self.pos] != ']') return error.InvalidToml;
            self.pos += 1;
        }
        try self.expectLineEnd();

        if (is_array) {
            try self.openArrayTable(path);
            self.cur_path = path;
            self.cur_is_array_elem = true;
        } else {
            // Normal table: record cursor path and create lazily.
            self.cur_path = path;
            self.cur_is_array_elem = false;
        }
    }

    /// [[a.b]]: navigate to a, ensure b is an array, and append an empty table.
    fn openArrayTable(self: *Parser, path: []const []const u8) Error!void {
        var map: *ObjectMap = &self.root;
        for (path[0 .. path.len - 1]) |seg| map = try ensureObjectChild(self.arena, map, seg);
        const leaf = path[path.len - 1];
        if (map.getPtr(leaf)) |v| {
            if (v.* != .array) return error.InvalidToml;
        } else {
            try map.put(self.arena, try self.dup(leaf), .{ .array = Array.init(self.arena) });
        }
        const arr = &map.getPtr(leaf).?.array;
        try arr.append(.{ .object = .empty });
    }

    // ---- Key/value pairs -------------------------------------------------

    fn parseKeyValue(self: *Parser) Error!void {
        const key_path = try self.parseDottedKey();
        if (key_path.len == 0) return error.InvalidToml;
        self.skipInline();
        if (self.pos >= self.src.len or self.src[self.pos] != '=') return error.InvalidToml;
        self.pos += 1;
        self.skipInline();
        const val = try self.parseValue();
        try self.expectLineEnd();

        // Navigate to current table, then descend dotted key segments to insert.
        var map = try self.currentTable();
        for (key_path[0 .. key_path.len - 1]) |seg| map = try ensureObjectChild(self.arena, map, seg);
        const leaf = key_path[key_path.len - 1];
        if (map.contains(leaf)) return error.InvalidToml; // Duplicate key.
        try map.put(self.arena, try self.dup(leaf), val);
    }

    /// Navigates by cursor to the current insertion table without caching pointers.
    fn currentTable(self: *Parser) Error!*ObjectMap {
        var map: *ObjectMap = &self.root;
        const n = self.cur_path.len;
        for (self.cur_path, 0..) |seg, i| {
            const last = (i == n - 1);
            if (last and self.cur_is_array_elem) {
                const v = map.getPtr(seg) orelse return error.InvalidToml;
                if (v.* != .array) return error.InvalidToml;
                const items = v.array.items;
                if (items.len == 0) return error.InvalidToml;
                const elem = &items[items.len - 1];
                if (elem.* != .object) return error.InvalidToml;
                return &elem.object;
            }
            map = try ensureObjectChild(self.arena, map, seg);
        }
        return map;
    }

    // ---- Key parsing -----------------------------------------------------

    /// Parses dotted key `a.b.c` and returns segments, bare or quoted.
    fn parseDottedKey(self: *Parser) Error![]const []const u8 {
        var segs: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipInline();
            const seg = try self.parseKeySegment();
            try segs.append(self.arena, seg);
            self.skipInline();
            if (self.pos < self.src.len and self.src[self.pos] == '.') {
                self.pos += 1;
                continue;
            }
            break;
        }
        return segs.items;
    }

    fn parseKeySegment(self: *Parser) Error![]const u8 {
        const c = self.peek() orelse return error.InvalidToml;
        if (c == '"' or c == '\'') return self.parseString();
        // Bare key: A-Za-z0-9_-
        const start = self.pos;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
                (ch >= '0' and ch <= '9') or ch == '_' or ch == '-';
            if (!ok) break;
            self.pos += 1;
        }
        if (self.pos == start) return error.InvalidToml;
        return self.dup(self.src[start..self.pos]);
    }

    // ---- Value parsing ---------------------------------------------------

    fn parseValue(self: *Parser) Error!Value {
        self.skipInline();
        const c = self.peek() orelse return error.InvalidToml;
        switch (c) {
            '"', '\'' => return .{ .string = try self.parseString() },
            '[' => {
                // Inline array/table nesting guard: InvalidToml instead of stack overflow.
                if (self.depth >= max_nesting_depth) return error.InvalidToml;
                self.depth += 1;
                defer self.depth -= 1;
                return self.parseArray();
            },
            '{' => {
                if (self.depth >= max_nesting_depth) return error.InvalidToml;
                self.depth += 1;
                defer self.depth -= 1;
                return self.parseInlineTable();
            },
            't', 'f' => return self.parseBool(),
            '0'...'9', '+', '-' => return self.parseNumber(),
            else => return error.InvalidToml,
        }
    }

    fn parseBool(self: *Parser) Error!Value {
        if (self.matchWord("true")) return .{ .bool = true };
        if (self.matchWord("false")) return .{ .bool = false };
        return error.InvalidToml;
    }

    fn matchWord(self: *Parser, word: []const u8) bool {
        if (self.pos + word.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + word.len], word)) return false;
        // Word must be followed by a boundary, not alnum or underscore.
        const after = self.pos + word.len;
        if (after < self.src.len) {
            const ch = self.src[after];
            const cont = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
                (ch >= '0' and ch <= '9') or ch == '_';
            if (cont) return false;
        }
        self.pos = after;
        return true;
    }

    /// Single-line string: basic `"..."` with escapes or literal `'...'`.
    /// Multiline `"""` / `'''` strings are unsupported.
    fn parseString(self: *Parser) Error![]const u8 {
        const quote = self.src[self.pos];
        // Reject multiline strings.
        if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == quote and self.src[self.pos + 2] == quote)
            return error.InvalidToml;
        self.pos += 1;
        if (quote == '\'') {
            // Literal string: raw until next ', with no escapes and no newlines.
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '\'') {
                if (self.src[self.pos] == '\n') return error.InvalidToml;
                self.pos += 1;
            }
            if (self.pos >= self.src.len) return error.InvalidToml;
            const s = self.src[start..self.pos];
            self.pos += 1; // Consume closing '.
            return self.dup(s);
        }
        // Basic string: process escapes.
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (ch == '"') {
                self.pos += 1;
                return out.items;
            }
            if (ch == '\n') return error.InvalidToml;
            if (ch == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.InvalidToml;
                const e = self.src[self.pos];
                switch (e) {
                    '"' => try out.append(self.arena, '"'),
                    '\\' => try out.append(self.arena, '\\'),
                    'n' => try out.append(self.arena, '\n'),
                    't' => try out.append(self.arena, '\t'),
                    'r' => try out.append(self.arena, '\r'),
                    'b' => try out.append(self.arena, 0x08),
                    'f' => try out.append(self.arena, 0x0C),
                    '/' => try out.append(self.arena, '/'),
                    'u' => try self.parseUnicodeEscape(&out, 4),
                    'U' => try self.parseUnicodeEscape(&out, 8),
                    else => return error.InvalidToml,
                }
                self.pos += 1;
            } else {
                try out.append(self.arena, ch);
                self.pos += 1;
            }
        }
        return error.InvalidToml; // Unclosed.
    }

    /// Handles \uXXXX / \UXXXXXXXX by reading n hex digits and UTF-8 encoding
    /// them into out. On entry self.pos points at 'u'/'U'; on return it points at
    /// the final hex digit so the outer loop can advance once more.
    fn parseUnicodeEscape(self: *Parser, out: *std.ArrayList(u8), n: usize) Error!void {
        if (self.pos + n >= self.src.len) return error.InvalidToml;
        // Use u32 for eight \U hex digits; u21 would drop high bits while
        // accumulating and truncate out-of-range codepoints (issue #47).
        var cp: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const hc = self.src[self.pos + 1 + i];
            const d = hexDigit(hc) orelse return error.InvalidToml;
            cp = (cp << 4) | d;
        }
        // Reject out-of-range (> U+10FFFF) and surrogate codepoints explicitly.
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return error.InvalidToml;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch return error.InvalidToml;
        try out.appendSlice(self.arena, buf[0..len]);
        self.pos += n; // Outer loop advances once more after the final digit.
    }

    fn parseArray(self: *Parser) Error!Value {
        self.pos += 1; // [
        var arr = Array.init(self.arena);
        while (true) {
            self.skipTrivia(); // Arrays may span lines and contain comments.
            const c = self.peek() orelse return error.InvalidToml;
            if (c == ']') {
                self.pos += 1;
                return .{ .array = arr };
            }
            const v = try self.parseValue();
            try arr.append(v);
            self.skipTrivia();
            const sep = self.peek() orelse return error.InvalidToml;
            if (sep == ',') {
                self.pos += 1;
            } else if (sep == ']') {
                self.pos += 1;
                return .{ .array = arr };
            } else return error.InvalidToml;
        }
    }

    fn parseInlineTable(self: *Parser) Error!Value {
        self.pos += 1; // {
        var obj: ObjectMap = .empty;
        self.skipTrivia();
        if (self.peek() == @as(u8, '}')) {
            self.pos += 1;
            return .{ .object = obj };
        }
        while (true) {
            self.skipTrivia();
            const key_path = try self.parseDottedKey();
            if (key_path.len == 0) return error.InvalidToml;
            self.skipInline();
            if (self.pos >= self.src.len or self.src[self.pos] != '=') return error.InvalidToml;
            self.pos += 1;
            const v = try self.parseValue();

            var map: *ObjectMap = &obj;
            for (key_path[0 .. key_path.len - 1]) |seg| map = try ensureObjectChild(self.arena, map, seg);
            const leaf = key_path[key_path.len - 1];
            if (map.contains(leaf)) return error.InvalidToml;
            try map.put(self.arena, try self.dup(leaf), v);
            // obj itself is stack-owned, so map=&obj remains valid; child table
            // growth may move child buffers, but not the root ObjectMap value.

            self.skipTrivia();
            const sep = self.peek() orelse return error.InvalidToml;
            if (sep == ',') {
                self.pos += 1;
                self.skipTrivia();
                if (self.peek() == @as(u8, '}')) { // Allow trailing comma.
                    self.pos += 1;
                    return .{ .object = obj };
                }
            } else if (sep == '}') {
                self.pos += 1;
                return .{ .object = obj };
            } else return error.InvalidToml;
        }
    }

    /// Number: decimal integer with optional `_`, or float. Rejects date-times,
    /// non-decimal forms, inf, and nan.
    fn parseNumber(self: *Parser) Error!Value {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            const tok = (ch >= '0' and ch <= '9') or ch == '_' or ch == '.' or
                ch == '+' or ch == '-' or ch == 'e' or ch == 'E';
            if (!tok) break;
            self.pos += 1;
        }
        const raw = self.src[start..self.pos];
        if (raw.len == 0) return error.InvalidToml;

        // Reject date-time residue. ':' is excluded from token chars, so those
        // forms stop earlier, but forms like 1979-05-27 are tokenized and contain
        // a middle '-' that marks a date. Remove `_` separators before checking.
        var buf: std.ArrayList(u8) = .empty;
        for (raw) |ch| {
            if (ch == '_') continue;
            try buf.append(self.arena, ch);
        }
        const s = buf.items;
        if (s.len == 0) return error.InvalidToml;

        // A middle '-' not at the start and not immediately after e/E marks a
        // date and is rejected. Exponent negatives like `1e-5` are valid floats.
        var k: usize = 1;
        while (k < s.len) : (k += 1) {
            if (s[k] == '-' and s[k - 1] != 'e' and s[k - 1] != 'E') return error.InvalidToml;
        }

        const is_float = std.mem.indexOfScalar(u8, s, '.') != null or
            std.mem.indexOfScalar(u8, s, 'e') != null or
            std.mem.indexOfScalar(u8, s, 'E') != null;
        if (is_float) {
            const f = std.fmt.parseFloat(f64, s) catch return error.InvalidToml;
            if (!std.math.isFinite(f)) return error.InvalidToml;
            return .{ .float = f };
        }
        const i = std.fmt.parseInt(i64, s, 10) catch return error.InvalidToml;
        return .{ .integer = i };
    }

    fn dup(self: *Parser, s: []const u8) Error![]const u8 {
        return self.arena.dupe(u8, s);
    }
};

/// Ensures `name` under parent is an object table and returns its pointer.
/// Existing non-table values return InvalidToml.
fn ensureObjectChild(arena: std.mem.Allocator, parent: *ObjectMap, name: []const u8) Error!*ObjectMap {
    if (parent.getPtr(name)) |v| {
        if (v.* != .object) return error.InvalidToml;
        return &v.object;
    }
    try parent.put(arena, try arena.dupe(u8, name), .{ .object = .empty });
    return &parent.getPtr(name).?.object;
}

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "toml: basic tables and scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# comment
        \\[backend]
        \\base_url = "https://x/openai/v1"  # line endingcomment
        \\model = "gpt-5.5"
        \\max_turns = 32
        \\enabled = true
        \\
        \\[tools]
        \\policy = 'guarded'
    ;
    const v = try parse(arena.allocator(), src);
    const backend = v.object.get("backend").?.object;
    try std.testing.expectEqualStrings("https://x/openai/v1", backend.get("base_url").?.string);
    try std.testing.expectEqualStrings("gpt-5.5", backend.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 32), backend.get("max_turns").?.integer);
    try std.testing.expectEqual(true, backend.get("enabled").?.bool);
    try std.testing.expectEqualStrings("guarded", v.object.get("tools").?.object.get("policy").?.string);
}

test "toml: dotted table [a.b] maps to nested object for extra_body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[backend]
        \\model = "gpt-5.5"
        \\
        \\[backend.extra_body]
        \\service_tier = "priority"
        \\reasoning_effort = "high"
    ;
    const v = try parse(arena.allocator(), src);
    const eb = v.object.get("backend").?.object.get("extra_body").?.object;
    try std.testing.expectEqualStrings("priority", eb.get("service_tier").?.string);
    try std.testing.expectEqualStrings("high", eb.get("reasoning_effort").?.string);
}

test "toml: inline table and string array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[backend]
        \\extra_body = { service_tier = "priority", reasoning_effort = "high" }
        \\
        \\[skills]
        \\extra_paths = ["/a/b", "/c/d"]
    ;
    const v = try parse(arena.allocator(), src);
    const eb = v.object.get("backend").?.object.get("extra_body").?.object;
    try std.testing.expectEqualStrings("priority", eb.get("service_tier").?.string);
    const paths = v.object.get("skills").?.object.get("extra_paths").?.array;
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("/a/b", paths.items[0].string);
    try std.testing.expectEqualStrings("/c/d", paths.items[1].string);
}

test "toml: array of tables [[schedule.jobs]]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[schedule]
        \\enabled = true
        \\
        \\[[schedule.jobs]]
        \\id = "disk"
        \\goal = "check disk"
        \\every_sec = 300
        \\
        \\[[schedule.jobs]]
        \\id = "morning"
        \\at_unix = 1893456000
    ;
    const v = try parse(arena.allocator(), src);
    const sched = v.object.get("schedule").?.object;
    try std.testing.expectEqual(true, sched.get("enabled").?.bool);
    const jobs = sched.get("jobs").?.array;
    try std.testing.expectEqual(@as(usize, 2), jobs.items.len);
    try std.testing.expectEqualStrings("disk", jobs.items[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 300), jobs.items[0].object.get("every_sec").?.integer);
    try std.testing.expectEqualStrings("morning", jobs.items[1].object.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 1893456000), jobs.items[1].object.get("at_unix").?.integer);
}

test "toml: escapingand negative numbers / floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\a = "line\nbreak\t\"q\""
        \\b = -17
        \\c = 0.5
        \\d = 1_000
    ;
    const v = try parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("line\nbreak\t\"q\"", v.object.get("a").?.string);
    try std.testing.expectEqual(@as(i64, -17), v.object.get("b").?.integer);
    try std.testing.expectEqual(@as(f64, 0.5), v.object.get("c").?.float);
    try std.testing.expectEqual(@as(i64, 1000), v.object.get("d").?.integer);
}

test "toml: empty content returns empty object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "  \n # only comments\n\t\n");
    try std.testing.expect(v == .object);
    try std.testing.expectEqual(@as(usize, 0), v.object.count());
}

test "toml: malformed input errors instead of panicking(defensive)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "key =", // Missing value.
        "key = \"unterminated", // Unclosed string.
        "= 5", // Missing key.
        "[unclosed", // Unclosed header.
        "a = 2020-05-27", // Date-time unsupported.
        "a = \"\"\"x\"\"\"", // Multiline string unsupported.
        "a = 0x1F", // Non-decimal.
        "a = nan", // nan
        "[a]\nx = 1\nx = 2", // Duplicate key.
        "a = [1, 2", // Unclosed array.
    };
    for (bad) |s| {
        try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), s));
    }
}

test "toml: negative exponent float is valid(issue #43)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\a = 1e-5
        \\b = 2.5e-10
        \\c = -3e-2
        \\d = 1e+5
        \\e = 6.022e23
    ;
    const v = try parse(arena.allocator(), src);
    try std.testing.expectApproxEqRel(@as(f64, 1e-5), v.object.get("a").?.float, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 2.5e-10), v.object.get("b").?.float, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, -3e-2), v.object.get("c").?.float, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 1e5), v.object.get("d").?.float, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 6.022e23), v.object.get("e").?.float, 1e-12);
    // Real dates are still rejected.
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), "x = 1979-05-27"));
}

test "toml: deep nesting returns InvalidToml without stack overflow(issue #44)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const open_arrays = "[" ** 5000;
    const src_arr = try std.fmt.allocPrint(arena.allocator(), "a = {s}", .{open_arrays});
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), src_arr));
    // Inline tables behave the same.
    const tbl = "x={" ** 5000;
    const src_tbl = try std.fmt.allocPrint(arena.allocator(), "a = {s}", .{tbl});
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), src_tbl));
    // Legal shallow nesting still works.
    const ok = try parse(arena.allocator(), "a = [[1, 2], [3, 4]]");
    try std.testing.expectEqual(@as(usize, 2), ok.object.get("a").?.array.items.len);
}

test "toml: out-of-range unicode escape is rejected and not truncated silently(issue #47)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // \U00200000 > U+10FFFF must error instead of truncating to a bad character.
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), "s = \"\\U00200000\""));
    // Surrogate codepoints are also rejected.
    try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), "s = \"\\uD800\""));
    // Legal escapes still work.
    const v = try parse(arena.allocator(), "s = \"\\u00e9\\U0001F600\"");
    try std.testing.expectEqualStrings("é😀", v.object.get("s").?.string);
}

test "toml: reports parse failure diagnostics (issue #46)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "a = 1\nb = 2\nc = @bad\n";
    var diag: Diagnostic = undefined;
    try std.testing.expectError(error.InvalidToml, parseDiag(arena.allocator(), src, &diag));
    try std.testing.expectEqual(@as(usize, 3), diag.line);
}
