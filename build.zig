const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "chonk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .single_threaded = true,
        }),
    });

    b.installArtifact(exe);

    // The freestanding dispatcher. No libc — raw syscalls only, custom
    // naked `_start` entry (src/stub.zig). Freestanding target is what keeps
    // std.start out: on linux targets the compiler force-analyzes std.zig,
    // which force-analyzes std.start, which demands a `main` and fights over
    // the `_start` symbol. Freestanding skips all of that; std.os.linux
    // wrappers still compile (arch-gated, not os-gated).
    const stub = b.addExecutable(.{
        .name = "stub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stub.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
            .strip = optimize != .Debug,
            .single_threaded = true,
        }),
    });

    stub.entry = .enabled;

    b.installArtifact(stub);

    // The hosted packer. Ordinary target — no freestanding constraints here.
    const packer = b.addExecutable(.{
        .name = "packer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/packer.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        }),
    });

    b.installArtifact(packer);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
