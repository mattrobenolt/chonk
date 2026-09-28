//! Example consumer: a plain Zig project that builds one fat binary out of
//! the same app compiled for two CPUs. Run with:
//!
//!     zig build && ./zig-out/bin/app
//!
//! The whole integration is one call: `chonk.addExecutable` with a target
//! list instead of a single target.

const std = @import("std");
const Build = std.Build;
const Target = std.Target;
const OptimizeMode = std.builtin.OptimizeMode;

const chonk = @import("chonk");

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // One app, one name, a list of targets. The neoverse_v2 build
    // dispatches on the SVE2-family bits implied by its features; the
    // arch-baseline build is the fallback. Note .{ .cpu_model = .baseline }
    // — a bare .{} would mean native-on-this-build-machine, which on V2
    // hardware would build a V2 binary as the "fallback".
    const fat = chonk.addExecutable(b, .{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .targets = &.{
            .{ .cpu_model = .{ .explicit = &Target.aarch64.cpu.neoverse_v2 } },
            .{ .cpu_model = .baseline }, // the fallback
        },
    });

    // The LazyPath return is a first-class graph citizen: feed it to a run
    // step and `zig build run` executes the FAT binary — which on this
    // machine dispatches to the right variant. The dev loop goes through
    // the front door; the intermediates never need exposing.
    const run_step = b.step("run", "Run the fat binary");
    const run_cmd = Build.Step.Run.create(b, "run app");
    run_cmd.addFileArg(fat);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);
}
