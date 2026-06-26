//! Minimal Wasm binary structure decoder for Scoot's W0 wasm-host work.
//!
//! This is intentionally not an executor and not a complete WebAssembly
//! validator. It owns the cheap, dependency-free checks that make package
//! validation catch malformed module bytes before any runtime exists.
const std = @import("std");

const wasm = std.wasm;

pub const Summary = struct {
    sections: u32 = 0,
    types: u32 = 0,
    imported_functions: u32 = 0,
    functions: u32 = 0,
    codes: u32 = 0,
    tables: u32 = 0,
    memories: u32 = 0,
    globals: u32 = 0,
    exports: u32 = 0,
    data_segments: u32 = 0,
    declared_data_count: ?u32 = null,
};

pub const Validation = union(enum) {
    valid: Summary,
    invalid: []const u8,
};

const DecodeError = error{Invalid};

const Decoder = struct {
    arena: std.mem.Allocator,
    bytes: []const u8,
    r: std.Io.Reader,
    message: []const u8 = "invalid wasm module",

    fn init(arena: std.mem.Allocator, bytes: []const u8) Decoder {
        return .{
            .arena = arena,
            .bytes = bytes,
            .r = .fixed(bytes),
        };
    }

    fn fail(self: *Decoder, comptime fmt: []const u8, args: anytype) DecodeError {
        self.message = std.fmt.allocPrint(self.arena, fmt, args) catch "invalid wasm module";
        return error.Invalid;
    }

    fn takeByte(self: *Decoder, context: []const u8) DecodeError!u8 {
        return self.r.takeByte() catch |err| self.fail("{s}: truncated byte ({s})", .{ context, @errorName(err) });
    }

    fn takeU32(self: *Decoder, context: []const u8) DecodeError!u32 {
        return self.r.takeLeb128(u32) catch |err| self.fail("{s}: invalid or truncated u32 LEB128 ({s})", .{ context, @errorName(err) });
    }

    fn takeI32(self: *Decoder, context: []const u8) DecodeError!i32 {
        return self.r.takeLeb128(i32) catch |err| self.fail("{s}: invalid or truncated i32 LEB128 ({s})", .{ context, @errorName(err) });
    }

    fn takeI64(self: *Decoder, context: []const u8) DecodeError!i64 {
        return self.r.takeLeb128(i64) catch |err| self.fail("{s}: invalid or truncated i64 LEB128 ({s})", .{ context, @errorName(err) });
    }

    fn takeBytes(self: *Decoder, len: usize, context: []const u8) DecodeError![]const u8 {
        if (len > self.remaining()) return self.fail("{s}: truncated bytes", .{context});
        const start = self.r.seek;
        self.r.seek += len;
        return self.bytes[start..self.r.seek];
    }

    fn remaining(self: *const Decoder) usize {
        return self.bytes.len - self.r.seek;
    }

    fn expectEnd(self: *Decoder, context: []const u8) DecodeError!void {
        if (self.remaining() != 0) return self.fail("{s}: trailing bytes in section payload", .{context});
    }

    fn parseName(self: *Decoder, context: []const u8) DecodeError![]const u8 {
        const len = try self.takeU32(context);
        return self.takeBytes(len, context);
    }

    fn parseValType(self: *Decoder, context: []const u8) DecodeError!void {
        const b = try self.takeByte(context);
        _ = std.enums.fromInt(wasm.Valtype, b) orelse return self.fail("{s}: invalid value type 0x{x}", .{ context, b });
    }

    fn parseRefType(self: *Decoder, context: []const u8) DecodeError!void {
        const b = try self.takeByte(context);
        _ = std.enums.fromInt(wasm.RefType, b) orelse return self.fail("{s}: invalid reference type 0x{x}", .{ context, b });
    }

    fn parseLimits(self: *Decoder, context: []const u8) DecodeError!void {
        const flags = try self.takeU32(context);
        if (flags > 0x03) return self.fail("{s}: invalid limits flags {d}", .{ context, flags });
        const min = try self.takeU32(context);
        if ((flags & 0x01) != 0) {
            const max = try self.takeU32(context);
            if (max < min) return self.fail("{s}: limits max is smaller than min", .{context});
        }
    }

    fn parseTableType(self: *Decoder, context: []const u8) DecodeError!void {
        try self.parseRefType(context);
        try self.parseLimits(context);
    }

    fn parseGlobalType(self: *Decoder, context: []const u8) DecodeError!void {
        try self.parseValType(context);
        const mut = try self.takeByte(context);
        if (mut != 0 and mut != 1) return self.fail("{s}: invalid global mutability {d}", .{ context, mut });
    }

    fn parseInitExpr(self: *Decoder, context: []const u8) DecodeError!void {
        const opcode_byte = try self.takeByte(context);
        if (opcode_byte == 0xd0) {
            try self.parseRefType(context);
        } else if (opcode_byte == 0xd2) {
            _ = try self.takeU32(context);
        } else {
            const opcode = std.enums.fromInt(wasm.Opcode, opcode_byte) orelse
                return self.fail("{s}: invalid init opcode 0x{x}", .{ context, opcode_byte });
            switch (opcode) {
                .i32_const => _ = try self.takeI32(context),
                .i64_const => _ = try self.takeI64(context),
                .f32_const => _ = try self.takeBytes(4, context),
                .f64_const => _ = try self.takeBytes(8, context),
                .global_get => _ = try self.takeU32(context),
                else => return self.fail("{s}: unsupported init opcode {s}", .{ context, @tagName(opcode) }),
            }
        }
        const end = try self.takeByte(context);
        if (end != @intFromEnum(wasm.Opcode.end)) return self.fail("{s}: init expression missing end opcode", .{context});
    }
};

pub fn validateModuleBytes(arena: std.mem.Allocator, bytes: []const u8) !Validation {
    var d = Decoder.init(arena, bytes);
    const summary = parseModule(&d) catch |err| switch (err) {
        error.Invalid => return .{ .invalid = d.message },
    };
    return .{ .valid = summary };
}

fn parseModule(d: *Decoder) DecodeError!Summary {
    if (d.bytes.len < wasm.magic.len + wasm.version.len) {
        return d.fail("wasm file is too small", .{});
    }
    const magic = try d.takeBytes(wasm.magic.len, "wasm header");
    if (!std.mem.eql(u8, magic, &wasm.magic)) return d.fail("wasm magic bytes are invalid", .{});
    const version = try d.takeBytes(wasm.version.len, "wasm header");
    if (!std.mem.eql(u8, version, &wasm.version)) return d.fail("wasm version must be 1", .{});

    var summary: Summary = .{};
    var seen = [_]bool{false} ** 13;
    var last_order: u8 = 0;
    var saw_code = false;
    var declared_function_count: ?u32 = null;
    var declared_data_count: ?u32 = null;

    while (d.remaining() > 0) {
        const id = try d.takeByte("section id");
        if (id > @intFromEnum(wasm.Section.data_count)) {
            return d.fail("unknown wasm section id {d}", .{id});
        }
        const size = try d.takeU32("section size");
        if (size > d.remaining()) {
            return d.fail("section {s} payload truncated", .{sectionName(id)});
        }

        const section_start = d.r.seek;
        const section_end = section_start + @as(usize, size);
        const payload = d.bytes[section_start..section_end];
        d.r.seek = section_end;

        if (id != @intFromEnum(wasm.Section.custom)) {
            if (seen[id]) return d.fail("duplicate section {s}", .{sectionName(id)});
            seen[id] = true;
            const order = sectionOrder(id);
            if (order < last_order) return d.fail("section {s} appears out of order", .{sectionName(id)});
            last_order = order;
        }

        var section_decoder = Decoder.init(d.arena, payload);
        switch (@as(wasm.Section, @enumFromInt(id))) {
            .custom => parseCustomSection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err),
            .type => summary.types = parseTypeSection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err),
            .import => parseImportSection(&section_decoder, &summary) catch |err| return adoptSectionError(d, &section_decoder, err),
            .function => {
                const count = parseFunctionSection(&section_decoder, summary.types) catch |err| return adoptSectionError(d, &section_decoder, err);
                declared_function_count = count;
                summary.functions = count;
            },
            .table => summary.tables += parseTableSection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err),
            .memory => summary.memories += parseMemorySection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err),
            .global => summary.globals += parseGlobalSection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err),
            .@"export" => summary.exports = parseExportSection(&section_decoder, summary) catch |err| return adoptSectionError(d, &section_decoder, err),
            .start => parseStartSection(&section_decoder, summary.imported_functions + summary.functions) catch |err| return adoptSectionError(d, &section_decoder, err),
            .element => parseElementSection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err),
            .code => {
                saw_code = true;
                const count = parseCodeSection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err);
                summary.codes = count;
                if (declared_function_count) |expected| {
                    if (count != expected) return d.fail("function section count {d} does not match code section count {d}", .{ expected, count });
                }
            },
            .data => {
                const count = parseDataSection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err);
                summary.data_segments = count;
                if (declared_data_count) |expected| {
                    if (count != expected) return d.fail("data_count section declares {d} segments but data section has {d}", .{ expected, count });
                }
            },
            .data_count => {
                if (saw_code) return d.fail("data_count section must appear before code section", .{});
                declared_data_count = parseDataCountSection(&section_decoder) catch |err| return adoptSectionError(d, &section_decoder, err);
                summary.declared_data_count = declared_data_count;
            },
            _ => unreachable,
        }
        if (section_decoder.remaining() != 0) return d.fail("section {s} has trailing bytes", .{sectionName(id)});
        summary.sections += 1;
    }

    if (declared_function_count != null and !saw_code and summary.functions != 0) {
        return d.fail("function section is present without code section", .{});
    }
    return summary;
}

fn adoptSectionError(parent: *Decoder, child: *const Decoder, err: DecodeError) DecodeError {
    parent.message = child.message;
    return err;
}

fn sectionOrder(id: u8) u8 {
    return switch (id) {
        @intFromEnum(wasm.Section.type) => 1,
        @intFromEnum(wasm.Section.import) => 2,
        @intFromEnum(wasm.Section.function) => 3,
        @intFromEnum(wasm.Section.table) => 4,
        @intFromEnum(wasm.Section.memory) => 5,
        @intFromEnum(wasm.Section.global) => 6,
        @intFromEnum(wasm.Section.@"export") => 7,
        @intFromEnum(wasm.Section.start) => 8,
        @intFromEnum(wasm.Section.element) => 9,
        @intFromEnum(wasm.Section.data_count) => 10,
        @intFromEnum(wasm.Section.code) => 11,
        @intFromEnum(wasm.Section.data) => 12,
        else => 0,
    };
}

fn sectionName(id: u8) []const u8 {
    return switch (id) {
        @intFromEnum(wasm.Section.custom) => "custom",
        @intFromEnum(wasm.Section.type) => "type",
        @intFromEnum(wasm.Section.import) => "import",
        @intFromEnum(wasm.Section.function) => "function",
        @intFromEnum(wasm.Section.table) => "table",
        @intFromEnum(wasm.Section.memory) => "memory",
        @intFromEnum(wasm.Section.global) => "global",
        @intFromEnum(wasm.Section.@"export") => "export",
        @intFromEnum(wasm.Section.start) => "start",
        @intFromEnum(wasm.Section.element) => "element",
        @intFromEnum(wasm.Section.code) => "code",
        @intFromEnum(wasm.Section.data) => "data",
        @intFromEnum(wasm.Section.data_count) => "data_count",
        else => "unknown",
    };
}

fn parseVectorCount(d: *Decoder, context: []const u8) DecodeError!u32 {
    return d.takeU32(context);
}

fn parseCustomSection(d: *Decoder) DecodeError!void {
    _ = try d.parseName("custom section name");
    d.r.seek = d.bytes.len;
}

fn parseTypeSection(d: *Decoder) DecodeError!u32 {
    const count = try parseVectorCount(d, "type count");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const tag = try d.takeByte("function type");
        if (tag != wasm.function_type) return d.fail("type entry {d}: expected function type", .{i});
        const params = try parseVectorCount(d, "function params");
        var p: u32 = 0;
        while (p < params) : (p += 1) try d.parseValType("function param type");
        const results = try parseVectorCount(d, "function results");
        var r: u32 = 0;
        while (r < results) : (r += 1) try d.parseValType("function result type");
    }
    return count;
}

fn parseImportSection(d: *Decoder, summary: *Summary) DecodeError!void {
    const count = try parseVectorCount(d, "import count");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        _ = try d.parseName("import module name");
        _ = try d.parseName("import field name");
        const kind_byte = try d.takeByte("import kind");
        const kind = std.enums.fromInt(wasm.ExternalKind, kind_byte) orelse
            return d.fail("import entry {d}: invalid external kind {d}", .{ i, kind_byte });
        switch (kind) {
            .function => {
                const type_index = try d.takeU32("import function type index");
                if (type_index >= summary.types) return d.fail("import function type index {d} out of bounds", .{type_index});
                summary.imported_functions += 1;
            },
            .table => {
                try d.parseTableType("import table type");
                summary.tables += 1;
            },
            .memory => {
                try d.parseLimits("import memory limits");
                summary.memories += 1;
            },
            .global => {
                try d.parseGlobalType("import global type");
                summary.globals += 1;
            },
        }
    }
}

fn parseFunctionSection(d: *Decoder, type_count: u32) DecodeError!u32 {
    const count = try parseVectorCount(d, "function count");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const type_index = try d.takeU32("function type index");
        if (type_index >= type_count) return d.fail("function type index {d} out of bounds", .{type_index});
    }
    return count;
}

fn parseTableSection(d: *Decoder) DecodeError!u32 {
    const count = try parseVectorCount(d, "table count");
    var i: u32 = 0;
    while (i < count) : (i += 1) try d.parseTableType("table type");
    return count;
}

fn parseMemorySection(d: *Decoder) DecodeError!u32 {
    const count = try parseVectorCount(d, "memory count");
    var i: u32 = 0;
    while (i < count) : (i += 1) try d.parseLimits("memory limits");
    return count;
}

fn parseGlobalSection(d: *Decoder) DecodeError!u32 {
    const count = try parseVectorCount(d, "global count");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try d.parseGlobalType("global type");
        try d.parseInitExpr("global init expression");
    }
    return count;
}

fn parseExportSection(d: *Decoder, summary: Summary) DecodeError!u32 {
    const count = try parseVectorCount(d, "export count");
    const functions = summary.imported_functions + summary.functions;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        _ = try d.parseName("export name");
        const kind_byte = try d.takeByte("export kind");
        const kind = std.enums.fromInt(wasm.ExternalKind, kind_byte) orelse
            return d.fail("export entry {d}: invalid external kind {d}", .{ i, kind_byte });
        const index = try d.takeU32("export index");
        const limit = switch (kind) {
            .function => functions,
            .table => summary.tables,
            .memory => summary.memories,
            .global => summary.globals,
        };
        if (index >= limit) return d.fail("export index {d} out of bounds for {s}", .{ index, @tagName(kind) });
    }
    return count;
}

fn parseStartSection(d: *Decoder, function_count: u32) DecodeError!void {
    const index = try d.takeU32("start function index");
    if (index >= function_count) return d.fail("start function index {d} out of bounds", .{index});
}

fn parseElementSection(d: *Decoder) DecodeError!void {
    const count = try parseVectorCount(d, "element segment count");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flags = try d.takeU32("element segment flags");
        switch (flags) {
            0 => {
                try d.parseInitExpr("element offset expression");
                const funcs = try parseVectorCount(d, "element function index count");
                var n: u32 = 0;
                while (n < funcs) : (n += 1) _ = try d.takeU32("element function index");
            },
            1 => {
                const kind = try d.takeByte("element kind");
                if (kind != wasm.element_type) return d.fail("element segment kind must be funcref", .{});
                const funcs = try parseVectorCount(d, "element function index count");
                var n: u32 = 0;
                while (n < funcs) : (n += 1) _ = try d.takeU32("element function index");
            },
            2 => {
                _ = try d.takeU32("element table index");
                try d.parseInitExpr("element offset expression");
                const kind = try d.takeByte("element kind");
                if (kind != wasm.element_type) return d.fail("element segment kind must be funcref", .{});
                const funcs = try parseVectorCount(d, "element function index count");
                var n: u32 = 0;
                while (n < funcs) : (n += 1) _ = try d.takeU32("element function index");
            },
            else => return d.fail("unsupported element segment flags {d}", .{flags}),
        }
    }
}

fn parseCodeSection(d: *Decoder) DecodeError!u32 {
    const count = try parseVectorCount(d, "code body count");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const body_size = try d.takeU32("code body size");
        const body = try d.takeBytes(body_size, "code body");
        var body_decoder = Decoder.init(d.arena, body);
        const local_sets = try parseVectorCount(&body_decoder, "code local declaration count");
        var local_i: u32 = 0;
        while (local_i < local_sets) : (local_i += 1) {
            _ = try body_decoder.takeU32("code local count");
            try body_decoder.parseValType("code local type");
        }
        if (body_decoder.remaining() == 0) return d.fail("code body {d}: missing expression", .{i});
        if (body[body.len - 1] != @intFromEnum(wasm.Opcode.end)) return d.fail("code body {d}: expression must end with end opcode", .{i});
    }
    return count;
}

fn parseDataSection(d: *Decoder) DecodeError!u32 {
    const count = try parseVectorCount(d, "data segment count");
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const flags = try d.takeU32("data segment flags");
        switch (flags) {
            0 => try d.parseInitExpr("data offset expression"),
            1 => {},
            2 => {
                _ = try d.takeU32("data memory index");
                try d.parseInitExpr("data offset expression");
            },
            else => return d.fail("unsupported data segment flags {d}", .{flags}),
        }
        const size = try d.takeU32("data segment size");
        _ = try d.takeBytes(size, "data segment bytes");
    }
    return count;
}

fn parseDataCountSection(d: *Decoder) DecodeError!u32 {
    return d.takeU32("data_count value");
}

test "validateModuleBytes: accepts empty MVP module" {
    const res = try validateModuleBytes(std.testing.allocator, "\x00asm\x01\x00\x00\x00");
    const summary = switch (res) {
        .valid => |s| s,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u32, 0), summary.sections);
}

test "validateModuleBytes: rejects bad magic and version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad_magic = try validateModuleBytes(arena, "xxxx\x01\x00\x00\x00");
    switch (bad_magic) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "magic") != null),
    }
    const bad_version = try validateModuleBytes(arena, "\x00asm\x02\x00\x00\x00");
    switch (bad_version) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "version") != null),
    }
}

test "validateModuleBytes: rejects truncated section payload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const res = try validateModuleBytes(arena_state.allocator(), "\x00asm\x01\x00\x00\x00\x01\x01");
    switch (res) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "truncated") != null),
    }
}

test "validateModuleBytes: rejects malformed LEB128" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const res = try validateModuleBytes(arena_state.allocator(), "\x00asm\x01\x00\x00\x00\x01\x80\x80\x80\x80\x80\x00");
    switch (res) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "LEB128") != null),
    }
}

test "validateModuleBytes: checks function and code counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const module =
        "\x00asm\x01\x00\x00\x00" ++
        "\x01\x04\x01\x60\x00\x00" ++
        "\x03\x02\x01\x00" ++
        "\x0a\x01\x00";
    const res = try validateModuleBytes(arena_state.allocator(), module);
    switch (res) {
        .valid => return error.TestUnexpectedResult,
        .invalid => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "function section count") != null),
    }
}

test {
    std.testing.refAllDecls(@This());
}
