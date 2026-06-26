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
    \\  scoot-wasm --help
    \\
    \\`check` validates Wasm binary structure only (it does not execute code).
    \\`run` executes an exported integer function with the W1 stack machine
    \\(structured control flow, linear memory, traps, fuel/depth limits); it does
    \\not provide WASI, so a function that imports host functions will trap.
    \\
;

const component_read_limit: std.Io.Limit = .limited(16 * 1024 * 1024);

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
