//! Example consumer: a plain Zig project that builds one fat binary out of
//! the same app compiled for two CPUs. Run with:
//!
//!     zig build && ./zig-out/bin/app

const std = @import("std");
const Build = std.Build;
const Target = std.Target;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const chonk = b.lazyImport(@This(), "chonk") orelse return;

    // Same app, two CPUs: Neoverse V2 (the SVE2 family) and baseline.
    const app_v2 = app(b, optimize, .{
        .cpu_model = .{ .explicit = &Target.aarch64.cpu.neoverse_v2 },
    });
    const app_baseline = app(b, optimize, .{});

    // One fat binary. At exec time the stub reads the CPU's hwcap from the
    // auxv and the first variant whose conditions pass wins.
    _ = chonk.addFatBinary(b, .{
        .name = "app",
        .variants = &.{
            .{ .exe = app_v2, .name = "neoverse-v2", .bit = .sve2 },
            .{ .exe = app_baseline, .name = "baseline" }, // the fallback
        },
    });
}

fn app(b: *Build, optimize: OptimizeMode, query: Target.Query) *Build.Step.Compile {
    return b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = optimize,
        }),
    });
}
