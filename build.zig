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
const x86 = std.Target.x86;

/// Bit → the Zig aarch64 target feature that implies it, where one exists.
/// The kernel vocabulary is finer-grained than LLVM's in three places
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

/// Zig x86_64 feature → the CPUID (leaf, subleaf, register, bit) that
/// advertises it, curated to the psABI-level-defining set (x86-64
/// v2/v3/v4). Locations pinned from the x86-64 psABI / Intel SDM.
fn cpuidSpec(feature: x86.Feature) ?pack.Cpuid {
    return switch (feature) {
        // CPUID.1H:ECX
        .ssse3 => .{ .leaf = 1, .register = .ecx, .bit = 9 },
        .cx16 => .{ .leaf = 1, .register = .ecx, .bit = 13 },
        .sse4_1 => .{ .leaf = 1, .register = .ecx, .bit = 19 },
        .sse4_2 => .{ .leaf = 1, .register = .ecx, .bit = 20 },
        .fma => .{ .leaf = 1, .register = .ecx, .bit = 12 },
        .movbe => .{ .leaf = 1, .register = .ecx, .bit = 22 },
        .popcnt => .{ .leaf = 1, .register = .ecx, .bit = 23 },
        .aes => .{ .leaf = 1, .register = .ecx, .bit = 25 },
        .avx => .{ .leaf = 1, .register = .ecx, .bit = 28 },
        .f16c => .{ .leaf = 1, .register = .ecx, .bit = 29 },
        // CPUID.7H.0H:EBX
        .bmi => .{ .leaf = 7, .register = .ebx, .bit = 3 },
        .avx2 => .{ .leaf = 7, .register = .ebx, .bit = 5 },
        .bmi2 => .{ .leaf = 7, .register = .ebx, .bit = 8 },
        .avx512f => .{ .leaf = 7, .register = .ebx, .bit = 16 },
        .avx512dq => .{ .leaf = 7, .register = .ebx, .bit = 17 },
        .avx512cd => .{ .leaf = 7, .register = .ebx, .bit = 28 },
        .avx512bw => .{ .leaf = 7, .register = .ebx, .bit = 30 },
        .avx512vl => .{ .leaf = 7, .register = .ebx, .bit = 31 },
        // CPUID.80000001H:ECX
        .sahf => .{ .leaf = 0x8000_0001, .register = .ecx, .bit = 0 },
        .lzcnt => .{ .leaf = 0x8000_0001, .register = .ecx, .bit = 5 },
        else => null,
    };
}

/// Infer the dispatch conditions from a target: every inferable condition
/// whose feature the target has and the arch baseline lacks. aarch64
/// yields named hwcap bits; x86_64 yields CPUID feature tests.
fn inferMatches(b: *Build, target: std.Target) []const pack.Match {
    const cpu = target.cpu;
    const baseline = std.Target.Cpu.baseline(cpu.arch, target.os);
    var matches: std.ArrayList(pack.Match) = .empty;
    switch (cpu.arch) {
        .aarch64 => {
            inline for (comptime std.enums.values(Bit)) |bit| {
                if (zigFeature(bit)) |feature| {
                    if (cpu.has(.aarch64, feature) and !baseline.has(.aarch64, feature)) {
                        matches.append(b.allocator, .{ .bit = bit }) catch @panic("OOM");
                    }
                }
            }
        },
        .x86_64 => {
            inline for (comptime std.enums.values(x86.Feature)) |feature| {
                if (cpuidSpec(feature)) |c| {
                    if (cpu.has(.x86, feature) and !baseline.has(.x86, feature)) {
                        matches.append(b.allocator, .{ .cpuid = c }) catch @panic("OOM");
                    }
                }
            }
        },
        else => @panic("chonk.addExecutable: unsupported arch (aarch64, x86_64)"),
    }
    return matches.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// The fallback target: identical to the arch baseline. `.{ .target = .{} }`
/// is NOT this — it means native on the build machine, which on V2
/// hardware builds a V2 binary as the "fallback". Use
/// `.{ .cpu_model = .baseline }`.
fn isBaseline(target: std.Target) bool {
    const cpu = target.cpu;
    const baseline = std.Target.Cpu.baseline(cpu.arch, target.os);
    switch (cpu.arch) {
        .aarch64 => {
            inline for (comptime std.enums.values(aarch64.Feature)) |feature| {
                if (cpu.has(.aarch64, feature) != baseline.has(.aarch64, feature)) {
                    return false;
                }
            }
        },
        .x86_64 => {
            inline for (comptime std.enums.values(x86.Feature)) |feature| {
                if (cpu.has(.x86, feature) != baseline.has(.x86, feature)) {
                    return false;
                }
            }
        },
        else => return false,
    }
    return true;
}

/// `chonk.addExecutable` options — the `b.addExecutable` shape with the
/// name and a target list instead of a single target.
/// Which arch's model table does this model come from? The records carry
/// no arch — the tables do (Target.<arch>.cpu.*). Comptime-scanned, the
/// pointers compared at graph time.
/// Which arch's model table does this model come from? The records carry
/// no arch — the tables do (Target.<arch>.cpu.*). Comptime-scanned, the
/// pointers compared at graph time. Without this check, a copy-pasted
/// model from another arch silently builds garbage.
fn modelArch(model: *const std.Target.Cpu.Model) ?std.Target.Cpu.Arch {
    const tables = .{
        .{ std.Target.Cpu.Arch.aarch64, std.Target.aarch64.cpu },
        .{ std.Target.Cpu.Arch.x86_64, std.Target.x86.cpu },
    };
    inline for (tables) |t| {
        const arch = t[0];
        const ns = t[1];
        inline for (comptime @typeInfo(ns).@"struct".decls) |decl| {
            if (@TypeOf(@field(ns, decl.name)) == std.Target.Cpu.Model) {
                if (&@field(ns, decl.name) == model) return arch;
            }
        }
    }
    return null;
}

pub const ExecutableOptions = struct {
    /// The fat binary's name — the ONLY name. Installed as
    /// zig-out/bin/<name>; intermediates auto-name from their CPU models.
    name: []const u8,
    /// The same source for every target.
    root_source_file: LazyPath,
    /// The shared target skeleton — arch, OS, abi, any shared feature
    /// tweaks. This is the SPECIES of the fat binary; every model in
    /// `targets` builds on it, so mixed-arch lists are impossible.
    target: std.Target.Query,
    /// Per-target CPU models — the only thing that varies. `.baseline` is
    /// the fallback (exactly one required); it unambiguously means the
    /// skeleton arch's baseline, never "native on the build machine".
    targets: []const std.Target.Query.CpuModel,
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
///         .target = .{ .cpu_arch = .aarch64, .abi = .musl },
///         .optimize = optimize,
///         .targets = &.{
///             .{ .explicit = &Target.aarch64.cpu.neoverse_v2 },
///             .baseline, // the fallback
///         },
///     });
///
/// Returns the fat binary's LazyPath; installs it as zig-out/bin/<name>
/// unless `install = false`.
///
/// One fat binary per species: the skeleton's arch decides, so call once
/// per arch with that arch's models.
pub fn addExecutable(b: *Build, options: ExecutableOptions) LazyPath {
    // Resolve every model onto the shared skeleton; infer its dispatch
    // conditions; find the fallback. The skeleton fixes the species, so
    // mixed-arch builds are impossible by construction.
    const targets = b.allocator.alloc(ResolvedTarget, options.targets.len) catch @panic("OOM");
    var fallback_count: usize = 0;
    for (options.targets, 0..) |model, i| {
        if (model == .explicit and options.target.cpu_arch != null) {
            // Model records carry no arch — the tables are namespaced by
            // arch, so scan them and compare pointers. Without this, a
            // copy-pasted model from another arch silently builds garbage.
            const implied = modelArch(model.explicit);
            if (implied != null and implied.? != options.target.cpu_arch.?) {
                const skeleton_arch = @tagName(options.target.cpu_arch.?);
                @panic(b.fmt(
                    "chonk.addExecutable: model '{s}' is {s}, not {s}",
                    .{ model.explicit.name, @tagName(implied.?), skeleton_arch },
                ));
            }
        }
        var query = options.target;
        query.cpu_model = model;
        const resolved = b.resolveTargetQuery(query);
        const match = inferMatches(b, resolved.result);
        const fallback = isBaseline(resolved.result);
        if (fallback) {
            fallback_count += 1;
        } else if (match.len == 0) {
            @panic(b.fmt(
                "chonk.addExecutable: target '{s}' maps to no dispatchable feature",
                .{resolved.result.cpu.model.name},
            ));
        }
        targets[i] = .{
            .name = resolved.result.cpu.model.name,
            .resolved = resolved,
            .match = match,
            .fallback = fallback,
        };
    }
    if (fallback_count != 1) {
        @panic("chonk.addExecutable: exactly one target must be the arch " ++
            "baseline (the fallback) — the bare .baseline model");
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

    // The freestanding stub for THIS species, compiled into THIS build
    // graph from source. Compiled-once-forever: always ReleaseSmall +
    // stripped, regardless of the consumer's optimize setting. The
    // skeleton's resolved arch decides.
    const dep = b.dependency("chonk", .{});
    const species = b.resolveTargetQuery(options.target).result.cpu.arch;
    const stub_target: std.Target.Query = switch (species) {
        .aarch64 => .{ .cpu_arch = .aarch64, .os_tag = .freestanding },
        .x86_64 => .{ .cpu_arch = .x86_64, .os_tag = .freestanding },
        else => @panic("chonk.addExecutable: unsupported arch"),
    };
    const stub = b.addExecutable(.{
        .name = "stub",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/stub.zig"),
            .target = b.resolveTargetQuery(stub_target),
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
            .match = t.match,
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
    match: []const pack.Match,
    fallback: bool,
};

/// Hash one match into a manifest — the match's full meaning, so a
/// condition change re-packs.
fn hashMatch(man: *Build.Cache.Manifest, m: pack.Match) void {
    if (m.bit) |bit| {
        man.hash.addBytes(@tagName(bit));
    } else if (m.cpuid) |c| {
        man.hash.add(c.leaf);
        man.hash.add(c.subleaf);
        man.hash.add(@intFromEnum(c.register));
        man.hash.add(c.bit);
    } else if (m.source) |source| {
        man.hash.add(@intFromEnum(source));
        if (m.mask) |mask| man.hash.add(mask);
        if (m.expected) |expected| man.hash.add(expected);
    } else {
        man.hash.addBytes("(unconditional)");
    }
}

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
        match: []const pack.Match,
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
            for (input.match) |m| {
                hashMatch(&man, m);
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
            variants[i] = .{
                .name = input.name,
                .binary = input.payload.getPath2(b, step),
                .match = input.match,
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
