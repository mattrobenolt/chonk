<p align="center"><img src="chonk.svg" alt="chonk" width="620"></p>

A fat binary dispatcher for Linux. A fat binary is one executable file that
contains several builds of the same program, and the running CPU picks
the payload at exec time. Think of a macOS universal binary, built for
Linux from scratch, with no libc, no IFUNC, and no dynamic linker in the
dispatch path.

The front of the file is a freestanding stub. It walks the initial stack,
reads the CPU features, picks the first variant whose conditions pass, and
execs into it. The payload then runs as a normal process. The kernel passes
the original argv, envp, and exit code through untouched.

## How it works

```
[ stub ][ pad → page ][ payload_0 ][ pad ][ payload_1 ] ...
[ Condition blob ][ VariantEntry[0..N] ][ Footer ]  ← last 32 bytes
```

The kernel reads the ELF header at the front of the file and starts the
stub. The kernel never maps the payloads; they are inert bytes until the
stub picks one.

At startup, the stub does this:

1. Walk the initial stack: argc, argv, envp, auxv.
2. Read `AT_EXECFN` (its own path), `AT_HWCAP`, and `AT_HWCAP2`.
3. Open its own file and read the footer from EOF.
4. Walk the variant table in order. The first variant whose conditions all
   pass wins. The variant with no match is the fallback.
5. Embedded mode (the default): stream the payload into a memfd with
   `sendfile`, then call `execveat` with `AT_EMPTY_PATH`. File mode: build
   `<its own path>.d/<variant>` and `execve` it — see
   [File mode](#file-mode-payloads-on-disk).

The release stub fits in the first three pages of the file. It issues raw
syscalls only: `openat`, `lseek`, `pread64`, `memfd_create`, `sendfile`,
and `execveat`. The file-mode stub is a separate build of the same dispatch
core: it replaces the memfd path with `readlinkat` and a plain `execve`, so
neither syscall appears in the binary. On aarch64 the detection values come
from the auxv; on x86_64 the stub reads CPUID and XCR0 itself. Both arms of
the entry are copied verbatim from Zig's own startup code, per architecture.

Inferred AVX variants require XCR0 bits 1 and 2. AVX-512 variants also
require bits 5, 6, and 7. The stub checks XSAVE and OSXSAVE before it
executes XGETBV. If either flag is absent, the XCR0 condition fails.

One fat binary serves one architecture. The footer stores the ELF
`e_machine` value, and the stub validates this value before it trusts the
trailer. Build one fat binary per architecture, with that architecture's
CPU tiers as targets. A cross-architecture universal binary cannot work on
Linux: the kernel loads the front ELF as the stub's architecture, and Linux
has no load-time architecture selector.

## File mode: payloads on disk

The default shape is one self-contained file, and dispatch ends in `execveat`
on a memfd. Under AppArmor, that exec has no path: the LSM resolves the
anonymous file to `/` (or a disconnected `memfd:` name), so a profile cannot
name the payload. The only rule that admits it is `/ ix` — execute anything —
which is a sandbox escape, not a policy.

File mode keeps the same variant table and dispatch logic, but the payloads
are separate files and the stub ends in a plain `execve` of a real path:

```
bin/app                  the shim (the stub plus the variant table)
bin/app.d/neoverse_v2
bin/app.d/neoverse_v1
bin/app.d/generic
```

The shim resolves `<its own path>.d/<variant>` at run time, using
`/proc/self/exe` and falling back to `AT_EXECFN` when `/proc` is not
mounted. A symlinked PATH entry therefore finds the payloads beside the real
file, and a shim renamed at install time looks in its own renamed directory.
Variant names are on the wire in both modes; in file mode they are file
names, so the packer accepts only single path components
(`A-Za-z0-9._-`, at most 255 bytes) and rejects duplicates.

CLI:

```console
$ chonk pack --files zig-out/bin/stub-aarch64-files config.zon bin/app
```

That writes `bin/app` and copies the payloads into `bin/app.d/`. Add
`--no-copy` when the caller installs the payloads itself. The stub matters:
file mode needs `stub-<arch>-files`. Each stub refuses a trailer of the
other mode at run time, so packing with the wrong one fails loudly instead
of dispatching garbage.

With the build API:

```zig
const files = chonk.addFilesExecutable(b, .{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),
    .target = .{ .cpu_arch = .aarch64, .abi = .musl },
    .targets = &.{ ... },
});
```

It returns `{ shim, payloads }`: install the shim as `bin/<name>` and each
payload as `bin/<name>.d/<payload.name>`. The default `install = true` does
exactly that; `examples/consumer` wires it by hand from `install = false`
and `zig build files`.

The AppArmor rule then names the files:

```
/usr/bin/handoff mrix,
/usr/bin/handoff.d/* mrix,
```

`ix` inherits the calling profile, which is what the payloads got before —
they are the same program. Use `px` on a named payload when it should
transition to its own profile. AppArmor matches resolved paths (the same
reason a `/var/run` rule matches `/run`), so a shim symlinked from a system
profile needs the rule for its resolved location, or the shim and its `.d/`
must be installed at a stable path.

Differences from embedded mode: inside the payload, `/proc/self/exe` and
`AT_EXECFN` point at the payload file, not the shim. `argv` and `envp` pass
through unchanged, so `argv[0]` is still the shim path. Condition evaluation,
first-match order, the fallback, and the exit code are identical. Identical
payload bytes are not deduplicated in file mode — each variant gets its own
file. The shim and its `.d/` directory must travel together; a shim installed
without the directory prints the path it tried and exits 1.

## Build-system integration

Add chonk as a dependency in `build.zig.zon`, then replace your
`b.addExecutable` with `chonk.addExecutable`:

```zig
const chonk = @import("chonk");

const fat = chonk.addExecutable(b, .{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),
    .target = .{ .cpu_arch = .aarch64, .abi = .musl },
    .optimize = optimize,
    .targets = &.{
        .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v2 } },
        .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v1 } },
        .{ .model = .{ .explicit = &Target.aarch64.cpu.neoverse_n1 } },
        // No fallback listed: chonk appends the arch baseline for you.
    },
});
```

`target` is the shared skeleton — architecture, OS, ABI — and `targets`
lists the CPU models. These are the only things that vary per variant. A
target entry can also carry an explicit `match` to override the condition
inference, for silicon chonk has not heard of.

A nonempty `match` replaces inference. It must include every required ISA
condition. `extra_match` adds conditions without removal of the inferred
checks, or supplements an explicit `match`.

```zig
.{
    .model = .{ .explicit = &Target.aarch64.cpu.neoverse_v3 },
    .extra_match = &.{chonk.midrPart(0x41, 0xd84)},
},
```

MIDR identifies the CPU model, not the ISA features that the kernel exposes.
The V3 entry retains the inferred ISA checks alongside its MIDR tiebreak.

For builds with dependencies or compile options, set `make_exe` instead
of `root_source_file`. chonk calls it once per variant with the
variant's resolved target; wire imports exactly as the normal build
does, and name the executable `v.name`:

```zig
fn makeExe(b: *Build, v: chonk.Variant) *Build.Step.Compile {
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = v.target,
        .optimize = v.optimize,
    });
    app_mod.addImport("my_dep", my_dep.module("my_dep"));
    const exe = b.addExecutable(.{ .name = v.name, .root_module = app_mod });
    exe.use_llvm = true;
    return exe;
}
```

The call does the rest:

- It compiles one intermediate binary per CPU model. The intermediates
  never install, and their names come from the CPU models.
- It infers the dispatch conditions from each target's feature delta over
  the arch baseline. On x86_64, this covers the psABI level features: the
  SSE4, AVX2, and AVX-512 families.
- It compiles the freestanding stub into your build graph from source,
  always `ReleaseSmall` and stripped.
- It packs everything in-process — the same module the CLI uses — and
  returns the fat file as a `LazyPath`.
- It runs `post_process` per variant, when set, and packs what it returns
  (see below).

The fat binary installs to `zig-out/bin/<name>`. Set `install` to `false`
and wire your own install step when the fat binary must stay off the
default install. `examples/consumer` shows the full pattern: `zig build`
builds the normal native binary, and `zig build chonk` builds the release
fleet. `examples/factory` shows `make_exe` with a dependency module
import and a `post_process` hook that swaps the fallback variant's payload
for a different binary.

To rewrite each payload between its compile and the pack, set
`post_process`. chonk calls it once per variant with the emitted binary;
the returned path is what gets packed, and the pack waits on whatever
step produces it:

```zig
fn postProcess(b: *Build, v: chonk.Variant, payload: LazyPath) LazyPath {
    _ = v;
    // copy first — patchelf rewrites in place
    const run = b.addSystemCommand(&.{ "bash", "-c",
        "cp \"$1\" \"$2\" && patchelf --set-interpreter " ++
        "/run/current-system/sw/bin/ld-linux-aarch64.so.1 \"$2\"" });
    run.addFileArg(payload);
    return run.addOutputFileArg("payload-patched");
}
```

`patchelf` the interpreter, force old dtags, sign, or compress — whatever
runs between compile and pack. Return `payload` unchanged for the
variants that need nothing.

### Dynamically linked payloads on NixOS

A payload that links a shared library hits a NixOS trap that looks like
a chonk bug. A variant built from a non-native `std.Target.Query` gets
zig's glibc-stub interpreter, `/lib/ld-linux-<arch>.so.1`. On NixOS that
path is nix-ld, and nix-ld resolves libraries through
`NIX_LD_LIBRARY_PATH`, which the system points at nixpkgs builds.
`LD_LIBRARY_PATH` is searched before `DT_RUNPATH`, so the payload binds
the nixpkgs library instead of the one its rpath names, and dies at
first use with an undefined symbol.

Verified against zig 0.16, neither of these fixes it:
`linker_enable_new_dtags = false` — the driver accepts `--disable-new-dtags`
and never forwards it to lld, so the payload always carries `DT_RUNPATH` —
and `query.dynamic_linker` pointing at the real loader — it propagates
into the glibc sub-compilations, which fail with
`ObjectFilesCannotSpecifyDynamicLinker`.

What works: run the fat binary with `LD_LIBRARY_PATH` naming the right
library's directory, or bake an rpath on the payload's module
(`root_module.addRPath`) and accept that nix-ld still wins when its
directory holds the same soname. The complete fix is a `post_process` hook
that `patchelf --set-interpreter`s each payload to the host's real
loader — the rewrite runs between compile and pack, where it belongs.

## Cloud coverage

One call per architecture covers the ARM fleets on AWS, GCP, and Azure:

| Model | Cloud | Separated by |
|---|---|---|
| `neoverse_v3` | AWS Graviton5 | Inferred ISA checks plus `extra_match = &.{midrPart(0x41, 0xd84)}` |
| `neoverse_v2` | AWS Graviton4, GCP Axion | inferred: the SVE2 family |
| `neoverse_v1` | AWS Graviton3 | inferred: SVE + crypto |
| `neoverse_n1` | AWS Graviton2, Azure Cobalt 100, Ampere Altra | inferred: base-word crypto (AES, SHA2, CRC32, LSE, ...) |
| baseline (appended) | AWS Graviton1 (Cortex-A72) + any v8.0 | — |

On x86_64, the psABI tiers do the same: `v4` (AVX-512: Sapphire/Emerald/
Granite Rapids, EPYC Genoa+) → `v3` (AVX2: Skylake, EPYC Naples–Milan) →
baseline. `examples/consumer` carries both ladders end to end.

`midrPart` is the tiebreak for same-hwcap silicon: when two microarchitectures
advertise identical feature words — V3 and V2 do, on many hosts — only the
part number separates them, and the stub reads `MIDR_EL1` directly.

## The CLI

```console
$ chonk pack <stub> <config.zon> <output>
$ chonk pack --files <stub> <config.zon> <shim>
$ chonk inspect <binary>
$ chonk --help
```

`pack` concatenates a stub file, the payload binaries from the config, and
the trailer. `--files` writes a file-mode shim instead and copies the
payloads into `<output>.d/`; `--no-copy` then means shim only. File mode
needs the matching `stub-<arch>-files` binary. `inspect` prints the variant
table of an existing fat binary or shim, including the names. Every command
and the top level accept `-h`/`--help`.

The config is ZON, a subset of Zig syntax. It type-checks at parse time:
a bit name implies its source, and a typo is a parse error with a line
number.

```zig
.{ .variants = .{
    .{ .name = "neoverse-v2", .binary = "build/app-v2", .match = .{
        .{ .bit = .sve2 },
    } },
    // Raw form, for anything the enum does not name:
    //   .{ .source = .hwcap, .mask = 0x400000, .expected = 0x400000 }
    // CPUID form (x86_64):
    //   .{ .cpuid = .{ .leaf = 7, .register = .ebx, .bit = 5 } }
    // AVX state condition, alongside the required CPUID features:
    //   .{ .source = .xcr0, .mask = 0x6, .expected = 0x6 }
    // AVX-512 state uses mask = expected = 0xe6.
    .{ .binary = "build/app-generic" }, // the fallback: no match
} }
```

## The wire format

All multi-byte integers are little-endian. `src/format.zig` is the single
source of truth for the packer and the stub.

| Record        | Size  | Fields                                                              |
| ------------- | ----- | ------------------------------------------------------------------- |
| `Footer`      | 32 B  | magic, `table_offset` u64, `variant_count` u32, `format_version` u32, `machine` u16, `mode` u8, pad |
| `VariantEntry`| 32 B  | `payload_offset` u64, `payload_size` u64, `condition_offset` u32, `condition_count` u32, `name_offset` u32, `name_len` u16, `is_default` u8, pad |
| `Condition`   | 24 B  | `mask` u64, `expected` u64, `source` u8, pad                          |

The name blob sits between the condition blob and the entry table;
`name_offset`/`name_len` index it. Names carry no terminator and are not
deduplicated. `payload_offset` is zero in file mode, where the bytes are not
in this file; `payload_size` is still recorded for `inspect` and diagnostics.

Condition sources:

- `hwcap` and `hwcap2` compare an auxv word against `mask`.
- `cpuid` transports a leaf, a subleaf, a register, and a bit.
- `midr` compares `MIDR_EL1` against `mask` for the CPU tiebreak.
- `xcr0` compares XCR0 against `mask` after the XSAVE and OSXSAVE checks.

Format version 2 added `xcr0` as source 4. Format version 3 adds the footer
`mode` byte and the per-variant name fields (the mode byte took a padding
byte; the name fields fit the existing 32-byte entry, so record sizes did
not grow). A stub rejects every trailer whose version or mode it does not
match, and the CLI requires the current stub for new packs.

In embedded mode, identical payload bytes are stored once — entries may
share `payload_offset`. The packer never holds payloads resident: sizes come
from stat, ELF checks from a positioned 64-byte header read, and the copy
streams in 32 KB chunks with a digest check, so a payload that changes
mid-pack fails instead of shipping.

The stub validates magic, version, machine, and mode before it trusts any
offset. The format is young, and a change bumps `format_version`; old
stubs refuse new trailers at run time.

## Requirements

- Zig 0.17.1 (`nix develop` supplies it)
- Linux, aarch64 or x86_64

## Development

`nix develop` supplies Zig 0.17, `just`, and qemu-user. `just` runs the
full e2e battery — `tests/e2e.sh`, a plain bash script: both pack doors,
the file-mode CLI and build doors, the qemu tier matrix, the factory
example, and the error paths. The host
arch picks the native legs; the qemu legs run everywhere. CI runs the
battery on both species on every push, an `ubuntu-24.04-arm` job and an
`ubuntu-24.04` job, so a full native dispatch on each architecture is
verified continuously.

Use `-cpu` models to verify dispatch under controlled CPU identities:

```console
$ qemu-aarch64 -cpu neoverse-v1 ./zig-out/bin/app  # SVE, no SVE2
$ qemu-aarch64 -cpu cortex-a72 ./zig-out/bin/app   # no SVE
```

A cross-architecture `execveat` under qemu-user reaches the host kernel,
so an emulated x86_64 payload cannot exec from an aarch64 host. The stub
mechanics still verify under `-strace`, and CI runs the real dispatch on
x86_64 hardware.

`direction.md` records the full design history.

## License

MIT — see [LICENSE](LICENSE).
