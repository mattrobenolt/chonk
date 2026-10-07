const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Step = Build.Step;
const Io = std.Io;
const Target = std.Target;
const aarch64 = Target.aarch64;
const x86 = Target.x86;
const OptimizeMode = std.builtin.OptimizeMode;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const resolveTargetQuery = std.zig.system.resolveTargetQuery;

const pack = @import("pack.zig");
/// The vocabulary shared with the ZON config — pack.zig is the one
/// definition; re-exported for consumer ergonomics.
pub const Match = pack.Match;
pub const midrPart = pack.midrPart;
pub const Bit = pack.Bit;
const stdio = @import("stdio.zig");
const x86_probe = @import("x86.zig");

// ---------------------------------------------------------------------------
// Build-system integration — usable from any project that depends on chonk.
// The pack logic runs IN-PROCESS (src/pack.zig via b.graph.io); the CLI is
// just the other consumer of the same module.
// ---------------------------------------------------------------------------

/// Bit → the Zig aarch64 target feature that implies it, where one exists.
/// The kernel vocabulary is finer-grained than LLVM's in three places
/// (svepmull, svei8mm, svebf16 have no Zig feature) — those stay
/// explicit-only (the ZON config's raw form).
/// Infer the dispatch conditions from a target: every inferable condition
/// whose feature the target has and the arch baseline lacks. aarch64
/// yields named hwcap bits. x86_64 yields CPUID features and the required XCR0 state.
fn inferMatches(arena: Allocator, target: Target) []const pack.Match {
    const cpu = target.cpu;
    const baseline = Target.Cpu.baseline(cpu.arch, target.os);
    var matches: std.ArrayList(pack.Match) = .empty;
    switch (cpu.arch) {
        // One table read (pack.aarch64_table): wire form + Zig feature
        // together, comptime-uniqueness-checked. A bit with no Zig feature
        // (pmull, sha1, ...) can not be inferred — explicit match only.
        .aarch64 => {
            inline for (pack.aarch64_table) |e| {
                if (e.feature) |feature| {
                    if (cpu.has(.aarch64, feature) and !baseline.has(.aarch64, feature)) {
                        matches.append(arena, .{ .bit = e.bit }) catch @panic("OOM");
                    }
                }
            }
        },
        .x86_64 => {
            inline for (pack.x86_table) |e| {
                if (cpu.has(.x86, e.feature) and !baseline.has(.x86, e.feature)) {
                    matches.append(arena, .{ .cpuid = e.cpuid }) catch @panic("OOM");
                }
            }
            const state_mask: u64 = if (cpu.has(.x86, .avx512f))
                x86_probe.avx512_state
            else if (cpu.has(.x86, .avx))
                x86_probe.avx_state
            else
                0;
            if (state_mask != 0) {
                matches.append(arena, .{
                    .source = .xcr0,
                    .mask = state_mask,
                    .expected = state_mask,
                }) catch @panic("OOM");
            }
        },
        else => @panic("chonk.addExecutable: unsupported arch (aarch64, x86_64)"),
    }
    return matches.toOwnedSlice(arena) catch @panic("OOM");
}

/// The fallback target: identical to the arch baseline. `.{ .target = .{} }`
/// is NOT this — it means native on the build machine, which on V2
/// hardware builds a V2 binary as the "fallback". Use
/// `.{ .cpu_model = .baseline }`.
fn isBaseline(target: Target) bool {
    const cpu = target.cpu;
    const baseline = Target.Cpu.baseline(cpu.arch, target.os);
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
fn modelArch(model: *const Target.Cpu.Model) ?Target.Cpu.Arch {
    const tables = .{
        .{ Target.Cpu.Arch.aarch64, Target.aarch64.cpu },
        .{ Target.Cpu.Arch.x86_64, Target.x86.cpu },
    };
    inline for (tables) |t| {
        const arch = t[0];
        const ns = t[1];
        inline for (comptime @typeInfo(ns).@"struct".decls) |decl| {
            if (@TypeOf(@field(ns, decl.name)) == Target.Cpu.Model) {
                if (&@field(ns, decl.name) == model) return arch;
            }
        }
    }
    return null;
}

/// One CPU model and its dispatch conditions.
pub const TargetSpec = struct {
    model: Target.Query.CpuModel,
    /// A nonempty match replaces inference. It must include every required ISA condition.
    match: []const pack.Match = &.{},
    /// These conditions supplement inference or the explicit match.
    /// Use this field for a MIDR tiebreak without removal of the ISA checks.
    extra_match: []const pack.Match = &.{},
};

fn targetMatches(arena: Allocator, target: Target, spec: TargetSpec) []const pack.Match {
    var matches: std.ArrayList(pack.Match) = .empty;
    const required = if (spec.match.len > 0) spec.match else inferMatches(arena, target);
    // Runtime match expressions can refer to stack temporaries. The graph owns the copies.
    matches.appendSlice(arena, required) catch @panic("OOM");
    matches.appendSlice(arena, spec.extra_match) catch @panic("OOM");
    return matches.toOwnedSlice(arena) catch @panic("OOM");
}

/// What chonk hands the consumer's executable factory (#1): everything a
/// variant's build needs — its auto-derived name, its per-variant resolved
/// target (skeleton plus model), the optimize mode.
pub const Variant = struct {
    name: []const u8,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
};

/// The consumer's per-variant executable factory (#1). Real builds wire
/// dependency modules (which resolve against a target, so they must be
/// re-created per variant), options modules, linked system libraries,
/// `use_llvm`, `strip`, frame pointers. The factory owns all of that;
/// chonk owns target resolution, condition inference, the fallback
/// append, the per-species stub, the pack, and the install. Name the
/// executable `v.name`; chonk never installs it.
pub const ExeFactory = *const fn (b: *Build, v: Variant) *Step.Compile;

/// The consumer's per-payload post-processor (#5): same Variant as the
/// factory gets, plus the compiled payload. Wire a Run step (patchelf,
/// strip, objcopy, signing) that consumes `payload` and return its output;
/// the pack depends on the returned path's producer automatically.
pub const PostProcess = *const fn (b: *Build, v: Variant, payload: LazyPath) LazyPath;

pub const ExecutableOptions = struct {
    /// Optional per-payload post-processor (#5): called once per variant
    /// after its compile, with the emitted binary; the returned LazyPath is
    /// what gets packed. patchelf the interpreter (the NixOS loader trap),
    /// force old dtags, sign, or compress — the hook owns the payload
    /// between compile and pack. Return `payload` unchanged to pass
    /// through.
    post_process: ?PostProcess = null,
    /// The fat binary's name — the ONLY name. Installed as
    /// zig-out/bin/<name>; intermediates auto-name from their CPU models.
    name: []const u8,
    /// The same source for every target. Mutually exclusive with
    /// `make_exe`; exactly one is required.
    root_source_file: ?LazyPath = null,
    /// The per-variant executable factory (#1). When set, chonk calls it
    /// once per variant — plus the implicit baseline fallback — instead of
    /// building from `root_source_file`.
    make_exe: ?ExeFactory = null,
    /// The shared target skeleton — arch, OS, abi, any shared feature
    /// tweaks. This is the SPECIES of the fat binary; every model in
    /// `targets` builds on it, so mixed-arch lists are impossible.
    target: Target.Query,
    /// Per-target specs — the model is the only thing that varies.
    /// `.baseline` is the fallback (exactly one required); it
    /// unambiguously means the skeleton arch's baseline, never "native
    /// on the build machine".
    targets: []const TargetSpec,
    optimize: OptimizeMode = .Debug,
    /// Wire the zig-out/bin/<name> install.
    install: bool = true,
};

/// chonk's `b.addExecutable`: one call, a list of compilation targets, one
/// fat binary out that picks a payload by CPU features at exec time. The
/// near-drop-in replacement, from another project's build.zig with this
/// repo as a `chonk` dependency:
///
///     const chonk = @import("chonk");
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
    if (options.targets.len == 0) {
        @panic("chonk.addExecutable: list at least one variant target — " ++
            "the arch-baseline fallback is appended automatically");
    }
    if (options.make_exe == null and options.root_source_file == null) {
        @panic("chonk.addExecutable: set root_source_file or make_exe");
    }
    if (options.make_exe != null and options.root_source_file != null) {
        @panic("chonk.addExecutable: root_source_file and make_exe are " ++
            "mutually exclusive");
    }

    // Resolve every model onto the shared skeleton; infer or take its
    // dispatch conditions; find the fallback. The skeleton fixes the
    // species, so mixed-arch builds are impossible by construction. One
    // slot is held for the implicit arch-baseline fallback, used when no
    // listed target is itself the fallback — the baseline is always
    // derivable from the skeleton, so requiring it explicitly would be
    // ceremony.
    const targets = b.allocator.alloc(ResolvedTarget, options.targets.len + 1) catch @panic("OOM");
    var used: usize = 0;
    var fallback_count: usize = 0;
    for (options.targets) |spec| {
        const model = spec.model;
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
        const match = targetMatches(b.allocator, resolved.result, spec);
        const fallback = isBaseline(resolved.result);
        if (fallback) {
            fallback_count += 1;
        } else if (match.len == 0) {
            @panic(b.fmt(
                "chonk.addExecutable: target '{s}' maps to no dispatchable feature; " ++
                    "set an explicit match or pick a model with a mapped feature delta",
                .{resolved.result.cpu.model.name},
            ));
        }
        targets[used] = .{
            .name = resolved.result.cpu.model.name,
            .resolved = resolved,
            .match = match,
            .fallback = fallback,
        };
        used += 1;
    }
    if (fallback_count > 1) {
        @panic("chonk.addExecutable: at most one baseline target — it is the " ++
            "fallback; with none listed, the arch baseline is appended automatically");
    }
    if (fallback_count == 0) {
        var query = options.target;
        query.cpu_model = .baseline;
        const resolved = b.resolveTargetQuery(query);
        targets[used] = .{
            .name = resolved.result.cpu.model.name,
            .resolved = resolved,
            .match = inferMatches(b.allocator, resolved.result),
            .fallback = true,
        };
        used += 1;
    }
    const variants = targets[0..used];

    // The intermediates: one build per target, auto-named from the CPU
    // model, cache-only, never installed. With make_exe (#1), the consumer's
    // factory builds each variant — dependencies, linked libraries, and
    // compile options resolve against the per-variant target, so every
    // variant needs its own module; the factory is called once per variant
    // with everything it needs. Without it, the simple root_source_file
    // path — one source, no imports.
    const exes = b.allocator.alloc(*Step.Compile, variants.len) catch @panic("OOM");
    for (variants, 0..) |t, i| {
        if (options.make_exe) |make| {
            exes[i] = make(b, .{
                .name = t.name,
                .target = t.resolved,
                .optimize = options.optimize,
            });
        } else {
            exes[i] = b.addExecutable(.{
                .name = t.name,
                .root_module = b.createModule(.{
                    .root_source_file = options.root_source_file.?,
                    .target = t.resolved,
                    .optimize = options.optimize,
                }),
            });
        }
    }

    // The freestanding stub for THIS species, compiled into THIS build
    // graph from source. Compiled-once-forever: always ReleaseSmall +
    // stripped, regardless of the consumer's optimize setting. The
    // skeleton's resolved arch decides.
    const dep = b.dependency("chonk", .{});
    const species = b.resolveTargetQuery(options.target).result.cpu.arch;
    const stub_target: Target.Query = switch (species) {
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

    // The post-compile hook (#5): called once per variant with what
    // make_exe/root_source_file built; the returned LazyPath is what gets
    // packed. A Run-step output rewrites the payload between compile and
    // pack; `payload` passes through unchanged.
    const pack_step = b.allocator.create(PackStep) catch @panic("OOM");
    const inputs = b.allocator.alloc(PackStep.Input, variants.len) catch @panic("OOM");
    for (variants, 0..) |t, i| {
        var payload = exes[i].getEmittedBin();
        if (options.post_process) |post| {
            payload = post(b, .{
                .name = t.name,
                .target = t.resolved,
                .optimize = options.optimize,
            }, payload);
        }
        inputs[i] = .{
            .name = t.name,
            .payload = payload,
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

    // The pack runs after the stub + every variant compiles + every
    // hook output's producer. LazyPath carries no step accessor in 0.16,
    // so pull the producer off the generated tag; static paths have no
    // producer.
    pack_step.step.dependOn(&stub.step);
    for (exes) |exe| {
        pack_step.step.dependOn(&exe.step);
    }
    for (inputs) |input| {
        if (producerStep(input.payload)) |producer| {
            pack_step.step.dependOn(producer);
        }
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

/// The step that produces a LazyPath, for generated paths; static paths
/// (src, cwd, dependency) have no producer — the file exists by pack time
/// or the pack fails.
fn producerStep(payload: LazyPath) ?*Step {
    return switch (payload) {
        .generated => |g| g.file.step,
        else => null,
    };
}

/// Packs a fat binary in-process: the same module the CLI uses, run by the
/// build runner with b.graph.io — no subprocess, no argv marshalling.
/// One resolved target: the auto-name, the resolved query, the inferred
/// dispatch bits, and whether it is the arch-baseline fallback.
const ResolvedTarget = struct {
    name: []const u8,
    resolved: Build.ResolvedTarget,
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

        defer stdio.flush();
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

test "extra_match retains inferred ISA checks and owns caller conditions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try resolveTargetQuery(testing.io, .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .cpu_model = .{ .explicit = &aarch64.cpu.neoverse_v3 },
    });
    const inferred = inferMatches(arena, target);
    var extra = [_]pack.Match{midrPart(0x41, 0xd84)};
    const matches = targetMatches(arena, target, .{
        .model = .{ .explicit = &aarch64.cpu.neoverse_v3 },
        .extra_match = &extra,
    });
    try testing.expectEqual(inferred.len + 1, matches.len);
    try testing.expectEqualSlices(pack.Match, inferred, matches[0..inferred.len]);
    var found_sve = false;
    var found_sve2 = false;
    for (matches) |m| {
        if (m.bit == .sve) found_sve = true;
        if (m.bit == .sve2) found_sve2 = true;
    }
    try testing.expect(found_sve);
    try testing.expect(found_sve2);
    extra[0] = midrPart(0x41, 0xd0c);
    try testing.expectEqual(midrPart(0x41, 0xd84), matches[inferred.len]);
}

test "explicit match still overrides inference and accepts extra conditions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try resolveTargetQuery(testing.io, .{ .cpu_arch = .aarch64, .os_tag = .linux });
    var explicit = [_]pack.Match{.{ .bit = .sve }};
    const matches = targetMatches(arena, target, .{
        .model = .baseline,
        .match = &explicit,
        .extra_match = &.{midrPart(0x41, 0xd84)},
    });
    try testing.expectEqual(@as(u32, 2), matches.len);
    explicit[0] = .{ .bit = .sve2 };
    try testing.expectEqual(pack.Match{ .bit = .sve }, matches[0]);
    try testing.expectEqual(midrPart(0x41, 0xd84), matches[1]);
}

test "x86 inference requires the OS state for each psABI vector tier" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tiers = .{
        .{ &x86.cpu.x86_64, @as(u64, 0) },
        .{ &x86.cpu.x86_64_v2, @as(u64, 0) },
        .{ &x86.cpu.x86_64_v3, @as(u64, 0x6) },
        .{ &x86.cpu.x86_64_v4, @as(u64, 0xe6) },
    };
    inline for (tiers) |tier| {
        const target = try resolveTargetQuery(testing.io, .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .cpu_model = .{ .explicit = tier[0] },
        });
        const matches = inferMatches(arena, target);
        var state_count: u32 = 0;
        var xsave_count: u32 = 0;
        for (matches) |m| {
            if (m.source == .xcr0) {
                state_count += 1;
                try testing.expectEqual(tier[1], m.mask.?);
                try testing.expectEqual(tier[1], m.expected.?);
            }
            if (m.cpuid) |c| {
                if (c.leaf == 1 and c.register == .ecx and c.bit == 26) xsave_count += 1;
            }
        }
        const expected_count: u32 = if (tier[1] == 0) 0 else 1;
        try testing.expectEqual(expected_count, state_count);
        try testing.expectEqual(expected_count, xsave_count);
    }
}
