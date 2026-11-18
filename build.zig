//! chonk's own build. The consumer-facing build API lives in
//! src/build.zig (everything behind `chonk.addExecutable`); this file
//! builds chonk itself and re-exports that API so a dependency's
//! `@import("chonk")` reaches it.

const std = @import("std");
const Build = std.Build;

const api = @import("src/build.zig");

// The consumer surface: `chonk.addExecutable(...)` and friends.
pub const addExecutable = api.addExecutable;
pub const addFilesExecutable = api.addFilesExecutable;
pub const ExecutableOptions = api.ExecutableOptions;
pub const FilesExecutable = api.FilesExecutable;
pub const Payload = api.Payload;
pub const TargetSpec = api.TargetSpec;
pub const Variant = api.Variant;
pub const ExeFactory = api.ExeFactory;
pub const Match = api.Match;
pub const Bit = api.Bit;
pub const midrPart = api.midrPart;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cli_dep = b.dependency("cli", .{ .target = target });

    const exe = b.addExecutable(.{
        .name = "chonk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            .single_threaded = true,
        }),
    });
    exe.root_module.addImport("cli", cli_dep.module("cli"));

    b.installArtifact(exe);

    // The freestanding dispatchers, per species and per trailer mode (#3):
    // no libc — raw syscalls only, custom naked `_start` entry
    // (src/stub.zig). The `-files` pair carries the file-mode exec path
    // (payload files beside the shim, plain execve); the plain pair carries
    // the embedded path (memfd + execveat). Building them separately keeps
    // each path out of the other binary.
    //
    // Freestanding target is what keeps std.start out: on linux targets the
    // compiler force-analyzes std.zig, which force-analyzes std.start, which
    // demands a `main` and fights over the `_start` symbol. Freestanding
    // skips all of that; std.os.linux wrappers still compile (arch-gated,
    // not os-gated). Always ReleaseSmall + stripped — compiled-once-forever
    // artifacts (~3 pages), for the CLI pack path. The build API compiles
    // its own per species at addExecutable time.
    inline for ([_]struct { name: []const u8, arch: std.Target.Cpu.Arch, files: bool }{
        .{ .name = "stub-aarch64", .arch = .aarch64, .files = false },
        .{ .name = "stub-aarch64-files", .arch = .aarch64, .files = true },
        .{ .name = "stub-x86_64", .arch = .x86_64, .files = false },
        .{ .name = "stub-x86_64-files", .arch = .x86_64, .files = true },
    }) |stub_spec| {
        const options = b.addOptions();
        options.addOption(bool, "files", stub_spec.files);

        const stub_mod = b.createModule(.{
            .root_source_file = b.path("src/stub.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = stub_spec.arch,
                .os_tag = .freestanding,
            }),
            .optimize = .small,
            .strip = true,
            .single_threaded = true,
        });
        stub_mod.addOptions("build_options", options);

        const stub = b.addExecutable(.{
            .name = stub_spec.name,
            .root_module = stub_mod,
        });

        stub.entry = .enabled;

        b.installArtifact(stub);
    }

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
