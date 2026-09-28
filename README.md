<p align="center"><img src="chonk.svg" alt="chonk" width="620"></p>

A fat binary dispatcher for Linux. A fat binary is one executable file that
contains several builds of the same program. The running CPU picks the
payload at exec time. Think of a macOS universal binary, built for Linux
from scratch — with no libc, no IFUNC, and no dynamic linker in the dispatch
path.

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
   On x86_64, conditions read CPUID directly; the instruction is
   unprivileged, so the kernel stays out of the detection path.
3. Open its own file and read the footer from EOF.
4. Walk the variant table in order. The first variant whose conditions all
   pass wins. The variant with no match is the fallback.
5. Stream the payload into a memfd with `sendfile`, then call `execveat`
   with `AT_EMPTY_PATH`.

The release stub fits in the first three pages of the file. It issues raw
syscalls only: `openat`, `lseek`, `pread64`, `memfd_create`, `sendfile`,
`execveat`.

One fat binary serves one architecture. The footer stores the ELF
`e_machine` value, and the stub validates this value before it trusts the
trailer. Build one fat binary per architecture, with that architecture's
CPU tiers as targets. A cross-architecture universal binary cannot work on
Linux: the kernel loads the front ELF as the stub's architecture, and Linux
has no load-time architecture selector.

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

For builds with dependencies, linked libraries, or compile options, set
`make_exe` instead of `root_source_file`. chonk calls it once per variant
with the variant's resolved target; wire imports and options exactly as
the normal build does, and name the executable `v.name`:

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

The fat binary installs to `zig-out/bin/<name>`. Set `install` to `false`
and wire your own install step when the fat binary must stay off the
default install. `examples/consumer` shows the full pattern: `zig build`
builds the normal native binary, and `zig build chonk` builds the release
fleet.

## The CLI

```console
$ chonk pack <stub> <config.zon> <output>
$ chonk inspect <binary>
```

`pack` concatenates a stub file, the payload binaries from the config, and
the trailer. `inspect` prints the variant table of an existing fat binary.

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
    .{ .binary = "build/app-generic" }, // the fallback: no match
} }
```

## The wire format

All multi-byte integers are little-endian. `src/format.zig` is the single
source of truth for the packer and the stub.

| Record        | Size  | Fields                                                              |
| ------------- | ----- | ------------------------------------------------------------------- |
| `Footer`      | 32 B  | magic, `table_offset` u64, `variant_count` u32, `format_version` u32, `machine` u16, pad |
| `VariantEntry`| 32 B  | `payload_offset` u64, `payload_size` u64, `condition_offset` u32, `condition_count` u32, `is_default` u8, pad |
| `Condition`   | 24 B  | `mask` u64, `expected` u64, `source` u8, pad                          |

Condition sources: `hwcap` and `hwcap2` compare an auxv word against
`mask`. `cpuid` transports a leaf, a subleaf, a register, and a bit.
`midr` is reserved.

The stub validates magic, version, and machine before it trusts any
offset. The format is young, and a change bumps `format_version`; old
stubs refuse new trailers at run time.

## Requirements

- Zig 0.16.0
- Linux, aarch64 or x86_64

## Development

From the repository root:

- `zig build` — build the CLI and both stubs (`stub-aarch64`,
  `stub-x86_64`).
- `zig build test` — run the tests.
- `ziglint src/ build.zig` — lint.
- `cd examples/consumer && zig build chonk` — build the example release
  fleet.

The devshell provides qemu-user. Use `-cpu` models to verify dispatch
under controlled CPU identities:

```console
$ qemu-aarch64 -cpu neoverse-v1 ./zig-out/bin/app  # SVE, no SVE2
$ qemu-aarch64 -cpu cortex-a72 ./zig-out/bin/app   # no SVE
```

A cross-architecture `execveat` under qemu-user reaches the host kernel,
so an emulated x86_64 payload cannot exec from an aarch64 host. The stub
mechanics still verify under `-strace`, and real x86_64 hardware runs the
full dispatch.

`direction.md` records the full design history.

## License

MIT — see [LICENSE](LICENSE).
