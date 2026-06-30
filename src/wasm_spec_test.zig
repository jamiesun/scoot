//! WebAssembly spec-suite conformance runner (issue #163).
//!
//! Executes a curated, pinned subset of the upstream WebAssembly spec test
//! suite against the `scoot-wasm` engine (`wasm_engine.zig`), so the decoder,
//! validator, and interpreter are checked against canonical expectations rather
//! than only hand-encoded byte fixtures (#162).
//!
//! The fixtures are generated OFFLINE with `wast2json` (wabt) by
//! `scripts/gen_wasm_spec_fixtures.sh` and committed under `test/wasm-spec/`.
//! They are embedded here via `@embedFile` (through the generated
//! `fixtures.zig` index), so `zig build test` needs no external toolchain and
//! the zero-dependency core is preserved.
//!
//! Each group is a wast2json command manifest: a sequence of `module`,
//! `assert_return`, `assert_trap`, `assert_exhaustion`, `assert_invalid`,
//! `assert_malformed`, and `action` commands. The runner replays them against
//! the engine and asserts every command matches its canonical expectation.
//!
//! Out of scope (consistent with #100's non-goals and the curated group list in
//! the generator): SIMD, threads, GC, exceptions, tail-call, multi-memory,
//! reference types, module linking/registration, and text-form `assert_malformed`
//! (`.wat`) cases, which a binary-only engine cannot and should not consume.
const std = @import("std");
const engine = @import("wasm_engine.zig");
const fixtures = @import("spec_fixtures");

/// One JSON value/argument: `{ "type": "i32", "value": "42" }`. `value` is a
/// decimal string of the raw bit pattern (or `nan:canonical`/`nan:arithmetic`
/// in an expected result), absent for an `assert_trap` expected slot.
const JsonValue = struct {
    type: []const u8,
    value: ?[]const u8 = null,
};

const JsonAction = struct {
    type: []const u8,
    field: []const u8 = "",
    args: []JsonValue = &.{},
};

const JsonCommand = struct {
    type: []const u8,
    line: u32 = 0,
    filename: ?[]const u8 = null,
    name: ?[]const u8 = null,
    action: ?JsonAction = null,
    text: ?[]const u8 = null,
    expected: ?[]JsonValue = null,
    module_type: ?[]const u8 = null,
};

const JsonManifest = struct {
    source_filename: []const u8 = "",
    commands: []JsonCommand,
};

/// Modest per-instance limits: spec test modules are tiny, so this keeps the
/// arena footprint low across the many instantiated modules while staying well
/// above what any included case needs. `assert_exhaustion` still traps on the
/// call-depth bound.
const spec_limits: engine.Limits = .{
    .fuel = 1_000_000_000,
    .max_call_depth = 1024,
    .value_stack_slots = 1 << 14,
    .control_stack_slots = 1 << 13,
    .max_memory_pages = 1024,
};

const Failure = struct {
    group: []const u8,
    line: u32,
    reason: []const u8,
};

const Counts = struct { pass: usize = 0, skip: usize = 0 };

fn moduleBytes(group: fixtures.Group, name: []const u8) ?[]const u8 {
    for (group.modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.bytes;
    }
    return null;
}

/// Parses a wast2json scalar into an engine `Value`. Integer/float literals are
/// unsigned decimal of the raw bit pattern; floats keep their raw bits.
fn parseValue(v: JsonValue) !engine.Value {
    const s = v.value orelse return error.MissingValue;
    if (std.mem.eql(u8, v.type, "i32")) {
        return .{ .i32 = @bitCast(try std.fmt.parseInt(u32, s, 10)) };
    } else if (std.mem.eql(u8, v.type, "i64")) {
        return .{ .i64 = @bitCast(try std.fmt.parseInt(u64, s, 10)) };
    } else if (std.mem.eql(u8, v.type, "f32")) {
        return .{ .f32 = try std.fmt.parseInt(u32, s, 10) };
    } else if (std.mem.eql(u8, v.type, "f64")) {
        return .{ .f64 = try std.fmt.parseInt(u64, s, 10) };
    }
    return error.UnsupportedType;
}

fn isCanonicalNanF32(bits: u32) bool {
    return (bits & 0x7FFF_FFFF) == 0x7FC0_0000;
}
fn isArithmeticNanF32(bits: u32) bool {
    // Any NaN (max exponent, non-zero mantissa) with the quiet bit set.
    return (bits & 0x7F80_0000) == 0x7F80_0000 and (bits & 0x0040_0000) != 0;
}
fn isCanonicalNanF64(bits: u64) bool {
    return (bits & 0x7FFF_FFFF_FFFF_FFFF) == 0x7FF8_0000_0000_0000;
}
fn isArithmeticNanF64(bits: u64) bool {
    return (bits & 0x7FF0_0000_0000_0000) == 0x7FF0_0000_0000_0000 and
        (bits & 0x0008_0000_0000_0000) != 0;
}

/// Compares one engine result against an expected JSON slot, honouring the
/// spec's NaN classes (`nan:canonical`/`nan:arithmetic`).
fn valuesMatch(expected: JsonValue, actual: engine.Value) bool {
    if (std.mem.eql(u8, expected.type, "i32")) {
        const want = std.fmt.parseInt(u32, expected.value orelse return false, 10) catch return false;
        return actual == .i32 and @as(u32, @bitCast(actual.i32)) == want;
    } else if (std.mem.eql(u8, expected.type, "i64")) {
        const want = std.fmt.parseInt(u64, expected.value orelse return false, 10) catch return false;
        return actual == .i64 and @as(u64, @bitCast(actual.i64)) == want;
    } else if (std.mem.eql(u8, expected.type, "f32")) {
        if (actual != .f32) return false;
        const s = expected.value orelse return false;
        if (std.mem.eql(u8, s, "nan:canonical")) return isCanonicalNanF32(actual.f32);
        if (std.mem.eql(u8, s, "nan:arithmetic")) return isArithmeticNanF32(actual.f32);
        const want = std.fmt.parseInt(u32, s, 10) catch return false;
        return actual.f32 == want;
    } else if (std.mem.eql(u8, expected.type, "f64")) {
        if (actual != .f64) return false;
        const s = expected.value orelse return false;
        if (std.mem.eql(u8, s, "nan:canonical")) return isCanonicalNanF64(actual.f64);
        if (std.mem.eql(u8, s, "nan:arithmetic")) return isArithmeticNanF64(actual.f64);
        const want = std.fmt.parseInt(u64, s, 10) catch return false;
        return actual.f64 == want;
    }
    return false;
}

const Invocation = struct { result: engine.InvokeResult, ok: bool };

fn invoke(
    arena: std.mem.Allocator,
    inst: *engine.Instance,
    action: JsonAction,
) !engine.InvokeResult {
    const args = try arena.alloc(engine.Value, action.args.len);
    for (action.args, 0..) |a, i| args[i] = try parseValue(a);
    return inst.invokeExport(action.field, args);
}

/// Replays one group's command manifest, appending any mismatches to `fails`.
fn runGroup(
    gpa: std.mem.Allocator,
    group: fixtures.Group,
    fails: *std.ArrayList(Failure),
    counts: *Counts,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(JsonManifest, arena, group.json, .{
        .ignore_unknown_fields = true,
    });
    const manifest = parsed.value;

    var current: ?engine.Instance = null;

    for (manifest.commands) |cmd| {
        const ct = cmd.type;
        if (std.mem.eql(u8, ct, "module")) {
            const fname = cmd.filename orelse continue;
            const bytes = moduleBytes(group, fname) orelse {
                try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "module fixture missing" });
                current = null;
                continue;
            };
            var module = engine.load(arena, bytes) catch {
                try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "valid module failed to load" });
                current = null;
                continue;
            };
            var inst = engine.Instance.init(arena, &module, spec_limits) catch {
                try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "valid module failed to instantiate" });
                current = null;
                continue;
            };
            // Run a module start function if present; a fault there is a failure.
            if (inst.runStart()) |_| {
                try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "module start trapped" });
            }
            current = inst;
        } else if (std.mem.eql(u8, ct, "assert_return")) {
            const inst = &(current orelse {
                counts.skip += 1;
                continue;
            });
            const action = cmd.action orelse continue;
            if (!std.mem.eql(u8, action.type, "invoke")) {
                counts.skip += 1;
                continue;
            }
            const result = invoke(arena, inst, action) catch {
                try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "invoke errored" });
                continue;
            };
            const expected = cmd.expected orelse &.{};
            switch (result) {
                .values => |vals| {
                    if (vals.len != expected.len) {
                        try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "result arity mismatch" });
                        continue;
                    }
                    var matched = true;
                    for (expected, vals) |e, got| {
                        if (!valuesMatch(e, got)) {
                            matched = false;
                            break;
                        }
                    }
                    if (matched) counts.pass += 1 else try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "result value mismatch" });
                },
                .trap => try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "unexpected trap on assert_return" }),
                .exited => try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "unexpected exit on assert_return" }),
            }
        } else if (std.mem.eql(u8, ct, "assert_trap") or std.mem.eql(u8, ct, "assert_exhaustion")) {
            const inst = &(current orelse {
                counts.skip += 1;
                continue;
            });
            const action = cmd.action orelse continue;
            if (!std.mem.eql(u8, action.type, "invoke")) {
                counts.skip += 1;
                continue;
            }
            const result = invoke(arena, inst, action) catch {
                // An engine-level Trap error is also an acceptable trap.
                counts.pass += 1;
                continue;
            };
            switch (result) {
                .trap => counts.pass += 1,
                else => try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "expected trap, got value/exit" }),
            }
        } else if (std.mem.eql(u8, ct, "assert_invalid") or std.mem.eql(u8, ct, "assert_malformed")) {
            // Only binary modules are in scope; text-form (.wat) cases are not
            // committed and are skipped.
            const mt = cmd.module_type orelse "binary";
            if (!std.mem.eql(u8, mt, "binary")) {
                counts.skip += 1;
                continue;
            }
            const fname = cmd.filename orelse continue;
            const bytes = moduleBytes(group, fname) orelse {
                counts.skip += 1;
                continue;
            };
            if (engine.load(arena, bytes)) |_| {
                try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "invalid/malformed module was accepted" });
            } else |_| {
                counts.pass += 1;
            }
        } else if (std.mem.eql(u8, ct, "action")) {
            const inst = &(current orelse {
                counts.skip += 1;
                continue;
            });
            const action = cmd.action orelse continue;
            if (!std.mem.eql(u8, action.type, "invoke")) {
                counts.skip += 1;
                continue;
            }
            _ = invoke(arena, inst, action) catch {
                try fails.append(gpa, .{ .group = group.name, .line = cmd.line, .reason = "action invoke errored" });
            };
            counts.pass += 1;
        } else {
            // register / assert_uninstantiable / assert_unlinkable / etc.
            counts.skip += 1;
        }
    }
}

test "wasm spec conformance: curated upstream subset passes" {
    const gpa = std.testing.allocator;
    var fails: std.ArrayList(Failure) = .empty;
    defer fails.deinit(gpa);
    var counts: Counts = .{};

    for (fixtures.groups) |group| {
        try runGroup(gpa, group, &fails, &counts);
    }

    if (fails.items.len != 0) {
        std.debug.print(
            "\nwasm spec conformance: {d} pass, {d} skip, {d} FAIL (testsuite @ {s})\n",
            .{ counts.pass, counts.skip, fails.items.len, fixtures.testsuite_rev },
        );
        var shown: usize = 0;
        for (fails.items) |f| {
            if (shown >= 40) {
                std.debug.print("  ... and {d} more\n", .{fails.items.len - shown});
                break;
            }
            std.debug.print("  FAIL {s}.wast:{d}: {s}\n", .{ f.group, f.line, f.reason });
            shown += 1;
        }
        return error.WasmConformanceFailed;
    }

    // Guard against an empty or mis-wired fixture set silently "passing".
    try std.testing.expect(counts.pass > 1000);
}

test {
    std.testing.refAllDecls(@This());
}
