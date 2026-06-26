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

// ---------------------------------------------------------------------------
// W2: minimal WASI preview1 subset.
// ---------------------------------------------------------------------------

/// The WASI preview1 function imports this host understands. Anything else
/// (including the entire filesystem / network surface) is `unsupported`: it
/// traps when called, so a hostile module gets no capability by construction.
pub const WasiFn = enum {
    unsupported,
    args_sizes_get,
    args_get,
    environ_sizes_get,
    environ_get,
    clock_time_get,
    random_get,
    fd_write,
    fd_read,
    fd_close,
    fd_seek,
    fd_fdstat_get,
    proc_exit,
};

/// Resolves an `(module, field)` import pair to a `WasiFn`. Both the modern
/// `wasi_snapshot_preview1` and the legacy `wasi_unstable` module names map to
/// the same subset.
fn resolveWasiFn(module_name: []const u8, field: []const u8) WasiFn {
    const is_wasi = std.mem.eql(u8, module_name, "wasi_snapshot_preview1") or
        std.mem.eql(u8, module_name, "wasi_unstable");
    if (!is_wasi) return .unsupported;
    const table = [_]struct { name: []const u8, fnc: WasiFn }{
        .{ .name = "args_sizes_get", .fnc = .args_sizes_get },
        .{ .name = "args_get", .fnc = .args_get },
        .{ .name = "environ_sizes_get", .fnc = .environ_sizes_get },
        .{ .name = "environ_get", .fnc = .environ_get },
        .{ .name = "clock_time_get", .fnc = .clock_time_get },
        .{ .name = "random_get", .fnc = .random_get },
        .{ .name = "fd_write", .fnc = .fd_write },
        .{ .name = "fd_read", .fnc = .fd_read },
        .{ .name = "fd_close", .fnc = .fd_close },
        .{ .name = "fd_seek", .fnc = .fd_seek },
        .{ .name = "fd_fdstat_get", .fnc = .fd_fdstat_get },
        .{ .name = "proc_exit", .fnc = .proc_exit },
    };
    for (table) |e| {
        if (std.mem.eql(u8, field, e.name)) return e.fnc;
    }
    return .unsupported;
}

/// Subset of WASI preview1 `errno` values returned by the host functions.
const Errno = enum(i32) {
    success = 0,
    badf = 8,
    fault = 21,
    inval = 28,
    nosys = 52,
    spipe = 70,

    fn code(self: Errno) i32 {
        return @intFromEnum(self);
    }
};

/// A fault while touching guest linear memory; surfaced to the module as
/// `EFAULT` rather than killing it.
const MemFault = error{Fault};

/// Standard preopened WASI file descriptors.
const fd_stdin: u32 = 0;
const fd_stdout: u32 = 1;
const fd_stderr: u32 = 2;

/// Host-side WASI state shared with the running instance. The engine never
/// performs real IO itself: stdin is a fixed buffer and stdout/stderr are
/// in-memory sinks the caller (the `scoot-wasm` host) drains afterwards. Time
/// and randomness are seeded by the caller so runs stay deterministic and
/// dependency-free.
pub const Wasi = struct {
    stdin: []const u8 = &.{},
    stdin_pos: usize = 0,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    /// Each entry is a NUL-free argument; argv[0] is the program name.
    args: []const []const u8 = &.{},
    /// Each entry is a `KEY=VALUE` string (no NUL).
    env: []const []const u8 = &.{},
    alloc: std.mem.Allocator,
    exit_code: u32 = 0,
    clock_realtime_ns: u64 = 0,
    clock_monotonic_ns: u64 = 0,
    rng: u64 = 0x2545F4914F6CDD1D,

    /// splitmix64; deterministic given the seed, no OS entropy.
    fn nextRandom(self: *Wasi) u64 {
        self.rng +%= 0x9E3779B97F4A7C15;
        var z = self.rng;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
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
    /// Clean WASI `proc_exit`: not a fault, unwound to the entry point.
    Exit,
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
    val_type: ValType,
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
    /// WASI mapping per imported function, parallel to the first
    /// `imported_func_count` entries of `func_types`.
    import_fns: []WasiFn = &.{},
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
    /// WASI `proc_exit` was called with this status code.
    exited: u32,
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
    var import_fns: std.ArrayList(WasiFn) = .empty;
    var defined_codes: std.ArrayList(Code) = .empty;

    while (!c.atEnd()) {
        const id = try c.byte();
        const size = try c.uleb(u32);
        const payload = try c.take(size);
        var s = Cursor{ .bytes = payload };
        switch (id) {
            0 => {}, // custom: ignore
            1 => m.types = try loadTypes(arena, &s),
            2 => try loadImports(arena, &s, &m, &func_type_indices, &import_fns),
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
    m.import_fns = import_fns.items;
    m.codes = defined_codes.items;
    if (m.codes.len != m.func_types.len - m.imported_func_count) return error.InvalidModule;
    if (m.start) |s| {
        if (s >= m.func_types.len) return error.InvalidModule;
        const ft = m.types[m.func_types[s]];
        if (ft.params.len != 0 or ft.results.len != 0) return error.InvalidModule;
    }

    // Precompute control-flow metadata and run a W3 static type check for each
    // defined function body. The validator intentionally covers the current
    // integer/WASI host subset rather than claiming full WebAssembly parity.
    for (m.codes, 0..) |*code, i| {
        try scanBody(arena, &m, code);
        try validateBodyTypes(arena, &m, code, @intCast(m.imported_func_count + i));
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
    import_fns: *std.ArrayList(WasiFn),
) LoadError!void {
    const n = try s.uleb(u32);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const mod_name = try s.name();
        const field_name = try s.name();
        const kind = try s.byte();
        switch (kind) {
            0 => {
                const t = try s.uleb(u32);
                if (t >= m.types.len) return error.InvalidModule;
                try func_type_indices.append(arena, t);
                try import_fns.append(arena, resolveWasiFn(mod_name, field_name));
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
                // Imported globals require storage and initialization semantics
                // this standalone host does not implement yet.
                _ = try valTypeFromByte(try s.byte());
                const mut = try s.byte();
                if (mut != 0 and mut != 1) return error.InvalidModule;
                return error.InvalidModule;
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
        if (mut != 0 and mut != 1) return error.InvalidModule;
        g.* = .{ .val_type = vt, .value = try constExpr(s, vt), .mutable = mut == 1 };
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
// W3 static type validation for the currently supported host subset.
// ---------------------------------------------------------------------------

const BlockSig = struct {
    params: []const ValType,
    results: []const ValType,
};

fn blockTypeSig(arena: std.mem.Allocator, m: *const Module, s: *Cursor) LoadError!BlockSig {
    const v = try s.sleb(i64);
    if (v == -64) return .{ .params = &.{}, .results = &.{} }; // empty (0x40)
    if (v < 0) {
        if (v < -128 or v > -1) return error.InvalidModule;
        const b: u8 = @intCast(v + 0x80);
        const one = try arena.alloc(ValType, 1);
        one[0] = try valTypeFromByte(b);
        return .{ .params = &.{}, .results = one };
    }
    const idx: usize = @intCast(v);
    if (idx >= m.types.len) return error.InvalidModule;
    return .{ .params = m.types[idx].params, .results = m.types[idx].results };
}

const StackType = enum {
    i32,
    i64,
    f32,
    f64,
    funcref,
    externref,
    unknown,

    fn fromValType(vt: ValType) StackType {
        return switch (vt) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            .funcref => .funcref,
            .externref => .externref,
        };
    }

    fn matches(actual: StackType, expected: ValType) bool {
        return actual == .unknown or actual == fromValType(expected);
    }
};

const TypeValidator = struct {
    arena: std.mem.Allocator,
    module: *const Module,
    func_index: u32,
    code: *const Code,
    locals: []ValType,
    stack: std.ArrayList(StackType) = .empty,
    ctrl: std.ArrayList(Frame) = .empty,

    const FrameKind = enum { function, block, loop, @"if" };

    const Frame = struct {
        kind: FrameKind,
        height: usize,
        start: []const ValType,
        end: []const ValType,
        label: []const ValType,
        @"unreachable": bool = false,
        seen_else: bool = false,
    };

    fn init(arena: std.mem.Allocator, module: *const Module, code: *const Code, func_index: u32) LoadError!TypeValidator {
        const ft = module.types[module.func_types[func_index]];
        const locals = try arena.alloc(ValType, ft.params.len + code.local_types.len);
        @memcpy(locals[0..ft.params.len], ft.params);
        @memcpy(locals[ft.params.len..], code.local_types);
        return .{
            .arena = arena,
            .module = module,
            .func_index = func_index,
            .code = code,
            .locals = locals,
        };
    }

    fn fail(self: *TypeValidator) LoadError {
        _ = self;
        return error.InvalidModule;
    }

    fn current(self: *TypeValidator) *Frame {
        return &self.ctrl.items[self.ctrl.items.len - 1];
    }

    fn pushType(self: *TypeValidator, vt: ValType) LoadError!void {
        try self.stack.append(self.arena, StackType.fromValType(vt));
    }

    fn pushTypes(self: *TypeValidator, types: []const ValType) LoadError!void {
        for (types) |t| try self.pushType(t);
    }

    fn popType(self: *TypeValidator, expected: ValType) LoadError!void {
        const frame = self.current();
        if (self.stack.items.len == frame.height and frame.@"unreachable") return;
        if (self.stack.items.len <= frame.height) return self.fail();
        const actual = self.stack.pop().?;
        if (!actual.matches(expected)) return self.fail();
    }

    fn popAny(self: *TypeValidator) LoadError!StackType {
        const frame = self.current();
        if (self.stack.items.len == frame.height and frame.@"unreachable") return .unknown;
        if (self.stack.items.len <= frame.height) return self.fail();
        return self.stack.pop().?;
    }

    fn popTypes(self: *TypeValidator, types: []const ValType) LoadError!void {
        var i = types.len;
        while (i > 0) {
            i -= 1;
            try self.popType(types[i]);
        }
    }

    fn markUnreachable(self: *TypeValidator) void {
        const frame = self.current();
        self.stack.shrinkRetainingCapacity(frame.height);
        frame.@"unreachable" = true;
    }

    fn pushFrame(self: *TypeValidator, kind: FrameKind, start: []const ValType, end: []const ValType) LoadError!void {
        const label = if (kind == .loop) start else end;
        try self.ctrl.append(self.arena, .{
            .kind = kind,
            .height = self.stack.items.len,
            .start = start,
            .end = end,
            .label = label,
        });
        try self.pushTypes(start);
    }

    fn endFrame(self: *TypeValidator) LoadError!void {
        if (self.ctrl.items.len == 0) return self.fail();
        const frame = self.current().*;
        if (frame.kind == .@"if" and !frame.seen_else and frame.end.len != 0) return self.fail();
        try self.popTypes(frame.end);
        if (self.stack.items.len != frame.height) return self.fail();
        self.stack.shrinkRetainingCapacity(frame.height);
        _ = self.ctrl.pop();
        try self.pushTypes(frame.end);
    }

    fn elseFrame(self: *TypeValidator) LoadError!void {
        if (self.ctrl.items.len == 0) return self.fail();
        const idx = self.ctrl.items.len - 1;
        if (self.ctrl.items[idx].kind != .@"if" or self.ctrl.items[idx].seen_else) return self.fail();
        const end = self.ctrl.items[idx].end;
        const start = self.ctrl.items[idx].start;
        const height = self.ctrl.items[idx].height;
        try self.popTypes(end);
        if (self.stack.items.len != height) return self.fail();
        self.stack.shrinkRetainingCapacity(height);
        self.ctrl.items[idx].@"unreachable" = false;
        self.ctrl.items[idx].seen_else = true;
        try self.pushTypes(start);
    }

    fn branch(self: *TypeValidator, depth: u32) LoadError!void {
        if (depth >= self.ctrl.items.len) return self.fail();
        const target = self.ctrl.items[self.ctrl.items.len - 1 - depth];
        try self.popTypes(target.label);
        self.markUnreachable();
    }

    fn branchIf(self: *TypeValidator, depth: u32) LoadError!void {
        try self.popType(.i32);
        if (depth >= self.ctrl.items.len) return self.fail();
        const target = self.ctrl.items[self.ctrl.items.len - 1 - depth];
        try self.popTypes(target.label);
        try self.pushTypes(target.label);
    }

    fn branchTable(self: *TypeValidator, body: []const u8, pc: *usize) LoadError!void {
        const n = try readU32Load(body, pc);
        var depths = try self.arena.alloc(u32, @as(usize, n) + 1);
        for (depths) |*d| d.* = try readU32Load(body, pc);
        try self.popType(.i32);
        if (depths.len == 0) return self.fail();
        const first = try self.labelTypes(depths[0]);
        for (depths[1..]) |d| {
            const other = try self.labelTypes(d);
            if (!sameValTypes(first, other)) return self.fail();
        }
        try self.popTypes(first);
        self.markUnreachable();
    }

    fn labelTypes(self: *TypeValidator, depth: u32) LoadError![]const ValType {
        if (depth >= self.ctrl.items.len) return self.fail();
        return self.ctrl.items[self.ctrl.items.len - 1 - depth].label;
    }

    fn call(self: *TypeValidator, func_index: u32) LoadError!void {
        if (func_index >= self.module.func_types.len) return self.fail();
        const ft = self.module.types[self.module.func_types[func_index]];
        try self.popTypes(ft.params);
        try self.pushTypes(ft.results);
    }

    fn callIndirect(self: *TypeValidator, body: []const u8, pc: *usize) LoadError!void {
        const type_index = try readU32Load(body, pc);
        const table_index = try readU32Load(body, pc);
        if (type_index >= self.module.types.len or table_index != 0 or self.module.table_min == null) return self.fail();
        try self.popType(.i32);
        const ft = self.module.types[type_index];
        try self.popTypes(ft.params);
        try self.pushTypes(ft.results);
    }

    fn localGet(self: *TypeValidator, idx: u32) LoadError!void {
        if (idx >= self.locals.len) return self.fail();
        try self.pushType(self.locals[idx]);
    }

    fn localSet(self: *TypeValidator, idx: u32, tee: bool) LoadError!void {
        if (idx >= self.locals.len) return self.fail();
        try self.popType(self.locals[idx]);
        if (tee) try self.pushType(self.locals[idx]);
    }

    fn globalGet(self: *TypeValidator, idx: u32) LoadError!void {
        if (idx >= self.module.globals.len) return self.fail();
        try self.pushType(self.module.globals[idx].val_type);
    }

    fn globalSet(self: *TypeValidator, idx: u32) LoadError!void {
        if (idx >= self.module.globals.len or !self.module.globals[idx].mutable) return self.fail();
        try self.popType(self.module.globals[idx].val_type);
    }

    fn requireMemory(self: *TypeValidator) LoadError!void {
        if (self.module.memory_type == null) return self.fail();
    }

    fn memoryAccess(self: *TypeValidator, op: u8, body: []const u8, pc: *usize) LoadError!void {
        try self.requireMemory();
        _ = try readU32Load(body, pc); // align
        _ = try readU32Load(body, pc); // offset
        switch (op) {
            0x28, 0x2C, 0x2D, 0x2E, 0x2F => {
                try self.popType(.i32);
                try self.pushType(.i32);
            },
            0x29, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35 => {
                try self.popType(.i32);
                try self.pushType(.i64);
            },
            0x2A => {
                try self.popType(.i32);
                try self.pushType(.f32);
            },
            0x2B => {
                try self.popType(.i32);
                try self.pushType(.f64);
            },
            0x36, 0x3A, 0x3B => {
                try self.popType(.i32);
                try self.popType(.i32);
            },
            0x37, 0x3C, 0x3D, 0x3E => {
                try self.popType(.i64);
                try self.popType(.i32);
            },
            0x38 => {
                try self.popType(.f32);
                try self.popType(.i32);
            },
            0x39 => {
                try self.popType(.f64);
                try self.popType(.i32);
            },
            else => return self.fail(),
        }
    }

    fn miscOp(self: *TypeValidator, body: []const u8, pc: *usize) LoadError!void {
        const sub = try readU32Load(body, pc);
        switch (sub) {
            10 => {
                try self.requireMemory();
                const dst_mem = try readByteLoad(body, pc);
                const src_mem = try readByteLoad(body, pc);
                if (dst_mem != 0 or src_mem != 0) return self.fail();
                try self.popType(.i32); // n
                try self.popType(.i32); // src
                try self.popType(.i32); // dst
            },
            11 => {
                try self.requireMemory();
                const mem = try readByteLoad(body, pc);
                if (mem != 0) return self.fail();
                try self.popType(.i32); // n
                try self.popType(.i32); // value
                try self.popType(.i32); // dst
            },
            else => return self.fail(),
        }
    }

    fn numeric(self: *TypeValidator, op: u8) LoadError!void {
        switch (op) {
            0x45 => {
                try self.popType(.i32);
                try self.pushType(.i32);
            },
            0x46...0x4F => {
                try self.popType(.i32);
                try self.popType(.i32);
                try self.pushType(.i32);
            },
            0x50 => {
                try self.popType(.i64);
                try self.pushType(.i32);
            },
            0x51...0x5A => {
                try self.popType(.i64);
                try self.popType(.i64);
                try self.pushType(.i32);
            },
            0x67...0x69 => {
                try self.popType(.i32);
                try self.pushType(.i32);
            },
            0x6A...0x78 => {
                try self.popType(.i32);
                try self.popType(.i32);
                try self.pushType(.i32);
            },
            0x79...0x7B => {
                try self.popType(.i64);
                try self.pushType(.i64);
            },
            0x7C...0x8A => {
                try self.popType(.i64);
                try self.popType(.i64);
                try self.pushType(.i64);
            },
            0xA7 => {
                try self.popType(.i64);
                try self.pushType(.i32);
            },
            0xAC, 0xAD => {
                try self.popType(.i32);
                try self.pushType(.i64);
            },
            0xBC => {
                try self.popType(.f32);
                try self.pushType(.i32);
            },
            0xBD => {
                try self.popType(.f64);
                try self.pushType(.i64);
            },
            0xBE => {
                try self.popType(.i32);
                try self.pushType(.f32);
            },
            0xBF => {
                try self.popType(.i64);
                try self.pushType(.f64);
            },
            0xC0, 0xC1 => {
                try self.popType(.i32);
                try self.pushType(.i32);
            },
            0xC2...0xC4 => {
                try self.popType(.i64);
                try self.pushType(.i64);
            },
            else => return self.fail(),
        }
    }

    fn validate(self: *TypeValidator) LoadError!void {
        const ft = self.module.types[self.module.func_types[self.func_index]];
        try self.ctrl.append(self.arena, .{
            .kind = .function,
            .height = 0,
            .start = &.{},
            .end = ft.results,
            .label = ft.results,
        });

        const body = self.code.body;
        var pc: usize = 0;
        while (pc < body.len) {
            const op = try readByteLoad(body, &pc);
            switch (op) {
                0x00 => self.markUnreachable(),
                0x01 => {},
                0x02, 0x03 => {
                    var tmp = Cursor{ .bytes = body, .pos = pc };
                    const sig = try blockTypeSig(self.arena, self.module, &tmp);
                    pc = tmp.pos;
                    try self.popTypes(sig.params);
                    try self.pushFrame(if (op == 0x03) .loop else .block, sig.params, sig.results);
                },
                0x04 => {
                    var tmp = Cursor{ .bytes = body, .pos = pc };
                    const sig = try blockTypeSig(self.arena, self.module, &tmp);
                    pc = tmp.pos;
                    try self.popType(.i32);
                    try self.popTypes(sig.params);
                    try self.pushFrame(.@"if", sig.params, sig.results);
                },
                0x05 => try self.elseFrame(),
                0x0B => {
                    try self.endFrame();
                    if (self.ctrl.items.len == 0 and pc != body.len) return self.fail();
                },
                0x0C => try self.branch(try readU32Load(body, &pc)),
                0x0D => try self.branchIf(try readU32Load(body, &pc)),
                0x0E => try self.branchTable(body, &pc),
                0x0F => {
                    if (self.ctrl.items.len == 0) return self.fail();
                    try self.branch(@intCast(self.ctrl.items.len - 1));
                },
                0x10 => try self.call(try readU32Load(body, &pc)),
                0x11 => try self.callIndirect(body, &pc),
                0x1A => _ = try self.popAny(),
                0x1B => {
                    try self.popType(.i32);
                    const b = try self.popAny();
                    const a = try self.popAny();
                    const out = mergeStackTypes(a, b) orelse return self.fail();
                    try self.stack.append(self.arena, out);
                },
                0x20 => try self.localGet(try readU32Load(body, &pc)),
                0x21 => try self.localSet(try readU32Load(body, &pc), false),
                0x22 => try self.localSet(try readU32Load(body, &pc), true),
                0x23 => try self.globalGet(try readU32Load(body, &pc)),
                0x24 => try self.globalSet(try readU32Load(body, &pc)),
                0x28...0x3E => try self.memoryAccess(op, body, &pc),
                0x3F => {
                    try self.requireMemory();
                    if (try readByteLoad(body, &pc) != 0) return self.fail();
                    try self.pushType(.i32);
                },
                0x40 => {
                    try self.requireMemory();
                    if (try readByteLoad(body, &pc) != 0) return self.fail();
                    try self.popType(.i32);
                    try self.pushType(.i32);
                },
                0x41 => {
                    _ = try readI32Load(body, &pc);
                    try self.pushType(.i32);
                },
                0x42 => {
                    _ = try readI64Load(body, &pc);
                    try self.pushType(.i64);
                },
                0x43 => {
                    _ = try readU32leLoad(body, &pc);
                    try self.pushType(.f32);
                },
                0x44 => {
                    _ = try readU64leLoad(body, &pc);
                    try self.pushType(.f64);
                },
                0x45...0xC4 => try self.numeric(op),
                0xFC => try self.miscOp(body, &pc),
                else => return self.fail(),
            }
        }
        if (self.ctrl.items.len != 0) return self.fail();
    }
};

fn validateBodyTypes(arena: std.mem.Allocator, m: *const Module, code: *const Code, func_index: u32) LoadError!void {
    var v = try TypeValidator.init(arena, m, code, func_index);
    try v.validate();
}

fn sameValTypes(a: []const ValType, b: []const ValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn mergeStackTypes(a: StackType, b: StackType) ?StackType {
    if (a == .unknown) return b;
    if (b == .unknown) return a;
    if (a == b) return a;
    return null;
}

fn readByteLoad(body: []const u8, pc: *usize) LoadError!u8 {
    return readByte(body, pc) catch error.InvalidModule;
}

fn readU32Load(body: []const u8, pc: *usize) LoadError!u32 {
    return readU32(body, pc) catch error.InvalidModule;
}

fn readI32Load(body: []const u8, pc: *usize) LoadError!i32 {
    return readI32(body, pc) catch error.InvalidModule;
}

fn readI64Load(body: []const u8, pc: *usize) LoadError!i64 {
    return readI64(body, pc) catch error.InvalidModule;
}

fn readU32leLoad(body: []const u8, pc: *usize) LoadError!u32 {
    return readU32le(body, pc) catch error.InvalidModule;
}

fn readU64leLoad(body: []const u8, pc: *usize) LoadError!u64 {
    return readU64le(body, pc) catch error.InvalidModule;
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
    /// Optional WASI host. When null, calls to imported functions trap.
    wasi: ?*Wasi = null,
    /// Set when WASI `proc_exit` requested a clean shutdown.
    exited: bool = false,

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
    /// A clean WASI `proc_exit` is not a fault and leaves `self.exited` set.
    pub fn runStart(self: *Instance) ?[]const u8 {
        const idx = self.module.start orelse return null;
        self.vsp = 0;
        self.csp = 0;
        self.depth = 0;
        self.callFunction(idx) catch |err| {
            if (err == error.Exit) return null;
            return self.trapMessage();
        };
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

        self.callFunction(func_index) catch |err| {
            if (err == error.Exit) {
                return .{ .exited = if (self.wasi) |w| w.exit_code else 0 };
            }
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
            return self.callImport(func_index);
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

    // ---- WASI host imports (W2) ----

    /// Dispatches a call to an imported function. Without a configured WASI
    /// host, or for an import outside the supported subset, this traps so a
    /// module gains no capability by construction.
    fn callImport(self: *Instance, func_index: u32) Trap!void {
        const w = self.wasi orelse {
            self.setTrap("call to imported function (no WASI host configured)");
            return error.Unsupported;
        };
        const which: WasiFn = if (func_index < self.module.import_fns.len)
            self.module.import_fns[func_index]
        else
            .unsupported;
        switch (which) {
            .unsupported => {
                self.setTrap("call to unsupported host import");
                return error.Unsupported;
            },
            .proc_exit => {
                const code = try self.popU32();
                w.exit_code = code;
                self.exited = true;
                return error.Exit;
            },
            .args_sizes_get => try self.push(.{ .i32 = try self.wasiArgsSizesGet(w) }),
            .args_get => try self.push(.{ .i32 = try self.wasiArgsGet(w) }),
            .environ_sizes_get => try self.push(.{ .i32 = try self.wasiEnvironSizesGet(w) }),
            .environ_get => try self.push(.{ .i32 = try self.wasiEnvironGet(w) }),
            .clock_time_get => try self.push(.{ .i32 = try self.wasiClockTimeGet(w) }),
            .random_get => try self.push(.{ .i32 = try self.wasiRandomGet(w) }),
            .fd_write => try self.push(.{ .i32 = try self.wasiFdWrite(w) }),
            .fd_read => try self.push(.{ .i32 = try self.wasiFdRead(w) }),
            .fd_close => try self.push(.{ .i32 = try self.wasiFdClose() }),
            .fd_seek => try self.push(.{ .i32 = try self.wasiFdSeek() }),
            .fd_fdstat_get => try self.push(.{ .i32 = try self.wasiFdFdstatGet() }),
        }
    }

    fn popU32(self: *Instance) Trap!u32 {
        return @bitCast(try self.popI32());
    }

    fn memSliceMut(self: *Instance, addr: u64, len: u64) MemFault![]u8 {
        const end = addr + len;
        if (end > self.memory.len) return error.Fault;
        return self.memory[@intCast(addr)..@intCast(end)];
    }

    fn memReadU32(self: *Instance, addr: u64) MemFault!u32 {
        const s = try self.memSliceMut(addr, 4);
        return std.mem.readInt(u32, s[0..4], .little);
    }

    fn memWriteU32(self: *Instance, addr: u64, v: u32) MemFault!void {
        const s = try self.memSliceMut(addr, 4);
        std.mem.writeInt(u32, s[0..4], v, .little);
    }

    fn memWriteU64(self: *Instance, addr: u64, v: u64) MemFault!void {
        const s = try self.memSliceMut(addr, 8);
        std.mem.writeInt(u64, s[0..8], v, .little);
    }

    /// Writes `argc`/`environc` and the total NUL-terminated buffer size.
    fn writeVecSizes(self: *Instance, items: []const []const u8, count_ptr: u32, buf_size_ptr: u32) Trap!i32 {
        var buf_size: u64 = 0;
        for (items) |it| buf_size += @as(u64, it.len) + 1;
        if (buf_size > std.math.maxInt(u32) or items.len > std.math.maxInt(u32)) {
            return Errno.inval.code();
        }
        self.memWriteU32(count_ptr, @intCast(items.len)) catch return Errno.fault.code();
        self.memWriteU32(buf_size_ptr, @intCast(buf_size)) catch return Errno.fault.code();
        return Errno.success.code();
    }

    /// Writes a pointer array plus a packed buffer of NUL-terminated strings.
    fn writeStringVec(self: *Instance, items: []const []const u8, vec_ptr: u32, buf_ptr: u32) Trap!i32 {
        var ptr: u64 = buf_ptr;
        var vp: u64 = vec_ptr;
        for (items) |it| {
            const dst = self.memSliceMut(ptr, @as(u64, it.len) + 1) catch return Errno.fault.code();
            self.memWriteU32(vp, @intCast(ptr)) catch return Errno.fault.code();
            @memcpy(dst[0..it.len], it);
            dst[it.len] = 0;
            ptr += @as(u64, it.len) + 1;
            vp += 4;
        }
        return Errno.success.code();
    }

    fn wasiArgsSizesGet(self: *Instance, w: *Wasi) Trap!i32 {
        const buf_size_ptr = try self.popU32();
        const argc_ptr = try self.popU32();
        return self.writeVecSizes(w.args, argc_ptr, buf_size_ptr);
    }

    fn wasiArgsGet(self: *Instance, w: *Wasi) Trap!i32 {
        const buf_ptr = try self.popU32();
        const vec_ptr = try self.popU32();
        return self.writeStringVec(w.args, vec_ptr, buf_ptr);
    }

    fn wasiEnvironSizesGet(self: *Instance, w: *Wasi) Trap!i32 {
        const buf_size_ptr = try self.popU32();
        const count_ptr = try self.popU32();
        return self.writeVecSizes(w.env, count_ptr, buf_size_ptr);
    }

    fn wasiEnvironGet(self: *Instance, w: *Wasi) Trap!i32 {
        const buf_ptr = try self.popU32();
        const vec_ptr = try self.popU32();
        return self.writeStringVec(w.env, vec_ptr, buf_ptr);
    }

    fn wasiClockTimeGet(self: *Instance, w: *Wasi) Trap!i32 {
        const time_ptr = try self.popU32();
        _ = try self.popI64(); // precision (ignored)
        const clock_id = try self.popU32();
        const ns: u64 = switch (clock_id) {
            0 => w.clock_realtime_ns, // realtime
            1 => w.clock_monotonic_ns, // monotonic
            else => return Errno.inval.code(),
        };
        self.memWriteU64(time_ptr, ns) catch return Errno.fault.code();
        return Errno.success.code();
    }

    fn wasiRandomGet(self: *Instance, w: *Wasi) Trap!i32 {
        const buf_len = try self.popU32();
        const buf = try self.popU32();
        const dst = self.memSliceMut(buf, buf_len) catch return Errno.fault.code();
        var i: usize = 0;
        while (i < dst.len) {
            const r = w.nextRandom();
            var shift: u6 = 0;
            while (i < dst.len) : (i += 1) {
                dst[i] = @truncate(r >> shift);
                if (shift == 56) {
                    i += 1;
                    break;
                }
                shift += 8;
            }
        }
        return Errno.success.code();
    }

    fn wasiFdWrite(self: *Instance, w: *Wasi) Trap!i32 {
        const nwritten_ptr = try self.popU32();
        const iovs_len = try self.popU32();
        const iovs_ptr = try self.popU32();
        const fd = try self.popU32();
        const sink: *std.ArrayList(u8) = switch (fd) {
            fd_stdout => w.stdout,
            fd_stderr => w.stderr,
            else => return Errno.badf.code(),
        };
        var total: u64 = 0;
        var i: u32 = 0;
        while (i < iovs_len) : (i += 1) {
            const rec = @as(u64, iovs_ptr) + @as(u64, i) * 8;
            const ptr = self.memReadU32(rec) catch return Errno.fault.code();
            const len = self.memReadU32(rec + 4) catch return Errno.fault.code();
            const chunk = self.memSliceMut(ptr, len) catch return Errno.fault.code();
            sink.appendSlice(w.alloc, chunk) catch return error.OutOfMemory;
            total += len;
        }
        if (total > std.math.maxInt(u32)) return Errno.inval.code();
        self.memWriteU32(nwritten_ptr, @intCast(total)) catch return Errno.fault.code();
        return Errno.success.code();
    }

    fn wasiFdRead(self: *Instance, w: *Wasi) Trap!i32 {
        const nread_ptr = try self.popU32();
        const iovs_len = try self.popU32();
        const iovs_ptr = try self.popU32();
        const fd = try self.popU32();
        if (fd != fd_stdin) return Errno.badf.code();
        var total: u64 = 0;
        var i: u32 = 0;
        outer: while (i < iovs_len) : (i += 1) {
            const rec = @as(u64, iovs_ptr) + @as(u64, i) * 8;
            const ptr = self.memReadU32(rec) catch return Errno.fault.code();
            const len = self.memReadU32(rec + 4) catch return Errno.fault.code();
            const dst = self.memSliceMut(ptr, len) catch return Errno.fault.code();
            const remaining = w.stdin.len - w.stdin_pos;
            if (remaining == 0) break;
            const n = @min(dst.len, remaining);
            @memcpy(dst[0..n], w.stdin[w.stdin_pos..][0..n]);
            w.stdin_pos += n;
            total += n;
            if (n < dst.len) break :outer; // stdin exhausted mid-iovec
        }
        self.memWriteU32(nread_ptr, @intCast(total)) catch return Errno.fault.code();
        return Errno.success.code();
    }

    fn wasiFdClose(self: *Instance) Trap!i32 {
        const fd = try self.popU32();
        return switch (fd) {
            fd_stdin, fd_stdout, fd_stderr => Errno.success.code(),
            else => Errno.badf.code(),
        };
    }

    fn wasiFdSeek(self: *Instance) Trap!i32 {
        _ = try self.popU32(); // newoffset_ptr
        _ = try self.popU32(); // whence
        _ = try self.popI64(); // offset
        const fd = try self.popU32();
        // stdio streams are not seekable.
        return switch (fd) {
            fd_stdin, fd_stdout, fd_stderr => Errno.spipe.code(),
            else => Errno.badf.code(),
        };
    }

    fn wasiFdFdstatGet(self: *Instance) Trap!i32 {
        const stat_ptr = try self.popU32();
        const fd = try self.popU32();
        switch (fd) {
            fd_stdin, fd_stdout, fd_stderr => {},
            else => return Errno.badf.code(),
        }
        // fdstat is 24 bytes; fs_filetype is the first byte.
        const buf = self.memSliceMut(stat_ptr, 24) catch return Errno.fault.code();
        @memset(buf, 0);
        buf[0] = 2; // __WASI_FILETYPE_CHARACTER_DEVICE
        return Errno.success.code();
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
        .exited => .{ .trap = "module called proc_exit without a WASI host" },
    };
}

// ---------------------------------------------------------------------------
// W2: WASI entry point used by the `scoot-wasm wasi` subcommand.
// ---------------------------------------------------------------------------

pub const WasiConfig = struct {
    /// Bytes presented to the module on fd 0 (stdin).
    stdin: []const u8 = &.{},
    /// argv; argv[0] is the program name.
    args: []const []const u8 = &.{},
    /// environ; each entry is `KEY=VALUE`.
    env: []const []const u8 = &.{},
    /// Value returned by `clock_time_get(realtime)` in nanoseconds.
    clock_realtime_ns: u64 = 0,
    /// Value returned by `clock_time_get(monotonic)` in nanoseconds.
    clock_monotonic_ns: u64 = 0,
    /// Seed for the deterministic `random_get` generator.
    random_seed: u64 = 0x2545F4914F6CDD1D,
    /// Exported entry point to run (WASI command modules use `_start`).
    entry: []const u8 = "_start",
    limits: Limits = .{},
};

pub const WasiResult = union(enum) {
    /// Clean exit (explicit `proc_exit` or normal return from the entry).
    exited: u32,
    trap: []const u8,
    load_error: []const u8,
};

/// Loads and runs a `wasm32-wasi` command module: instantiates it, exposes the
/// minimal WASI subset, runs the start section and then the `_start` export.
/// stdout/stderr are appended to the caller-provided sinks. Never panics.
pub fn runWasi(
    arena: std.mem.Allocator,
    bytes: []const u8,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    cfg: WasiConfig,
) WasiResult {
    const module = arena.create(Module) catch return .{ .load_error = "out of memory" };
    module.* = load(arena, bytes) catch |err| return .{ .load_error = @errorName(err) };

    var instance = Instance.init(arena, module, cfg.limits) catch |err| return .{ .load_error = @errorName(err) };

    var wasi = Wasi{
        .stdin = cfg.stdin,
        .stdout = stdout,
        .stderr = stderr,
        .args = cfg.args,
        .env = cfg.env,
        .alloc = arena,
        .clock_realtime_ns = cfg.clock_realtime_ns,
        .clock_monotonic_ns = cfg.clock_monotonic_ns,
        .rng = cfg.random_seed,
    };
    instance.wasi = &wasi;

    if (instance.runStart()) |msg| return .{ .trap = msg };
    if (instance.exited) return .{ .exited = wasi.exit_code };

    const result = instance.invokeExport(cfg.entry, &.{}) catch |err| {
        return .{ .trap = @errorName(err) };
    };
    return switch (result) {
        .exited => |code| .{ .exited = code },
        .values => .{ .exited = 0 }, // normal return == exit 0
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

test "load error: local index out of range is rejected before execution" {
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
    try expectLoadError(runExport(a, bytes, "f", &.{}, .{}));
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

test "load error: start function must not require params or return results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // start points to a function typed (i32) -> i32, which cannot be invoked
    // by a module start section.
    const type_sec = try sec(a, 1, &.{ 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F });
    const func_sec = try sec(a, 3, &.{ 0x01, 0x00 });
    const start_sec = try sec(a, 8, &.{0x00});
    const code_sec = try sec(a, 10, &.{ 0x01, 0x04, 0x00, 0x20, 0x00, 0x0B });
    const bytes = try std.mem.concat(a, u8, &.{ header, type_sec, func_sec, start_sec, code_sec });
    try expectLoadError(runExport(a, bytes, "f", &.{}, .{}));
}

test "load error: block consuming missing param is rejected before execution" {
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
    try expectLoadError(runExport(a, bytes, "f", &.{}, .{}));
}

test "load error: static validator rejects operand type mismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = Builder{
        .a = a,
        .results = &.{0x7F},
        // i64.const 1; i32.const 2; i32.add; end -> add needs two i32 values.
        .body = &.{ 0x00, 0x42, 0x01, 0x41, 0x02, 0x6A, 0x0B },
    };
    const bytes = try b.module();
    try expectLoadError(runExport(a, bytes, "f", &.{}, .{}));
}

test "load error: static validator rejects immutable global.set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const type_sec = try sec(a, 1, &.{ 0x01, 0x60, 0x00, 0x00 });
    const func_sec = try sec(a, 3, &.{ 0x01, 0x00 });
    const global_sec = try sec(a, 6, &.{ 0x01, 0x7F, 0x00, 0x41, 0x01, 0x0B });
    var ex: std.ArrayList(u8) = .empty;
    try ex.appendSlice(a, &.{ 0x01, 0x01, 'f', 0x00, 0x00 });
    const export_sec = try sec(a, 7, ex.items);
    const code_sec = try sec(a, 10, &.{ 0x01, 0x06, 0x00, 0x41, 0x02, 0x24, 0x00, 0x0B });
    const bytes = try std.mem.concat(a, u8, &.{ header, type_sec, func_sec, global_sec, export_sec, code_sec });
    try expectLoadError(runExport(a, bytes, "f", &.{}, .{}));
}

// ---------------------------------------------------------------------------
// W2 tests: WASI preview1 subset, hand-built command modules.
// ---------------------------------------------------------------------------

const wasi_module = "wasi_snapshot_preview1";

const Sig = struct { params: []const u8 = &.{}, results: []const u8 = &.{} };
const ImportDesc = struct { field: []const u8, type_idx: u8 };
const ExportDesc = struct { name: []const u8, kind: u8 = 0x00, index: u8 };
const DataDesc = struct { offset: u8, bytes: []const u8 };

fn encUleb(a: std.mem.Allocator, value: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try out.append(a, byte);
        if (v == 0) break;
    }
    return out.items;
}

fn encSection(a: std.mem.Allocator, id: u8, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, id);
    try out.appendSlice(a, try encUleb(a, payload.len));
    try out.appendSlice(a, payload);
    return out.items;
}

fn encName(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try encUleb(a, s.len));
    try out.appendSlice(a, s);
    return out.items;
}

/// Builds a single-memory WASI command module from high-level section
/// descriptions. `bodies` is parallel to `defined_func_types`.
fn buildWasiModule(
    a: std.mem.Allocator,
    sigs: []const Sig,
    imports: []const ImportDesc,
    defined_func_types: []const u8,
    memory_min: u8,
    exports: []const ExportDesc,
    bodies: []const []const u8,
    data: ?DataDesc,
) ![]u8 {
    // Type section.
    var tp: std.ArrayList(u8) = .empty;
    try tp.appendSlice(a, try encUleb(a, sigs.len));
    for (sigs) |sg| {
        try tp.append(a, 0x60);
        try tp.appendSlice(a, try encUleb(a, sg.params.len));
        try tp.appendSlice(a, sg.params);
        try tp.appendSlice(a, try encUleb(a, sg.results.len));
        try tp.appendSlice(a, sg.results);
    }

    // Import section.
    var im: std.ArrayList(u8) = .empty;
    try im.appendSlice(a, try encUleb(a, imports.len));
    for (imports) |imp| {
        try im.appendSlice(a, try encName(a, wasi_module));
        try im.appendSlice(a, try encName(a, imp.field));
        try im.append(a, 0x00); // function import
        try im.appendSlice(a, try encUleb(a, imp.type_idx));
    }

    // Function section.
    var fn_sec: std.ArrayList(u8) = .empty;
    try fn_sec.appendSlice(a, try encUleb(a, defined_func_types.len));
    for (defined_func_types) |t| try fn_sec.appendSlice(a, try encUleb(a, t));

    // Memory section (single memory, min pages).
    const mem_payload = [_]u8{ 0x01, 0x00, memory_min };

    // Export section.
    var ex: std.ArrayList(u8) = .empty;
    try ex.appendSlice(a, try encUleb(a, exports.len));
    for (exports) |e| {
        try ex.appendSlice(a, try encName(a, e.name));
        try ex.append(a, e.kind);
        try ex.appendSlice(a, try encUleb(a, e.index));
    }

    // Code section.
    var cd: std.ArrayList(u8) = .empty;
    try cd.appendSlice(a, try encUleb(a, bodies.len));
    for (bodies) |body| {
        try cd.appendSlice(a, try encUleb(a, body.len));
        try cd.appendSlice(a, body);
    }

    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(a, header);
    try parts.append(a, try encSection(a, 1, tp.items));
    if (imports.len != 0) try parts.append(a, try encSection(a, 2, im.items));
    try parts.append(a, try encSection(a, 3, fn_sec.items));
    try parts.append(a, try encSection(a, 5, &mem_payload));
    try parts.append(a, try encSection(a, 7, ex.items));
    try parts.append(a, try encSection(a, 10, cd.items));
    if (data) |d| {
        var ds: std.ArrayList(u8) = .empty;
        try ds.append(a, 0x01); // 1 segment
        try ds.append(a, 0x00); // active, memory 0
        try ds.appendSlice(a, &.{ 0x41, d.offset, 0x0B }); // i32.const offset; end
        try ds.appendSlice(a, try encUleb(a, d.bytes.len));
        try ds.appendSlice(a, d.bytes);
        try parts.append(a, try encSection(a, 11, ds.items));
    }
    return std.mem.concat(a, u8, parts.items);
}

const sig_unit = Sig{}; // () -> ()
const sig_i32_i32 = Sig{ .params = &.{ 0x7F, 0x7F }, .results = &.{0x7F} };
const sig_i32x4 = Sig{ .params = &.{ 0x7F, 0x7F, 0x7F, 0x7F }, .results = &.{0x7F} };
const sig_proc_exit = Sig{ .params = &.{0x7F} };
const sig_clock = Sig{ .params = &.{ 0x7F, 0x7E, 0x7F }, .results = &.{0x7F} };

const WasiRun = struct {
    result: WasiResult,
    stdout: []const u8,
    stderr: []const u8,
};

fn runWasiTest(
    a: std.mem.Allocator,
    bytes: []const u8,
    stdin: []const u8,
    args: []const []const u8,
    env: []const []const u8,
) WasiRun {
    const so = a.create(std.ArrayList(u8)) catch unreachable;
    const se = a.create(std.ArrayList(u8)) catch unreachable;
    so.* = .empty;
    se.* = .empty;
    const r = runWasi(a, bytes, so, se, .{
        .stdin = stdin,
        .args = args,
        .env = env,
        .clock_realtime_ns = 0x0102030405060708,
        .clock_monotonic_ns = 0x1112131415161718,
        .random_seed = 42,
    });
    return .{ .result = r, .stdout = so.items, .stderr = se.items };
}

test "wasi: echo stdin to stdout via fd_read/fd_write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // imports: 0 fd_read, 1 fd_write, 2 proc_exit ; defined _start = func 3.
    const body = [_]u8{
        0x00, // 0 locals
        // iovec.buf = 1024 at addr 0
        0x41,
        0x00,
        0x41,
        0x80,
        0x08,
        0x36,
        0x02,
        0x00,
        // iovec.buf_len = 1024 at addr 4
        0x41,
        0x04,
        0x41,
        0x80,
        0x08,
        0x36,
        0x02,
        0x00,
        // fd_read(0, iovs=0, len=1, nread=8); drop errno
        0x41,
        0x00,
        0x41,
        0x00,
        0x41,
        0x01,
        0x41,
        0x08,
        0x10,
        0x00,
        0x1A,
        // ciovec.buf = 1024 at addr 16
        0x41,
        0x10,
        0x41,
        0x80,
        0x08,
        0x36,
        0x02,
        0x00,
        // ciovec.buf_len = *nread at addr 20
        0x41,
        0x14,
        0x41,
        0x08,
        0x28,
        0x02,
        0x00,
        0x36,
        0x02,
        0x00,
        // fd_write(1, iovs=16, len=1, nwritten=24); drop errno
        0x41,
        0x01,
        0x41,
        0x10,
        0x41,
        0x01,
        0x41,
        0x18,
        0x10,
        0x01,
        0x1A,
        // proc_exit(0)
        0x41,
        0x00,
        0x10,
        0x02,
        0x0B,
    };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_i32x4, sig_proc_exit },
        &.{
            .{ .field = "fd_read", .type_idx = 1 },
            .{ .field = "fd_write", .type_idx = 1 },
            .{ .field = "proc_exit", .type_idx = 2 },
        },
        &.{0}, // _start: type0 () -> ()
        1,
        &.{.{ .name = "_start", .index = 3 }},
        &.{&body},
        null,
    );
    const run = runWasiTest(a, bytes, "hello world", &.{"prog"}, &.{});
    try testing.expect(run.result == .exited);
    try testing.expectEqual(@as(u32, 0), run.result.exited);
    try testing.expectEqualStrings("hello world", run.stdout);
}

test "wasi: proc_exit sets exit code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]u8{ 0x00, 0x41, 0x07, 0x10, 0x00, 0x0B }; // proc_exit(7); end
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_proc_exit },
        &.{.{ .field = "proc_exit", .type_idx = 1 }},
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 1 }},
        &.{&body},
        null,
    );
    const run = runWasiTest(a, bytes, "", &.{"prog"}, &.{});
    try testing.expect(run.result == .exited);
    try testing.expectEqual(@as(u32, 7), run.result.exited);
}

test "wasi: normal return from _start exits 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]u8{ 0x00, 0x0B }; // just end
    const bytes = try buildWasiModule(
        a,
        &.{sig_unit},
        &.{},
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 0 }},
        &.{&body},
        null,
    );
    const run = runWasiTest(a, bytes, "", &.{"prog"}, &.{});
    try testing.expect(run.result == .exited);
    try testing.expectEqual(@as(u32, 0), run.result.exited);
}

test "wasi: args round-trip via args_sizes_get/args_get" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // imports: 0 args_get, 1 fd_write, 2 proc_exit ; _start = func 3.
    // Layout: argv pointer array at 256, argv buffer at 512. argv[1] points
    // into the buffer; we echo the whole packed buffer's first arg.
    // Simpler: write argv buffer, then fd_write argv[0] string.
    const body = [_]u8{
        0x00,
        // args_get(argv=256, argv_buf=512); drop
        0x41, 0x80, 0x02, // i32.const 256
        0x41, 0x80, 0x04, // i32.const 512
        0x10, 0x00, 0x1A,
        // ciovec at 0: buf = *argv[1] (load argv ptr at 256+4=260), len = 3
        0x41, 0x00, // addr 0
        0x41, 0x84, 0x02, 0x28, 0x02, 0x00, // i32.const 260; i32.load -> argv[1] ptr
        0x36, 0x02, 0x00, // store ciovec.buf
        0x41, 0x04, 0x41, 0x03, 0x36, 0x02, 0x00, // ciovec.buf_len = 3 at addr 4
        // fd_write(1, iovs=0, len=1, nwritten=8); drop
        0x41, 0x01, 0x41, 0x00, 0x41, 0x01, 0x41,
        0x08, 0x10, 0x01, 0x1A,
        0x41, 0x00, 0x10, 0x02, // proc_exit(0)
        0x0B,
    };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_i32_i32, sig_i32x4, sig_proc_exit },
        &.{
            .{ .field = "args_get", .type_idx = 1 },
            .{ .field = "fd_write", .type_idx = 2 },
            .{ .field = "proc_exit", .type_idx = 3 },
        },
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 3 }},
        &.{&body},
        null,
    );
    // argv[1] == "abc"
    const run = runWasiTest(a, bytes, "", &.{ "prog", "abc" }, &.{});
    try testing.expect(run.result == .exited);
    try testing.expectEqualStrings("abc", run.stdout);
}

test "wasi: environ round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // imports: 0 environ_get, 1 fd_write, 2 proc_exit ; _start = func 3.
    const body = [_]u8{
        0x00,
        // environ_get(environ=256, buf=512); drop
        0x41,
        0x80,
        0x02,
        0x41,
        0x80,
        0x04,
        0x10,
        0x00,
        0x1A,
        // ciovec.buf = *environ[0] (ptr at 256), len = 7 ("FOO=bar")
        0x41,
        0x00,
        0x41, 0x80, 0x02, 0x28, 0x02, 0x00, // load environ[0] ptr
        0x36, 0x02, 0x00, 0x41, 0x04, 0x41,
        0x07, 0x36, 0x02, 0x00, 0x41, 0x01,
        0x41, 0x00, 0x41, 0x01, 0x41, 0x08,
        0x10, 0x01, 0x1A, 0x41, 0x00, 0x10,
        0x02, 0x0B,
    };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_i32_i32, sig_i32x4, sig_proc_exit },
        &.{
            .{ .field = "environ_get", .type_idx = 1 },
            .{ .field = "fd_write", .type_idx = 2 },
            .{ .field = "proc_exit", .type_idx = 3 },
        },
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 3 }},
        &.{&body},
        null,
    );
    const run = runWasiTest(a, bytes, "", &.{"prog"}, &.{"FOO=bar"});
    try testing.expect(run.result == .exited);
    try testing.expectEqualStrings("FOO=bar", run.stdout);
}

test "wasi: clock_time_get writes realtime nanoseconds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // imports: 0 clock_time_get, 1 fd_write, 2 proc_exit ; _start = func 3.
    const body = [_]u8{
        0x00,
        // clock_time_get(id=0, precision=0, time_ptr=16); drop
        0x41, 0x00, // id
        0x42, 0x00, // i64.const 0 (precision)
        0x41, 0x10, // time_ptr 16
        0x10, 0x00,
        0x1A,
        // ciovec.buf = 16, len = 8 at addr 0
        0x41,
        0x00, 0x41,
        0x10, 0x36,
        0x02, 0x00,
        0x41, 0x04,
        0x41, 0x08,
        0x36, 0x02,
        0x00, 0x41,
        0x01, 0x41,
        0x00, 0x41,
        0x01, 0x41,
        0x28, 0x10,
        0x01, 0x1A,
        0x41, 0x00,
        0x10, 0x02,
        0x0B,
    };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_clock, sig_i32x4, sig_proc_exit },
        &.{
            .{ .field = "clock_time_get", .type_idx = 1 },
            .{ .field = "fd_write", .type_idx = 2 },
            .{ .field = "proc_exit", .type_idx = 3 },
        },
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 3 }},
        &.{&body},
        null,
    );
    const run = runWasiTest(a, bytes, "", &.{"prog"}, &.{});
    try testing.expect(run.result == .exited);
    var expected: [8]u8 = undefined;
    std.mem.writeInt(u64, &expected, 0x0102030405060708, .little);
    try testing.expectEqualSlices(u8, &expected, run.stdout);
}

test "wasi: random_get is deterministic for a fixed seed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // imports: 0 random_get, 1 fd_write, 2 proc_exit ; _start = func 3.
    const body = [_]u8{
        0x00,
        // random_get(buf=16, len=8); drop
        0x41,
        0x10,
        0x41,
        0x08,
        0x10,
        0x00,
        0x1A,
        // ciovec.buf = 16, len = 8
        0x41,
        0x00,
        0x41,
        0x10,
        0x36,
        0x02,
        0x00,
        0x41,
        0x04,
        0x41,
        0x08,
        0x36,
        0x02,
        0x00,
        0x41,
        0x01,
        0x41,
        0x00,
        0x41,
        0x01,
        0x41,
        0x28,
        0x10,
        0x01,
        0x1A,
        0x41,
        0x00,
        0x10,
        0x02,
        0x0B,
    };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_i32_i32, sig_i32x4, sig_proc_exit },
        &.{
            .{ .field = "random_get", .type_idx = 1 },
            .{ .field = "fd_write", .type_idx = 2 },
            .{ .field = "proc_exit", .type_idx = 3 },
        },
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 3 }},
        &.{&body},
        null,
    );
    const r1 = runWasiTest(a, bytes, "", &.{"prog"}, &.{});
    const r2 = runWasiTest(a, bytes, "", &.{"prog"}, &.{});
    try testing.expect(r1.result == .exited);
    try testing.expectEqual(@as(usize, 8), r1.stdout.len);
    try testing.expectEqualSlices(u8, r1.stdout, r2.stdout);
}

test "wasi: bad fd returns errno observable in output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // imports: 0 fd_close (i32)->i32, 1 fd_write, 2 proc_exit ; _start = func 3.
    const sig_i32_to_i32 = Sig{ .params = &.{0x7F}, .results = &.{0x7F} };
    const body = [_]u8{
        0x00,
        // errno = fd_close(5); store at addr 32 (fd 5 is not stdio -> EBADF)
        0x41, 0x20, // addr 32
        0x41, 0x05, 0x10, 0x00, // fd_close(5) -> errno
        0x36, 0x02, 0x00, // store errno at 32
        // ciovec.buf = 32, len = 4
        0x41, 0x00, 0x41,
        0x20, 0x36, 0x02,
        0x00, 0x41, 0x04,
        0x41, 0x04, 0x36,
        0x02, 0x00, 0x41,
        0x01, 0x41, 0x00,
        0x41, 0x01, 0x41,
        0x08, 0x10, 0x01,
        0x1A, 0x41, 0x00,
        0x10, 0x02, 0x0B,
    };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_proc_exit, sig_i32x4, sig_i32_to_i32 },
        &.{
            .{ .field = "fd_close", .type_idx = 3 },
            .{ .field = "fd_write", .type_idx = 2 },
            .{ .field = "proc_exit", .type_idx = 1 },
        },
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 3 }},
        &.{&body},
        null,
    );
    const run = runWasiTest(a, bytes, "", &.{"prog"}, &.{});
    try testing.expect(run.result == .exited);
    var expected: [4]u8 = undefined;
    std.mem.writeInt(u32, &expected, 8, .little); // EBADF
    try testing.expectEqualSlices(u8, &expected, run.stdout);
}

test "wasi: out-of-bounds pointer yields EFAULT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // imports: 0 fd_write, 1 proc_exit ; _start = func 2.
    // errno = fd_write(1, iovs=0x7fffffff, len=1, nwritten=0) -> EFAULT(21)
    const body = [_]u8{
        0x00,
        0x41, 0x20, // addr 32 to store errno
        0x41, 0x01, // fd 1
        0x41, 0xFF, 0xFF, 0xFF, 0xFF, 0x07, // i32.const 0x7fffffff (iovs ptr)
        0x41, 0x01, // len 1
        0x41, 0x00, // nwritten 0
        0x10, 0x00, // fd_write -> errno
        0x36, 0x02, 0x00, // store errno at 32
        // ciovec.buf = 32, len = 4
        0x41, 0x00, 0x41,
        0x20, 0x36, 0x02,
        0x00, 0x41, 0x04,
        0x41, 0x04, 0x36,
        0x02, 0x00, 0x41,
        0x01, 0x41, 0x00,
        0x41, 0x01, 0x41,
        0x08, 0x10, 0x00,
        0x1A, 0x41, 0x00,
        0x10, 0x01, 0x0B,
    };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_i32x4, sig_proc_exit },
        &.{
            .{ .field = "fd_write", .type_idx = 1 },
            .{ .field = "proc_exit", .type_idx = 2 },
        },
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 2 }},
        &.{&body},
        null,
    );
    const run = runWasiTest(a, bytes, "", &.{"prog"}, &.{});
    try testing.expect(run.result == .exited);
    var expected: [4]u8 = undefined;
    std.mem.writeInt(u32, &expected, 21, .little); // EFAULT
    try testing.expectEqualSlices(u8, &expected, run.stdout);
}

test "wasi: unknown import traps when called" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // imports: 0 path_open (unsupported) ; _start = func 1 calls it.
    const sig_path_open = Sig{ .params = &.{ 0x7F, 0x7F }, .results = &.{0x7F} };
    const body = [_]u8{
        0x00,
        0x41, 0x00, 0x41, 0x00, 0x10, 0x00, 0x1A, // path_open(0,0); drop
        0x0B,
    };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_path_open },
        &.{.{ .field = "path_open", .type_idx = 1 }},
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 1 }},
        &.{&body},
        null,
    );
    const run = runWasiTest(a, bytes, "", &.{"prog"}, &.{});
    try testing.expect(run.result == .trap);
}

test "wasi: imported call without host traps via runExport" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // _start calls proc_exit but runExport configures no WASI host.
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x10, 0x00, 0x0B };
    const bytes = try buildWasiModule(
        a,
        &.{ sig_unit, sig_proc_exit },
        &.{.{ .field = "proc_exit", .type_idx = 1 }},
        &.{0},
        1,
        &.{.{ .name = "_start", .index = 1 }},
        &.{&body},
        null,
    );
    try expectTrap(runExport(a, bytes, "_start", &.{}, .{}));
}
