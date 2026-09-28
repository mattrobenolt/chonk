set minimum-version := "1.55.0"

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Full e2e: build, both pack doors, the tier matrix, x86 selection, the
# factory, and the error paths. The default recipe.
default: build pack-cli consumer tiers x86-select factory errors

# Build the CLI and both stubs, run the unit tests, lint.
build:
    zig build
    zig build test --summary all
    ziglint src/ build.zig
    @echo "ok: build"

# CLI door: pack example.zon (dedup visible), inspect it, dispatch (the
# sve2 tier wins on this hardware; exit 2 is the dispatched chonk's own
# usage exit code passed through the wait status).
pack-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache/e2e
    ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 example.zon \
        .zig-cache/e2e/example-fat | grep -q "2 unique payload(s)"
    ./zig-out/bin/chonk inspect .zig-cache/e2e/example-fat \
        | grep -q "machine aarch64, 3 variants"
    rc=0; out=$(timeout 60 .zig-cache/e2e/example-fat 2>&1) || rc=$?
    grep -q "usage: chonk" <<<"$out"
    test "$rc" -eq 2
    echo "ok: pack-cli"

# Build-system door: the consumer example end to end — normal build,
# run, the two-species release fleet, native dispatch, inspect both species.
consumer:
    #!/usr/bin/env bash
    set -euo pipefail
    cd examples/consumer
    zig build --summary all
    ./zig-out/bin/app | grep -q "app built for CPU model"
    zig build run | grep -q "app built for CPU model"
    zig build chonk --summary all
    ./zig-out/bin/app | grep -q "app built for CPU model: neoverse"
    ../..//zig-out/bin/chonk inspect zig-out/bin/app \
        | grep -q "machine aarch64, 5 variants"
    ../..//zig-out/bin/chonk inspect zig-out/bin/app-x86_64 \
        | grep -q "machine x86_64, 2 variants"
    echo "ok: consumer"

# The aarch64 tier matrix under controlled CPU identities: native (V3
# hardware, MIDR tiebreak), qemu max (sve2), neoverse-v1 (sve, no sve2),
# neoverse-n1 (base word), cortex-a72 (nothing). Each tier has a distinct
# tracer payload: bash echoes, multicall true reports argv[0], chonk prints
# usage (exit 2).
tiers:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache/e2e
    cat > .zig-cache/e2e/tiers.zon <<ZON
    .{ .variants = .{
        .{ .name = "v2-tier", .binary = "/run/current-system/sw/bin/bash", .match = .{ .{ .bit = .sve2 } } },
        .{ .name = "v1-tier", .binary = "/run/current-system/sw/bin/true", .match = .{ .{ .bit = .sve } } },
        .{ .binary = "{{ justfile_directory() }}/zig-out/bin/chonk" },
    } }
    ZON
    ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 .zig-cache/e2e/tiers.zon \
        .zig-cache/e2e/fat-tiers > /dev/null
    rc=0; out=$(timeout 60 .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash' 2>&1) || rc=$?
    grep -q "TIER-v2-bash" <<<"$out"; test "$rc" -eq 0
    echo "ok: tiers native (v2 tier, bash tracer)"
    rc=0; out=$(timeout 60 qemu-aarch64 -cpu max .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash' 2>&1) || rc=$?
    grep -q "TIER-v2-bash" <<<"$out"; test "$rc" -eq 0
    echo "ok: tiers qemu max (first-match ordering: sve2 tier beats sve tier)"
    rc=0; out=$(timeout 60 qemu-aarch64 -cpu neoverse-v1 .zig-cache/e2e/fat-tiers -c x 2>&1) || rc=$?
    grep -q "coreutils: unknown program" <<<"$out"; test "$rc" -eq 1
    echo "ok: tiers qemu neoverse-v1 (v1 tier, multicall true tracer)"
    rc=0; out=$(timeout 60 qemu-aarch64 -cpu neoverse-n1 .zig-cache/e2e/fat-tiers -c x 2>&1) || rc=$?
    grep -q "usage: chonk" <<<"$out"; test "$rc" -eq 2
    echo "ok: tiers qemu neoverse-n1 (fallback: qemu's n1 does not advertise sve)"
    rc=0; out=$(timeout 60 qemu-aarch64 -cpu cortex-a72 .zig-cache/e2e/fat-tiers -c x 2>&1) || rc=$?
    grep -q "usage: chonk" <<<"$out"; test "$rc" -eq 2
    echo "ok: tiers qemu cortex-a72 (fallback, chonk tracer, exit 2)"

# The x86_64 selection paths under qemu: both CPU identities select a
# payload (different sendfile sizes), and the documented emulation wall
# (foreign-arch execveat, errno 8) holds. Needs the consumer fleet.
x86-select: consumer
    #!/usr/bin/env bash
    set -euo pipefail
    fat=examples/consumer/zig-out/bin/app-x86_64
    trace() { timeout 60 qemu-x86_64 -strace "$@" "$fat" 2>&1; }
    # Capture the full trace per identity — grep -m1 on a live qemu pipe
    # closes it early and qemu dies to SIGPIPE under pipefail (141).
    # qemu always exits nonzero here — the stub hits the emulation wall
    # and exits 1 — so the capture must not abort on it.
    t1=$(trace -cpu max) || true
    t2=$(trace -cpu qemu64,-avx2,-fma,-popcnt,-sse4.2,-sse4.1,-ssse3) || true
    l1=$(grep -m1 "sendfile" <<<"$t1")
    l2=$(grep -m1 "sendfile" <<<"$t2")
    s1=${l1##*= }
    s2=${l2##*= }
    test -n "$s1" -a -n "$s2"
    test "$s1" != "$s2"
    grep -q "execveat.*errno=8" <<<"$t1"
    echo "ok: x86-select ($s1 vs $s2 — both selection paths; wall errno=8)"

# The make_exe factory (#1): a handoff-shaped consumer with a dependency
# module, per-variant imports, and exe-level flags — the paths the simple
# root_source_file shape cannot express.
factory:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .zig-cache/e2e/factory
    mkdir -p .zig-cache/e2e/factory/src .zig-cache/e2e/factory/lib
    ln -sfn "{{ justfile_directory() }}" .zig-cache/e2e/factory/lib/chonk
    cd .zig-cache/e2e/factory
    cat > build.zig.zon <<ZON
    .{
        .name = .factory,
        .version = "0.0.0",
        .fingerprint = 0xfb361ef9e71c0392,
        .minimum_zig_version = "0.16.0",
        .dependencies = .{
            .chonk = .{ .path = "lib/chonk" },
        },
        .paths = .{ "build.zig", "build.zig.zon", "src" },
    }
    ZON
    cat > build.zig <<ZIG
    const std = @import("std");
    const Build = std.Build;
    const chonk = @import("chonk");

    pub fn build(b: *Build) void {
        const fat = chonk.addExecutable(b, .{
            .name = "app",
            .target = .{ .cpu_arch = .aarch64, .abi = .musl },
            .optimize = .Debug,
            .install = true,
            .make_exe = makeExe,
            .targets = &.{
                .{ .model = .{ .explicit = &std.Target.aarch64.cpu.neoverse_v2 } },
            },
        });
        _ = fat;
    }

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
    ZIG
    cat > src/main.zig <<ZIG
    const std = @import("std");
    const helper = @import("helper");

    pub fn main(init: std.process.Init) !void {
        var buf: [256]u8 = undefined;
        var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
        try stdout.interface.print(
            "{s} built for {s}\n",
            .{ helper.tag(), @import("builtin").cpu.model.name },
        );
        try stdout.interface.flush();
    }
    ZIG
    cat > src/helper.zig <<ZIG
    pub fn tag() []const u8 {
        return "factory-helper";
    }
    ZIG
    zig build --summary all
    ./zig-out/bin/app | grep -q "factory-helper built for neoverse"
    echo "ok: factory (dependency import + exe flags through make_exe)"

# The error paths: a non-chonk stub, inspect on a non-chonk binary, a
# config typo (parse error with line:column), and a machine mismatch
# caught at pack time.
errors:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache/e2e
    rc=0; out=$(timeout 60 ./zig-out/bin/stub-aarch64 2>&1) || rc=$?
    grep -q "bad footer magic" <<<"$out"; test "$rc" -eq 1
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk inspect \
        /run/current-system/sw/bin/true 2>&1) || rc=$?
    grep -q "not a chonk binary" <<<"$out"; test "$rc" -eq 1
    cat > .zig-cache/e2e/typo.zon <<ZON
    .{ .variants = .{
        .{ .name = "x", .binary = "/run/current-system/sw/bin/true",
           .match = .{ .{ .bit = .totally_real } } },
        .{ .binary = "/run/current-system/sw/bin/true" },
    } }
    ZON
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 \
        .zig-cache/e2e/typo.zon .zig-cache/e2e/typo-fat 2>&1) || rc=$?
    grep -q "unexpected enum literal" <<<"$out"; test "$rc" -eq 1
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk pack zig-out/bin/stub-x86_64 \
        example.zon .zig-cache/e2e/mismatch-fat 2>&1) || rc=$?
    grep -q "machine mismatch with stub" <<<"$out"; test "$rc" -eq 1
    echo "ok: errors"
