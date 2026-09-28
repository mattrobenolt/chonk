const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Step = Build.Step;
const Io = std.Io;

const pack = @import("src/pack.zig");
const stdio = @import("src/stdio.zig");

// ---------------------------------------------------------------------------
// Build-system integration — usable from any project that depends on chonk.
// The pack logic runs IN-PROCESS (src/pack.zig via b.graph.io); the CLI is
// just the other consumer of the same module.
// ---------------------------------------------------------------------------

/// The vocabulary shared with the ZON config — pack.zig is the one
/// definition; re-exported for consumer ergonomics.
pub const Match = pack.Match;
pub const Bit = pack.Bit;

/// One variant for `addFatBinary`: an executable plus what distinguishes
/// it. `bit == null` marks the fallback — exactly one variant must omit
/// it. Build the executable per CPU target exactly as you normally would;
/// the packer checks every variant agrees on machine.
pub const FatVariant = struct {
    exe: *Step.Compile,
    /// Display name; defaults to the exe's name.
    name: ?[]const u8 = null,
    /// Kernel hwcap bit that must be set for this variant to win.
    bit: ?Bit = null,
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
/// time. The stub is compiled into THIS build graph from source; the pack
/// step runs the same module the CLI uses, in-process. From another
/// project's build.zig, with this repo as a `chonk` dependency:
///
///     const chonk = b.lazyImport(@This(), "chonk") orelse return;
///     _ = chonk.addFatBinary(b, .{
///         .name = "app",
///         .variants = &.{
///             .{ .exe = app_v2, .bit = .sve2 },
///             .{ .exe = app_baseline }, // the fallback
///         },
///     });
///
/// Returns the fat binary's LazyPath; installs it as zig-out/bin/<name>
/// unless `install = false`.
///
/// One fat binary per architecture: the trailer's machine field is a
/// species check, so call once per arch with that arch's variants.
pub fn addFatBinary(b: *Build, options: FatBinaryOptions) LazyPath {
    var fallback_count: usize = 0;
    for (options.variants) |v| {
        if (v.bit == null) fallback_count += 1;
    }
    if (fallback_count != 1) {
        @panic("addFatBinary: exactly one variant must omit 'bit' (the fallback)");
    }

    // The freestanding stub, compiled into THIS build graph from source.
    // Compiled-once-forever: always ReleaseSmall + stripped, regardless of
    // the consumer's optimize setting.
    const dep = b.dependency("chonk", .{});
    const stub = b.addExecutable(.{
        .name = "stub",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/stub.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
            .strip = true,
            .single_threaded = true,
        }),
    });
    stub.entry = .enabled;

    const pack_step = b.allocator.create(PackStep) catch @panic("OOM");
    const inputs = b.allocator.alloc(PackStep.Input, options.variants.len) catch @panic("OOM");
    for (options.variants, 0..) |v, i| {
        inputs[i] = .{
            .name = v.name orelse v.exe.name,
            .payload = v.exe.getEmittedBin(),
            .bit = v.bit,
        };
    }
    pack_step.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = b.fmt("chonk pack {s}", .{options.name}),
            .owner = b,
            .makeFn = PackStep.make,
        }),
        .fat = .{ .step = &pack_step.step },
        .out_name = options.name,
        .stub = stub.getEmittedBin(),
        .inputs = inputs,
    };

    // The pack runs after the stub + every variant compiles.
    pack_step.step.dependOn(&stub.step);
    for (options.variants) |v| {
        pack_step.step.dependOn(&v.exe.step);
    }

    const fat: LazyPath = .{ .generated = .{ .file = &pack_step.fat } };
    // addInstallFile* creates the step but does not wire it — the
    // lowercase install helpers wire but take static paths only.
    if (options.install) {
        const install = b.addInstallFileWithDir(fat, .bin, options.name);
        b.getInstallStep().dependOn(&install.step);
    }
    return fat;
}

/// Packs a fat binary in-process: the same module the CLI uses, run by the
/// build runner with b.graph.io — no subprocess, no argv marshalling.
const PackStep = struct {
    step: Step,
    fat: Build.GeneratedFile,
    out_name: []const u8,
    stub: LazyPath,
    inputs: []Input,

    const Input = struct {
        name: []const u8,
        payload: LazyPath,
        bit: ?Bit,
    };

    fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const io = b.graph.io;
        const arena = b.allocator;
        const self: *PackStep = @fieldParentPtr("step", step);

        // Manifest: the output name, every input file, and the conditions.
        var man = b.graph.cache.obtain();
        defer man.deinit();
        man.hash.addBytes(self.out_name);
        _ = try man.addFilePath(self.stub.getPath3(b, step), null);
        for (self.inputs) |input| {
            man.hash.addBytes(input.name);
            man.hash.addBytes(if (input.bit) |bit| @tagName(bit) else "(fallback)");
            _ = try man.addFilePath(input.payload.getPath3(b, step), null);
        }

        if (try step.cacheHit(&man)) {
            const digest = man.final();
            self.fat.path = try b.cache_root.join(arena, &.{ "o", &digest, self.out_name });
            return;
        }
        const digest = man.final();
        const dir_sub = b.fmt("o/{s}", .{&digest});
        self.fat.path = try b.cache_root.join(arena, &.{ dir_sub, self.out_name });

        // A canonical cache home for the fat binary.
        b.cache_root.handle.createDirPath(io, dir_sub) catch |err| {
            return step.fail("create cache dir: {s}", .{@errorName(err)});
        };

        // The same module the CLI uses; stdio is ours to init in-process,
        // and ours to flush on every exit path of make().
        stdio.init(io);
        defer stdio.flush();
        const stub_path = self.stub.getPath2(b, step);
        const cwd = Io.Dir.cwd();
        const variants = try arena.alloc(pack.Variant, self.inputs.len);
        for (self.inputs, 0..) |input, i| {
            const match: []pack.Match = if (input.bit) |bit| blk: {
                const one = try arena.create(pack.Match);
                one.* = .{ .bit = bit };
                break :blk one[0..1];
            } else &.{};
            variants[i] = .{
                .name = input.name,
                .binary = input.payload.getPath2(b, step),
                .match = match,
            };
        }
        _ = try pack.packAll(io, arena, cwd, cwd, self.fat.path.?, stub_path, .{
            .variants = variants,
        });
        try step.writeManifest(&man);
    }
};

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
