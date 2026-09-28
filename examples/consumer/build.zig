//! Example consumer: the canonical chonk integration.
//!
//!   zig build          — the normal binary, native CPU (the dev loop)
//!   zig build run      — run the normal binary
//!   zig build chonk    — the fat binary (the release build)
//!
//! The last one out of zig-out/bin/app is whichever you built: the fat
//! binary is the release version of the same app, same name, same
//! interface — it just picks its payload by CPU features at exec time.

const std = @import("std");
const Build = std.Build;
const Target = std.Target;
const OptimizeMode = std.builtin.OptimizeMode;

const chonk = @import("chonk");

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // The normal binary: plain Zig scaffolding, nothing chonk about it.
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build chonk`: the same app compiled for the target fleet,
    // packed into one fat binary that dispatches by CPU features.
    const fat = chonk.addExecutable(b, .{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .install = false, // wired into the chonk step below, not the default
        .targets = &.{
            .{ .cpu_model = .{ .explicit = &Target.aarch64.cpu.neoverse_v2 } },
            .{ .cpu_model = .baseline }, // the fallback — NOT bare .{} (= native)
        },
    });

    // addInstallFileWithDir creates the install step but wires nothing —
    // depending on it from OUR step (not the default install) is what makes
    // `zig build chonk` the only trigger. The fat binary lands at
    // zig-out/bin/app, same name as the dev build: last one built wins.
    const install_fat = b.addInstallFileWithDir(fat, .bin, "app");
    const chonk_step = b.step("chonk", "Build the fat binary");
    chonk_step.dependOn(&install_fat.step);
}
