const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Step = Build.Step;
const Target = std.Target;
const aarch64 = Target.aarch64;
const x86 = Target.x86;
const Optimize = std.lang.Optimize;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const resolveTargetQuery = std.zig.system.resolveTargetQuery;

const pack = @import("pack.zig");
/// The vocabulary shared with the ZON config — pack.zig is the one
/// definition; re-exported for consumer ergonomics.
pub const Match = pack.Match;
pub const midrPart = pack.midrPart;
pub const Bit = pack.Bit;
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
fn inferMatches(arena: Allocator, target: Target) []const Match {
    const cpu = target.cpu;
    const baseline = Target.Cpu.baseline(cpu.arch, target.os);
    var matches: std.ArrayList(Match) = .empty;
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
        .{ Target.Cpu.Arch.aarch64, aarch64.cpu },
        .{ Target.Cpu.Arch.x86_64, x86.cpu },
    };
    inline for (tables) |t| {
        const arch = t[0];
        const ns = t[1];
        inline for (comptime @typeInfo(ns).@"struct".decl_names) |decl_name| {
            if (@TypeOf(@field(ns, decl_name)) == Target.Cpu.Model) {
                if (&@field(ns, decl_name) == model) return arch;
            }
        }
    }
    return null;
}

/// One CPU model and its dispatch conditions.
pub const TargetSpec = struct {
    model: Target.Query.CpuModel,
    /// A nonempty match replaces inference. It must include every required ISA condition.
    match: []const Match = &.{},
    /// These conditions supplement inference or the explicit match.
    /// Use this field for a MIDR tiebreak without removal of the ISA checks.
    extra_match: []const Match = &.{},
};

fn targetMatches(arena: Allocator, target: Target, spec: TargetSpec) []const Match {
    var matches: std.ArrayList(Match) = .empty;
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
    optimize: Optimize,
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
    optimize: Optimize = .debug,
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
/// per arch with that arch's models. For separate payload files and a plain
/// execve at run time, use `addFilesExecutable`.
pub fn addExecutable(b: *Build, options: ExecutableOptions) LazyPath {
    const prepared = prepare(b, options, .embedded);

    const pack_cmd = b.addRunArtifact(prepared.tool);
    pack_cmd.addArg("pack");
    pack_cmd.addFileArg(prepared.stub);
    pack_cmd.addFileArg(prepared.config);
    const fat = pack_cmd.addOutputFileArg(options.name);

    if (options.install) {
        const install = b.addInstallFileWithDir(fat, .bin, options.name);
        b.getInstallStep().dependOn(&install.step);
    }
    return fat;
}

/// The files-mode door: same options, but the output is a shim plus payload
/// files that stay separate. The shim carries the variant table and, at run
/// time, `execve`s `<shim>.d/<variant>` beside itself — no memfd and no
/// `execveat`, so path-based LSM profiles (AppArmor) can name each payload.
///
/// With `install = true`, installs the shim as `zig-out/bin/<name>` and each
/// payload as `zig-out/bin/<name>.d/<variant name>`. With `install = false`,
/// installs nothing and returns both pieces so the caller can reproduce that
/// layout in its own step:
///
///     const files = chonk.addFilesExecutable(b, .{ ... .install = false });
///     const step = b.step("files", "Build the files-mode fleet");
///     step.dependOn(&b.addInstallFileWithDir(files.shim, .bin, "app").step);
///     for (files.payloads) |p| {
///         const install = b.addInstallFileWithDir(
///             p.path, .bin, b.fmt("app.d/{s}", .{p.name}));
///         step.dependOn(&install.step);
///     }
///
/// The silent failure mode is installing the shim without its directory (or
/// under a different basename than the directory): the shim then reports
/// `execve payload: ENOENT` with the path it tried.
pub fn addFilesExecutable(b: *Build, options: ExecutableOptions) FilesExecutable {
    const prepared = prepare(b, options, .files);

    // --no-copy: the payloads are installed from the compile artifacts, so
    // the packer writes only the shim.
    const pack_cmd = b.addRunArtifact(prepared.tool);
    pack_cmd.addArg("pack");
    pack_cmd.addArg("--files");
    pack_cmd.addArg("--no-copy");
    pack_cmd.addFileArg(prepared.stub);
    pack_cmd.addFileArg(prepared.config);
    const shim = pack_cmd.addOutputFileArg(options.name);

    const payloads = b.allocator.alloc(Payload, prepared.variants.len) catch @panic("OOM");
    for (prepared.variants, 0..) |t, i| {
        payloads[i] = .{ .name = t.name, .path = prepared.payloads[i] };
    }

    if (options.install) {
        const install_shim = b.addInstallFileWithDir(shim, .bin, options.name);
        b.getInstallStep().dependOn(&install_shim.step);
        for (payloads) |payload| {
            const install = b.addInstallFileWithDir(
                payload.path,
                .bin,
                b.fmt("{s}.d/{s}", .{ options.name, payload.name }),
            );
            b.getInstallStep().dependOn(&install.step);
        }
    }

    return .{ .shim = shim, .payloads = payloads };
}

/// What both doors share: validate the options, resolve the fleet onto the
/// skeleton, compile every variant, run post_process, and stage the config
/// the packer reads. `mode` selects the stub artifact.
const Prepared = struct {
    variants: []const ResolvedTarget,
    /// Post-processed payload binaries, one per variant, in table order.
    payloads: []const LazyPath,
    /// The generated config naming the payload copies.
    config: LazyPath,
    /// The species stub for the mode, copied into the generated directory.
    stub: LazyPath,
    /// The `chonk` CLI, which does the actual pack.
    tool: *Step.Compile,
};

fn prepare(b: *Build, options: ExecutableOptions, mode: pack.Mode) Prepared {
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

    // The stub for THIS species and mode, compiled by chonk's own build
    // (always ReleaseSmall + stripped, compiled once for every consumer).
    // The skeleton's resolved arch decides.
    const dep = b.dependency("chonk", .{});
    const species = b.resolveTargetQuery(options.target).result.cpu.arch;
    const stub = dep.artifact(stubArtifact(species, mode));

    // The pack is the CLI's work: 0.17 executes a fixed set of steps by tag,
    // so a build script has no way to run code itself. The payloads and the
    // stub are copied into one generated directory beside a config that
    // names them, and `chonk pack` writes the output as the run step's
    // file. The run step's manifest hashes the argv, the copied payloads,
    // the stub, and the config text, so a changed payload, match, or stub
    // re-packs.
    const files = b.addWriteFiles();
    const files_variants = b.allocator.alloc(pack.Variant, variants.len) catch @panic("OOM");
    const payloads = b.allocator.alloc(LazyPath, variants.len) catch @panic("OOM");
    for (variants, 0..) |t, i| {
        var payload = exes[i].getEmittedBin();
        if (options.post_process) |post| {
            payload = post(b, .{
                .name = t.name,
                .target = t.resolved,
                .optimize = options.optimize,
            }, payload);
        }
        payloads[i] = payload;
        const sub_path = b.fmt("payload-{d}", .{i});
        _ = files.addCopyFile(payload, sub_path);
        files_variants[i] = .{
            .name = t.name,
            .binary = sub_path,
            .match = t.match,
        };
    }
    const config = files.add(
        "config.zon",
        pack.configZon(b.allocator, .{ .variants = files_variants }),
    );

    return .{
        .variants = variants,
        .payloads = payloads,
        .config = config,
        .stub = files.addCopyFile(stub.getEmittedBin(), "stub"),
        .tool = dep.artifact("chonk"),
    };
}

/// The stub artifact for a species and trailer mode. File mode builds a
/// separate stub so its exec path (plain execve of a path) and the embedded
/// path (memfd + execveat) never share a binary.
fn stubArtifact(arch: Target.Cpu.Arch, mode: pack.Mode) []const u8 {
    return switch (arch) {
        .aarch64 => if (mode == .files) "stub-aarch64-files" else "stub-aarch64",
        .x86_64 => if (mode == .files) "stub-x86_64-files" else "stub-x86_64",
        else => @panic("chonk.addExecutable: unsupported arch"),
    };
}

/// One payload file in files mode.
pub const Payload = struct {
    /// The variant name, which is also the file name under `<shim>.d/`.
    name: []const u8,
    /// The compiled (and post-processed) payload binary.
    path: LazyPath,
};

/// What `addFilesExecutable` returns: the shim and the payload files it
/// execs. Install the shim as `bin/<name>` and each payload as
/// `bin/<name>.d/<payload.name>` — anywhere else and the shim cannot find
/// them.
pub const FilesExecutable = struct {
    shim: LazyPath,
    payloads: []const Payload,
};

/// One resolved target: the auto-name, the resolved query, the inferred
/// dispatch bits, and whether it is the arch-baseline fallback.
const ResolvedTarget = struct {
    name: []const u8,
    resolved: Build.ResolvedTarget,
    match: []const Match,
    fallback: bool,
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
    var extra = [_]Match{midrPart(0x41, 0xd84)};
    const matches = targetMatches(arena, target, .{
        .model = .{ .explicit = &aarch64.cpu.neoverse_v3 },
        .extra_match = &extra,
    });
    try testing.expectEqual(inferred.len + 1, matches.len);
    try testing.expectEqualSlices(Match, inferred, matches[0..inferred.len]);
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
    var explicit = [_]Match{.{ .bit = .sve }};
    const matches = targetMatches(arena, target, .{
        .model = .baseline,
        .match = &explicit,
        .extra_match = &.{midrPart(0x41, 0xd84)},
    });
    try testing.expectEqual(@as(u32, 2), matches.len);
    explicit[0] = .{ .bit = .sve2 };
    try testing.expectEqual(Match{ .bit = .sve }, matches[0]);
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
