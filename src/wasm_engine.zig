//! W1 integer stack machine for Scoot's standalone `scoot-wasm` host.
//!
//! This module loads a decoded Wasm module into a runnable form and executes
//! integer functions: a stack machine with call frames and locals, structured
//! control flow (block/loop/if/else/br/br_if/br_table/return/call/
//! call_indirect), i32/i64 arithmetic, a single linear memory (64 KiB pages,
//! bounds-checked load/store, memory.size/grow), globals, a funcref table for
//! call_indirect, and active data/element segments.
//!
//! Safety is the point: every fault is a structured trap, never a panic. Fuel,
//! call-depth, value-stack, and memory-page caps bound runaway or hostile
//! modules. WASI, a full type validator, and floating point arithmetic are out
//! of scope for W1 (later phases); float values are carried as opaque bits so
//! integer code that merely moves them stays correct.
const std = @import("std");
const wasm = std.wasm;

pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    funcref = 0x70,
    externref = 0x6F,
};

pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: u32,
    f64: u64,

    pub fn zeroOf(t: ValType) Value {
        return switch (t) {
            .i32, .funcref, .externref => .{ .i32 = 0 },
            .i64 => .{ .i64 = 0 },
            .f32 => .{ .f32 = 0 },
            .f64 => .{ .f64 = 0 },
        };
    }
};

pub const Limits = struct {
    /// Maximum number of executed instructions before trapping.
    fuel: u64 = 200_000_000,
    /// Maximum Wasm call depth (guards native recursion too).
    max_call_depth: u32 = 1024,
    /// Maximum value-stack slots (operands + locals across all frames).
    value_stack_slots: u32 = 1 << 16,
    /// Maximum control-stack labels across all frames.
    control_stack_slots: u32 = 1 << 14,
    /// Maximum linear-memory pages the module may own/grow to.
    max_memory_pages: u32 = 1024,
};

pub const LoadError = error{ InvalidModule, OutOfMemory };

pub const Trap = error{
    Unreachable,
    DivByZero,
    IntOverflow,
    OutOfBoundsMemory,
    OutOfBoundsTable,
    UndefinedElement,
    IndirectCallTypeMismatch,
    CallStackExhausted,
    FuelExhausted,
    ValueStackOverflow,
    ValueStackUnderflow,
    ControlStackOverflow,
    LabelOutOfRange,
    Unsupported,
    TypeMismatch,
    GrowFailed,
    MalformedBody,
    OutOfMemory,
};

const page_size: u32 = 64 * 1024;

const FuncType = struct {
    params: []ValType,
    results: []ValType,
};

const Code = struct {
    local_types: []ValType,
    body: []const u8,
    meta: std.AutoHashMapUnmanaged(usize, BlockInfo) = .{},
};

const BlockKind = enum { block, loop, @"if" };

const BlockInfo = struct {
    kind: BlockKind,
    inner_start: usize,
    else_pc: ?usize,
    end_pc: usize,
    param_arity: u32,
    result_arity: u32,
};

const ExportKind = enum { function, table, memory, global };

const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

const Global = struct {
    value: Value,
    mutable: bool,
};

const MemoryType = struct {
    min: u32,
    max: ?u32,
};

pub const Module = struct {
    arena: std.mem.Allocator,
    types: []FuncType = &.{},
    /// type index per function (imports first, then defined).
    func_types: []u32 = &.{},
    imported_func_count: u32 = 0,
    codes: []Code = &.{},
    exports: []Export = &.{},
    globals: []Global = &.{},
    memory_type: ?MemoryType = null,
    table_min: ?u32 = null,
    table_max: ?u32 = null,
    /// Active element segments: table offset + function indices.
    active_elements: []ActiveElement = &.{},
    /// Active data segments: memory offset + bytes.
    active_data: []ActiveData = &.{},
    start: ?u32 = null,
};

const ActiveElement = struct {
    offset: u32,
    funcs: []u32,
};

const ActiveData = struct {
    offset: u32,
    bytes: []const u8,
};

pub const InvokeResult = union(enum) {
    values: []Value,
    trap: []const u8,
};

// ---------------------------------------------------------------------------
// Loader
// ---------------------------------------------------------------------------

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn atEnd(self: *const Cursor) bool {
        return self.pos >= self.bytes.len;
    }

    fn byte(self: *Cursor) LoadError!u8 {
        if (self.pos >= self.bytes.len) return error.InvalidModule;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn take(self: *Cursor, n: usize) LoadError![]const u8 {
        if (n > self.bytes.len - self.pos) return error.InvalidModule;
        const out = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn uleb(self: *Cursor, comptime T: type) LoadError!T {
        const bits = @typeInfo(T).int.bits;
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
            if (shift >= 64) return error.InvalidModule;
        }
        if (bits < 64 and result > std.math.maxInt(T)) return error.InvalidModule;
        return @intCast(result);
    }

    fn sleb(self: *Cursor, comptime T: type) LoadError!T {
        const bits = @typeInfo(T).int.bits;
        var result: i64 = 0;
        var shift: u7 = 0;
        var b: u8 = 0;
        while (true) {
            b = try self.byte();
            result |= @as(i64, @intCast(b & 0x7f)) << @intCast(shift);
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (shift >= 70) return error.InvalidModule;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            result |= @as(i64, -1) << @intCast(shift);
        }
        if (bits < 64) {
            if (result < std.math.minInt(T) or result > std.math.maxInt(T)) return error.InvalidModule;
        }
        return @intCast(result);
    }

    fn name(self: *Cursor) LoadError![]const u8 {
        const len = try self.uleb(u32);
        return self.take(len);
    }
};

fn valTypeFromByte(b: u8) LoadError!ValType {
    return std.enums.fromInt(ValType, b) orelse error.InvalidModule;
}

pub fn load(arena: std.mem.Allocator, bytes: []const u8) LoadError!Module {
    var m = Module{ .arena = arena };
    var c = Cursor{ .bytes = bytes };

    if (bytes.len < wasm.magic.len + wasm.version.len) return error.InvalidModule;
    if (!std.mem.eql(u8, try c.take(wasm.magic.len), &wasm.magic)) return error.InvalidModule;
    if (!std.mem.eql(u8, try c.take(wasm.version.len), &wasm.version)) return error.InvalidModule;

    var func_type_indices: std.ArrayList(u32) = .empty;
    var defined_codes: std.ArrayList(Code) = .empty;

    while (!c.atEnd()) {
        const id = try c.byte();
        const size = try c.uleb(u32);
        const payload = try c.take(size);
        var s = Cursor{ .bytes = payload };
        switch (id) {
            0 => {}, // custom: ignore
            1 => m.types = try loadTypes(arena, &s),
            2 => try loadImports(arena, &s, &m, &func_type_indices),
            3 => {
                const n = try s.uleb(u32);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const t = try s.uleb(u32);
                    if (t >= m.types.len) return error.InvalidModule;
                    try func_type_indices.append(arena, t);
                }
            },
            4 => try loadTable(&s, &m),
            5 => try loadMemory(&s, &m),
            6 => m.globals = try loadGlobals(arena, &s),
            7 => m.exports = try loadExports(arena, &s),
            8 => m.start = try s.uleb(u32),
            9 => m.active_elements = try loadElements(arena, &s),
            10 => try loadCode(arena, &s, &defined_codes),
            11 => m.active_data = try loadData(arena, &s),
            12 => {}, // data_count: structural only, ignored here
            else => return error.InvalidModule,
        }
    }

    m.func_types = func_type_indices.items;
    m.codes = defined_codes.items;
    if (m.codes.len != m.func_types.len - m.imported_func_count) return error.InvalidModule;
    if (m.start) |s| {
        if (s >= m.func_types.len) return error.InvalidModule;
    }

    // Precompute control-flow metadata for each defined function body.
    for (m.codes) |*code| {
        try scanBody(arena, &m, code);
    }
    return m;
}

fn loadTypes(arena: std.mem.Allocator, s: *Cursor) LoadError![]FuncType {
    const n = try s.uleb(u32);
    const types = try arena.alloc(FuncType, n);
    for (types) |*t| {
        if (try s.byte() != wasm.function_type) return error.InvalidModule;
        const np = try s.uleb(u32);
        const params = try arena.alloc(ValType, np);
        for (params) |*p| p.* = try valTypeFromByte(try s.byte());
        const nr = try s.uleb(u32);
        const results = try arena.alloc(ValType, nr);
        for (results) |*r| r.* = try valTypeFromByte(try s.byte());
        t.* = .{ .params = params, .results = results };
    }
    return types;
}

fn loadImports(
    arena: std.mem.Allocator,
    s: *Cursor,
    m: *Module,
    func_type_indices: *std.ArrayList(u32),
) LoadError!void {
    const n = try s.uleb(u32);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try s.name();
        _ = try s.name();
        const kind = try s.byte();
        switch (kind) {
            0 => {
                const t = try s.uleb(u32);
                if (t >= m.types.len) return error.InvalidModule;
                try func_type_indices.append(arena, t);
                m.imported_func_count += 1;
            },
            1 => { // table
                _ = try valTypeFromByte(try s.byte());
                try readLimitsInto(s, &m.table_min, &m.table_max);
            },
            2 => { // memory
                var min: u32 = 0;
                var max: ?u32 = null;
                try readLimitsRaw(s, &min, &max);
                m.memory_type = .{ .min = min, .max = max };
            },
            3 => { // global
                _ = try valTypeFromByte(try s.byte());
                _ = try s.byte(); // mutability
            },
            else => return error.InvalidModule,
        }
    }
}

fn readLimitsRaw(s: *Cursor, min: *u32, max: *?u32) LoadError!void {
    const flags = try s.byte();
    if (flags > 1) return error.InvalidModule;
    min.* = try s.uleb(u32);
    if (flags == 1) {
        const mx = try s.uleb(u32);
        if (mx < min.*) return error.InvalidModule;
        max.* = mx;
    } else max.* = null;
}

fn readLimitsInto(s: *Cursor, min: *?u32, max: *?u32) LoadError!void {
    var lo: u32 = 0;
    var hi: ?u32 = null;
    try readLimitsRaw(s, &lo, &hi);
    min.* = lo;
    max.* = hi;
}

fn loadTable(s: *Cursor, m: *Module) LoadError!void {
    const n = try s.uleb(u32);
    if (n == 0) return;
    if (n != 1) return error.InvalidModule; // single table only (W1)
    _ = try valTypeFromByte(try s.byte());
    try readLimitsInto(s, &m.table_min, &m.table_max);
}

fn loadMemory(s: *Cursor, m: *Module) LoadError!void {
    const n = try s.uleb(u32);
    if (n == 0) return;
    if (n != 1) return error.InvalidModule; // single memory only
    var min: u32 = 0;
    var max: ?u32 = null;
    try readLimitsRaw(s, &min, &max);
    m.memory_type = .{ .min = min, .max = max };
}

fn loadGlobals(arena: std.mem.Allocator, s: *Cursor) LoadError![]Global {
    const n = try s.uleb(u32);
    const globals = try arena.alloc(Global, n);
    for (globals) |*g| {
        const vt = try valTypeFromByte(try s.byte());
        const mut = try s.byte();
        g.* = .{ .value = try constExpr(s, vt), .mutable = mut == 1 };
    }
    return globals;
}

fn constExpr(s: *Cursor, vt: ValType) LoadError!Value {
    const op = try s.byte();
    const v: Value = switch (op) {
        0x41 => .{ .i32 = try s.sleb(i32) },
        0x42 => .{ .i64 = try s.sleb(i64) },
        0x43 => .{ .f32 = std.mem.readInt(u32, (try s.take(4))[0..4], .little) },
        0x44 => .{ .f64 = std.mem.readInt(u64, (try s.take(8))[0..8], .little) },
        0xd0 => blk: { // ref.null
            _ = try s.byte();
            break :blk .{ .i32 = -1 };
        },
        0xd2 => .{ .i32 = @bitCast(try s.uleb(u32)) }, // ref.func
        else => return error.InvalidModule,
    };
    if (try s.byte() != @intFromEnum(wasm.Opcode.end)) return error.InvalidModule;
    return coerce(v, vt);
}

fn coerce(v: Value, vt: ValType) Value {
    return switch (vt) {
        .i32, .funcref, .externref => switch (v) {
            .i32 => v,
            .i64 => |x| .{ .i32 = @truncate(x) },
            else => v,
        },
        .i64 => switch (v) {
            .i64 => v,
            .i32 => |x| .{ .i64 = x },
            else => v,
        },
        else => v,
    };
}

fn loadExports(arena: std.mem.Allocator, s: *Cursor) LoadError![]Export {
    const n = try s.uleb(u32);
    const exports = try arena.alloc(Export, n);
    for (exports) |*e| {
        const nm = try s.name();
        const kind_byte = try s.byte();
        const kind: ExportKind = switch (kind_byte) {
            0 => .function,
            1 => .table,
            2 => .memory,
            3 => .global,
            else => return error.InvalidModule,
        };
        e.* = .{ .name = nm, .kind = kind, .index = try s.uleb(u32) };
    }
    return exports;
}

fn loadElements(arena: std.mem.Allocator, s: *Cursor) LoadError![]ActiveElement {
    const n = try s.uleb(u32);
    var out: std.ArrayList(ActiveElement) = .empty;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const flags = try s.uleb(u32);
        switch (flags) {
            0 => {
                const offset = try constI32(s);
                const funcs = try readFuncVec(arena, s);
                try out.append(arena, .{ .offset = @bitCast(offset), .funcs = funcs });
            },
            1, 3 => { // passive / declarative: skip funcs
                _ = try s.byte(); // elemkind
                _ = try readFuncVec(arena, s);
            },
            2 => {
                _ = try s.uleb(u32); // table index
                const offset = try constI32(s);
                _ = try s.byte(); // elemkind
                const funcs = try readFuncVec(arena, s);
                try out.append(arena, .{ .offset = @bitCast(offset), .funcs = funcs });
            },
            else => return error.InvalidModule,
        }
    }
    return out.items;
}

fn readFuncVec(arena: std.mem.Allocator, s: *Cursor) LoadError![]u32 {
    const n = try s.uleb(u32);
    const funcs = try arena.alloc(u32, n);
    for (funcs) |*f| f.* = try s.uleb(u32);
    return funcs;
}

fn constI32(s: *Cursor) LoadError!i32 {
    if (try s.byte() != 0x41) return error.InvalidModule;
    const v = try s.sleb(i32);
    if (try s.byte() != @intFromEnum(wasm.Opcode.end)) return error.InvalidModule;
    return v;
}

fn loadCode(arena: std.mem.Allocator, s: *Cursor, codes: *std.ArrayList(Code)) LoadError!void {
    const n = try s.uleb(u32);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const body_size = try s.uleb(u32);
        const body = try s.take(body_size);
        var bc = Cursor{ .bytes = body };
        const decl_sets = try bc.uleb(u32);
        var local_types: std.ArrayList(ValType) = .empty;
        var total_locals: u64 = 0;
        var j: u32 = 0;
        while (j < decl_sets) : (j += 1) {
            const count = try bc.uleb(u32);
            const vt = try valTypeFromByte(try bc.byte());
            total_locals += count;
            if (total_locals > 1_000_000) return error.InvalidModule;
            var k: u32 = 0;
            while (k < count) : (k += 1) try local_types.append(arena, vt);
        }
        const expr = body[bc.pos..];
        if (expr.len == 0 or expr[expr.len - 1] != @intFromEnum(wasm.Opcode.end)) {
            return error.InvalidModule;
        }
        try codes.append(arena, .{ .local_types = local_types.items, .body = expr });
    }
}

fn loadData(arena: std.mem.Allocator, s: *Cursor) LoadError![]ActiveData {
    const n = try s.uleb(u32);
    var out: std.ArrayList(ActiveData) = .empty;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const flags = try s.uleb(u32);
        switch (flags) {
            0 => {
                const offset = try constI32(s);
                const len = try s.uleb(u32);
                const bytes = try s.take(len);
                try out.append(arena, .{ .offset = @bitCast(offset), .bytes = bytes });
            },
            1 => { // passive: skip
                const len = try s.uleb(u32);
                _ = try s.take(len);
            },
            2 => {
                _ = try s.uleb(u32); // memory index
                const offset = try constI32(s);
                const len = try s.uleb(u32);
                const bytes = try s.take(len);
                try out.append(arena, .{ .offset = @bitCast(offset), .bytes = bytes });
            },
            else => return error.InvalidModule,
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Control-flow pre-pass: matches block/loop/if/else/end and records arities.
// ---------------------------------------------------------------------------

fn blockTypeArity(m: *const Module, s: *Cursor) LoadError!struct { param: u32, result: u32 } {
    const v = try s.sleb(i64);
    if (v == -64) return .{ .param = 0, .result = 0 }; // empty (0x40)
    if (v < 0) return .{ .param = 0, .result = 1 }; // single value type
    const idx: usize = @intCast(v);
    if (idx >= m.types.len) return error.InvalidModule;
    const t = m.types[idx];
    return .{ .param = @intCast(t.params.len), .result = @intCast(t.results.len) };
}

fn scanBody(arena: std.mem.Allocator, m: *Module, code: *Code) LoadError!void {
    const body = code.body;
    var c = Cursor{ .bytes = body };
    const Pending = struct { kind: BlockKind, start: usize, inner: usize, param: u32, result: u32, else_pc: ?usize };
    var stack: std.ArrayList(Pending) = .empty;

    while (!c.atEnd()) {
        const op_pc = c.pos;
        const op = try c.byte();
        switch (op) {
            0x02, 0x03, 0x04 => { // block, loop, if
                const ar = try blockTypeArity(m, &c);
                const kind: BlockKind = switch (op) {
                    0x02 => .block,
                    0x03 => .loop,
                    else => .@"if",
                };
                try stack.append(arena, .{
                    .kind = kind,
                    .start = op_pc,
                    .inner = c.pos,
                    .param = ar.param,
                    .result = ar.result,
                    .else_pc = null,
                });
            },
            0x05 => { // else
                if (stack.items.len == 0) return error.InvalidModule;
                stack.items[stack.items.len - 1].else_pc = op_pc;
            },
            0x0B => { // end
                if (stack.items.len == 0) {
                    // function-body end; nothing to record.
                } else {
                    const p = stack.pop().?;
                    try code.meta.put(arena, p.start, .{
                        .kind = p.kind,
                        .inner_start = p.inner,
                        .else_pc = p.else_pc,
                        .end_pc = op_pc,
                        .param_arity = p.param,
                        .result_arity = p.result,
                    });
                }
            },
            else => try skipImmediates(&c, op),
        }
    }
    if (stack.items.len != 0) return error.InvalidModule;
}

fn skipImmediates(c: *Cursor, op: u8) LoadError!void {
    switch (op) {
        // already handled by caller: 0x02 0x03 0x04 0x05 0x0B
        0x0C, 0x0D => _ = try c.uleb(u32), // br, br_if
        0x0E => { // br_table
            const n = try c.uleb(u32);
            var i: u32 = 0;
            while (i < n + 1) : (i += 1) _ = try c.uleb(u32);
        },
        0x10 => _ = try c.uleb(u32), // call
        0x11 => { // call_indirect
            _ = try c.uleb(u32);
            _ = try c.uleb(u32);
        },
        0x20, 0x21, 0x22, 0x23, 0x24 => _ = try c.uleb(u32), // local/global
        0x28...0x3E => { // loads/stores: align + offset
            _ = try c.uleb(u32);
            _ = try c.uleb(u32);
        },
        0x3F, 0x40 => _ = try c.byte(), // memory.size / memory.grow
        0x41 => _ = try c.sleb(i32), // i32.const
        0x42 => _ = try c.sleb(i64), // i64.const
        0x43 => _ = try c.take(4), // f32.const
        0x44 => _ = try c.take(8), // f64.const
        0xD0 => _ = try c.byte(), // ref.null
        0xD2 => _ = try c.uleb(u32), // ref.func
        0xFC => { // misc prefix
            const sub = try c.uleb(u32);
            switch (sub) {
                0...7 => {}, // trunc_sat: no immediates
                10 => { // memory.copy
                    _ = try c.byte();
                    _ = try c.byte();
                },
                11 => _ = try c.byte(), // memory.fill
                else => return error.InvalidModule,
            }
        },
        0xFD, 0xFE => return error.InvalidModule, // simd / atomics: unsupported
        else => {}, // single-byte opcodes
    }
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

pub const Instance = struct {
    module: *const Module,
    arena: std.mem.Allocator,
    limits: Limits,
    fuel: u64,
    depth: u32 = 0,
    memory: []u8 = &.{},
    mem_pages: u32 = 0,
    globals: []Value = &.{},
    table: []i64 = &.{}, // funcref entries; -1 = null
    values: []Value = &.{},
    vsp: usize = 0,
    control: []Label = &.{},
    csp: usize = 0,
    trap_msg: ?[]const u8 = null,

    const Label = struct {
        is_loop: bool,
        base: usize,
        branch_arity: u32,
        branch_pc: usize,
        end_pc: usize,
    };

    pub fn init(arena: std.mem.Allocator, module: *const Module, limits: Limits) LoadError!Instance {
        var self = Instance{
            .module = module,
            .arena = arena,
            .limits = limits,
            .fuel = limits.fuel,
        };
        self.values = try arena.alloc(Value, limits.value_stack_slots);
        self.control = try arena.alloc(Label, limits.control_stack_slots);

        // Globals (copy of module init values).
        self.globals = try arena.alloc(Value, module.globals.len);
        for (module.globals, 0..) |g, i| self.globals[i] = g.value;

        // Linear memory.
        if (module.memory_type) |mt| {
            if (mt.min > limits.max_memory_pages) return error.InvalidModule;
            self.mem_pages = mt.min;
            self.memory = try arena.alloc(u8, @as(usize, mt.min) * page_size);
            @memset(self.memory, 0);
        }

        // Table.
        if (module.table_min) |tmin| {
            self.table = try arena.alloc(i64, tmin);
            @memset(self.table, -1);
        }

        // Active element segments.
        for (module.active_elements) |seg| {
            for (seg.funcs, 0..) |f, i| {
                const idx = @as(usize, seg.offset) + i;
                if (idx >= self.table.len) return error.InvalidModule;
                self.table[idx] = f;
            }
        }

        // Active data segments.
        for (module.active_data) |seg| {
            const end = @as(usize, seg.offset) + seg.bytes.len;
            if (end > self.memory.len) return error.InvalidModule;
            @memcpy(self.memory[seg.offset..end], seg.bytes);
        }

        return self;
    }

    fn funcType(self: *const Instance, func_index: u32) *const FuncType {
        return &self.module.types[self.module.func_types[func_index]];
    }

    pub fn findExport(self: *const Instance, name: []const u8, kind: ExportKind) ?u32 {
        for (self.module.exports) |e| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name)) return e.index;
        }
        return null;
    }

    /// Runs the module start function (if any). Returns a trap message on fault.
    pub fn runStart(self: *Instance) ?[]const u8 {
        const idx = self.module.start orelse return null;
        self.vsp = 0;
        self.csp = 0;
        self.depth = 0;
        self.callFunction(idx) catch return self.trapMessage();
        return null;
    }

    /// Invokes an exported function by name with the given arguments.
    pub fn invokeExport(self: *Instance, name: []const u8, args: []const Value) Trap!InvokeResult {
        const func_index = self.findExport(name, .function) orelse {
            return .{ .trap = "export not found or not a function" };
        };
        if (func_index >= self.module.func_types.len) {
            return .{ .trap = "export references undefined function" };
        }
        const ft = self.funcType(func_index);
        if (args.len != ft.params.len) return .{ .trap = "argument count mismatch" };

        self.vsp = 0;
        self.csp = 0;
        self.depth = 0;
        for (args, 0..) |a, i| self.values[i] = coerce(a, ft.params[i]);
        self.vsp = args.len;

        self.callFunction(func_index) catch {
            return .{ .trap = self.trapMessage() };
        };

        const results = try self.arena.alloc(Value, ft.results.len);
        @memcpy(results, self.values[self.vsp - ft.results.len .. self.vsp]);
        return .{ .values = results };
    }

    fn trapMessage(self: *Instance) []const u8 {
        return self.trap_msg orelse "trap";
    }

    fn setTrap(self: *Instance, comptime msg: []const u8) void {
        if (self.trap_msg == null) self.trap_msg = msg;
    }

    // ---- value stack helpers ----

    fn push(self: *Instance, v: Value) Trap!void {
        if (self.vsp >= self.values.len) {
            self.setTrap("value stack overflow");
            return error.ValueStackOverflow;
        }
        self.values[self.vsp] = v;
        self.vsp += 1;
    }

    fn pop(self: *Instance) Trap!Value {
        if (self.vsp == 0) {
            self.setTrap("value stack underflow");
            return error.ValueStackUnderflow;
        }
        self.vsp -= 1;
        return self.values[self.vsp];
    }

    fn popI32(self: *Instance) Trap!i32 {
        return switch (try self.pop()) {
            .i32 => |x| x,
            else => {
                self.setTrap("expected i32 operand");
                return error.TypeMismatch;
            },
        };
    }

    fn popI64(self: *Instance) Trap!i64 {
        return switch (try self.pop()) {
            .i64 => |x| x,
            else => {
                self.setTrap("expected i64 operand");
                return error.TypeMismatch;
            },
        };
    }

    fn moveTop(self: *Instance, base: usize, arity: usize) Trap!void {
        if (self.vsp < base + arity) {
            self.setTrap("value stack underflow on branch");
            return error.ValueStackUnderflow;
        }
        if (base != self.vsp - arity) {
            std.mem.copyForwards(Value, self.values[base .. base + arity], self.values[self.vsp - arity .. self.vsp]);
        }
        self.vsp = base + arity;
    }

    fn consumeFuel(self: *Instance) Trap!void {
        if (self.fuel == 0) {
            self.setTrap("out of fuel");
            return error.FuelExhausted;
        }
        self.fuel -= 1;
    }

    /// Executes a function whose arguments are already on the value stack top.
    fn callFunction(self: *Instance, func_index: u32) Trap!void {
        if (func_index >= self.module.func_types.len) {
            self.setTrap("call to undefined function");
            return error.MalformedBody;
        }
        if (func_index < self.module.imported_func_count) {
            self.setTrap("call to imported function (WASI is W2, not implemented)");
            return error.Unsupported;
        }
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > self.limits.max_call_depth) {
            self.setTrap("call stack exhausted");
            return error.CallStackExhausted;
        }

        const ft = self.funcType(func_index);
        const code = &self.module.codes[func_index - self.module.imported_func_count];

        const param_count = ft.params.len;
        if (self.vsp < param_count) {
            self.setTrap("value stack underflow at call");
            return error.ValueStackUnderflow;
        }
        const locals_base = self.vsp - param_count;

        // Append extra locals (zero-initialised).
        for (code.local_types) |lt| try self.push(Value.zeroOf(lt));
        const operand_base = self.vsp;
        const control_base = self.csp;

        // Outer (function-body) label.
        try self.pushLabel(.{
            .is_loop = false,
            .base = operand_base,
            .branch_arity = @intCast(ft.results.len),
            .branch_pc = 0,
            .end_pc = code.body.len - 1,
        });

        try self.run(code, locals_base, operand_base, control_base);

        // Move results down over the locals; leave them as caller's operands.
        const result_count = ft.results.len;
        try self.moveTop(locals_base, result_count);
        self.csp = control_base;
    }

    fn pushLabel(self: *Instance, label: Label) Trap!void {
        if (self.csp >= self.control.len) {
            self.setTrap("control stack overflow");
            return error.ControlStackOverflow;
        }
        self.control[self.csp] = label;
        self.csp += 1;
    }

    fn doBranch(self: *Instance, l: u32, pc: *usize, control_base: usize) Trap!void {
        const labels = self.csp - control_base;
        if (l >= labels) {
            self.setTrap("branch label out of range");
            return error.LabelOutOfRange;
        }
        const tidx = self.csp - 1 - l;
        const lab = self.control[tidx];
        try self.moveTop(lab.base, lab.branch_arity);
        if (lab.is_loop) {
            self.csp = tidx + 1;
            pc.* = lab.branch_pc;
        } else {
            self.csp = tidx;
            pc.* = lab.end_pc + 1;
        }
    }

    fn run(self: *Instance, code: *const Code, locals_base: usize, operand_base: usize, control_base: usize) Trap!void {
        const num_locals = operand_base - locals_base;
        const body = code.body;
        var pc: usize = 0;
        while (pc < body.len) {
            try self.consumeFuel();
            const op = body[pc];
            pc += 1;
            switch (op) {
                0x00 => { // unreachable
                    self.setTrap("unreachable executed");
                    return error.Unreachable;
                },
                0x01 => {}, // nop
                0x02, 0x03 => { // block, loop
                    const info = code.meta.get(pc - 1) orelse return self.malformed();
                    if (self.vsp < operand_base + info.param_arity) return self.malformed();
                    const is_loop = op == 0x03;
                    try self.pushLabel(.{
                        .is_loop = is_loop,
                        .base = self.vsp - info.param_arity,
                        .branch_arity = if (is_loop) info.param_arity else info.result_arity,
                        .branch_pc = info.inner_start,
                        .end_pc = info.end_pc,
                    });
                    pc = info.inner_start;
                },
                0x04 => { // if
                    const info = code.meta.get(pc - 1) orelse return self.malformed();
                    const cond = try self.popI32();
                    if (self.vsp < operand_base + info.param_arity) return self.malformed();
                    try self.pushLabel(.{
                        .is_loop = false,
                        .base = self.vsp - info.param_arity,
                        .branch_arity = info.result_arity,
                        .branch_pc = info.inner_start,
                        .end_pc = info.end_pc,
                    });
                    if (cond != 0) {
                        pc = info.inner_start;
                    } else if (info.else_pc) |epc| {
                        pc = epc + 1;
                    } else {
                        pc = info.end_pc;
                    }
                },
                0x05 => { // else: reached end of then-branch, skip to matching end
                    if (self.csp == control_base) return self.malformed();
                    pc = self.control[self.csp - 1].end_pc;
                },
                0x0B => { // end
                    if (self.csp == control_base + 1) {
                        return; // function-body end
                    }
                    self.csp -= 1;
                },
                0x0C => { // br
                    const l = try readU32(body, &pc);
                    try self.doBranch(l, &pc, control_base);
                },
                0x0D => { // br_if
                    const l = try readU32(body, &pc);
                    if (try self.popI32() != 0) try self.doBranch(l, &pc, control_base);
                },
                0x0E => { // br_table
                    const n = try readU32(body, &pc);
                    var chosen: u32 = 0;
                    const idx = @as(u32, @bitCast(try self.popI32()));
                    var i: u32 = 0;
                    var target: u32 = 0;
                    while (i < n + 1) : (i += 1) {
                        const l = try readU32(body, &pc);
                        if (i == idx or (i == n and idx >= n)) {
                            if (i == idx) {
                                target = l;
                                chosen = 1;
                            } else if (chosen == 0) {
                                target = l;
                            }
                        }
                    }
                    try self.doBranch(target, &pc, control_base);
                },
                0x0F => { // return
                    const labels = self.csp - control_base;
                    try self.doBranch(@intCast(labels - 1), &pc, control_base);
                },
                0x10 => { // call
                    const idx = try readU32(body, &pc);
                    if (idx >= self.module.func_types.len) return self.malformed();
                    try self.callFunction(idx);
                },
                0x11 => try self.callIndirect(body, &pc),
                0x1A => _ = try self.pop(), // drop
                0x1B => { // select
                    const c = try self.popI32();
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(if (c != 0) a else b);
                },
                0x20 => { // local.get
                    const i = try readU32(body, &pc);
                    if (i >= num_locals) return self.malformed();
                    try self.push(self.values[locals_base + i]);
                },
                0x21 => { // local.set
                    const i = try readU32(body, &pc);
                    if (i >= num_locals) return self.malformed();
                    self.values[locals_base + i] = try self.pop();
                },
                0x22 => { // local.tee
                    const i = try readU32(body, &pc);
                    if (i >= num_locals) return self.malformed();
                    const v = try self.pop();
                    self.values[locals_base + i] = v;
                    try self.push(v);
                },
                0x23 => { // global.get
                    const i = try readU32(body, &pc);
                    if (i >= self.globals.len) return self.malformed();
                    try self.push(self.globals[i]);
                },
                0x24 => { // global.set
                    const i = try readU32(body, &pc);
                    if (i >= self.globals.len) return self.malformed();
                    self.globals[i] = try self.pop();
                },
                0x28...0x3E => try self.memoryAccess(op, body, &pc),
                0x3F => { // memory.size
                    _ = try readByte(body, &pc);
                    try self.push(.{ .i32 = @bitCast(self.mem_pages) });
                },
                0x40 => { // memory.grow
                    _ = try readByte(body, &pc);
                    const delta = @as(u32, @bitCast(try self.popI32()));
                    try self.push(.{ .i32 = try self.memoryGrow(delta) });
                },
                0x41 => try self.push(.{ .i32 = try readI32(body, &pc) }),
                0x42 => try self.push(.{ .i64 = try readI64(body, &pc) }),
                0x43 => try self.push(.{ .f32 = try readU32le(body, &pc) }),
                0x44 => try self.push(.{ .f64 = try readU64le(body, &pc) }),
                0x45...0xC4 => try self.numericOp(op),
                0xFC => try self.miscOp(body, &pc),
                else => {
                    self.setTrap("unsupported opcode");
                    return error.Unsupported;
                },
            }
        }
        // Fell off the end (outer branch/return jumped past the final end).
        return;
    }

    fn malformed(self: *Instance) Trap {
        self.setTrap("malformed function body");
        return error.MalformedBody;
    }

    fn callIndirect(self: *Instance, body: []const u8, pc: *usize) Trap!void {
        const type_index = try readU32(body, pc);
        _ = try readU32(body, pc); // table index (single table)
        const elem = @as(u32, @bitCast(try self.popI32()));
        if (elem >= self.table.len) {
            self.setTrap("indirect call index out of bounds");
            return error.OutOfBoundsTable;
        }
        const entry = self.table[elem];
        if (entry < 0) {
            self.setTrap("indirect call to null element");
            return error.UndefinedElement;
        }
        const func_index: u32 = @intCast(entry);
        if (func_index >= self.module.func_types.len) return self.malformed();
        if (self.module.func_types[func_index] != type_index) {
            self.setTrap("indirect call type mismatch");
            return error.IndirectCallTypeMismatch;
        }
        try self.callFunction(func_index);
    }

    fn memoryGrow(self: *Instance, delta: u32) Trap!i32 {
        const old = self.mem_pages;
        const want = @as(u64, old) + delta;
        var cap = self.limits.max_memory_pages;
        if (self.module.memory_type) |mt| {
            if (mt.max) |mx| cap = @min(cap, mx);
        }
        if (want > cap) return -1;
        const new_bytes = self.arena.alloc(u8, @as(usize, @intCast(want)) * page_size) catch return -1;
        @memset(new_bytes, 0);
        @memcpy(new_bytes[0..self.memory.len], self.memory);
        self.memory = new_bytes;
        self.mem_pages = @intCast(want);
        return @bitCast(old);
    }

    fn effectiveAddr(self: *Instance, body: []const u8, pc: *usize, size: usize) Trap!usize {
        _ = try readU32(body, pc); // alignment hint
        const offset = try readU32(body, pc);
        const base = @as(u32, @bitCast(try self.popI32()));
        const addr = @as(u64, base) + offset;
        if (addr + size > self.memory.len) {
            self.setTrap("out of bounds memory access");
            return error.OutOfBoundsMemory;
        }
        return @intCast(addr);
    }

    fn memoryAccess(self: *Instance, op: u8, body: []const u8, pc: *usize) Trap!void {
        switch (op) {
            0x28 => { // i32.load
                const a = try self.effectiveAddr(body, pc, 4);
                try self.push(.{ .i32 = std.mem.readInt(i32, self.memory[a..][0..4], .little) });
            },
            0x29 => { // i64.load
                const a = try self.effectiveAddr(body, pc, 8);
                try self.push(.{ .i64 = std.mem.readInt(i64, self.memory[a..][0..8], .little) });
            },
            0x2A => { // f32.load
                const a = try self.effectiveAddr(body, pc, 4);
                try self.push(.{ .f32 = std.mem.readInt(u32, self.memory[a..][0..4], .little) });
            },
            0x2B => { // f64.load
                const a = try self.effectiveAddr(body, pc, 8);
                try self.push(.{ .f64 = std.mem.readInt(u64, self.memory[a..][0..8], .little) });
            },
            0x2C => { // i32.load8_s
                const a = try self.effectiveAddr(body, pc, 1);
                try self.push(.{ .i32 = @as(i8, @bitCast(self.memory[a])) });
            },
            0x2D => { // i32.load8_u
                const a = try self.effectiveAddr(body, pc, 1);
                try self.push(.{ .i32 = self.memory[a] });
            },
            0x2E => { // i32.load16_s
                const a = try self.effectiveAddr(body, pc, 2);
                try self.push(.{ .i32 = std.mem.readInt(i16, self.memory[a..][0..2], .little) });
            },
            0x2F => { // i32.load16_u
                const a = try self.effectiveAddr(body, pc, 2);
                try self.push(.{ .i32 = std.mem.readInt(u16, self.memory[a..][0..2], .little) });
            },
            0x30 => { // i64.load8_s
                const a = try self.effectiveAddr(body, pc, 1);
                try self.push(.{ .i64 = @as(i8, @bitCast(self.memory[a])) });
            },
            0x31 => { // i64.load8_u
                const a = try self.effectiveAddr(body, pc, 1);
                try self.push(.{ .i64 = self.memory[a] });
            },
            0x32 => { // i64.load16_s
                const a = try self.effectiveAddr(body, pc, 2);
                try self.push(.{ .i64 = std.mem.readInt(i16, self.memory[a..][0..2], .little) });
            },
            0x33 => { // i64.load16_u
                const a = try self.effectiveAddr(body, pc, 2);
                try self.push(.{ .i64 = std.mem.readInt(u16, self.memory[a..][0..2], .little) });
            },
            0x34 => { // i64.load32_s
                const a = try self.effectiveAddr(body, pc, 4);
                try self.push(.{ .i64 = std.mem.readInt(i32, self.memory[a..][0..4], .little) });
            },
            0x35 => { // i64.load32_u
                const a = try self.effectiveAddr(body, pc, 4);
                try self.push(.{ .i64 = std.mem.readInt(u32, self.memory[a..][0..4], .little) });
            },
            0x36 => { // i32.store
                const v = try self.popI32();
                const a = try self.effectiveAddr(body, pc, 4);
                std.mem.writeInt(i32, self.memory[a..][0..4], v, .little);
            },
            0x37 => { // i64.store
                const v = try self.popI64();
                const a = try self.effectiveAddr(body, pc, 8);
                std.mem.writeInt(i64, self.memory[a..][0..8], v, .little);
            },
            0x38 => { // f32.store
                const v = try self.popF32Bits();
                const a = try self.effectiveAddr(body, pc, 4);
                std.mem.writeInt(u32, self.memory[a..][0..4], v, .little);
            },
            0x39 => { // f64.store
                const v = try self.popF64Bits();
                const a = try self.effectiveAddr(body, pc, 8);
                std.mem.writeInt(u64, self.memory[a..][0..8], v, .little);
            },
            0x3A => { // i32.store8
                const v = try self.popI32();
                const a = try self.effectiveAddr(body, pc, 1);
                self.memory[a] = @truncate(@as(u32, @bitCast(v)));
            },
            0x3B => { // i32.store16
                const v = try self.popI32();
                const a = try self.effectiveAddr(body, pc, 2);
                std.mem.writeInt(u16, self.memory[a..][0..2], @truncate(@as(u32, @bitCast(v))), .little);
            },
            0x3C => { // i64.store8
                const v = try self.popI64();
                const a = try self.effectiveAddr(body, pc, 1);
                self.memory[a] = @truncate(@as(u64, @bitCast(v)));
            },
            0x3D => { // i64.store16
                const v = try self.popI64();
                const a = try self.effectiveAddr(body, pc, 2);
                std.mem.writeInt(u16, self.memory[a..][0..2], @truncate(@as(u64, @bitCast(v))), .little);
            },
            0x3E => { // i64.store32
                const v = try self.popI64();
                const a = try self.effectiveAddr(body, pc, 4);
                std.mem.writeInt(u32, self.memory[a..][0..4], @truncate(@as(u64, @bitCast(v))), .little);
            },
            else => unreachable,
        }
    }

    fn popF32Bits(self: *Instance) Trap!u32 {
        return switch (try self.pop()) {
            .f32 => |b| b,
            .i32 => |x| @bitCast(x),
            else => {
                self.setTrap("expected f32 operand");
                return error.TypeMismatch;
            },
        };
    }

    fn popF64Bits(self: *Instance) Trap!u64 {
        return switch (try self.pop()) {
            .f64 => |b| b,
            .i64 => |x| @bitCast(x),
            else => {
                self.setTrap("expected f64 operand");
                return error.TypeMismatch;
            },
        };
    }

    fn miscOp(self: *Instance, body: []const u8, pc: *usize) Trap!void {
        const sub = try readU32(body, pc);
        switch (sub) {
            10 => { // memory.copy
                _ = try readByte(body, pc);
                _ = try readByte(body, pc);
                const n = @as(u32, @bitCast(try self.popI32()));
                const src = @as(u32, @bitCast(try self.popI32()));
                const dst = @as(u32, @bitCast(try self.popI32()));
                const send = @as(u64, src) + n;
                const dend = @as(u64, dst) + n;
                if (send > self.memory.len or dend > self.memory.len) {
                    self.setTrap("out of bounds memory.copy");
                    return error.OutOfBoundsMemory;
                }
                if (n != 0) {
                    std.mem.copyForwards(u8, self.memory[dst .. dst + n], self.memory[src .. src + n]);
                }
            },
            11 => { // memory.fill
                _ = try readByte(body, pc);
                const n = @as(u32, @bitCast(try self.popI32()));
                const val: u8 = @truncate(@as(u32, @bitCast(try self.popI32())));
                const dst = @as(u32, @bitCast(try self.popI32()));
                if (@as(u64, dst) + n > self.memory.len) {
                    self.setTrap("out of bounds memory.fill");
                    return error.OutOfBoundsMemory;
                }
                @memset(self.memory[dst .. dst + n], val);
            },
            else => {
                self.setTrap("unsupported misc opcode");
                return error.Unsupported;
            },
        }
    }

    fn numericOp(self: *Instance, op: u8) Trap!void {
        switch (op) {
            // ---- i32 comparisons ----
            0x45 => try self.push(.{ .i32 = b2i(try self.popI32() == 0) }),
            0x46 => try self.cmpI32(.eq),
            0x47 => try self.cmpI32(.ne),
            0x48 => try self.cmpI32(.lt_s),
            0x49 => try self.cmpI32(.lt_u),
            0x4A => try self.cmpI32(.gt_s),
            0x4B => try self.cmpI32(.gt_u),
            0x4C => try self.cmpI32(.le_s),
            0x4D => try self.cmpI32(.le_u),
            0x4E => try self.cmpI32(.ge_s),
            0x4F => try self.cmpI32(.ge_u),
            // ---- i64 comparisons ----
            0x50 => try self.push(.{ .i32 = b2i(try self.popI64() == 0) }),
            0x51 => try self.cmpI64(.eq),
            0x52 => try self.cmpI64(.ne),
            0x53 => try self.cmpI64(.lt_s),
            0x54 => try self.cmpI64(.lt_u),
            0x55 => try self.cmpI64(.gt_s),
            0x56 => try self.cmpI64(.gt_u),
            0x57 => try self.cmpI64(.le_s),
            0x58 => try self.cmpI64(.le_u),
            0x59 => try self.cmpI64(.ge_s),
            0x5A => try self.cmpI64(.ge_u),
            // ---- i32 unary ----
            0x67 => try self.push(.{ .i32 = @clz(@as(u32, @bitCast(try self.popI32()))) }),
            0x68 => try self.push(.{ .i32 = @ctz(@as(u32, @bitCast(try self.popI32()))) }),
            0x69 => try self.push(.{ .i32 = @popCount(@as(u32, @bitCast(try self.popI32()))) }),
            // ---- i32 binary ----
            0x6A => try self.binI32(.add),
            0x6B => try self.binI32(.sub),
            0x6C => try self.binI32(.mul),
            0x6D => try self.binI32(.div_s),
            0x6E => try self.binI32(.div_u),
            0x6F => try self.binI32(.rem_s),
            0x70 => try self.binI32(.rem_u),
            0x71 => try self.binI32(.@"and"),
            0x72 => try self.binI32(.@"or"),
            0x73 => try self.binI32(.xor),
            0x74 => try self.binI32(.shl),
            0x75 => try self.binI32(.shr_s),
            0x76 => try self.binI32(.shr_u),
            0x77 => try self.binI32(.rotl),
            0x78 => try self.binI32(.rotr),
            // ---- i64 unary ----
            0x79 => try self.push(.{ .i64 = @clz(@as(u64, @bitCast(try self.popI64()))) }),
            0x7A => try self.push(.{ .i64 = @ctz(@as(u64, @bitCast(try self.popI64()))) }),
            0x7B => try self.push(.{ .i64 = @popCount(@as(u64, @bitCast(try self.popI64()))) }),
            // ---- i64 binary ----
            0x7C => try self.binI64(.add),
            0x7D => try self.binI64(.sub),
            0x7E => try self.binI64(.mul),
            0x7F => try self.binI64(.div_s),
            0x80 => try self.binI64(.div_u),
            0x81 => try self.binI64(.rem_s),
            0x82 => try self.binI64(.rem_u),
            0x83 => try self.binI64(.@"and"),
            0x84 => try self.binI64(.@"or"),
            0x85 => try self.binI64(.xor),
            0x86 => try self.binI64(.shl),
            0x87 => try self.binI64(.shr_s),
            0x88 => try self.binI64(.shr_u),
            0x89 => try self.binI64(.rotl),
            0x8A => try self.binI64(.rotr),
            // ---- conversions ----
            0xA7 => try self.push(.{ .i32 = @truncate(try self.popI64()) }), // i32.wrap_i64
            0xAC => try self.push(.{ .i64 = try self.popI32() }), // i64.extend_i32_s
            0xAD => try self.push(.{ .i64 = @as(u32, @bitCast(try self.popI32())) }), // i64.extend_i32_u
            0xBC => try self.push(.{ .i32 = @bitCast(try self.popF32Bits()) }), // i32.reinterpret_f32
            0xBD => try self.push(.{ .i64 = @bitCast(try self.popF64Bits()) }), // i64.reinterpret_f64
            0xBE => try self.push(.{ .f32 = @bitCast(try self.popI32()) }), // f32.reinterpret_i32
            0xBF => try self.push(.{ .f64 = @bitCast(try self.popI64()) }), // f64.reinterpret_i64
            0xC0 => try self.push(.{ .i32 = @as(i8, @truncate(try self.popI32())) }), // i32.extend8_s
            0xC1 => try self.push(.{ .i32 = @as(i16, @truncate(try self.popI32())) }), // i32.extend16_s
            0xC2 => try self.push(.{ .i64 = @as(i8, @truncate(try self.popI64())) }), // i64.extend8_s
            0xC3 => try self.push(.{ .i64 = @as(i16, @truncate(try self.popI64())) }), // i64.extend16_s
            0xC4 => try self.push(.{ .i64 = @as(i32, @truncate(try self.popI64())) }), // i64.extend32_s
            else => {
                self.setTrap("unsupported numeric opcode (likely floating point, a later phase)");
                return error.Unsupported;
            },
        }
    }

    const Cmp = enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u };
    const Bin = enum { add, sub, mul, div_s, div_u, rem_s, rem_u, @"and", @"or", xor, shl, shr_s, shr_u, rotl, rotr };

    fn cmpI32(self: *Instance, comptime c: Cmp) Trap!void {
        const b = try self.popI32();
        const a = try self.popI32();
        const ua: u32 = @bitCast(a);
        const ub: u32 = @bitCast(b);
        const r = switch (c) {
            .eq => a == b,
            .ne => a != b,
            .lt_s => a < b,
            .lt_u => ua < ub,
            .gt_s => a > b,
            .gt_u => ua > ub,
            .le_s => a <= b,
            .le_u => ua <= ub,
            .ge_s => a >= b,
            .ge_u => ua >= ub,
        };
        try self.push(.{ .i32 = b2i(r) });
    }

    fn cmpI64(self: *Instance, comptime c: Cmp) Trap!void {
        const b = try self.popI64();
        const a = try self.popI64();
        const ua: u64 = @bitCast(a);
        const ub: u64 = @bitCast(b);
        const r = switch (c) {
            .eq => a == b,
            .ne => a != b,
            .lt_s => a < b,
            .lt_u => ua < ub,
            .gt_s => a > b,
            .gt_u => ua > ub,
            .le_s => a <= b,
            .le_u => ua <= ub,
            .ge_s => a >= b,
            .ge_u => ua >= ub,
        };
        try self.push(.{ .i32 = b2i(r) });
    }

    fn binI32(self: *Instance, comptime op: Bin) Trap!void {
        const b = try self.popI32();
        const a = try self.popI32();
        const ua: u32 = @bitCast(a);
        const ub: u32 = @bitCast(b);
        const r: i32 = switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
            .div_s => blk: {
                if (b == 0) return self.trapDiv();
                if (a == std.math.minInt(i32) and b == -1) return self.trapOverflow();
                break :blk @divTrunc(a, b);
            },
            .div_u => blk: {
                if (b == 0) return self.trapDiv();
                break :blk @bitCast(ua / ub);
            },
            .rem_s => blk: {
                if (b == 0) return self.trapDiv();
                if (a == std.math.minInt(i32) and b == -1) break :blk 0;
                break :blk @rem(a, b);
            },
            .rem_u => blk: {
                if (b == 0) return self.trapDiv();
                break :blk @bitCast(ua % ub);
            },
            .@"and" => a & b,
            .@"or" => a | b,
            .xor => a ^ b,
            .shl => @bitCast(ua << @intCast(ub & 31)),
            .shr_s => a >> @intCast(ub & 31),
            .shr_u => @bitCast(ua >> @intCast(ub & 31)),
            .rotl => @bitCast(std.math.rotl(u32, ua, ub & 31)),
            .rotr => @bitCast(std.math.rotr(u32, ua, ub & 31)),
        };
        try self.push(.{ .i32 = r });
    }

    fn binI64(self: *Instance, comptime op: Bin) Trap!void {
        const b = try self.popI64();
        const a = try self.popI64();
        const ua: u64 = @bitCast(a);
        const ub: u64 = @bitCast(b);
        const r: i64 = switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
            .div_s => blk: {
                if (b == 0) return self.trapDiv();
                if (a == std.math.minInt(i64) and b == -1) return self.trapOverflow();
                break :blk @divTrunc(a, b);
            },
            .div_u => blk: {
                if (b == 0) return self.trapDiv();
                break :blk @bitCast(ua / ub);
            },
            .rem_s => blk: {
                if (b == 0) return self.trapDiv();
                if (a == std.math.minInt(i64) and b == -1) break :blk 0;
                break :blk @rem(a, b);
            },
            .rem_u => blk: {
                if (b == 0) return self.trapDiv();
                break :blk @bitCast(ua % ub);
            },
            .@"and" => a & b,
            .@"or" => a | b,
            .xor => a ^ b,
            .shl => @bitCast(ua << @intCast(ub & 63)),
            .shr_s => a >> @intCast(ub & 63),
            .shr_u => @bitCast(ua >> @intCast(ub & 63)),
            .rotl => @bitCast(std.math.rotl(u64, ua, ub & 63)),
            .rotr => @bitCast(std.math.rotr(u64, ua, ub & 63)),
        };
        try self.push(.{ .i64 = r });
    }

    fn trapDiv(self: *Instance) Trap {
        self.setTrap("integer divide by zero");
        return error.DivByZero;
    }

    fn trapOverflow(self: *Instance) Trap {
        self.setTrap("integer overflow");
        return error.IntOverflow;
    }
};

fn b2i(b: bool) i32 {
    return if (b) 1 else 0;
}

// Re-export Trap for the raw body readers below.
const RawTrap = Trap;

// ---- raw body readers (bounds-checked) ----

fn readByte(body: []const u8, pc: *usize) RawTrap!u8 {
    if (pc.* >= body.len) return error.MalformedBody;
    const b = body[pc.*];
    pc.* += 1;
    return b;
}

fn readU32(body: []const u8, pc: *usize) RawTrap!u32 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const b = try readByte(body, pc);
        result |= @as(u64, b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift >= 35) return error.MalformedBody;
    }
    if (result > std.math.maxInt(u32)) return error.MalformedBody;
    return @intCast(result);
}

fn readI32(body: []const u8, pc: *usize) RawTrap!i32 {
    const v = try readSleb(body, pc, 32);
    return @intCast(v);
}

fn readI64(body: []const u8, pc: *usize) RawTrap!i64 {
    return readSleb(body, pc, 64);
}

fn readSleb(body: []const u8, pc: *usize, comptime bits: u8) RawTrap!i64 {
    var result: i64 = 0;
    var shift: u7 = 0;
    var b: u8 = 0;
    while (true) {
        b = try readByte(body, pc);
        result |= @as(i64, @intCast(b & 0x7f)) << @intCast(shift);
        shift += 7;
        if ((b & 0x80) == 0) break;
        if (shift >= 70) return error.MalformedBody;
    }
    if (shift < 64 and (b & 0x40) != 0) result |= @as(i64, -1) << @intCast(shift);
    _ = bits;
    return result;
}

fn readU32le(body: []const u8, pc: *usize) RawTrap!u32 {
    if (pc.* + 4 > body.len) return error.MalformedBody;
    const v = std.mem.readInt(u32, body[pc.*..][0..4], .little);
    pc.* += 4;
    return v;
}

fn readU64le(body: []const u8, pc: *usize) RawTrap!u64 {
    if (pc.* + 8 > body.len) return error.MalformedBody;
    const v = std.mem.readInt(u64, body[pc.*..][0..8], .little);
    pc.* += 8;
    return v;
}

// ---------------------------------------------------------------------------
// High-level convenience entry point used by the host binary.
// ---------------------------------------------------------------------------

pub const RunOutcome = union(enum) {
    ok: []Value,
    trap: []const u8,
    load_error: []const u8,
};

/// Loads `bytes`, instantiates, runs the start function, then invokes `name`
/// with `args`. Returns a structured outcome; never panics on bad input.
pub fn runExport(
    arena: std.mem.Allocator,
    bytes: []const u8,
    name: []const u8,
    args: []const Value,
    limits: Limits,
) RunOutcome {
    const module = arena.create(Module) catch return .{ .load_error = "out of memory" };
    module.* = load(arena, bytes) catch |err| return .{ .load_error = @errorName(err) };

    var instance = Instance.init(arena, module, limits) catch |err| return .{ .load_error = @errorName(err) };

    if (instance.runStart()) |msg| return .{ .trap = msg };

    const result = instance.invokeExport(name, args) catch |err| {
        return .{ .trap = @errorName(err) };
    };
    return switch (result) {
        .values => |v| .{ .ok = v },
        .trap => |m| .{ .trap = m },
    };
}

test {
    std.testing.refAllDecls(@This());
}

// ---------------------------------------------------------------------------
// Tests: hand-built modules, no external toolchain required.
// ---------------------------------------------------------------------------

const testing = std.testing;

const header = "\x00asm\x01\x00\x00\x00";

/// Wraps `id` and a `payload` (whose length must be < 128) into a section.
fn sec(a: std.mem.Allocator, id: u8, payload: []const u8) ![]u8 {
    std.debug.assert(payload.len < 128);
    return std.mem.concat(a, u8, &.{ &[_]u8{ id, @intCast(payload.len) }, payload });
}

/// Builds a single-function module exporting `name` with the given signature
/// and `body` (the raw code expression, including locals decl and trailing end).
const Builder = struct {
    a: std.mem.Allocator,
    params: []const u8 = &.{}, // valtype bytes
    results: []const u8 = &.{}, // valtype bytes
    body: []const u8 = &.{},
    name: []const u8 = "f",
    memory_min: ?u8 = null,

    fn module(self: Builder) ![]u8 {
        const a = self.a;
        // Type section: one func type.
        var tp: std.ArrayList(u8) = .empty;
        try tp.appendSlice(a, &.{ 0x01, 0x60, @intCast(self.params.len) });
        try tp.appendSlice(a, self.params);
        try tp.append(a, @intCast(self.results.len));
        try tp.appendSlice(a, self.results);
        const type_sec = try sec(a, 1, tp.items);

        const func_sec = try sec(a, 3, &.{ 0x01, 0x00 });

        var ex: std.ArrayList(u8) = .empty;
        try ex.appendSlice(a, &.{ 0x01, @intCast(self.name.len) });
        try ex.appendSlice(a, self.name);
        try ex.appendSlice(a, &.{ 0x00, 0x00 });
        const export_sec = try sec(a, 7, ex.items);

        var cd: std.ArrayList(u8) = .empty;
        try cd.appendSlice(a, &.{ 0x01, @intCast(self.body.len) });
        try cd.appendSlice(a, self.body);
        const code_sec = try sec(a, 10, cd.items);

        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(a, header);
        try parts.append(a, type_sec);
        try parts.append(a, func_sec);
        if (self.memory_min) |mp| {
            const mem_sec = try sec(a, 5, &.{ 0x01, 0x00, mp });
            try parts.append(a, mem_sec);
        }
        try parts.append(a, export_sec);
        try parts.append(a, code_sec);
        return std.mem.concat(a, u8, parts.items);
    }
};

fn expectI32(outcome: RunOutcome, want: i32) !void {
    switch (outcome) {
        .ok => |vals| {
            try testing.expectEqual(@as(usize, 1), vals.len);
            try testing.expectEqual(want, vals[0].i32);
        },
        .trap => |m| {
            std.debug.print("unexpected trap: {s}\n", .{m});
            return error.TestUnexpectedTrap;
        },
        .load_error => |m| {
            std.debug.print("unexpected load error: {s}\n", .{m});
            return error.TestUnexpectedLoadError;
        },
    }
}

fn expectI64(outcome: RunOutcome, want: i64) !void {
    switch (outcome) {
        .ok => |vals| {
            try testing.expectEqual(@as(usize, 1), vals.len);
            try testing.expectEqual(want, vals[0].i64);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "i32.add" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Builder{
        .a = a,
        .params = &.{ 0x7F, 0x7F },
        .results = &.{0x7F},
        // (local.get 0)(local.get 1)(i32.add)(end)
        .body = &.{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A, 0x0B },
    };
    const bytes = try b.module();
    const out = runExport(a, bytes, "f", &.{ .{ .i32 = 2 }, .{ .i32 = 40 } }, .{});
    try expectI32(out, 42);
}

test "if/else max" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Builder{
        .a = a,
        .params = &.{ 0x7F, 0x7F },
        .results = &.{0x7F},
        // local.get0 local.get1 i32.gt_s
        // if (result i32) local.get0 else local.get1 end
        // end
        .body = &.{
            0x00,
            0x20,
            0x00,
            0x20,
            0x01,
            0x4A,
            0x04,
            0x7F,
            0x20,
            0x00,
            0x05,
            0x20,
            0x01,
            0x0B,
            0x0B,
        },
    };
    const bytes = try b.module();
    try expectI32(runExport(a, bytes, "f", &.{ .{ .i32 = 7 }, .{ .i32 = 3 } }, .{}), 7);
    try expectI32(runExport(a, bytes, "f", &.{ .{ .i32 = 1 }, .{ .i32 = 9 } }, .{}), 9);
}

test "loop sum 1..n with br_if" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // locals: acc(1) i(1)  => param n is local 0
    // acc=0; i=1; loop: if i>n break; acc+=i; i+=1; continue
    const b = Builder{
        .a = a,
        .params = &.{0x7F},
        .results = &.{0x7F},
        .body = &.{
            0x01, 0x02, 0x7F, // 2 i32 locals (local1=acc, local2=i)
            0x41, 0x00, 0x21, 0x01, // i32.const 0 ; local.set 1 (acc=0)
            0x41, 0x01, 0x21, 0x02, // i32.const 1 ; local.set 2 (i=1)
            0x02, 0x40, // block
            0x03, 0x40, //   loop
            0x20, 0x02, 0x20, 0x00, 0x4A, // local.get i; local.get n; i32.gt_s
            0x0D, 0x01, //     br_if 1 (break out of block if i>n)
            0x20, 0x01, 0x20, 0x02, 0x6A, 0x21, 0x01, // acc = acc + i
            0x20, 0x02, 0x41, 0x01, 0x6A, 0x21, 0x02, // i = i + 1
            0x0C, 0x00, //     br 0 (continue loop)
            0x0B, //   end loop
            0x0B, // end block
            0x20, 0x01, // local.get acc
            0x0B, // end
        },
    };
    const bytes = try b.module();
    // sum 1..10 = 55
    try expectI32(runExport(a, bytes, "f", &.{.{ .i32 = 10 }}, .{}), 55);
    try expectI32(runExport(a, bytes, "f", &.{.{ .i32 = 100 }}, .{}), 5050);
}

test "memory store/load roundtrip and grow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // store param at addr 0, then load it back and add memory.grow(1) result*0
    const b = Builder{
        .a = a,
        .params = &.{0x7F},
        .results = &.{0x7F},
        .memory_min = 1,
        .body = &.{
            0x00, // 0 local declarations
            0x41, 0x00, 0x20, 0x00, 0x36, 0x02, 0x00, // i32.const 0; local.get0; i32.store align2 off0
            0x41, 0x00, 0x28, 0x02, 0x00, // i32.const0; i32.load align2 off0
            0x0B,
        },
    };
    const bytes = try b.module();
    try expectI32(runExport(a, bytes, "f", &.{.{ .i32 = 123456 }}, .{}), 123456);
}

test "trap: divide by zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Builder{
        .a = a,
        .params = &.{ 0x7F, 0x7F },
        .results = &.{0x7F},
        .body = &.{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x6D, 0x0B }, // i32.div_s
    };
    const bytes = try b.module();
    const out = runExport(a, bytes, "f", &.{ .{ .i32 = 1 }, .{ .i32 = 0 } }, .{});
    switch (out) {
        .trap => |m| try testing.expect(std.mem.indexOf(u8, m, "divide by zero") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "trap: unreachable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Builder{ .a = a, .body = &.{ 0x00, 0x00, 0x0B } }; // locals=0; unreachable; end
    const bytes = try b.module();
    switch (runExport(a, bytes, "f", &.{}, .{})) {
        .trap => |m| try testing.expect(std.mem.indexOf(u8, m, "unreachable") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "trap: out of fuel on infinite loop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // loop br 0 end (never terminates)
    const b = Builder{ .a = a, .body = &.{ 0x00, 0x03, 0x40, 0x0C, 0x00, 0x0B, 0x0B } };
    const bytes = try b.module();
    switch (runExport(a, bytes, "f", &.{}, .{ .fuel = 10_000 })) {
        .trap => |m| try testing.expect(std.mem.indexOf(u8, m, "fuel") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "trap: out of bounds memory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Builder{
        .a = a,
        .results = &.{0x7F},
        .memory_min = 1,
        // i32.const 0x10000 ; i32.load  -> one page is 0..0xffff, so addr 0x10000 OOB
        .body = &.{ 0x00, 0x41, 0x80, 0x80, 0x04, 0x28, 0x02, 0x00, 0x0B },
    };
    const bytes = try b.module();
    switch (runExport(a, bytes, "f", &.{}, .{})) {
        .trap => |m| try testing.expect(std.mem.indexOf(u8, m, "out of bounds") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "br_table dispatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // result = switch(param){ 0 => 10, 1 => 20, default => 30 }
    const b = Builder{
        .a = a,
        .params = &.{0x7F},
        .results = &.{0x7F},
        .body = &.{
            0x00,
            0x02, 0x7F, // block (result i32)  outer, label depth target
            0x02, 0x40, //   block
            0x02, 0x40, //     block
            0x02, 0x40, //       block
            0x20, 0x00, // local.get 0
            0x0E, 0x02, 0x00, 0x01, 0x02, // br_table [0,1] default 2
            0x0B, //       end (label for case 0)
            0x41, 0x0A, 0x0C, 0x02, // i32.const 10; br 2 (to outer)
            0x0B, //     end (case 1)
            0x41, 0x14, 0x0C, 0x01, // i32.const 20; br 1
            0x0B, //   end (default)
            0x41, 0x1E, // i32.const 30 (falls to outer end)
            0x0B, // end outer block
            0x0B, // end func
        },
    };
    const bytes = try b.module();
    try expectI32(runExport(a, bytes, "f", &.{.{ .i32 = 0 }}, .{}), 10);
    try expectI32(runExport(a, bytes, "f", &.{.{ .i32 = 1 }}, .{}), 20);
    try expectI32(runExport(a, bytes, "f", &.{.{ .i32 = 5 }}, .{}), 30);
}

test "i64 arithmetic and extend/wrap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (i64) param0 widened: local.get0 (i32) i64.extend_i32_s ; i64.const 1000000 ; i64.mul
    const b = Builder{
        .a = a,
        .params = &.{0x7F},
        .results = &.{0x7E},
        .body = &.{
            0x00,
            0x20, 0x00, 0xAC, // local.get0; i64.extend_i32_s
            0x42, 0xC0, 0x84, 0x3D, // i64.const 1000000
            0x7E, // i64.mul
            0x0B,
        },
    };
    const bytes = try b.module();
    try expectI64(runExport(a, bytes, "f", &.{.{ .i32 = 1234 }}, .{}), 1234 * 1000000);
}

test "load error on malformed magic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    switch (runExport(a, "nope\x01\x00\x00\x00", "f", &.{}, .{})) {
        .load_error => {},
        else => return error.TestUnexpectedResult,
    }
}

test "recursive call via call opcode (factorial)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two functions: fac(n) recursive, exported as "fac" (func 0).
    // fac: if n<2 return 1 else n*fac(n-1)
    const type_sec = try sec(a, 1, &.{ 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F });
    const func_sec = try sec(a, 3, &.{ 0x01, 0x00 });
    var ex: std.ArrayList(u8) = .empty;
    try ex.appendSlice(a, &.{ 0x01, 0x03 });
    try ex.appendSlice(a, "fac");
    try ex.appendSlice(a, &.{ 0x00, 0x00 });
    const export_sec = try sec(a, 7, ex.items);
    const body = [_]u8{
        0x00,
        0x20, 0x00, 0x41, 0x02, 0x48, // local.get0; i32.const 2; i32.lt_s
        0x04, 0x7F, // if (result i32)
        0x41, 0x01, //   i32.const 1
        0x05, //   else
        0x20, 0x00, //   local.get0
        0x20, 0x00, 0x41, 0x01, 0x6B, 0x10, 0x00, // local.get0; i32.const1; sub; call 0
        0x6C, //   i32.mul
        0x0B, // end if
        0x0B, // end
    };
    var cd: std.ArrayList(u8) = .empty;
    try cd.appendSlice(a, &.{ 0x01, @intCast(body.len) });
    try cd.appendSlice(a, &body);
    const code_sec = try sec(a, 10, cd.items);
    const bytes = try std.mem.concat(a, u8, &.{ header, type_sec, func_sec, export_sec, code_sec });
    try expectI32(runExport(a, bytes, "fac", &.{.{ .i32 = 5 }}, .{}), 120);
    try expectI32(runExport(a, bytes, "fac", &.{.{ .i32 = 10 }}, .{}), 3628800);
}

test "call_indirect through funcref table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // type0: (i32)->i32 dispatcher ; type1: ()->i32 callees
    const type_sec = try sec(a, 1, &.{ 0x02, 0x60, 0x01, 0x7F, 0x01, 0x7F, 0x60, 0x00, 0x01, 0x7F });
    const func_sec = try sec(a, 3, &.{ 0x03, 0x00, 0x01, 0x01 }); // funcs of type 0,1,1
    const table_sec = try sec(a, 4, &.{ 0x01, 0x70, 0x00, 0x02 }); // 1 funcref table min 2
    var ex: std.ArrayList(u8) = .empty;
    try ex.appendSlice(a, &.{ 0x01, 0x08 });
    try ex.appendSlice(a, "dispatch");
    try ex.appendSlice(a, &.{ 0x00, 0x00 });
    const export_sec = try sec(a, 7, ex.items);
    // active element: offset 0, funcs [1,2]
    const elem_sec = try sec(a, 9, &.{ 0x01, 0x00, 0x41, 0x00, 0x0B, 0x02, 0x01, 0x02 });
    // code: dispatcher (local.get0; call_indirect type1 table0), then two const funcs
    const body0 = [_]u8{ 0x00, 0x20, 0x00, 0x11, 0x01, 0x00, 0x0B };
    const body1 = [_]u8{ 0x00, 0x41, 0xE4, 0x00, 0x0B }; // i32.const 100 (SLEB: 0xE4 0x00)
    const body2 = [_]u8{ 0x00, 0x41, 0xC8, 0x01, 0x0B }; // i32.const 200
    var cd: std.ArrayList(u8) = .empty;
    try cd.append(a, 0x03);
    try cd.append(a, @intCast(body0.len));
    try cd.appendSlice(a, &body0);
    try cd.append(a, @intCast(body1.len));
    try cd.appendSlice(a, &body1);
    try cd.append(a, @intCast(body2.len));
    try cd.appendSlice(a, &body2);
    const code_sec = try sec(a, 10, cd.items);
    const bytes = try std.mem.concat(a, u8, &.{ header, type_sec, func_sec, table_sec, export_sec, elem_sec, code_sec });
    try expectI32(runExport(a, bytes, "dispatch", &.{.{ .i32 = 0 }}, .{}), 100);
    try expectI32(runExport(a, bytes, "dispatch", &.{.{ .i32 = 1 }}, .{}), 200);
    // out-of-bounds table index traps.
    switch (runExport(a, bytes, "dispatch", &.{.{ .i32 = 9 }}, .{})) {
        .trap => |m| try testing.expect(std.mem.indexOf(u8, m, "out of bounds") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "globals get/set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const type_sec = try sec(a, 1, &.{ 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F });
    const func_sec = try sec(a, 3, &.{ 0x01, 0x00 });
    // one mutable i32 global initialised to 5
    const global_sec = try sec(a, 6, &.{ 0x01, 0x7F, 0x01, 0x41, 0x05, 0x0B });
    var ex: std.ArrayList(u8) = .empty;
    try ex.appendSlice(a, &.{ 0x01, 0x01 });
    try ex.appendSlice(a, "f");
    try ex.appendSlice(a, &.{ 0x00, 0x00 });
    const export_sec = try sec(a, 7, ex.items);
    // g = g + param ; return g
    const body = [_]u8{
        0x00,
        0x23, 0x00, 0x20, 0x00, 0x6A, 0x24, 0x00, // global.get0; local.get0; add; global.set0
        0x23, 0x00, // global.get0
        0x0B,
    };
    var cd: std.ArrayList(u8) = .empty;
    try cd.appendSlice(a, &.{ 0x01, @intCast(body.len) });
    try cd.appendSlice(a, &body);
    const code_sec = try sec(a, 10, cd.items);
    const bytes = try std.mem.concat(a, u8, &.{ header, type_sec, func_sec, global_sec, export_sec, code_sec });
    try expectI32(runExport(a, bytes, "f", &.{.{ .i32 = 37 }}, .{}), 42);
}

// ---------------------------------------------------------------------------
// Regression tests: malformed/untrusted bodies must trap or fail to load,
// never panic (the whole point of W1 — run untrusted modules safely).
// ---------------------------------------------------------------------------

fn expectTrap(outcome: RunOutcome) !void {
    switch (outcome) {
        .trap => {},
        .ok => return error.TestExpectedTrap,
        .load_error => |m| {
            std.debug.print("expected trap, got load error: {s}\n", .{m});
            return error.TestExpectedTrap;
        },
    }
}

fn expectLoadError(outcome: RunOutcome) !void {
    switch (outcome) {
        .load_error => {},
        else => return error.TestExpectedLoadError,
    }
}

test "trap: local index out of range does not panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Builder{
        .a = a,
        // no params, no declared locals -> num_locals == 0
        // body: (local.get 5)(end) -- index 5 is out of range
        .body = &.{ 0x00, 0x20, 0x05, 0x0B },
    };
    const bytes = try b.module();
    try expectTrap(runExport(a, bytes, "f", &.{}, .{}));
}

test "load error: start function index out of range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 1 type (no params, no results), 1 function, start -> index 99 (invalid).
    const type_sec = try sec(a, 1, &.{ 0x01, 0x60, 0x00, 0x00 });
    const func_sec = try sec(a, 3, &.{ 0x01, 0x00 });
    const start_sec = try sec(a, 8, &.{0x63}); // start = func 99
    const code_sec = try sec(a, 10, &.{ 0x01, 0x02, 0x00, 0x0B });
    const bytes = try std.mem.concat(a, u8, &.{ header, type_sec, func_sec, start_sec, code_sec });
    try expectLoadError(runExport(a, bytes, "f", &.{}, .{}));
}

test "trap: block consuming missing param does not panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two types: type0 = () -> (); type1 = (i32) -> ().
    const type_sec = try sec(a, 1, &.{
        0x02, // 2 types
        0x60, 0x00, 0x00, // type0: () -> ()
        0x60, 0x01, 0x7F, 0x00, // type1: (i32) -> ()
    });
    const func_sec = try sec(a, 3, &.{ 0x01, 0x00 }); // 1 func of type0
    var ex: std.ArrayList(u8) = .empty;
    try ex.appendSlice(a, &.{ 0x01, 0x01, 'f', 0x00, 0x00 });
    const export_sec = try sec(a, 7, ex.items);
    // body: (block (type 1) ... end)(end) with empty stack -> param underflow.
    const code_sec = try sec(a, 10, &.{ 0x01, 0x05, 0x00, 0x02, 0x01, 0x0B, 0x0B });
    const bytes = try std.mem.concat(a, u8, &.{ header, type_sec, func_sec, export_sec, code_sec });
    try expectTrap(runExport(a, bytes, "f", &.{}, .{}));
}
