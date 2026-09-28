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

const aarch64 = std.Target.aarch64;

/// Bit → the Zig target feature that implies it, where one exists. The
/// kernel vocabulary is finer-grained than LLVM's in three places
/// (svepmull, svei8mm, svebf16 have no Zig feature) — those stay
/// explicit-only (the ZON config's raw form).
fn zigFeature(bit: Bit) ?aarch64.Feature {
    return switch (bit) {
        .sve => .sve,
        .sve2 => .sve2,
        .sveaes => .sve2_aes,
        .svepmull => null,
        .svebitperm => .sve2_bitperm,
        .svesha3 => .sve2_sha3,
        .svesm4 => .sve2_sm4,
        .svei8mm => null,
        .svebf16 => null,
        .i8mm => .i8mm,
        .bf16 => .bf16,
        .sme => .sme,
    };
}

/// Infer the dispatch conditions from a target: every inferable bit whose
/// feature the target has and the arch baseline lacks.
fn inferBits(b: *Build, target: std.Target) []const Bit {
    const cpu = target.cpu;
    const baseline = std.Target.Cpu.baseline(cpu.arch, target.os);
    var bits: std.ArrayList(Bit) = .empty;
    inline for (comptime std.enums.values(Bit)) |bit| {
        if (zigFeature(bit)) |feature| {
            if (cpu.has(.aarch64, feature) and !baseline.has(.aarch64, feature)) {
                bits.append(b.allocator, bit) catch @panic("OOM");
            }
        }
    }
    return bits.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// The fallback target: identical to the arch baseline. `.{ .target = .{} }`
/// is NOT this — it means native on the build machine, which on V2
/// hardware builds a V2 binary as the "fallback". Use
/// `.{ .cpu_model = .baseline }`.
fn isBaseline(target: std.Target) bool {
    const cpu = target.cpu;
    const baseline = std.Target.Cpu.baseline(cpu.arch, target.os);
    inline for (comptime std.enums.values(aarch64.Feature)) |feature| {
        if (cpu.has(.aarch64, feature) != baseline.has(.aarch64, feature)) {
            return false;
        }
    }
    return true;
}

/// `chonk.addExecutable` options — the `b.addExecutable` shape with the
/// name and a target list instead of a single target.
pub const ExecutableOptions = struct {
    /// The fat binary's name — the ONLY name. Installed as
    /// zig-out/bin/<name>; intermediates auto-name from their CPU models.
    name: []const u8,
    /// The same source for every target.
    root_source_file: LazyPath,
    /// Compilation targets. The arch-baseline target (usually
    /// `.{ .cpu_model = .baseline }`) is the fallback — exactly one
    /// required. Every other target dispatches on the hwcap bits implied
    /// by its features over baseline.
    targets: []const std.Target.Query,
    optimize: std.builtin.OptimizeMode = .Debug,
    /// Wire the zig-out/bin/<name> install.
    install: bool = true,
};

/// chonk's `b.addExecutable`: one call, a list of compilation targets, one
/// fat binary out that picks a payload by CPU features at exec time. The
/// near-drop-in replacement, from another project's build.zig with this
/// repo as a `chonk` dependency:
///
///     const chonk = b.lazyImport(@This(), "chonk") orelse return;
///     _ = chonk.addExecutable(b, .{
///         .name = "app",
///         .root_source_file = b.path("src/main.zig"),
///         .optimize = optimize,
///         .targets = &.{
///             .{ .cpu_model = .{ .explicit = &Target.aarch64.cpu.neoverse_v2 } },
///             .{ .cpu_model = .baseline }, // the fallback
///         },
///     });
///
/// Returns the fat binary's LazyPath; installs it as zig-out/bin/<name>
/// unless `install = false`.
///
/// One fat binary per architecture: the trailer's machine field is a
/// species check, so call once per arch with that arch's targets.
pub fn addExecutable(b: *Build, options: ExecutableOptions) LazyPath {
    // Resolve every target; infer its dispatch bits; find the fallback.
    const targets = b.allocator.alloc(ResolvedTarget, options.targets.len) catch @panic("OOM");
    var fallback_count: usize = 0;
    for (options.targets, 0..) |query, i| {
        const resolved = b.resolveTargetQuery(query);
        const bits = inferBits(b, resolved.result);
        const fallback = isBaseline(resolved.result);
        if (fallback) {
            fallback_count += 1;
        } else if (bits.len == 0) {
            @panic(b.fmt(
                "chonk.addExecutable: target '{s}' maps to no hwcap bit",
                .{resolved.result.cpu.model.name},
            ));
        }
        targets[i] = .{
            .name = resolved.result.cpu.model.name,
            .resolved = resolved,
            .bits = bits,
            .fallback = fallback,
        };
    }
    if (fallback_count != 1) {
        @panic("chonk.addExecutable: exactly one target must be the arch " ++
            "baseline (the fallback) — e.g. .{ .cpu_model = .baseline }");
    }

    // The intermediates: one build per target, auto-named from the CPU
    // model, cache-only, never installed.
    const exes = b.allocator.alloc(*Step.Compile, targets.len) catch @panic("OOM");
    for (targets, 0..) |t, i| {
        exes[i] = b.addExecutable(.{
            .name = t.name,
            .root_module = b.createModule(.{
                .root_source_file = options.root_source_file,
                .target = t.resolved,
                .optimize = options.optimize,
            }),
        });
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
    const inputs = b.allocator.alloc(PackStep.Input, targets.len) catch @panic("OOM");
    for (targets, 0..) |t, i| {
        inputs[i] = .{
            .name = t.name,
            .payload = exes[i].getEmittedBin(),
            .bits = t.bits,
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
    for (exes) |exe| {
        pack_step.step.dependOn(&exe.step);
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
/// One resolved target: the auto-name, the resolved query, the inferred
/// dispatch bits, and whether it is the arch-baseline fallback.
const ResolvedTarget = struct {
    name: []const u8,
    resolved: std.Build.ResolvedTarget,
    bits: []const Bit,
    fallback: bool,
};

const PackStep = struct {
    step: Step,
    fat: Build.GeneratedFile,
    out_name: []const u8,
    stub: LazyPath,
    inputs: []Input,

    const Input = struct {
        name: []const u8,
        payload: LazyPath,
        /// Empty = the fallback.
        bits: []const Bit,
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
            for (input.bits) |bit| {
                man.hash.addBytes(@tagName(bit));
            }
            man.hash.addBytes("(end)");
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
            const match = try arena.alloc(pack.Match, input.bits.len);
            for (input.bits, 0..) |bit, j| {
                match[j] = .{ .bit = bit };
            }
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
