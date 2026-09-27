# Fat Binary Dispatcher — Project Plan

A single self-contained Linux binary — aarch64 (Neoverse V1 vs V2, etc.) and
x86_64 — that detects the running CPU and re-execs into an embedded,
optimized payload — no libc, no IFUNC, no dynamic linker involved. Think "macOS universal binary,"
but built from scratch for our use case and driven by a small packer tool +
config file instead of a fixed Apple-defined format.

Two independent deliverables:

1. **`stub`** — the freestanding dispatcher binary. Compiled once. Never
   changes per-build.
2. **`packer`** — a CLI tool that reads a config file + a set of prebuilt
   variant binaries, and concatenates `stub + payload[0..N] + trailer` into
   one output file.

The stub and packer share exactly one thing: the **trailer format**. Get that
struct right first — everything else follows from it.

---

## 1. Why this shape (recap of the reasoning)

- ARM has no `CPUID`. Identity comes from **`AT_HWCAP`/`AT_HWCAP2`** in the
  auxv (present on the initial stack before libc ever runs — safe to read
  from a naked `_start`), with **`MIDR_EL1`** (readable at EL0 — Linux
  traps and emulates this specific read) as a tiebreaker/fallback.
- We don't need ZIP's central-directory trick. ZIP solves "index +
  random-access + optional compression + works with existing tools." We only
  need "index + random access," and we control both reader and writer, so a
  custom fixed-width trailer is far less code than a ZIP parser.
- Dispatch mechanism: **`memfd_create` + write payload + `execve
  ("/proc/self/fd/N")`**. This lets each payload be an ordinary static ELF —
  the kernel's normal loader builds argv/envp/auxv for us. (Rejected:
  `mmap(PROT_EXEC)` + direct jump — faster, but means hand-rolling the
  process entry ABI ourselves. Revisit only if the extra `execve` proves to
  matter.)
- Match conditions must be **data-driven** (read from the trailer at
  runtime), not compiled into the stub. Otherwise "one stub forever" breaks
  the moment we add a variant or change a condition.

---

## 2. File layout

```
[ ELF header + stub code/data ] [payload_0] [payload_1] ... [payload_N] [trailer]
```

- Payloads are page-aligned within the file (4096-byte boundaries) — costs a
  little size, keeps the door open for mmap+exec later without re-laying-out
  the format.
- Trailer sits at the very end. Stub finds it by seeking to
  `EOF - sizeof(Footer)` and checking a magic number, same trick ZIP/most
  self-describing trailers use.

---

## 3. Trailer format (the shared contract)

Sketch (adjust widths once real values are known — keep it a plain repr(C)
struct, no variable-length encoding inside records):

```c
// Fixed footer, fixed size, always the last N bytes of the file.
struct Footer {
    uint64_t magic;         // fixed constant, sanity check
    uint64_t table_offset;  // absolute file offset of VariantEntry[0]
    uint32_t variant_count;
    uint32_t format_version;
    uint16_t machine;       // ELF e_machine — packer stamps from stub ELF,
                            // stub validates against its own arch
    uint8_t  _pad[6];
};

// One per variant, table_offset .. table_offset + count * sizeof(VariantEntry)
struct VariantEntry {
    uint64_t payload_offset;   // page-aligned
    uint64_t payload_size;
    uint32_t condition_offset; // into condition blob, see below
    uint32_t condition_count;
    uint8_t  is_default;       // fallback if nothing else matches
    uint8_t  _pad[7];
};

// Condition blob: flat array of simple checks, ANDed within a variant.
// First variant (in file order) whose conditions all pass, wins.
// Evaluation order = table order = config file order.
struct Condition {
    uint8_t  source;   // 0 = HWCAP, 1 = HWCAP2, 2 = MIDR_EL1
    uint8_t  _pad[3];
    uint64_t mask;      // bits to check
    uint64_t expected;  // masked value must equal this
};
```

Decisions baked in here, worth confirming before writing code:

- **Match semantics: first-match-wins, in config order, conditions ANDed
  within a variant.** No OR logic — if we need "SVE2 OR something," just
  list two variants pointing at the same payload. Simpler stub, simpler
  packer, simpler mental model.
- One variant marked `is_default` acts as the catch-all if nothing above it
  matched — packer should validate exactly one default exists.
- `condition_offset`/`condition_count` instead of embedding conditions
  inline in `VariantEntry` — keeps `VariantEntry` fixed-size even though
  variants may have a different number of conditions.

---

## 4. `stub` (the dispatcher)

Freestanding, no libc, no allocator ideally (fixed-size stack buffers only).
Zig's freestanding target + manual `_start` is the easiest place to
prototype the auxv walk (naked entry, no libc runtime touching the stack
first). Rust works too but the naked entry means `global_asm!`.

Steps at runtime:

1. **`_start`**: grab the raw stack pointer before any prologue runs. Layout
   is `argc | argv[argc+1 with NULL] | envp[... with NULL] | auxv[Elf64_auxv_t...]`.
   Walk past argv and envp (stop at the NULLs) to reach auxv.
2. Scan auxv for `AT_HWCAP` (usually type 16) and `AT_HWCAP2` (type 26) —
   store both as u64.
3. Optionally read `MIDR_EL1` via `mrs x0, MIDR_EL1` for tiebreak /
   diagnostics.
4. Find own file: `readlink("/proc/self/exe")` or reuse `argv[0]` +
   fallback — need *some* fd to `pread` the trailer from. `open()` +
   `pread()` directly, both raw syscalls, no libc needed.
5. `pread` the last `sizeof(Footer)` bytes, verify magic.
6. `pread` the variant table + condition blob (sizes known from footer).
7. Walk variants in order; for each, AND-check its conditions against
   HWCAP/HWCAP2/MIDR; first pass wins; else fall through to `is_default`.
8. `pread` the winning payload's bytes into a buffer (or stream directly
   into the memfd via `sendfile`/loop of `pread`+`write` — avoid needing the
   whole payload resident if it's large, though for a first pass "just read
   it all into a stack/static buffer or one mmap'd region" is fine).
9. `memfd_create("payload", 0)`, write payload bytes into it.
10. `execve("/proc/self/fd/<memfd>", argv, envp)` — passes through the
    *original* argv/envp untouched, so the payload sees a normal process.

All syscalls raw (`svc #0` on aarch64) — no libc, no CRT startup.

---

## 5. `packer` (the build tool)

Ordinary hosted tool — no freestanding constraints, write it in whatever's
comfortable (Zig, Rust, even Python for a first draft since it's pure
"read binaries + concatenate + emit struct bytes").

Input: a config file. **Decided (2026-09-27): ZON** — Zig-native, `std.zon.parse`
exists in 0.16, no hand-rolled YAML subset parser to maintain. E.g.

```zig
.{
    .variants = .{
        .{ .name = "neoverse-v2", .binary = "build/app-v2", .match = .{
            .{ .source = "hwcap2", .mask = "SVE2" },
        } },
        .{ .name = "neoverse-v1", .binary = "build/app-v1", .match = .{
            .{ .source = "hwcap", .mask = "SVE" },
        } },
        .{ .name = "generic", .binary = "build/app-generic", .default = true },
    },
}
```

Packer responsibilities:

1. Parse YAML, resolve named bit constants (`SVE`, `SVE2`, ...) to actual
   HWCAP/HWCAP2 bit values — keep a small lookup table in the packer so the
   config stays human-readable instead of raw hex masks.
2. Validate: exactly one `default: true`, all `binary:` paths exist, no
   duplicate variant names.
3. Read `stub` binary bytes; validate stub + payload ELF `e_machine` agree
   and stamp it into the footer (the arch-blind species check).
4. For each variant, page-align the running offset, read payload bytes,
   record `(offset, size)`.
5. Emit condition blob + variant table + footer per the shared struct
   layout (§3) — same byte layout the stub expects, ideally generated from
   one shared struct definition (see §6) so the two never drift.
6. Concatenate everything to the output file, `chmod +x`.

Nice-to-have once the basic path works: `packer inspect <binary>` — parse an
already-built fat binary and print its variant table/conditions in
human-readable form, for debugging. This is basically free once the reader
side exists, and it's the equivalent of `unzip -l` from the earlier ZIP
idea — worth keeping even though we dropped ZIP itself.

---

## 6. Keeping stub and packer in sync

The trailer struct is the one piece of shared state between a freestanding
binary and a hosted tool, likely in different toolchains. Options, roughly
in order of preference:

- Define the structs once in C (or Zig, since Zig can `@cImport` or just be
  the single source of truth) and generate/derive both sides from that one
  definition, even if `packer` itself is written in something else — a tiny
  C header both sides parse/embed is cheap insurance against layout drift.
- At minimum: write the struct layout down in this file or a
  `FORMAT.md`, with explicit byte offsets, and hand-write both sides against
  it, with a round-trip test (packer writes a trailer, a test harness reads
  it back bit-for-bit) as the first thing that has to pass.

---

## 7. Suggested build order (so there's always something running)

1. Write the shared trailer struct + a tiny round-trip test (write footer/
   table/conditions to a buffer, read them back, assert equality). No CPU
   detection, no execve yet — just prove the byte layout is solid.
2. Write `stub`'s auxv walk in isolation: freestanding `_start` that reads
   HWCAP/HWCAP2 and just **exits with that value as the exit code** (or
   writes it to stdout via raw `write` syscall). Confirms the naked entry +
   auxv parsing works before anything else depends on it.
3. Write `packer` v0: takes one binary, no variants/conditions, just
   appends a trivial always-matches trailer. Confirms concatenation +
   alignment + `chmod +x` + footer-seek-from-EOF all work end to end.
4. Wire `stub` to actually read its own trailer (steps 4–6 in §4) and
   `execve` into the single payload. First real "fat binary of one variant"
   working end to end.
5. Extend `packer` to multiple variants + real YAML config + bit-name
   resolution (§5).
6. Extend `stub`'s condition evaluation to walk multiple variants and
   actually branch (rather than "there's only one, use it").
7. Add `MIDR_EL1` read as a tiebreak source, test on real Neoverse V1/V2
   hardware (or under QEMU if that's what's available) to confirm the HWCAP2
   SVE2 bit genuinely separates V1 from V2 the way we expect.
8. x86_64 twin: port the entry trampoline (~10 lines of asm — see
   std.start's x86_64 branch), design the CPUID condition source, cross-build
   in CI. Detection is trivial on x86 (unprivileged CPUID) but the dispatch
   problem (no libc, no dynamic linker) is arch-independent — that's why x86
   still gets the fat binary treatment.
9. Nice-to-haves: `packer inspect`, streaming payload read instead of
   whole-file buffering, mmap+exec as a faster alternative dispatch path.

---

## 8. Open questions to settle before/while coding

- Exact HWCAP2 bit name/value for SVE2 on the target kernel headers — pin
  this down from `<asm/hwcap.h>` rather than guessing.
- Whether `/proc/self/exe` readlink is reliable enough across however this
  gets invoked (containers, chroots) or whether we need an `argv[0]` /
  `AT_EXECFN` fallback too. — RESOLVED (step 4): the stub uses `AT_EXECFN`
  from the auxv it already walks, and `execveat(fd, "", AT_EMPTY_PATH)` —
  no /proc, no readlink, no argv[0] guessing at all.
- Multicall payloads (busybox/coreutils style) dispatch on `argv[0]` — and
  the stub passes the FAT binary's name through (verified live: coreutils
  answered `unknown program 'fat'`). If such payloads matter, the config
  needs a per-variant `argv[0]` override the stub substitutes at exec
  time; ordinary payloads ignore argv[0] entirely.
- How to encode CPUID conditions (leaf/subleaf/register/bit) into the
  existing `Condition` mask/expected pair — x86 needs a richer vocabulary
  than aarch64's hwcap mask.
- Max payload size we're comfortable reading fully into memory vs. when
  streaming into the memfd becomes worth the complexity.
- Whether we ever want more than AND-of-conditions-per-variant match logic —
  resist adding this until something actually needs it.
