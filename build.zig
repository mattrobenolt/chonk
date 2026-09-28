const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Step = Build.Step;

// ---------------------------------------------------------------------------
// Build-system integration — usable from any project that depends on chonk.
// ---------------------------------------------------------------------------

/// One variant for `addFatBinary`: an executable plus what distinguishes
/// it. Build the executable per CPU target exactly as you normally would —
/// the packer checks every variant agrees on machine.
pub const FatVariant = struct {
    name: []const u8,
    exe: *Step.Compile,
    /// Kernel hwcap bit name ("SVE2") — implies its source; the packer's
    /// bit table resolves it. Mutually exclusive with `default`.
    bit: ?[]const u8 = null,
    /// Fallback when nothing matches. Exactly one variant must set this.
    default: bool = false,
};

pub const FatBinaryOptions = struct {
    /// Installed as zig-out/bin/<name>.
    name: []const u8 = "fat",
    variants: []const FatVariant,
    /// Wire the zig-out/bin/<name> install.
    install: bool = true,
};

/// Build-system integration: pack `variants` plus this repo's freestanding
/// stub into one fat binary that picks a payload by CPU features at exec
/// time. From another project's build.zig, with this repo as a `chonk`
/// dependency in build.zig.zon:
///
///     const chonk = b.lazyImport(@This(), "chonk") orelse return;
///     _ = chonk.addFatBinary(b, .{ .variants = &.{ ... } });
///
/// Returns the fat binary's LazyPath; installs it as zig-out/bin/<name>
/// unless `install = false`.
///
/// One fat binary per architecture: the trailer's machine field is a
/// species check, so call once per arch with that arch's variants.
pub fn addFatBinary(b: *Build, options: FatBinaryOptions) LazyPath {
    for (options.variants) |v| {
        if (v.bit != null and v.default) {
            @panic("FatVariant: 'bit' and 'default' are mutually exclusive");
        }
        if (v.bit == null and !v.default) {
            @panic("FatVariant: needs 'bit' or 'default'");
        }
    }

    const dep = b.dependency("chonk", .{});
    const run = b.addRunArtifact(dep.artifact("chonk"));
    run.addArgs(&.{ "pack", "--stub" });
    run.addFileArg(dep.artifact("stub").getEmittedBin());
    run.addArgs(&.{"--out"});
    const fat = run.addOutputFileArg(options.name);
    for (options.variants) |v| {
        run.addArgs(&.{ "--variant", v.name });
        if (v.bit) |bit| {
            run.addArgs(&.{ "--bit", bit });
        } else {
            run.addArg("--default");
        }
        run.addFileArg(v.exe.getEmittedBin());
    }
    // addInstallFile* creates the step but does not wire it — the
    // lowercase install helpers wire but take static paths only.
    if (options.install) {
        const install = b.addInstallFileWithDir(fat, .bin, options.name);
        b.getInstallStep().dependOn(&install.step);
    }
    return fat;
}

// ---------------------------------------------------------------------------

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

    // The freestanding dispatcher. No libc — raw syscalls only, custom
    // naked `_start` entry (src/stub.zig). Freestanding target is what keeps
    // std.start out: on linux targets the compiler force-analyzes std.zig,
    // which force-analyzes std.start, which demands a `main` and fights over
    // the `_start` symbol. Freestanding skips all of that; std.os.linux
    // wrappers still compile (arch-gated, not os-gated).
    const stub = b.addExecutable(.{
        .name = "stub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stub.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
            .strip = optimize != .Debug,
            .single_threaded = true,
        }),
    });

    stub.entry = .enabled;

    b.installArtifact(stub);

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
