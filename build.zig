const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `scoot` 库模块：汇总各子系统命名空间，供 CLI 与外部嵌入者复用。
    const mod = b.addModule("scoot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // 版本号单一事实源：默认取 build.zig.zon 的 `.version`；发布时由 release 工作流用
    // `-Dversion=<tag>` 覆盖，使二进制内嵌版本与 git tag 始终一致，杜绝硬编码漂移。
    const zon_version = @import("build.zig.zon").version;
    const version = b.option([]const u8, "version", "覆盖内嵌版本号（发布时由 git tag 注入）") orelse zon_version;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    mod.addImport("build_options", build_options.createModule());

    // `scoot` 可执行文件：CLI / REPL / Daemon 入口。
    const exe = b.addExecutable(.{
        .name = "scoot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scoot", .module = mod },
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

    // zig build test
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "运行全部测试");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
