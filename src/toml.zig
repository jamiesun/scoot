//! 极简 TOML 子集解析器：把 config.toml 文本解析为 std.json.Value 树。
//! 解析结果交给 std.json.parseFromValueLeaky 映射进类型化的 FileConfig，
//! 从而复用全部默认值 / 按节合并 / extra_body 透传逻辑——本模块只管 TOML→Value 这一段。
//!
//! 覆盖 Scoot 配置实际需要的 TOML 子集：
//!   - `#` 行注释
//!   - `[table]` / `[a.b]` 表头（含点分嵌套）
//!   - `[[a.b]]` 表数组（schedule.jobs 用）
//!   - `key = value`（key 可裸键或带引号；支持点分键 `a.b = v`）
//!   - 值：基本串 `"..."`（带转义）、字面串 `'...'`、整数（可含 `_`）、浮点、布尔、
//!     行内数组 `[..]`（可跨行）、行内表 `{..}`
//!
//! 明确不支持（遇到即 `error.InvalidToml`，绝不静默 / panic——铁律 #4）：
//!   日期时间、多行串 `"""` / `'''`、非十进制整数（0x/0o/0b）、inf/nan。
//!   Scoot 配置无这些需求；需要时回落用 config.json。
//!
//! 内存：全部分配走调用方传入的 arena（与 Value 同寿命）；输入 `src` 须在 arena 存活期内有效。
//! 指针稳定性：不缓存任何指向托管表内部的长寿命指针——每次插入都从 root 按 cursor 现导航现插，
//!   规避 StringArrayHashMap / ArrayList 扩容搬迁导致的悬垂。

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;

pub const Error = error{InvalidToml} || std.mem.Allocator.Error;

/// 解析 TOML 文本，返回根表（Value.object）。畸形输入返回 error.InvalidToml。
pub fn parse(arena: std.mem.Allocator, src: []const u8) Error!Value {
    var p: Parser = .{ .src = src, .arena = arena, .root = .empty };
    try p.run();
    return .{ .object = p.root };
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    root: ObjectMap,
    /// 当前表头的点分路径（空 = 根表）。
    cur_path: []const []const u8 = &.{},
    /// cur_path 末段是否为「表数组」（[[..]]）——是则插入目标为该数组的最后一个元素。
    cur_is_array_elem: bool = false,

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

    // ---- 词法骨架 -------------------------------------------------------

    /// 跳过空白、换行与行注释（语句之间）。
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

    /// 仅跳过行内空白（空格 / 制表符）。
    fn skipInline(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t'))
            self.pos += 1;
    }

    fn skipToLineEnd(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
    }

    /// 语句尾：行内空白 + 可选注释后，必须是换行或 EOF。
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

    // ---- 表头 -----------------------------------------------------------

    fn parseHeader(self: *Parser) Error!void {
        // 已知 src[pos] == '['
        self.pos += 1;
        const is_array = self.pos < self.src.len and self.src[self.pos] == '[';
        if (is_array) self.pos += 1;

        const path = try self.parseDottedKey();
        if (path.len == 0) return error.InvalidToml;

        self.skipInline();
        // 关闭括号
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
            // 普通表：路径登记到 cursor，懒创建（空表回落默认即可）。
            self.cur_path = path;
            self.cur_is_array_elem = false;
        }
    }

    /// [[a.b]]：导航到 a，在其下确保 b 是数组并追加一个空表元素。
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

    // ---- 键值对 ---------------------------------------------------------

    fn parseKeyValue(self: *Parser) Error!void {
        const key_path = try self.parseDottedKey();
        if (key_path.len == 0) return error.InvalidToml;
        self.skipInline();
        if (self.pos >= self.src.len or self.src[self.pos] != '=') return error.InvalidToml;
        self.pos += 1;
        self.skipInline();
        const val = try self.parseValue();
        try self.expectLineEnd();

        // 导航到当前表，再按点分键下钻插入。
        var map = try self.currentTable();
        for (key_path[0 .. key_path.len - 1]) |seg| map = try ensureObjectChild(self.arena, map, seg);
        const leaf = key_path[key_path.len - 1];
        if (map.contains(leaf)) return error.InvalidToml; // 重复键
        try map.put(self.arena, try self.dup(leaf), val);
    }

    /// 按 cursor 现导航出当前插入目标表（不缓存指针）。
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

    // ---- 键解析 ---------------------------------------------------------

    /// 解析点分键 `a.b.c`，返回各段（裸键或带引号串）。
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
        // 裸键：A-Za-z0-9_-
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

    // ---- 值解析 ---------------------------------------------------------

    fn parseValue(self: *Parser) Error!Value {
        self.skipInline();
        const c = self.peek() orelse return error.InvalidToml;
        switch (c) {
            '"', '\'' => return .{ .string = try self.parseString() },
            '[' => return self.parseArray(),
            '{' => return self.parseInlineTable(),
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
        // 词后须为边界（非字母数字下划线）
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

    /// 单行字符串：基本串 `"..."`（带转义）或字面串 `'...'`（无转义）。
    /// 多行串 `"""` / `'''` 不支持。
    fn parseString(self: *Parser) Error![]const u8 {
        const quote = self.src[self.pos];
        // 拒绝多行串
        if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == quote and self.src[self.pos + 2] == quote)
            return error.InvalidToml;
        self.pos += 1;
        if (quote == '\'') {
            // 字面串：原样到下一个 '，不处理转义，不跨行
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '\'') {
                if (self.src[self.pos] == '\n') return error.InvalidToml;
                self.pos += 1;
            }
            if (self.pos >= self.src.len) return error.InvalidToml;
            const s = self.src[start..self.pos];
            self.pos += 1; // 吃掉收尾 '
            return self.dup(s);
        }
        // 基本串：处理转义
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
        return error.InvalidToml; // 未闭合
    }

    /// 处理 \uXXXX / \UXXXXXXXX：读 n 个十六进制位，UTF-8 编码进 out。
    /// 调用时 self.pos 指向 'u'/'U'；返回时 pos 指向最后一个十六进制位（外层再 +1）。
    fn parseUnicodeEscape(self: *Parser, out: *std.ArrayList(u8), n: usize) Error!void {
        if (self.pos + n >= self.src.len) return error.InvalidToml;
        var cp: u21 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const hc = self.src[self.pos + 1 + i];
            const d = hexDigit(hc) orelse return error.InvalidToml;
            cp = (cp << 4) | d;
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidToml;
        try out.appendSlice(self.arena, buf[0..len]);
        self.pos += n; // 外层循环结束再 +1 吃掉最后一位
    }

    fn parseArray(self: *Parser) Error!Value {
        self.pos += 1; // [
        var arr = Array.init(self.arena);
        while (true) {
            self.skipTrivia(); // 数组可跨行 + 含注释
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
            // obj 可能因 ensureObjectChild 顶层插入而搬迁，故每轮用本地 obj 副本？
            // 不会：obj 是栈上的 ObjectMap 值，map=&obj 始终有效；子表搬迁只动子表内部缓冲。

            self.skipTrivia();
            const sep = self.peek() orelse return error.InvalidToml;
            if (sep == ',') {
                self.pos += 1;
                self.skipTrivia();
                if (self.peek() == @as(u8, '}')) { // 容忍尾随逗号
                    self.pos += 1;
                    return .{ .object = obj };
                }
            } else if (sep == '}') {
                self.pos += 1;
                return .{ .object = obj };
            } else return error.InvalidToml;
        }
    }

    /// 数字：十进制整数（可含 `_`）或浮点。拒绝日期时间 / 非十进制 / inf / nan。
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

        // 拒绝日期时间残留（含 ':' 已被上面的 token 集排除——':' 不在集合，故会断在那；
        // 但形如 1979-05-27 会被读成 token，含中部 '-' → 视为日期，拒绝）。
        // 去掉下划线分隔符后判定。
        var buf: std.ArrayList(u8) = .empty;
        for (raw) |ch| {
            if (ch == '_') continue;
            try buf.append(self.arena, ch);
        }
        const s = buf.items;
        if (s.len == 0) return error.InvalidToml;

        // 中部出现 '-' （非首位）→ 日期，拒绝。
        if (std.mem.indexOfScalarPos(u8, s, 1, '-')) |_| return error.InvalidToml;

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

/// 在 parent 下确保 name 为对象表并返回其指针；name 已存在但非表 → InvalidToml。
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

test "toml: 基本表与标量" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# 注释
        \\[backend]
        \\base_url = "https://x/openai/v1"  # 行尾注释
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

test "toml: 点分表头 [a.b] 映射为嵌套对象（extra_body 场景）" {
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

test "toml: 行内表与字符串数组" {
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

test "toml: 表数组 [[schedule.jobs]]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\[schedule]
        \\enabled = true
        \\
        \\[[schedule.jobs]]
        \\id = "disk"
        \\goal = "巡检磁盘"
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

test "toml: 转义与负数 / 浮点" {
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

test "toml: 空内容 → 空对象" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "  \n # 只有注释\n\t\n");
    try std.testing.expect(v == .object);
    try std.testing.expectEqual(@as(usize, 0), v.object.count());
}

test "toml: 畸形输入一律报错不 panic（防弹）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "key =",                  // 缺值
        "key = \"unterminated",  // 未闭合串
        "= 5",                    // 缺键
        "[unclosed",              // 表头未闭合
        "a = 2020-05-27",        // 日期时间不支持
        "a = \"\"\"x\"\"\"",     // 多行串不支持
        "a = 0x1F",               // 非十进制
        "a = nan",                // nan
        "[a]\nx = 1\nx = 2",     // 重复键
        "a = [1, 2",              // 数组未闭合
    };
    for (bad) |s| {
        try std.testing.expectError(error.InvalidToml, parse(arena.allocator(), s));
    }
}
