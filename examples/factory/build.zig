//! The make_exe + post_process door: a consumer with a dependency module
//! import (helper), exe-level flags, and a post-compile hook that swaps the
//! fallback variant's payload for a different binary entirely. If the hook
//! were silently ignored, the fallback would print "factory-helper built
//! for generic" instead of the fallback binary's marker.

const std = @import("std");
const Build = std.Build;
const chonk = @import("chonk");

/// The binary the post-compile hook swaps in for the fallback variant:
/// a different, cheaper build of the app — the pattern for shipping a
/// stripped-down fallback. Set in build() before chonk calls the hook.
var fallback_exe: *Build.Step.Compile = undefined;

pub fn build(b: *Build) void {
    const target: std.Target.Query = .{ .cpu_arch = .aarch64, .abi = .musl };

    const fallback_mod = b.createModule(.{
        .root_source_file = b.path("src/fallback.zig"),
        .target = b.resolveTargetQuery(target),
        .optimize = .Debug,
    });
    fallback_exe = b.addExecutable(.{ .name = "fallback", .root_module = fallback_mod });

    const fat = chonk.addExecutable(b, .{
        .name = "app",
        .target = target,
        .optimize = .Debug,
        .make_exe = makeExe,
        .post_process = postProcess,
        .targets = &.{
            .{ .model = .{ .explicit = &std.Target.aarch64.cpu.neoverse_v2 } },
        },
    });
    _ = fat;
}

/// The post-compile hook (#5): the fallback variant packs a different
/// binary; every other variant passes through untouched.
fn postProcess(b: *Build, v: chonk.Variant, payload: Build.LazyPath) Build.LazyPath {
    _ = b;
    // "generic" is the aarch64 baseline model's name — the implicit
    // fallback chonk appends when no listed target is itself baseline.
    if (std.mem.eql(u8, v.name, "generic")) return fallback_exe.getEmittedBin();
    return payload;
}

/// The per-variant executable factory (#1): dependencies resolve against
/// each variant's target, so the modules are re-created per variant.
fn makeExe(b: *Build, v: chonk.Variant) *Build.Step.Compile {
    const helper_mod = b.createModule(.{
        .root_source_file = b.path("src/helper.zig"),
        .target = v.target,
        .optimize = v.optimize,
    });
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = v.target,
        .optimize = v.optimize,
    });
    app_mod.addImport("helper", helper_mod);
    const exe = b.addExecutable(.{ .name = v.name, .root_module = app_mod });
    exe.use_llvm = true;
    return exe;
}
