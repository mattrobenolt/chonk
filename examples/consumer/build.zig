//! Example consumer: the canonical chonk integration.
//!
//!   zig build          — the normal binary, native CPU (the dev loop)
//!   zig build run      — run the normal binary
//!   zig build chonk    — the fat binaries (the release fleet)
//!   zig build files    — the file-mode fleet (shim + separate payloads)
//!
//! The fat binaries are the release versions of the same app, same
//! interface — they just pick their payload by CPU features at exec time.
//! The files fleet is the same dispatch with the payloads on disk, which is
//! the shape path-based LSM profiles (AppArmor) can name.

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
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build chonk`: the release fleet. One fat binary per species —
    // one chonk.addExecutable call per arch — each dispatching by CPU
    // features at exec time.
    const chonk_step = b.step("chonk", "Build the fat binaries");

    // The ARM ladder, shared by both output modes below: the full cloud
    // ladder, strongest first (first match wins). V3 = AWS Graviton5;
    // V2 = Graviton4 / GCP Axion; V1 = Graviton3; N1 = Graviton2 / Azure
    // Cobalt 100 / Ampere Altra. V3 and V2 advertise the SAME hwcap words
    // on many hosts, so V3 is separated by its MIDR part number — the
    // tiebreak. No fallback listed — the arch baseline (Graviton1 /
    // Cortex-A72) is appended automatically.
    const arm_targets: []const chonk.TargetSpec = &.{
        .{
            .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v3 },
            .extra_match = &.{chonk.midrPart(0x41, 0xd84)},
        },
        .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v2 } },
        .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v1 } },
        .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_n1 } },
    };

    // aarch64: the Neoverse tiers + baseline fallback. The skeleton carries
    // the species (arch + abi); only the cpu model varies per target.
    const fat_arm = chonk.addExecutable(b, .{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .target = .{ .cpu_arch = .aarch64, .abi = .musl },
        .optimize = optimize,
        .install = false, // wired into the chonk step below, not the default
        .targets = arm_targets,
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

    // `zig build files`: the file-mode fleet. The shim carries the same
    // variant table, but the payloads stay separate files and the shim
    // execve()s one by path at run time — no memfd, no execveat, so a
    // path-based LSM profile (AppArmor) can allow `app-files mrix` and
    // `app-files.d/* mrix` instead of an anonymous-file exec. The shim
    // resolves `<its own path>.d/<variant>`, so the shim and the directory
    // must be installed together under matching names.
    const files_step = b.step("files", "Build the file-mode fleet (separate payload files)");
    const files_arm = chonk.addFilesExecutable(b, .{
        .name = "app-files",
        .root_source_file = b.path("src/main.zig"),
        .target = .{ .cpu_arch = .aarch64, .abi = .musl },
        .optimize = optimize,
        .install = false, // wired into the files step below, not the default
        .targets = arm_targets,
    });
    const install_files_shim = b.addInstallFileWithDir(files_arm.shim, .bin, "app-files");
    files_step.dependOn(&install_files_shim.step);
    for (files_arm.payloads) |payload| {
        const install_payload = b.addInstallFileWithDir(
            payload.path,
            .bin,
            b.fmt("app-files.d/{s}", .{payload.name}),
        );
        files_step.dependOn(&install_payload.step);
    }
}
