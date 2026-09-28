#!/usr/bin/env bash
# chonk e2e battery.
#
# One linear script: pack fixtures, dispatch fat binaries natively where the
# host can and under qemu where the CPU identity must be controlled, and
# assert outputs and exit codes. The host arch picks the native legs; the
# qemu legs run everywhere.
#
# Legs print "ok:" as they pass; failures accumulate and the exit code is
# the failure count. Build failures abort outright — a broken build is not
# a test result.

set -euo pipefail
cd "$(dirname "$0")/.."

arch=$(uname -m)

# --- harness ---------------------------------------------------------------

# Run a command with output and exit code captured, errexit suspended:
# qemu legs exit nonzero by design (the emulation wall), and the capture
# must not kill the script.
run() {
    rc=0
    out=$(timeout 60 "$@" 2>&1) || rc=$?
}

ok() {
    echo "ok: $*"
}

fail() {
    failures=$((failures + 1))
    echo "FAIL: $*" >&2
    [ -n "${out:-}" ] && printf '    output: %s\n' "$out" >&2
}

skip() {
    echo "skip: $*"
}

expect_out() { # expect_out PATTERN LABEL
    if grep -q "$1" <<<"$out"; then ok "$2"; else fail "$2 (output mismatch)"; fi
}

expect_rc() { # expect_rc EXACT LABEL
    if [ "$rc" = "$1" ]; then ok "$2"; else fail "$2 (rc=$rc, want $1)"; fi
}

expect_rc_any() { # expect_rc_any "0 2" LABEL
    case " $1 " in
        *" $rc "*) ok "$2" ;;
        *) fail "$2 (rc=$rc, want one of: $1)" ;;
    esac
}

failures=0

# --- guards -----------------------------------------------------------------

if [ ! -x zig-out/bin/chonk ]; then
    echo "zig-out/bin/chonk missing — run 'just build' first" >&2
    exit 1
fi
for bin in qemu-aarch64 qemu-x86_64; do
    command -v "$bin" >/dev/null || {
        echo "$bin not found — the devshell provides qemu-user" >&2
        exit 1
    }
done
case "$arch" in
    aarch64 | x86_64) ;;
    *) echo "unsupported host arch: $arch" >&2; exit 1 ;;
esac

# The host bash copied to the fixed path the ZON fixtures reference — host
# bash paths differ (NixOS vs Ubuntu), so the fixtures stay static and this
# copy normalizes the path. -f: the copied bash is mode 555 on NixOS (a
# store path), so a second copy onto the read-only file needs unlink-first.
mkdir -p .zig-cache/e2e tests/e2e
cp -f "$(command -v bash)" tests/e2e/bash

# --- CLI door: pack-cli.zon --------------------------------------------------
# Dedup shape: v1 and the fallback share the copied bash. Tracers: sve2
# tier → chonk usage (exit 2), sve tier → bash marker, fallback → bash
# marker. The fixture packs the aarch64 stub with host-arch payloads —
# an aarch64-host leg; the x86 battery has its own CLI door.

if [ "$arch" = aarch64 ]; then
    run ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 \
        tests/e2e/pack-cli.zon .zig-cache/e2e/pack-cli-fat
    expect_out "3 variants (2 unique payload(s))" "pack-cli pack (dedup)"
    expect_rc 0 "pack-cli pack"

    run ./zig-out/bin/chonk inspect .zig-cache/e2e/pack-cli-fat
    expect_out "machine aarch64, 3 variants" "pack-cli inspect"
    expect_rc 0 "pack-cli inspect"

    # Native dispatch: whichever tier the host's advertised features select
    # — tolerant because hosts differ (sve2 hw → the chonk tracer; GitHub's
    # arm runners → the bash fallback).
    run .zig-cache/e2e/pack-cli-fat -c 'echo TIER-v1-bash'
    case "$out" in
        *"usage: chonk"* | *"TIER-v1-bash"*) ok "pack-cli native dispatch (rc=$rc)" ;;
        *) fail "pack-cli native dispatch (unexpected output)" ;;
    esac
    expect_rc_any "0 2" "pack-cli native dispatch rc"
else
    skip "pack-cli (aarch64 CLI door; needs an aarch64 host)"
fi

# --- consumer example --------------------------------------------------------
# The build-system door: normal build, run step, the two-species release
# fleet, native dispatch, inspect both species. zig cross-builds, so this
# runs on any host arch.

pushd examples/consumer >/dev/null
zig build
./zig-out/bin/app | grep -q "app built for CPU model" || {
    fail "consumer normal build run"
}
zig build run | grep -q "app built for CPU model" || { fail "consumer run step"; }
zig build chonk
popd >/dev/null

# Native dispatch of the aarch64 fleet fat — aarch64 hosts only (the
# chonk fleet overwrites zig-out/bin/app with the aarch64 fat).
if [ "$arch" = aarch64 ]; then
    run ./examples/consumer/zig-out/bin/app
    expect_out "app built for CPU model: neoverse" "consumer native dispatch (tolerant: host tier)"
else
    skip "consumer native dispatch (aarch64 fat needs an aarch64 host)"
fi
run ./zig-out/bin/chonk inspect examples/consumer/zig-out/bin/app
expect_out "machine aarch64, 5 variants" "consumer inspect (aarch64 fleet)"
run ./zig-out/bin/chonk inspect examples/consumer/zig-out/bin/app-x86_64
expect_out "machine x86_64, 2 variants" "consumer inspect (x86_64 fleet)"

# --- tier matrix: tiers.zon ---------------------------------------------------
# Controlled CPU identities: qemu max (sve2), neoverse-v1 (sve, no sve2),
# neoverse-n1 (base word only — qemu's n1 does not advertise sve), and
# cortex-a72 (nothing). bash echoes a marker; chonk prints usage (exit 2).
# The fixture packs the aarch64 stub with host-arch payloads — an
# aarch64-host leg, whole section.

if [ "$arch" = aarch64 ]; then
    run ./zig-out/bin/chonk pack zig-out/bin/stub-aarch64 \
        tests/e2e/tiers.zon .zig-cache/e2e/fat-tiers
    expect_rc 0 "tiers pack"

    run .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash'
    case "$out" in
        *"TIER-v2-bash"* | *"TIER-v1-bash"* | *"usage: chonk"*) ok "tiers native (host hw dispatch, rc=$rc)" ;;
        *) fail "tiers native dispatch (unexpected output)" ;;
    esac
    expect_rc_any "0 2" "tiers native rc"

    run qemu-aarch64 -cpu max .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash'
    expect_out "TIER-v2-bash" "tiers qemu max (first-match: sve2 beats sve)"
    expect_rc 0 "tiers qemu max"

    run qemu-aarch64 -cpu neoverse-v1 .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash'
    expect_out "TIER-v2-bash" "tiers qemu neoverse-v1 (v1 tier, bash tracer)"
    expect_rc 0 "tiers qemu neoverse-v1"

    run qemu-aarch64 -cpu neoverse-n1 .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash'
    expect_out "usage: chonk" "tiers qemu neoverse-n1 (fallback: no sve advertised)"
    expect_rc 2 "tiers qemu neoverse-n1"

    run qemu-aarch64 -cpu cortex-a72 .zig-cache/e2e/fat-tiers -c 'echo TIER-v2-bash'
    expect_out "usage: chonk" "tiers qemu cortex-a72 (fallback, chonk tracer)"
    expect_rc 2 "tiers qemu cortex-a72"
else
    skip "tiers (aarch64 tier matrix; needs an aarch64 host)"
fi

# --- x86_64 selection paths: strace under qemu --------------------------------
# Both CPU identities select a payload (different sendfile sizes), and the
# documented emulation wall holds on aarch64 hosts: a foreign-arch
# execveat under qemu-user reaches the host kernel and gets errno 8.
# On x86_64 hosts there is no wall to observe — native dispatch covers it.

fat=examples/consumer/zig-out/bin/app-x86_64
trace() { timeout 60 qemu-x86_64 -strace "$@" "$fat" 2>&1 || true; }
# Capture the full trace per identity — grep -m1 on a live qemu pipe closes
# it early and qemu dies to SIGPIPE under pipefail (141).
t1=$(trace -cpu max)
t2=$(trace -cpu qemu64,-avx2,-fma,-popcnt,-sse4.2,-sse4.1,-ssse3)
s1=$(grep -m1 "sendfile" <<<"$t1" | sed 's/.*= //')
s2=$(grep -m1 "sendfile" <<<"$t2" | sed 's/.*= //')
if [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" != "$s2" ]; then
    ok "x86-select ($s1 vs $s2 — both selection paths)"
else
    fail "x86-select (sendfile sizes: '$s1' vs '$s2')"
fi
if [ "$arch" != x86_64 ]; then
    if grep -q "execveat.*errno=8" <<<"$t1"; then
        ok "x86-select wall (foreign-arch execveat, errno=8)"
    else
        fail "x86-select wall (no errno=8 in trace)"
    fi
else
    skip "x86-select wall (no wall on an x86_64 host)"
fi

# --- factory example ----------------------------------------------------------
# The make_exe + post_process door, built from committed sources. sve2-class
# hosts match the v2 tier (factory-helper); every other host hits the
# fallback — the post-processed payload — and prints the fallback binary's
# marker. A hook silently ignored prints "factory-helper built for generic"
# instead, and fails both assertions.

pushd examples/factory >/dev/null
zig build
popd >/dev/null

if [ "$arch" = aarch64 ]; then
    run ./examples/factory/zig-out/bin/app
    case "$out" in
        *"factory-helper built for neoverse_v2"* | *"fallback build"*) ok "factory native (host hw dispatch)" ;;
        *) fail "factory native dispatch (unexpected output)" ;;
    esac
else
    skip "factory native (aarch64 fat needs an aarch64 host)"
fi
# The hooked fallback, forced: qemu's synthesized auxv has no SVE under
# -cpu neoverse-n1, so the baseline — the hook's swapped binary —
# dispatches, on every host.
run qemu-aarch64 -cpu neoverse-n1 ./examples/factory/zig-out/bin/app
expect_out "post-processed payload" "factory qemu n1 (the hook's return packed)"
expect_rc 0 "factory qemu n1"

# --- x86_64 CLI door: pack-cli-x86.zon -----------------------------------------
# AVX2-conditioned tier plus the fallback, both the copied bash — one
# payload byte set. The host bash matches the x86_64 stub only on x86_64
# hosts, so the whole leg skips elsewhere.

if [ "$arch" = x86_64 ]; then
    run ./zig-out/bin/chonk pack zig-out/bin/stub-x86_64 \
        tests/e2e/pack-cli-x86.zon .zig-cache/e2e/pack-cli-x86-fat
    expect_out "2 variants (1 unique payload(s))" "pack-cli-x86 pack (dedup)"
    run ./zig-out/bin/chonk inspect .zig-cache/e2e/pack-cli-x86-fat
    expect_out "machine x86_64, 2 variants" "pack-cli-x86 inspect"
    run .zig-cache/e2e/pack-cli-x86-fat -c 'echo TIER-avx2'
    expect_out "TIER-avx2" "pack-cli-x86 native dispatch (avx2 tier)"
    expect_rc 0 "pack-cli-x86 native dispatch"
else
    skip "pack-cli-x86 (needs an x86_64 host; the CI x86 job covers it)"
fi

# --- x86_64 consumer fleet ------------------------------------------------------

run ./zig-out/bin/chonk inspect examples/consumer/zig-out/bin/app-x86_64
expect_out "machine x86_64, 2 variants" "consumer-x86 inspect (fleet built above)"

if [ "$arch" = x86_64 ]; then
    run ./examples/consumer/zig-out/bin/app-x86_64
    expect_out "app built for CPU model: x86_64" "consumer-x86 native dispatch"
else
    skip "consumer-x86 native dispatch (needs an x86_64 host)"
fi

# --- error paths ----------------------------------------------------------------
# A bare stub (bad footer magic), inspect on a non-chonk binary, a config
# typo (parse error with line:column), and a machine mismatch caught at
# pack time. All arch-blind.

case "$arch" in
    aarch64) HOST_STUB=stub-aarch64; MISMATCH=mismatch-aarch64 ;;
    x86_64) HOST_STUB=stub-x86_64; MISMATCH=mismatch-x86_64 ;;
esac

run "./zig-out/bin/$HOST_STUB"
expect_out "bad footer magic" "errors: bare stub (bad footer magic)"
expect_rc 1 "errors: bare stub rc"

run ./zig-out/bin/chonk inspect tests/e2e/bash
expect_out "not a chonk binary" "errors: inspect non-chonk"
expect_rc 1 "errors: inspect non-chonk rc"

run ./zig-out/bin/chonk pack "./zig-out/bin/$HOST_STUB" \
    tests/e2e/typo.zon .zig-cache/e2e/typo-fat
expect_out "unexpected enum literal" "errors: config typo (parse error)"
expect_rc 1 "errors: config typo rc"

run ./zig-out/bin/chonk pack "./zig-out/bin/$HOST_STUB" \
    "tests/e2e/$MISMATCH.zon" .zig-cache/e2e/mismatch-fat
expect_out "machine mismatch with stub" "errors: machine mismatch at pack time"
expect_rc 1 "errors: machine mismatch rc"

# --- summary --------------------------------------------------------------------

echo "-- $arch host: $failures failure(s)"
exit "$failures"
