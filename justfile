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

# The host bash copied to the fixed path the ZON fixtures in tests/e2e
# reference — host bash paths differ (NixOS vs Ubuntu), so the fixtures
# stay static and this copy normalizes the path. tests/e2e/bash is
# gitignored.
bash-bin:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .zig-cache/e2e tests/e2e
    # -f: the copied bash is mode 555 (NixOS store path), so a second
    # copy onto the existing read-only file needs the unlink-first.
    cp -f "$(command -v bash)" tests/e2e/bash

# The complete aarch64 battery: both pack doors, the qemu tier matrix,
# the x86 selection paths under qemu, the factory example, the error
# paths. Host dispatch legs assume an sve-capable aarch64 host (any
# Neoverse V1+; on GitHub's N1 runners the legs dispatch lower tiers —
# the tolerant assertions cover both).
e2e-arm: build pack-cli consumer tiers x86-select factory errors

# The x86_64 battery: the full native dispatch (the legs this box cannot
# run — the emulation wall), plus the build and error paths. Native
# dispatch legs skip on non-x86_64 hosts.
e2e-x86: build pack-cli-x86 consumer-x86 errors

# CLI door: pack the tests/e2e/pack-cli.zon fixture (dedup: v1 and the
# fallback share the copied bash), inspect it, dispatch. Tracers: sve2
# tier → chonk usage (exit 2), sve tier → bash marker, fallback → bash
# marker.
pack-cli: build bash-bin
    #!/usr/bin/env bash
    set -euo pipefail
    ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 tests/e2e/pack-cli.zon \
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
tiers: build bash-bin
    #!/usr/bin/env bash
    set -euo pipefail
    ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 tests/e2e/tiers.zon \
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

# The make_exe + post_process door: the factory example, built from
# committed sources. sve2-class hosts match the v2 tier (factory-helper);
# every other host hits the fallback — the post-processed payload — and
# prints the fallback binary's marker. A hook silently ignored prints
# "factory-helper built for generic" instead, and fails both greps.
factory:
    #!/usr/bin/env bash
    set -euo pipefail
    cd examples/factory
    zig build --summary all
    ./zig-out/bin/app | grep -q "factory-helper built for neoverse_v2\|fallback build"
    # The hooked fallback, forced: qemu's synthesized auxv has no SVE
    # under -cpu neoverse-n1, so the baseline — the hook's swapped
    # binary — dispatches, on every host.
    timeout 60 qemu-aarch64 -cpu neoverse-n1 ./zig-out/bin/app \
        | grep -q "post-processed payload"
    echo "ok: factory (make_exe dependency import + post_process payload swap)"

# CLI door on x86_64: pack the CPUID-conditioned fixture with the x86_64
# stub, inspect it, dispatch NATIVELY (the legs this aarch64 box cannot
# run). The whole leg skips on non-x86_64 hosts — the host bash matches
# the x86_64 stub only there (consumer-x86 covers pack + inspect on any
# host).
pack-cli-x86: build bash-bin
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname -m)" != "x86_64" ]; then
        echo "skip: pack-cli-x86 needs an x86_64 host (CI x86 runner covers it)"
        exit 0
    fi
    ./zig-out/bin/chonk pack zig-out/bin/stub-x86_64 tests/e2e/pack-cli-x86.zon \
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
errors: build bash-bin
    #!/usr/bin/env bash
    set -euo pipefail
    case "$(uname -m)" in
        aarch64) HOST_STUB=stub-aarch64; MISMATCH=mismatch-aarch64 ;;
        x86_64) HOST_STUB=stub-x86_64; MISMATCH=mismatch-x86_64 ;;
        *) echo "unsupported host arch" >&2; exit 1 ;;
    esac
    rc=0; out=$(timeout 60 "./zig-out/bin/$HOST_STUB" 2>&1) || rc=$?
    grep -q "bad footer magic" <<<"$out"; test "$rc" -eq 1
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk inspect tests/e2e/bash 2>&1) || rc=$?
    grep -q "not a chonk binary" <<<"$out"; test "$rc" -eq 1
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk pack "./zig-out/bin/$HOST_STUB" \
        tests/e2e/typo.zon .zig-cache/e2e/typo-fat 2>&1) || rc=$?
    grep -q "unexpected enum literal" <<<"$out"; test "$rc" -eq 1
    rc=0; out=$(timeout 60 ./zig-out/bin/chonk pack "./zig-out/bin/$HOST_STUB" \
        "tests/e2e/$MISMATCH.zon" .zig-cache/e2e/mismatch-fat 2>&1) || rc=$?
    grep -q "machine mismatch with stub" <<<"$out"; test "$rc" -eq 1
    echo "ok: errors"

# Audit GitHub Actions workflows with zizmor.
lint-actions:
    zizmor --format=plain --min-confidence=medium .

# Check that GitHub Actions references are SHA-pinned with valid version
# comments.
pinact-check:
    pinact run -check --verify -min-age 3 .github/workflows/*.yaml .github/actions/*/action.y*
