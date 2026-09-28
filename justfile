set minimum-version := "1.55.0"

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Full battery for whatever host this runs on: aarch64 hosts run the
# complete matrix; x86_64 hosts run the x86 legs natively. CI pins each
# job to one species explicitly.
default:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname -m)" = "aarch64" ]; then
        just e2e-arm
    else
        just e2e-x86
    fi

# Build the CLI and both stubs, run the unit tests, lint.
build:
    zig build
    zig build test --summary all
    ziglint src/ build.zig
    @echo "ok: build"

# The complete aarch64 battery: both pack doors, the qemu tier matrix,
# the x86 selection paths under qemu, the make_exe factory, the error
# paths. Host dispatch legs assume an sve-capable aarch64 host (any
# Neoverse V1+; on GitHub's N1 runners the legs dispatch lower tiers —
# the tolerant assertions cover both).
e2e-arm: build pack-cli consumer tiers x86-select factory errors

# The x86_64 battery: the full native dispatch (the legs this box cannot
# run — the emulation wall), plus the build and error paths. Native
# dispatch legs skip on non-x86_64 hosts.
e2e-x86: build pack-cli-x86 consumer-x86 errors

# CLI door: pack a generated config (dedup: v1 + fallback share the bash
# binary), inspect it, dispatch. Tracers: sve2 tier → chonk usage (exit 2),
# sve tier → bash marker, fallback → bash marker.
pack-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache/e2e
    BIN_BASH=$(command -v bash)
    cat > .zig-cache/e2e/pack-cli.zon <<ZON
    .{ .variants = .{
        .{ .name = "v2", .binary = "{{ justfile_directory() }}/zig-out/bin/chonk", .match = .{ .{ .bit = .sve2 } } },
        .{ .name = "v1", .binary = "$BIN_BASH", .match = .{ .{ .bit = .sve } } },
        .{ .binary = "$BIN_BASH" },
    } }
    ZON
    ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 .zig-cache/e2e/pack-cli.zon \
        .zig-cache/e2e/pack-cli-fat | grep -q "3 variants (2 unique payload(s))"
    ./zig-out/bin/chonk inspect .zig-cache/e2e/pack-cli-fat \
        | grep -q "machine aarch64, 3 variants"
    rc=0; out=$(timeout 60 .zig-cache/e2e/pack-cli-fat -c 'echo TIER-v1-bash' 2>&1) || rc=$?
    case "$out" in
        *"usage: chonk"*|*"TIER-v1-bash"*) ;;
        *) echo "unexpected dispatch output: $out" >&2; exit 1 ;;
    esac
    test "$rc" -eq 0 -o "$rc" -eq 2
    echo "ok: pack-cli ($rc, dispatched tier tolerated across host hw)"

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
    ../../zig-out/bin/chonk inspect zig-out/bin/app \
        | grep -q "machine aarch64, 5 variants"
    ../../zig-out/bin/chonk inspect zig-out/bin/app-x86_64 \
        | grep -q "machine x86_64, 2 variants"
    echo "ok: consumer"

# The aarch64 tier matrix under controlled CPU identities: native
# (host hw), qemu max (sve2), neoverse-v1 (sve, no sve2), neoverse-n1
# (base word only), cortex-a72 (nothing). Each tier has a distinct tracer:
# bash echoes a marker, chonk prints usage (exit 2).
tiers:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache/e2e
    BIN_BASH=$(command -v bash)
    cat > .zig-cache/e2e/tiers.zon <<ZON
    .{ .variants = .{
        .{ .name = "v2-tier", .binary = "$BIN_BASH", .match = .{ .{ .bit = .sve2 } } },
        .{ .name = "v1-tier", .binary = "$BIN_BASH", .match = .{ .{ .bit = .sve } } },
        .{ .binary = "{{ justfile_directory() }}/zig-out/bin/chonk" },
    } }
    ZON
    ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 .zig-cache/e2e/tiers.zon \
        .zig-cache/e2e/fat-tiers > /dev/null
    # Native: whichever tier the host's advertised features select —
    # tolerant because hosts differ (V3/V2 hw → v2 marker; GitHub's N1
    # runners → the fallback, no SVE at all).
    rc=0; out=$(timeout 60 .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash' 2>&1) || rc=$?
    case "$out" in
        *"TIER-v2-bash"*|*"TIER-v1-bash"*|*"usage: chonk"*) ;;
        *) echo "unexpected native dispatch: $out" >&2; exit 1 ;;
    esac
    test "$rc" -eq 0 -o "$rc" -eq 2
    echo "ok: tiers native (host hw dispatch, rc=$rc)"
    rc=0; out=$(timeout 60 qemu-aarch64 -cpu max .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash' 2>&1) || rc=$?
    grep -q "TIER-v2-bash" <<<"$out"; test "$rc" -eq 0
    echo "ok: tiers qemu max (first-match ordering: sve2 tier beats sve tier)"
    rc=0; out=$(timeout 60 qemu-aarch64 -cpu neoverse-v1 .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash' 2>&1) || rc=$?
    grep -q "TIER-v2-bash" <<<"$out"; test "$rc" -eq 0
    echo "ok: tiers qemu neoverse-v1 (v1 tier, bash tracer)"
    rc=0; out=$(timeout 60 qemu-aarch64 -cpu neoverse-n1 .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash' 2>&1) || rc=$?
    grep -q "usage: chonk" <<<"$out"; test "$rc" -eq 2
    echo "ok: tiers qemu neoverse-n1 (fallback: qemu's n1 does not advertise sve)"
    rc=0; out=$(timeout 60 qemu-aarch64 -cpu cortex-a72 .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash' 2>&1) || rc=$?
    grep -q "usage: chonk" <<<"$out"; test "$rc" -eq 2
    echo "ok: tiers qemu cortex-a72 (fallback, chonk tracer, exit 2)"

# The x86_64 selection paths under qemu: both CPU identities select a
# payload (different sendfile sizes), and the documented emulation wall
# (foreign-arch execveat, errno 8) holds. aarch64-host only.
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
# root_source_file shape cannot express. The dispatched tier depends on
# host hw (sve2 → neoverse_v2; less → the implicit baseline).
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
    # The post-compile hook test payload: a copied host bash. The hook
    # swaps the baseline variant's compiled binary for it, so a host where
    # nothing matches dispatches to bash and prints TIER-hook — proving the
    # PACKED bytes came from the hook's return, not the compile.
    cp "$(command -v bash)" tracer
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
            .post_process = postProcess,
            .targets = &.{
                .{ .model = .{ .explicit = &std.Target.aarch64.cpu.neoverse_v2 } },
            },
        });
        _ = fat;
    }

    fn postProcess(b: *Build, v: chonk.Variant, payload: Build.LazyPath) Build.LazyPath {
        // The baseline packs a copied bash (the recipe copies it in as
        // `tracer` before zig build); other variants pass through.
        if (std.mem.eql(u8, v.name, "generic")) return b.path("tracer");
        return payload;
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
    # sve2-class hosts match the v2 tier (factory-helper); N1-class hosts
    # hit the hooked baseline and print TIER-hook. A hook silently ignored
    # prints "factory-helper built for generic" — and fails this grep.
    ./zig-out/bin/app -c 'echo TIER-hook' \
        | grep -q "factory-helper built for neoverse_v2\|TIER-hook"
    # The hooked-baseline path, forced: qemu's synthesized auxv has no SVE
    # under -cpu neoverse-n1, so the baseline — the hook's swapped bash —
    # dispatches. This is the leg that proves the packed bytes are the
    # hook's return, on every host, not just no-SVE CI runners.
    timeout 60 qemu-aarch64 -cpu neoverse-n1 ./zig-out/bin/app -c 'echo TIER-hook' \
        | grep -q "TIER-hook"
    echo "ok: factory (make_exe dependency import + post_process payload swap)"

# CLI door on x86_64: pack a CPUID-conditioned fat (AVX2 tier + fallback)
# with the x86_64 stub, inspect it, dispatch NATIVELY (the legs this
# aarch64 box cannot run). Native dispatch skips on non-x86_64 hosts.
pack-cli-x86:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache/e2e
    # Both tiers point at the host's bash — one payload byte set, the
    # dedup shape — but the host bash matches the x86_64 stub only on an
    # x86_64 host, so the whole leg skips elsewhere (the consumer-x86
    # recipe covers pack + inspect on any host).
    if [ "$(uname -m)" != "x86_64" ]; then
        echo "skip: pack-cli-x86 needs an x86_64 host (CI x86 runner covers it)"
        exit 0
    fi
    BIN_BASH=$(command -v bash)
    cat > .zig-cache/e2e/pack-cli-x86.zon <<ZON
    .{ .variants = .{
        .{ .name = "avx2", .binary = "$BIN_BASH",
           .match = .{ .{ .cpuid = .{ .leaf = 7, .register = .ebx, .bit = 5 } } } },
        .{ .binary = "$BIN_BASH" },
    } }
    ZON
    ./zig-out/bin/chonk pack zig-out/bin/stub-x86_64 .zig-cache/e2e/pack-cli-x86.zon \
        .zig-cache/e2e/pack-cli-x86-fat | grep -q "2 variants (1 unique payload(s))"
    ./zig-out/bin/chonk inspect .zig-cache/e2e/pack-cli-x86-fat \
        | grep -q "machine x86_64, 2 variants"
    rc=0; out=$(timeout 60 .zig-cache/e2e/pack-cli-x86-fat -c 'echo TIER-avx2' 2>&1) || rc=$?
    grep -q "TIER-avx2" <<<"$out"; test "$rc" -eq 0
    echo "ok: pack-cli-x86 (native dispatch, avx2 tier, deduped payload)"

# Build-system door on x86_64: the consumer fleet, then the x86_64 fat
# binary dispatched NATIVELY — the full dispatch path this aarch64 box
# cannot run (the emulation wall). Native dispatch skips on non-x86_64
# hosts.
consumer-x86:
    #!/usr/bin/env bash
    set -euo pipefail
    cd examples/consumer
    zig build chonk --summary all
    if [ "$(uname -m)" = "x86_64" ]; then
        ./zig-out/bin/app-x86_64 | grep -q "app built for CPU model: x86_64"
        echo "ok: consumer-x86 (native x86_64 dispatch)"
    else
        echo "ok: consumer-x86 (fleet built; native dispatch needs an x86_64 host)"
    fi
    ../../zig-out/bin/chonk inspect zig-out/bin/app \
        | grep -q "machine aarch64, 5 variants"
    ../../zig-out/bin/chonk inspect zig-out/bin/app-x86_64 \
        | grep -q "machine x86_64, 2 variants"

# The error paths: a bare stub (bad footer magic), inspect on a non-chonk
# binary, a config typo (parse error with line:column), and a machine
# mismatch caught at pack time. All arch-blind.
errors:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache/e2e
    BIN_BASH=$(command -v bash)
    case "$(uname -m)" in
        aarch64) HOST_STUB=stub-aarch64; OTHER_STUB=stub-x86_64 ;;
        x86_64) HOST_STUB=stub-x86_64; OTHER_STUB=stub-aarch64 ;;
        *) echo "unsupported host arch" >&2; exit 1 ;;
    esac
    rc=0; out=$(timeout 60 "./zig-out/bin/$HOST_STUB" 2>&1) || rc=$?
    grep -q "bad footer magic" <<<"$out"; test "$rc" -eq 1
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk inspect "$BIN_BASH" 2>&1) || rc=$?
    grep -q "not a chonk binary" <<<"$out"; test "$rc" -eq 1
    cat > .zig-cache/e2e/typo.zon <<ZON
    .{ .variants = .{
        .{ .name = "x", .binary = "$BIN_BASH",
           .match = .{ .{ .bit = .totally_real } } },
        .{ .binary = "$BIN_BASH" },
    } }
    ZON
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk pack "./zig-out/bin/$HOST_STUB" \
        .zig-cache/e2e/typo.zon .zig-cache/e2e/typo-fat 2>&1) || rc=$?
    grep -q "unexpected enum literal" <<<"$out"; test "$rc" -eq 1
    # The OTHER species' stub as the payload → machine mismatch at pack time,
    # the cheapest portable wrong-species payload (both stubs always built).
    cat > .zig-cache/e2e/mismatch.zon <<ZON
    .{ .variants = .{
        .{ .binary = "{{ justfile_directory() }}/zig-out/bin/$OTHER_STUB" },
    } }
    ZON
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk pack "./zig-out/bin/$HOST_STUB" \
        .zig-cache/e2e/mismatch.zon .zig-cache/e2e/mismatch-fat 2>&1) || rc=$?
    grep -q "machine mismatch with stub" <<<"$out"; test "$rc" -eq 1
    echo "ok: errors"

# Audit GitHub Actions workflows with zizmor.
lint-actions:
    zizmor --format=plain --min-confidence=medium .

# Check that GitHub Actions references are SHA-pinned with valid version
# comments.
pinact-check:
    pinact run -check --verify -min-age 3 .github/workflows/*.yaml .github/actions/*/action.y*
