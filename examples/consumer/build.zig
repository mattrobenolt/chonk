//! Example consumer: a plain Zig project that builds one fat binary out of
//! the same app compiled for two CPUs. Run with:
//!
//!     zig build && ./zig-out/bin/app

const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const chonk = b.lazyImport(@This(), "chonk") orelse return;

    // Same app, two CPUs: Neoverse V2 (the SVE2 family) and baseline.
    // Build these exactly like any other executable — the packer checks
    // every variant agrees on machine.
    const app_v2 = app(b, optimize, .{
        .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.neoverse_v2 },
    });
    const app_baseline = app(b, optimize, .{});

    // One fat binary. At exec time the stub reads the CPU's hwcap from the
    // auxv and the first variant whose conditions pass wins.
    _ = chonk.addFatBinary(b, .{
        .name = "app",
        .variants = &.{
            .{ .name = "neoverse-v2", .exe = app_v2, .bit = "SVE2" },
            .{ .name = "baseline", .exe = app_baseline, .default = true },
        },
    });
}

fn app(b: *Build, optimize: std.builtin.OptimizeMode, query: std.Target.Query) *Build.Step.Compile {
    return b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = optimize,
        }),
    });
}
