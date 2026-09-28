//! chonk's own build. The consumer-facing build API lives in
//! src/build.zig (everything behind `chonk.addExecutable`); this file
//! builds chonk itself and re-exports that API so a dependency's
//! `@import("chonk")` reaches it.

const std = @import("std");
const Build = std.Build;

const api = @import("src/build.zig");

// The consumer surface: `chonk.addExecutable(...)` and friends.
pub const addExecutable = api.addExecutable;
pub const ExecutableOptions = api.ExecutableOptions;
pub const TargetSpec = api.TargetSpec;
pub const Variant = api.Variant;
pub const ExeFactory = api.ExeFactory;
pub const Match = api.Match;
pub const Bit = api.Bit;
pub const midrPart = api.midrPart;

pub fn build(b: *Build) void {
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

    // The freestanding dispatchers, one per species (#3): no libc — raw
    // syscalls only, custom naked `_start` entry (src/stub.zig). Freestanding
    // target is what keeps std.start out: on linux targets the compiler
    // force-analyzes std.zig, which force-analyzes std.start, which demands a
    // `main` and fights over the `_start` symbol. Freestanding skips all of
    // that; std.os.linux wrappers still compile (arch-gated, not os-gated).
    // Always ReleaseSmall + stripped — compiled-once-forever artifacts (~3
    // pages), for the CLI pack path. The build API compiles its own per
    // species at addExecutable time.
    inline for ([_]struct { []const u8, std.Target.Cpu.Arch }{
        .{ "stub-aarch64", .aarch64 },
        .{ "stub-x86_64", .x86_64 },
    }) |stub_spec| {
        const stub = b.addExecutable(.{
            .name = stub_spec[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/stub.zig"),
                .target = b.resolveTargetQuery(.{
                    .cpu_arch = stub_spec[1],
                    .os_tag = .freestanding,
                }),
                .optimize = .ReleaseSmall,
                .strip = true,
                .single_threaded = true,
            }),
        });

        stub.entry = .enabled;

        b.installArtifact(stub);
    }

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
