---
name: chonk-vocab
description: "Maintain chonk's CPU vocabulary: where each data class's source of truth lives, the update procedure when a new CPU generation or Zig release lands, the cloud microarchitecture ladder, and the verification rig. Triggers on adding hwcap/CPUID bits, new CPU models, Zig toolchain bumps affecting std.Target, cloud fleet coverage questions, or any edit to pack.aarch64_table / pack.x86_table / midrPart."
---

# chonk vocabulary maintenance

The vocabulary is two comptime tables (`pack.aarch64_table`, `pack.x86_table` in
src/pack.zig) plus `pack.midrPart`. The tables carry each bit's kernel wire form
AND its Zig feature mapping together — one entry per bit, comptime-checked.
Inference (build.zig), packing (compileMatches), and display (inspect.zig) all
read the same tables.

## Sources of truth, per data class — never invent values

| Data | Source | How to check |
|---|---|---|
| Kernel hwcap bit positions | `arch/arm64/include/uapi/asm/hwcap.h` (torvalds/linux master) | `webfetch https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/include/uapi/asm/hwcap.h` — every table `mask` must match a `#define HWCAP*_XXX (1 << n)` in it |
| CPUID leaf/subleaf/register/bit | x86-64 psABI level definitions + Intel SDM | cross-check the level tables; verify live with `qemu-x86_64 -strace` (sendfile size identifies the selected payload) |
| Zig feature names + CPU models | the PINNED toolchain's `std/Target/aarch64.zig` / `x86.zig` | `STD=$(zig env ... .std_dir)` then grep — model lists live in `pub const cpu = struct`, features in the top enum. NEVER trust training data for feature tag names (crc32→`.crc`, atomics→`.lse`, asimddp→`.dotprod`, sm4→`.sm4`; and Zig genuinely has NO features for pmull, sha1, fcma, dcpop, sm3, sha512, svepmull, svei8mm, svebf16) |
| What real silicon advertises | live auxv | a static dumper (getauxval + mrs — see the rig below); NOTE: LD_SHOW_AUXV=1 via a dynamic binary under qemu lies (host-loader artifact) |
| MIDR part numbers | the silicon's TRM, or a live `mrs` dump | live values: V1 0xd40, N1 0xd0c, V3 0xd84, Cortex-A72 0xd08 (verified); V2 0xd4f from Arm docs — VERIFY before relying |

## Update procedure — new CPU generation lands

1. Kernel side: fetch the hwcap header, diff bit positions against the
   aarch64_table. New bits in HWCAP/HWCAP2 = add table rows (additive, no
   format_version bump). A new source word (HWCAP3 exists in current kernels,
   AT_HWCAP3) = `format.Source` addition + stub auxv walk + transport
   semantics + format_version bump — a coordinated change, do not wing it.
2. Zig side: if the toolchain pinned by the flake changed, re-grep
   std/Target — new features/models may map previously-explicit-only bits
   (e.g. a future Zig adding `.pmull` makes pmull inferable), or new models
   (neoverse_v3 in 0.16's std). Update the table's feature column only against
   the pinned std.
3. Add the row: bit + source + mask (from the UAPI define, verbatim) +
   feature (null if Zig has none). Comptime uniqueness + the golden tests
   catch structure errors; the golden byte-layout tests pin the wire.
4. Verify: zig build test, then the qemu rig below. NEVER ship a vocabulary
   change without a dispatch verification under at least two CPU identities.

## The cloud ladder (GCP/AWS/Azure coverage, verified 2026-09-28)

aarch64 — examples/consumer carries the full ladder; every tier verified:

| Model | Cloud | Separator (conditions) |
|---|---|---|
| neoverse_v3 | AWS Graviton5 | **MIDR part 0xd84** — V3 advertises the same hwcap words as V2 on many hosts (this V3 box: hwcap=0xeff3ffff, hwcap2=0x801bf3bf, no SME advertised), so hwcap CANNOT separate V3 from V2 — the midrPart tiebreak is load-bearing |
| neoverse_v2 | AWS Graviton4, GCP Axion | inferred: sve2 family (sve, sve2, crc32, atomics, asimdrdm, asimddp, i8mm, bf16) |
| neoverse_v1 | AWS Graviton3 | inferred: sve + crypto (aes, sha2, crc32, atomics, asimdrdm, sha3, sm4, asimddp, sve, i8mm, bf16) — qemu's v1 model omits i8mm/bf16, so under qemu it falls to N1 (conservative, correct); real Graviton3 advertises them |
| neoverse_n1 | AWS Graviton2, Azure Cobalt 100, Ampere Altra (GCP T2A, Oracle) | inferred: base-word crypto (aes, sha2, crc32, atomics, asimdrdm, asimddp) |
| baseline (fallback) | AWS Graviton1 (Cortex-A72) + any v8.0 | appended automatically |

x86_64: psABI tiers — v4 (AVX-512: Intel Cascade Lake+ incl. Sapphire/
Emerald/Granite Rapids, AMD EPYC Genoa (Zen4)+, Turin (Zen5)) → v3 (AVX2: Intel
Skylake, AMD Zen1–Zen3 / Naples–Milan) → baseline. v2 is legacy on-prem,
nearly extinct in clouds. The consumer's x86 fleet: v3 + implicit baseline.

Order matters: strongest first, first-match-wins. A tier's conditions must be
a SUPERSET of what the tier below needs — the ladder cascade only works
because each tier fails on the tier-distinguishing bit of the tier above.

## Verification rig (qemu)

Models available in this qemu: max, neoverse-n1, neoverse-n2, neoverse-v1,
cortex-a72/a53/a76/a710, a64fx (NO neoverse-v2/v3 — use `max` for sve2-era
conditions).

```
# The static dumper — recreate on demand (getauxval + mrs midr_el1):
qemu-aarch64 -cpu neoverse-v1 ./dump   # hwcap=0xcffffffb hwcap2=0x13201 midr=0x411fd402

# The dispatch matrix — the payload prints its own CPU model (tier identity):
./app                                    # native: V3 → neoverse_v3 (midr 0xd84)
qemu-aarch64 -cpu max ./app              # sve2 family → v3-family tier
qemu-aarch64 -cpu neoverse-v1 ./app      # → n1 (v1 lacks i8mm in qemu; real hw → v1)
qemu-aarch64 -cpu neoverse-n1 ./app      # → neoverse_n1
qemu-aarch64 -cpu cortex-a72 ./app      # → generic (fallback)

# x86: sendfile size in -strace identifies the selected payload:
qemu-x86_64 -strace ./app-x86_64 2>&1 | grep sendfile
```

x86_64-under-qemu wall: the final execveat hands the guest ELF to the host
kernel → foreign-arch ENOEXEC (errno 8). Emulation boundary, not a chonk
defect — everything up to execveat verifies under -strace, and the same code
path runs natively on aarch64. Full x86 dispatch needs real x86_64 hardware
or `boot.binfmt.emulatedSystems = [ "x86_64-linux" ]` (Matt's system config).

## Bugs this rig has caught (do not repeat)

- midrPart's mask: the revision nibble [3:0] must be ZEROED (0xFF0FFFF0).
  0xFF0FFFFF keeps it → every midr match fails on any chip with revision != 0.
  One hex digit; found only by running the naked prong logic, not by reading.
- Explicit matches as `&.{ midrPart(...) }`: runtime call → STACK TEMPORARY →
  the stored slice dangles by make() time. Fixed: addExecutable dupes
  spec.match into the graph arena. Comptime literals (rodata) masked the bug
  in tests. The 12-line static dumper catches both classes in minutes.
- Two tiers with identical inferred conditions = first-match gives the
  stronger tier's BINARY to the weaker machine. Check with `chonk inspect`
  before shipping a ladder — identical condition lists on adjacent tiers is
  a bug unless the top tier carries a midrPart tiebreak.
