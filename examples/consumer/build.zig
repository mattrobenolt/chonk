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

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const chonk = b.lazyImport(@This(), "chonk") orelse return;

    // One app, one name, a list of targets. The neoverse_v2 build
    // dispatches on the SVE2-family bits implied by its features; the
    // arch-baseline build is the fallback. Note .{ .cpu_model = .baseline }
    // — a bare .{} would mean native-on-this-build-machine, which on V2
    // hardware would build a V2 binary as the "fallback".
    _ = chonk.addExecutable(b, .{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .targets = &.{
            .{ .cpu_model = .{ .explicit = &Target.aarch64.cpu.neoverse_v2 } },
            .{ .cpu_model = .baseline }, // the fallback
        },
    });
}
