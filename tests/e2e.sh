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

# --- help --------------------------------------------------------------------

for flag in --help -h; do
    run ./zig-out/bin/chonk "$flag"
    expect_out "usage: chonk <command>" "help: top level $flag"
    expect_rc 0 "help: top level $flag rc"
done

run ./zig-out/bin/chonk pack --help
expect_out "chonk stub for the target architecture" "help: pack"
expect_rc 0 "help: pack rc"

run ./zig-out/bin/chonk inspect -h
expect_out "usage: chonk inspect" "help: inspect"
expect_rc 0 "help: inspect rc"

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

# --- file mode: CLI door ------------------------------------------------------
# Same variant table, but the payloads are real files in <shim>.d/ and
# dispatch is a plain execve of a path — the AppArmor-compatible shape. The
# trace assertions are the point: the file-mode shim has no memfd_create and
# no execveat, while the embedded one has both.

if [ "$arch" = aarch64 ]; then
    run ./zig-out/bin/chonk pack --files zig-out/bin/stub-aarch64-files \
        tests/e2e/pack-cli.zon .zig-cache/e2e/pack-cli-files
    expect_out "linked: 3 variants" "file-mode pack"
    expect_rc 0 "file-mode pack rc"

    for name in v2 v1 bash; do
        if [ -x ".zig-cache/e2e/pack-cli-files.d/$name" ]; then
            ok "file-mode payload $name"
        else
            fail "file-mode payload $name missing"
        fi
    done

    run ./zig-out/bin/chonk inspect .zig-cache/e2e/pack-cli-files
    expect_out "chonk file-mode shim" "file-mode inspect mode"
    expect_out "0: v2 (" "file-mode inspect names"
    expect_out "2: bash (.*fallback" "file-mode inspect fallback"
    expect_rc 0 "file-mode inspect rc"

    # Native dispatch: whichever tier the host advertises — tolerant because
    # hosts differ (v2 is the chonk tracer, rc 2; v1/fallback are bash).
    run .zig-cache/e2e/pack-cli-files -c 'echo FILE-native'
    case "$out" in
        *"usage: chonk"* | *"FILE-native"*) ok "file-mode native dispatch (rc=$rc)" ;;
        *) fail "file-mode native dispatch (unexpected output)" ;;
    esac
    expect_rc_any "0 2" "file-mode native dispatch rc"

    # A symlinked entry point must still find the payloads beside the real
    # file: PATH entries are symlinks on NixOS, so this is the deployment
    # shape, not an edge case.
    ln -sf pack-cli-files .zig-cache/e2e/file-link
    run .zig-cache/e2e/file-link
    case "$out" in
        *"execve payload"*) fail "file-mode symlinked entry (payload lookup failed)" ;;
        *) ok "file-mode symlinked entry resolves the real directory" ;;
    esac

    # Controlled CPU identities, same matrix as the fat binary.
    run qemu-aarch64 -cpu max .zig-cache/e2e/pack-cli-files
    expect_out "usage: chonk" "file-mode qemu max (v2 tier: chonk tracer)"
    expect_rc 2 "file-mode qemu max rc"

    run qemu-aarch64 -cpu neoverse-v1 .zig-cache/e2e/pack-cli-files -c 'echo FILE-v1-bash'
    expect_out "FILE-v1-bash" "file-mode qemu neoverse-v1 (sve tier: bash)"
    expect_rc 0 "file-mode qemu neoverse-v1 rc"

    run qemu-aarch64 -cpu cortex-a72 .zig-cache/e2e/pack-cli-files -c 'echo FILE-fallback-bash'
    expect_out "FILE-fallback-bash" "file-mode qemu cortex-a72 (fallback: bash)"
    expect_rc 0 "file-mode qemu cortex-a72 rc"

    # The syscall shape, which is the whole reason this mode exists.
    t_files=$(timeout 60 qemu-aarch64 -strace .zig-cache/e2e/pack-cli-files 2>&1 || true)
    if grep -q "execve(" <<<"$t_files" &&
        ! grep -q "memfd_create" <<<"$t_files" &&
        ! grep -q "execveat" <<<"$t_files"; then
        ok "file-mode trace (execve of a path; no memfd_create/execveat)"
    else
        out=$t_files
        fail "file-mode trace (wanted execve and no memfd_create/execveat)"
    fi
    t_fat=$(timeout 60 qemu-aarch64 -strace .zig-cache/e2e/pack-cli-fat 2>&1 || true)
    if grep -q "memfd_create" <<<"$t_fat" && grep -q "execveat" <<<"$t_fat"; then
        ok "embedded trace (memfd_create + execveat, the contrast)"
    else
        out=$t_fat
        fail "embedded trace (wanted memfd_create + execveat)"
    fi
else
    skip "file mode CLI door (aarch64; the x86 job covers its own)"
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
zig build files
popd >/dev/null

# Native dispatch of the aarch64 fleet fat — aarch64 hosts only (the
# chonk fleet overwrites zig-out/bin/app with the aarch64 fat).
if [ "$arch" = aarch64 ]; then
    run ./examples/consumer/zig-out/bin/app
    expect_out "app built for CPU model: neoverse" "consumer native dispatch (tolerant: host tier)"

    run qemu-aarch64 -cpu max,sve=off,midr=0x410fd841 ./examples/consumer/zig-out/bin/app
    expect_out "app built for CPU model: neoverse_n1" "consumer V3 MIDR without SVE falls to N1"
    expect_rc 0 "consumer V3 MIDR without SVE rc"
else
    skip "consumer native dispatch (aarch64 fat needs an aarch64 host)"
fi
run ./zig-out/bin/chonk inspect examples/consumer/zig-out/bin/app
expect_out "machine aarch64, 5 variants" "consumer inspect (aarch64 fleet)"
run ./zig-out/bin/chonk inspect examples/consumer/zig-out/bin/app-x86_64
expect_out "machine x86_64, 2 variants" "consumer inspect (x86_64 fleet)"

# The files-mode fleet from the build door: shim at bin/app-files, payloads
# at bin/app-files.d/<cpu model>. The names come from the resolved models,
# and the fallback is the arch baseline (zig calls it "generic").
if [ -x examples/consumer/zig-out/bin/app-files ] &&
    [ -x examples/consumer/zig-out/bin/app-files.d/neoverse_v2 ] &&
    [ -x examples/consumer/zig-out/bin/app-files.d/generic ]; then
    ok "consumer files fleet layout"
else
    fail "consumer files fleet layout (shim or payloads missing)"
fi
run ./zig-out/bin/chonk inspect examples/consumer/zig-out/bin/app-files
expect_out "chonk file-mode shim" "consumer files inspect mode"
expect_out "machine aarch64, 5 variants" "consumer files inspect variants"
expect_rc 0 "consumer files inspect rc"

if [ "$arch" = aarch64 ]; then
    run ./examples/consumer/zig-out/bin/app-files
    expect_out "app built for CPU model: neoverse" "consumer files native dispatch"
    expect_rc 0 "consumer files native rc"

    run qemu-aarch64 -cpu max,sve=off,midr=0x410fd841 ./examples/consumer/zig-out/bin/app-files
    expect_out "app built for CPU model: neoverse_n1" "consumer files qemu n1 (V3 MIDR without SVE)"
    expect_rc 0 "consumer files qemu n1 rc"

    run qemu-aarch64 -cpu cortex-a72 ./examples/consumer/zig-out/bin/app-files
    expect_out "app built for CPU model: generic" "consumer files qemu a72 (baseline)"
    expect_rc 0 "consumer files qemu a72 rc"
else
    skip "consumer files native dispatch (aarch64 fleet, needs an aarch64 host)"
fi

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
# Haswell retains AVX and AVX2 but lacks XSAVE and OSXSAVE.
t_no_xsave=$(trace -cpu Haswell,-xsave,-hle,-rtm)
s_no_xsave=$(grep -m1 "sendfile" <<<"$t_no_xsave" | sed 's/.*= //')
if [ -n "$s2" ] && [ "$s_no_xsave" = "$s2" ]; then
    ok "x86-select without XSAVE/OSXSAVE (fallback)"
else
    out=$t_no_xsave
    fail "x86-select without XSAVE/OSXSAVE ('$s_no_xsave' vs fallback '$s2')"
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
    # The hooked fallback, forced: qemu's synthesized auxv has no SVE under
    # -cpu neoverse-n1, so the baseline — the hook's swapped binary —
    # dispatches. Same-arch execveat passes to the host kernel and works;
    # on an x86_64 host it hits the wall (the x86-select lesson, mirrored).
    run qemu-aarch64 -cpu neoverse-n1 ./examples/factory/zig-out/bin/app
    expect_out "post-processed payload" "factory qemu n1 (the hook's return packed)"
    expect_rc 0 "factory qemu n1"
else
    skip "factory native (aarch64 fat needs an aarch64 host)"
fi

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

    run ./zig-out/bin/chonk pack --files zig-out/bin/stub-x86_64-files \
        tests/e2e/pack-cli-x86.zon .zig-cache/e2e/pack-cli-x86-files
    expect_out "linked: 2 variants" "file-mode-x86 pack"
    expect_rc 0 "file-mode-x86 pack rc"
    run .zig-cache/e2e/pack-cli-x86-files -c 'echo TIER-avx2-files'
    expect_out "TIER-avx2-files" "file-mode-x86 native dispatch (avx2 tier)"
    expect_rc 0 "file-mode-x86 native dispatch"
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

run "./zig-out/bin/$HOST_STUB-files"
expect_out "bad footer magic" "errors: bare file-mode stub (bad footer magic)"
expect_rc 1 "errors: bare file-mode stub rc"

# Trailer mode is part of the contract. Packing with the wrong stub makes a
# file whose code and trailer disagree — the stub catches it at run time,
# which is the only place it can (the two stubs share an ELF machine).
run ./zig-out/bin/chonk pack "./zig-out/bin/$HOST_STUB-files" \
    tests/e2e/pack-cli.zon .zig-cache/e2e/mode-mismatch-embedded
run .zig-cache/e2e/mode-mismatch-embedded
expect_out "embedded fat binary" "errors: file-mode stub on an embedded fat binary"
expect_rc 1 "errors: file-mode stub on an embedded fat binary rc"

run ./zig-out/bin/chonk pack --files "./zig-out/bin/$HOST_STUB" \
    tests/e2e/pack-cli.zon .zig-cache/e2e/mode-mismatch-files
run .zig-cache/e2e/mode-mismatch-files
expect_out "file-mode trailer" "errors: embedded stub on a file-mode shim"
expect_rc 1 "errors: embedded stub on a file-mode shim rc"

# A shim copied away from its payload directory names the path it tried.
run ./zig-out/bin/chonk pack --files "./zig-out/bin/$HOST_STUB-files" \
    tests/e2e/pack-cli.zon .zig-cache/e2e/lonely-shim
cp -f .zig-cache/e2e/lonely-shim .zig-cache/e2e/lonely-shim-moved
run .zig-cache/e2e/lonely-shim-moved
expect_out "execve payload: ENOENT" "errors: file-mode missing payload dir"
expect_out "lonely-shim-moved.d" "errors: missing payload dir names the path"
expect_rc 1 "errors: file-mode missing payload dir rc"

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
