//! Standalone `scoot-wasm` W0 host wrapper.
//!
//! The first phase only decodes and validates Wasm module structure. It does not
//! execute modules or expose WASI.
const std = @import("std");
const wasm_bytecode = @import("wasm_bytecode.zig");

const usage =
    \\scoot-wasm - standalone Scoot Wasm host (W0 decoder)
    \\
    \\Usage:
    \\  scoot-wasm check <component.wasm>
    \\  scoot-wasm --help
    \\
    \\The W0 host validates Wasm binary structure only; it does not execute code.
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
