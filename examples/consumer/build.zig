//! Example consumer: the canonical chonk integration.
//!
//!   zig build          — the normal binary, native CPU (the dev loop)
//!   zig build run      — run the normal binary
//!   zig build chonk    — the fat binaries (the release fleet)
//!
//! The fat binaries are the release versions of the same app, same
//! interface — they just pick their payload by CPU features at exec time.

const std = @import("std");
const Build = std.Build;
const Target = std.Target;

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

    // `zig build chonk`: the release fleet. One fat binary per species —
    // one chonk.addExecutable call per arch — each dispatching by CPU
    // features at exec time.
    const chonk_step = b.step("chonk", "Build the fat binaries");

    // aarch64: the Neoverse tiers + baseline fallback. The skeleton carries
    // the species (arch + abi); only the cpu model varies per target.
    const fat_arm = chonk.addExecutable(b, .{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .target = .{ .cpu_arch = .aarch64, .abi = .musl },
        .optimize = optimize,
        .install = false, // wired into the chonk step below, not the default
        .targets = &.{
            // The full cloud ARM ladder, strongest first (first match wins):
            // V3 = AWS Graviton5; V2 = Graviton4 / GCP Axion;
            // V1 = Graviton3; N1 = Graviton2 / Azure Cobalt 100 / Ampere
            // Altra. V3 and V2 advertise the SAME hwcap words on many
            // hosts, so V3 is separated by its MIDR part number — the
            // tiebreak. No fallback listed — the arch baseline
            // (Graviton1 / Cortex-A72) is appended automatically.
            .{
                .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v3 },
                .extra_match = &.{chonk.midrPart(0x41, 0xd84)},
            },
            .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v2 } },
            .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v1 } },
            .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_n1 } },
        },
    });
    const install_arm = b.addInstallFileWithDir(fat_arm, .bin, "app");
    chonk_step.dependOn(&install_arm.step);

    // x86_64: the psABI levels — v3 (AVX2/BMI2/FMA) + baseline fallback —
    // cross-compiled from this aarch64 machine; runs anywhere x86_64.
    const fat_x86 = chonk.addExecutable(b, .{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .target = .{ .cpu_arch = .x86_64, .abi = .musl },
        .optimize = optimize,
        .install = false,
        .targets = &.{
            .{ .model = .{ .explicit = &Target.x86.cpu.x86_64_v3 } },
            // no fallback listed — the arch baseline is appended
            // automatically as the last entry
        },
    });
    const install_x86 = b.addInstallFileWithDir(fat_x86, .bin, "app-x86_64");
    chonk_step.dependOn(&install_x86.step);
}
