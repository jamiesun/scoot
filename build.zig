const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_wasm_host = b.option(bool, "wasm-host", "构建默认关闭的独立 scoot-wasm Wasm host") orelse false;

    // `scoot` 库模块：面向外部嵌入者的稳定公共 API。
    const mod = b.addModule("scoot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    // 内部模块：CLI 可使用完整子系统命名空间，但不把它们承诺给外部嵌入者。
    const internal_mod = b.addModule("scoot-internal", .{
        .root_source_file = b.path("src/internal.zig"),
        .target = target,
    });

    // 版本号单一事实源：默认取 build.zig.zon 的 `.version`；发布时由 release 工作流用
    // `-Dversion=<tag>` 覆盖，使二进制内嵌版本与 git tag 始终一致，杜绝硬编码漂移。
    const zon_version = @import("build.zig.zon").version;
    const version = b.option([]const u8, "version", "覆盖内嵌版本号（发布时由 git tag 注入）") orelse zon_version;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    const build_options_mod = build_options.createModule();
    mod.addImport("build_options", build_options_mod);
    internal_mod.addImport("build_options", build_options_mod);

    // `scoot` 可执行文件：CLI / REPL / Daemon 入口。
    const exe = b.addExecutable(.{
        .name = "scoot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scoot", .module = internal_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // zig build run [-- <args>]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "构建并运行 scoot");
    run_step.dependOn(&run_cmd.step);

    if (build_wasm_host) {
        const wasm_host = b.addExecutable(.{
            .name = "scoot-wasm",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm_host.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(wasm_host);
    }

    // The standalone Wasm engine lives outside the core `scoot` binary so the
    // zero-dependency core never embeds a runtime. Its tests are compiled as a
    // separate artifact (not linked into core) and always run under `zig build
    // test`.
    const wasm_engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_engine.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_wasm_engine_tests = b.addRunArtifact(wasm_engine_tests);

    const embed_example = b.addExecutable(.{
        .name = "scoot-embed-minimal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/embed/minimal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scoot", .module = mod },
            },
        }),
    });

    // zig build test
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const internal_tests = b.addTest(.{ .root_module = internal_mod });
    const run_internal_tests = b.addRunArtifact(internal_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // The three test artifacts compile overlapping source files, so the same
    // test (and its hardcoded /tmp/scoot_* path) is built into more than one
    // binary. Left unordered, the build runner executes the run steps in
    // parallel and the binaries race on those shared paths: one binary's
    // `deleteTree` defer can remove a file another is mid-`exec` on. Serialize
    // the run steps (compilation still parallelizes) so the suite is
    // deterministic under `zig build test`. See #127.
    run_internal_tests.step.dependOn(&run_mod_tests.step);
    run_exe_tests.step.dependOn(&run_internal_tests.step);

    const test_step = b.step("test", "运行全部测试");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_internal_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_wasm_engine_tests.step);
    test_step.dependOn(&embed_example.step);
}
