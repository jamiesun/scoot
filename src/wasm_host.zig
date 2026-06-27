//! Standalone `scoot-wasm` host wrapper.
//!
//! `check` validates Wasm binary structure only (W0). `run` executes an exported
//! integer function with the W1 stack machine (no WASI yet).
const std = @import("std");
const wasm_bytecode = @import("wasm_bytecode.zig");
const wasm_engine = @import("wasm_engine.zig");

const usage =
    \\scoot-wasm - standalone Scoot Wasm host
    \\
    \\Usage:
    \\  scoot-wasm check <component.wasm>
    \\  scoot-wasm run <module.wasm> <export> [int args...]
    \\  scoot-wasm wasi <module.wasm> [args...]
    \\  scoot-wasm --help
    \\
    \\`check` validates Wasm binary structure only (it does not execute code).
    \\`run` executes an exported integer function with the W1 stack machine
    \\(structured control flow, linear memory, traps, fuel/depth limits); it does
    \\not provide WASI, so a function that imports host functions will trap.
    \\`wasi` runs a wasm32-wasi command module (its `_start` export) with a
    \\minimal WASI preview1 subset: stdin is read from this process's stdin,
    \\stdout/stderr are forwarded, and `proc_exit` sets the exit code. The only
    \\channels are stdin, stdout/stderr, argv, and the exit code; environment,
    \\clock, randomness, files, and network are not exposed, so a plugin's output
    \\is a pure function of its stdin and argv.
    \\
;

const component_read_limit: std.Io.Limit = .limited(16 * 1024 * 1024);
const stdin_read_limit: std.Io.Limit = .limited(64 * 1024 * 1024);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        try out.writeAll(usage);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "run")) {
        try runCommand(arena, io, out, args);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "wasi")) {
        try wasiCommand(arena, io, out, args);
        return;
    }
    if (args.len != 3 or !std.mem.eql(u8, args[1], "check")) {
        try out.writeAll(usage);
        die(out, 2);
    }

    const path = args[2];
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, component_read_limit) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try out.print("FAIL {s}: file is missing\n", .{path});
            die(out, 1);
        },
        error.FileTooBig => {
            try out.print("FAIL {s}: file exceeds 16 MiB\n", .{path});
            die(out, 1);
        },
        else => {
            try out.print("FAIL {s}: cannot read file: {s}\n", .{ path, @errorName(err) });
            die(out, 1);
        },
    };

    const res = try wasm_bytecode.validateModuleBytes(arena, bytes);
    switch (res) {
        .valid => |summary| try out.print(
            "OK {s} sections={d} types={d} imports={d} functions={d} codes={d} exports={d} data={d}\n",
            .{
                path,
                summary.sections,
                summary.types,
                summary.imported_functions,
                summary.functions,
                summary.codes,
                summary.exports,
                summary.data_segments,
            },
        ),
        .invalid => |msg| {
            try out.print("FAIL {s}: {s}\n", .{ path, msg });
            die(out, 1);
        },
    }
}

fn die(out: *std.Io.Writer, code: u8) noreturn {
    out.flush() catch {};
    std.process.exit(code);
}

fn preflightModuleBytes(
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    path: []const u8,
    bytes: []const u8,
) !bool {
    const validation = try wasm_bytecode.validateModuleBytes(arena, bytes);
    switch (validation) {
        .valid => return true,
        .invalid => |msg| {
            try out.print("FAIL {s}: {s}\n", .{ path, msg });
            return false;
        },
    }
}

fn runCommand(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        try out.writeAll(usage);
        die(out, 2);
    }
    const path = args[2];
    const export_name = args[3];

    var call_args: std.ArrayList(wasm_engine.Value) = .empty;
    for (args[4..]) |raw| {
        const v = std.fmt.parseInt(i64, raw, 0) catch {
            try out.print("FAIL {s}: argument '{s}' is not an integer\n", .{ path, raw });
            die(out, 2);
        };
        try call_args.append(arena, .{ .i64 = v });
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, component_read_limit) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            try out.print("FAIL {s}: file is missing\n", .{path});
            die(out, 1);
        },
        error.FileTooBig => {
            try out.print("FAIL {s}: file exceeds 16 MiB\n", .{path});
            die(out, 1);
        },
        else => {
            try out.print("FAIL {s}: cannot read file: {s}\n", .{ path, @errorName(err) });
            die(out, 1);
        },
    };

    if (!try preflightModuleBytes(arena, out, path, bytes)) die(out, 1);

    const outcome = wasm_engine.runExport(arena, bytes, export_name, call_args.items, .{});
    switch (outcome) {
        .ok => |values| {
            try out.print("OK {s}:{s} ->", .{ path, export_name });
            if (values.len == 0) try out.writeAll(" (no results)");
            for (values) |val| switch (val) {
                .i32 => |x| try out.print(" {d}", .{x}),
                .i64 => |x| try out.print(" {d}", .{x}),
                .f32 => |b| try out.print(" f32:0x{x}", .{b}),
                .f64 => |b| try out.print(" f64:0x{x}", .{b}),
            };
            try out.writeAll("\n");
        },
        .trap => |msg| {
            try out.print("TRAP {s}:{s}: {s}\n", .{ path, export_name, msg });
            die(out, 1);
        },
        .load_error => |msg| {
            try out.print("FAIL {s}: {s}\n", .{ path, msg });
            die(out, 1);
        },
    }
}

fn readModule(arena: std.mem.Allocator, io: std.Io, errw: *std.Io.Writer, path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, component_read_limit) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => failErr(errw, path, "file is missing"),
        error.FileTooBig => failErr(errw, path, "file exceeds 16 MiB"),
        else => failErr(errw, path, @errorName(err)),
    };
}

fn failErr(errw: *std.Io.Writer, path: []const u8, msg: []const u8) noreturn {
    errw.print("FAIL {s}: {s}\n", .{ path, msg }) catch {};
    errw.flush() catch {};
    std.process.exit(1);
}

fn wasiCommand(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        try out.writeAll(usage);
        die(out, 2);
    }
    const path = args[2];

    var err_buf: [4096]u8 = undefined;
    var err_writer: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const errw = &err_writer.interface;
    defer errw.flush() catch {};

    const bytes = readModule(arena, io, errw, path);
    if (!try preflightModuleBytes(arena, errw, path, bytes)) die(errw, 1);

    // Read the entire stdin into a buffer presented to the module on fd 0.
    var in_buf: [1 << 16]u8 = undefined;
    var ir: std.Io.File.Reader = .init(.stdin(), io, &in_buf);
    const stdin_bytes = ir.interface.allocRemaining(arena, stdin_read_limit) catch |err| switch (err) {
        error.StreamTooLong => failErr(errw, path, "stdin exceeds 64 MiB"),
        else => failErr(errw, path, @errorName(err)),
    };

    // argv[0] is the module path; remaining CLI args follow.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, path);
    for (args[3..]) |a| try argv.append(arena, a);

    var stdout_sink: std.ArrayList(u8) = .empty;
    var stderr_sink: std.ArrayList(u8) = .empty;

    const result = wasm_engine.runWasi(arena, bytes, &stdout_sink, &stderr_sink, .{
        .stdin = stdin_bytes,
        .args = argv.items,
    });

    // Forward whatever the module produced before reporting the outcome.
    out.writeAll(stdout_sink.items) catch {};
    errw.writeAll(stderr_sink.items) catch {};

    switch (result) {
        .exited => |code| {
            out.flush() catch {};
            errw.flush() catch {};
            std.process.exit(@truncate(code));
        },
        .trap => |msg| {
            errw.print("TRAP {s}: {s}\n", .{ path, msg }) catch {};
            out.flush() catch {};
            errw.flush() catch {};
            std.process.exit(1);
        },
        .load_error => |msg| failErr(errw, path, msg),
    }
}

test "run preflight reports W0 truncated section errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const malformed_section = "\x00asm\x01\x00\x00\x00\x01\x01";
    const ok = try preflightModuleBytes(arena_state.allocator(), &out.writer, "bad-section.wasm", malformed_section);

    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings(
        "FAIL bad-section.wasm: section type payload truncated\n",
        out.writer.buffered(),
    );
}

test "wasi preflight reports W0 malformed LEB128 errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const malformed_leb = "\x00asm\x01\x00\x00\x00\x01\x80\x80\x80\x80\x80\x00";
    const ok = try preflightModuleBytes(arena_state.allocator(), &out.writer, "bad-leb.wasm", malformed_leb);

    try std.testing.expect(!ok);
    const written = out.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, written, "FAIL bad-leb.wasm: "));
    try std.testing.expect(std.mem.indexOf(u8, written, "LEB128") != null);
}

test {
    std.testing.refAllDecls(@This());
}
