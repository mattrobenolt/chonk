//! `chonk pack` (direction.md §5, §7 step 5): read a ZON config describing
//! variants + payload binaries, validate everything the stub will later
//! trust, and concatenate stub + payloads + conditions + entry table +
//! footer into one executable fat binary. All wire bytes come from
//! format.zig — the single source of truth shared with the stub.
//!
//! Output layout:
//!
//!   [ stub ][ pad→page ][ payload_0 ][ pad ][ payload_1 ] ...
//!   [ Condition blob ][ VariantEntry[0..N] ][ Footer ]
//!                                           ↑ table_offset  ↑ EOF
//!
//! The packer is arch-blind: it stamps the footer's `machine` from the
//! stub's own ELF header and refuses payloads whose machines disagree.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const elf = std.elf;
const fs_path = std.fs.path;

const format = @import("format.zig");
const stdio = @import("stdio.zig");
const zon = std.zon;

/// Not a format rule — a refusal to concatenate something absurd.
const max_file_size: u64 = 1 << 30;

// ---------------------------------------------------------------------------
// Config schema — what chonk.zon parses into.
// ---------------------------------------------------------------------------

/// The parsed config file.
pub const Config = struct {
    variants: []const Variant,
};

pub const Variant = struct {
    /// Display name — pure metadata, never on the wire, never read by the
    /// stub. Defaults to the payload basename; duplicates among EXPLICIT
    /// names are rejected (derived ones may collide legally: two variants
    /// pointing at the same payload with different conditions is the OR
    /// pattern).
    name: ?[]const u8 = null,
    /// Payload binary path, relative to the config file's directory.
    binary: []const u8,
    /// Conditions ANDed together. First variant in file order whose
    /// conditions all pass wins. THE VARIANT WITH NO MATCH IS THE
    /// FALLBACK — exactly one such variant per config.
    match: []const Match = &.{},
};

pub const Match = struct {
    /// Kernel hwcap bit that must be set. Implies its source; excludes
    /// the raw fields below.
    bit: ?Bit = null,
    /// Raw form: `(source & mask) == expected`. All three fields required;
    /// excludes `bit`.
    source: ?format.Source = null,
    mask: ?u64 = null,
    expected: ?u64 = null,
    /// x86_64 form: the CPUID leaf/subleaf/register/bit that must be set.
    /// Excludes everything above.
    cpuid: ?Cpuid = null,
};

/// One CPUID feature-present test (x86_64).
pub const Cpuid = struct {
    /// CPUID leaf (EAX input).
    leaf: u32,
    /// CPUID subleaf (ECX input), where the leaf uses one.
    subleaf: u32 = 0,
    /// Which output register carries the bit.
    register: Register,
    /// The bit, 0-31, that must be set.
    bit: u5,

    pub const Register = enum(u8) { eax, ebx, ecx, edx };
};

// ---------------------------------------------------------------------------
// Bit vocabulary — the only place chonk knows what "sve2" means.
// ---------------------------------------------------------------------------

/// Kernel hwcap bits the config accepts, pinned from
/// arch/arm64/include/uapi/asm/hwcap.h (torvalds master, 2026-09-27). A
/// name implies its source — that is the whole reason named bits exist:
/// the config never says "hwcap2", the enum does.
pub const Bit = enum {
    sve,
    sve2,
    sveaes,
    svepmull,
    svebitperm,
    svesha3,
    svesm4,
    svei8mm,
    svebf16,
    i8mm,
    bf16,
    sme,

    /// The wire form: which source word, which bit.
    pub fn spec(bit: Bit) struct { source: format.Source, mask: u64 } {
        return switch (bit) {
            .sve => .{ .source = .hwcap, .mask = 1 << 22 },
            .sve2 => .{ .source = .hwcap2, .mask = 1 << 1 },
            .sveaes => .{ .source = .hwcap2, .mask = 1 << 2 },
            .svepmull => .{ .source = .hwcap2, .mask = 1 << 3 },
            .svebitperm => .{ .source = .hwcap2, .mask = 1 << 4 },
            .svesha3 => .{ .source = .hwcap2, .mask = 1 << 5 },
            .svesm4 => .{ .source = .hwcap2, .mask = 1 << 6 },
            .svei8mm => .{ .source = .hwcap2, .mask = 1 << 9 },
            .svebf16 => .{ .source = .hwcap2, .mask = 1 << 12 },
            .i8mm => .{ .source = .hwcap2, .mask = 1 << 13 },
            .bf16 => .{ .source = .hwcap2, .mask = 1 << 14 },
            .sme => .{ .source = .hwcap2, .mask = 1 << 23 },
        };
    }
};

// ---------------------------------------------------------------------------
// run — the `chonk pack <stub> <config.zon> <output>` subcommand.
// ---------------------------------------------------------------------------

/// `chonk pack <stub> <config.zon> <output>` — the human door. The build
/// system calls `packAll` in-process as a module instead. args = everything
/// after the subcommand word; stdio is initialized by the front door.
pub fn run(io: Io, arena: Allocator, args: []const [:0]const u8) !u8 {
    const cwd = Io.Dir.cwd();

    if (args.len != 3) {
        stdio.writeAll(.err, "usage: chonk pack <stub> <config.zon> <output>");
        return error.Usage;
    }

    // Parse the config. ZON errors print with line:column from diag.
    const config_bytes = try readFile(io, arena, cwd, args[1]);
    const source = try arena.allocSentinel(u8, config_bytes.len, 0);
    @memcpy(source, config_bytes);
    var diag: zon.parse.Diagnostics = .{};
    const config = zon.parse.fromSliceAlloc(Config, arena, source, &diag, .{
        .free_on_error = false,
    }) catch |err| {
        if (err == error.ParseZon) {
            stdio.print(.err, "chonk: {s}: {f}", .{ args[1], &diag });
        }
        return error.Config;
    };

    // Payload paths are relative to the config's own directory.
    const config_dir: Io.Dir = if (fs_path.dirname(args[1])) |dir_name|
        try cwd.openDir(io, dir_name, .{})
    else
        cwd;

    return packAll(io, arena, cwd, config_dir, args[2], args[0], config);
}

/// The shared tail of both pack forms: read + check the stub, validate the
/// config, load + compile variants, write the fat binary, report.
pub fn packAll(
    io: Io,
    arena: Allocator,
    cwd: Io.Dir,
    config_dir: Io.Dir,
    out_path: []const u8,
    stub_path: []const u8,
    config: Config,
) !u8 {
    const stub = try readFile(io, arena, cwd, stub_path);
    const stub_machine = (try elfCheck(stub_path, stub)).machine;

    try validateConfig(config);
    const named = try normalizeConfig(arena, config);
    const loaded = try loadVariants(io, arena, config_dir, named, stub_machine);

    const lay = try writeFat(io, arena, cwd, out_path, stub, stub_machine, loaded);

    stdio.print(.out, "packed: {d} variants, total {d}", .{ loaded.len, lay.size });
    for (loaded, lay.payload_offsets) |v, offset| {
        const suffix: []const u8 = if (v.cfg.match.len == 0) ", fallback" else "";
        stdio.print(
            .out,
            "  {s}: payload @ {d} ({d} byte(s), {d} condition(s){s})",
            .{ v.cfg.name, offset, v.payload.len, v.conditions.len, suffix },
        );
    }
    return 0;
}

/// Config-level checks that need no filesystem: variant count, exactly one
/// default, unique names.
fn validateConfig(config: Config) !void {
    if (config.variants.len == 0) return configFail("config has no variants", .{});
    var fallback_count: usize = 0;
    for (config.variants) |v| {
        if (v.match.len == 0) fallback_count += 1;
    }
    if (fallback_count != 1) {
        return configFail(
            "exactly one variant must have no match (the fallback) — found {d}",
            .{fallback_count},
        );
    }
    for (config.variants, 0..) |a, i| {
        for (config.variants[i + 1 ..]) |b| {
            if (a.name != null and b.name != null and mem.eql(u8, a.name.?, b.name.?)) {
                return configFail("duplicate variant name '{s}'", .{a.name.?});
            }
        }
    }
}

/// Variant after normalization — the display name is guaranteed.
const NamedVariant = struct {
    name: []const u8,
    binary: []const u8,
    match: []const Match,
};

/// Fill optional names with derived ones — the payload basename. Display
/// only; downstream error messages and reports read better with a name.
fn normalizeConfig(arena: Allocator, config: Config) Allocator.Error![]NamedVariant {
    const variants = try arena.alloc(NamedVariant, config.variants.len);
    for (config.variants, 0..) |v, i| {
        variants[i] = .{
            .name = v.name orelse fs_path.basename(v.binary),
            .binary = v.binary,
            .match = v.match,
        };
    }
    return variants;
}

/// One validated variant: config + payload bytes + compiled conditions.
const LoadedVariant = struct {
    cfg: NamedVariant,
    payload: []const u8,
    conditions: []const format.Condition,
};

fn loadVariants(
    io: Io,
    arena: Allocator,
    config_dir: Io.Dir,
    variants: []const NamedVariant,
    stub_machine: u16,
) ![]LoadedVariant {
    const loaded = try arena.alloc(LoadedVariant, variants.len);
    for (variants, 0..) |v, i| {
        const payload = try readFile(io, arena, config_dir, v.binary);
        const ident = try elfCheck(v.binary, payload);
        if (ident.machine != stub_machine) {
            return configFail("{s}: machine mismatch with stub", .{v.binary});
        }
        if (!ident.is_program) {
            return configFail("{s}: not an executable — a library or no entry", .{v.binary});
        }
        loaded[i] = .{
            .cfg = v,
            .payload = payload,
            .conditions = try compileMatches(arena, v),
        };
    }
    return loaded;
}

/// Translate config matches into wire conditions. Every failure is a
/// config error with the variant's name attached.
fn compileMatches(arena: Allocator, v: NamedVariant) ![]const format.Condition {
    const out = try arena.alloc(format.Condition, v.match.len);
    for (v.match, 0..) |m, i| {
        if (m.cpuid) |c| {
            if (m.bit != null or m.source != null or m.mask != null or m.expected != null) {
                return configFail(
                    "variant '{s}': cpuid form excludes bit/source/mask/expected",
                    .{v.name},
                );
            }
            // Transport: mask = (leaf << 32) | subleaf,
            // expected = (register << 5) | bit. The stub requires the bit set.
            out[i] = .{
                .mask = (@as(u64, c.leaf) << 32) | c.subleaf,
                .expected = (@as(u64, @intFromEnum(c.register)) << 5) | c.bit,
                .source = .cpuid,
            };
        } else if (m.bit) |bit| {
            if (m.source != null or m.mask != null or m.expected != null) {
                return configFail(
                    "variant '{s}': bit form excludes source/mask/expected",
                    .{v.name},
                );
            }
            const s = bit.spec();
            out[i] = .{ .mask = s.mask, .expected = s.mask, .source = s.source };
        } else {
            const mask = m.mask orelse {
                return configFail("variant '{s}': raw match needs a mask", .{v.name});
            };
            const expected = m.expected orelse {
                return configFail("variant '{s}': raw match needs an expected", .{v.name});
            };
            const source = m.source orelse {
                return configFail("variant '{s}': raw match needs a source", .{v.name});
            };
            // The stub cannot read MIDR_EL1 yet (step 7) — refuse at pack
            // time rather than shipping a fat binary that dies at dispatch.
            if (source == .midr) {
                return configFail(
                    "variant '{s}': midr source lands with MIDR_EL1 support (step 7)",
                    .{v.name},
                );
            }
            if (mask == 0) {
                return configFail("variant '{s}': mask 0 checks nothing", .{v.name});
            }
            out[i] = .{ .mask = mask, .expected = expected, .source = source };
        }
    }
    return out;
}

/// Report a config problem and hand back the config error — mapped to
/// exit 1 by the front door.
fn configFail(comptime fmt: []const u8, args: anytype) error{Config} {
    stdio.print(.err, "chonk: " ++ fmt, args);
    return error.Config;
}

// ---------------------------------------------------------------------------
// File + ELF helpers.
// ---------------------------------------------------------------------------

/// Read a whole file. Logs the path on failure — "error.FileNotFound" with
/// no path is hostile from a CLI.
pub fn readFile(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8) ![]u8 {
    var file = dir.openFile(io, path, .{}) catch |err| {
        logFail(path, "open", err);
        return err;
    };
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    return file_reader.interface.allocRemaining(gpa, .limited(max_file_size)) catch |err| {
        logFail(path, "read", err);
        return err;
    };
}

const ElfIdentity = struct {
    machine: u16,
    /// e_type is EXEC or DYN with a nonzero entry — the file survives
    /// execve. Libraries (DYN with no entry) and relocatables do not.
    is_program: bool,
};

/// Validate ELF magic and extract what the packer needs. This is how the
/// packer stays arch-blind while keeping species from mixing.
fn elfCheck(path: []const u8, bytes: []const u8) error{NotAnElf}!ElfIdentity {
    const e_type_off = @offsetOf(elf.Elf64_Ehdr, "e_type");
    const e_machine_off = @offsetOf(elf.Elf64_Ehdr, "e_machine");
    const e_entry_off = @offsetOf(elf.Elf64_Ehdr, "e_entry");
    if (bytes.len < e_entry_off + @sizeOf(u64) or !mem.eql(u8, bytes[0..4], elf.MAGIC)) {
        logFail(path, "elf-check", error.NotAnElf);
        return error.NotAnElf;
    }
    const e_type = format.readInt(u16, bytes[e_type_off..][0..2]);
    const entry = format.readInt(u64, bytes[e_entry_off..][0..8]);
    return .{
        .machine = format.readInt(u16, bytes[e_machine_off..][0..2]),
        .is_program = (e_type == @intFromEnum(elf.ET.EXEC) or
            e_type == @intFromEnum(elf.ET.DYN)) and entry != 0,
    };
}

fn logFail(path: []const u8, action: []const u8, err: anyerror) void {
    stdio.print(.err, "packer: {s} {s}: {s}", .{ action, path, @errorName(err) });
}

// ---------------------------------------------------------------------------
// Layout + write.
// ---------------------------------------------------------------------------

/// Fat-binary offsets for N variants. Pure math over lengths — testable
/// without touching a file.
pub const Layout = struct {
    /// Per-variant absolute page-aligned payload offsets.
    payload_offsets: []u64,
    /// Per-variant absolute offsets of the variant's first Condition in
    /// the condition blob.
    condition_offsets: []u32,
    /// Absolute offset of `VariantEntry[0]`.
    table_offset: u64,
    /// Total output size.
    size: u64,
};

pub fn layout(
    arena: Allocator,
    stub_len: u64,
    payload_lens: []const u64,
    condition_counts: []const u32,
) Allocator.Error!Layout {
    const payload_offsets = try arena.alloc(u64, payload_lens.len);
    const condition_offsets = try arena.alloc(u32, condition_counts.len);

    var cursor: u64 = stub_len;
    for (payload_lens, 0..) |payload_len, i| {
        cursor = mem.alignForward(u64, cursor, format.page_size);
        payload_offsets[i] = cursor;
        cursor += payload_len;
    }

    // Condition blob: right after the last payload. No alignment needed —
    // the stub reads conditions through the decoder, not mmap.
    const blob_start = cursor;
    var running: u64 = 0;
    for (condition_counts, 0..) |count, i| {
        condition_offsets[i] = @intCast(blob_start + running);
        running += @as(u64, count) * @sizeOf(format.Condition);
    }
    cursor += running;

    const table_offset = cursor;
    cursor += @as(u64, payload_lens.len) * @sizeOf(format.VariantEntry) +
        @sizeOf(format.Footer);

    return .{
        .payload_offsets = payload_offsets,
        .condition_offsets = condition_offsets,
        .table_offset = table_offset,
        .size = cursor,
    };
}

/// Concatenate and write the fat binary: stub, page-padded payloads,
/// condition blob, entry table, footer. Output mode 0755.
fn writeFat(
    io: Io,
    arena: Allocator,
    dir: Io.Dir,
    out_path: []const u8,
    stub: []const u8,
    machine: u16,
    variants: []const LoadedVariant,
) !Layout {
    const payload_lens = try arena.alloc(u64, variants.len);
    const condition_counts = try arena.alloc(u32, variants.len);
    for (variants, 0..) |v, i| {
        payload_lens[i] = v.payload.len;
        condition_counts[i] = @intCast(v.conditions.len);
    }
    const lay = try layout(arena, stub.len, payload_lens, condition_counts);

    const entries = try arena.alloc(format.VariantEntry, variants.len);
    for (variants, 0..) |v, i| {
        entries[i] = .{
            .payload_offset = lay.payload_offsets[i],
            .payload_size = v.payload.len,
            .condition_offset = lay.condition_offsets[i],
            .condition_count = @intCast(v.conditions.len),
            .is_default = if (v.cfg.match.len == 0) 1 else 0,
        };
    }
    const footer: format.Footer = .{
        .magic = format.magic,
        .table_offset = lay.table_offset,
        .variant_count = @intCast(variants.len),
        .format_version = format.format_version,
        .machine = machine,
    };

    var out_file = dir.createFile(io, out_path, .{
        .permissions = .fromMode(0o755),
    }) catch |err| {
        logFail(out_path, "create", err);
        return err;
    };
    defer out_file.close(io);

    var out_buffer: [4096]u8 = undefined;
    var out: Io.File.Writer = .init(out_file, io, &out_buffer);
    const w = &out.interface;

    try w.writeAll(stub);
    // Each pad is < page_size: alignForward rounds up by at most one page.
    const zero_page: [format.page_size]u8 = @splat(0);
    var cursor: u64 = stub.len;
    for (variants, 0..) |v, i| {
        try w.writeAll(zero_page[0..@intCast(lay.payload_offsets[i] - cursor)]);
        try w.writeAll(v.payload);
        cursor = lay.payload_offsets[i] + v.payload.len;
    }
    for (variants) |v| {
        for (v.conditions) |c| {
            const condition_bytes = format.encode(format.Condition, c);
            try w.writeAll(&condition_bytes);
        }
    }
    for (entries) |e| {
        const entry_bytes = format.encode(format.VariantEntry, e);
        try w.writeAll(&entry_bytes);
    }
    const footer_bytes = format.encode(format.Footer, footer);
    try w.writeAll(&footer_bytes);
    try w.flush();

    return lay;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "layout: single variant matches the v0 math" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lay = try layout(arena, 100, &.{0x2000}, &.{0});
    try testing.expectEqual(@as(u64, 4096), lay.payload_offsets[0]);
    try testing.expectEqual(@as(u64, 4096 + 0x2000), lay.table_offset);
    try testing.expectEqual(
        @as(u64, 4096 + 0x2000 + @sizeOf(format.VariantEntry) + @sizeOf(format.Footer)),
        lay.size,
    );
    // One pad between stub and payload.
    try testing.expectEqual(@as(u64, 4096 - 100), lay.payload_offsets[0] - 100);
}

test "layout: two variants with conditions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // stub 100B, payload_0 0x2000B starting at 4096, payload_1 10B at
    // 4096+0x2000 (already page-aligned), conditions 2 then 0.
    const lay = try layout(arena, 100, &.{ 0x2000, 10 }, &.{ 2, 0 });
    try testing.expectEqual(@as(u64, 4096), lay.payload_offsets[0]);
    try testing.expectEqual(@as(u64, 4096 + 0x2000), lay.payload_offsets[1]);
    const blob_start: u64 = 4096 + 0x2000 + 10;
    try testing.expectEqual(@as(u32, @intCast(blob_start)), lay.condition_offsets[0]);
    // Zero-count variant points at the same place the table starts.
    const after_two: u64 = blob_start + 2 * @sizeOf(format.Condition);
    try testing.expectEqual(@as(u32, @intCast(after_two)), lay.condition_offsets[1]);
    const table_offset: u64 = blob_start + 2 * @sizeOf(format.Condition);
    try testing.expectEqual(table_offset, lay.table_offset);
    try testing.expectEqual(
        table_offset + 2 * @sizeOf(format.VariantEntry) + @sizeOf(format.Footer),
        lay.size,
    );
}

test "config parses from ZON" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    stdio.init(testing.io);

    const source =
        \\.{ .variants = .{
        \\    .{ .name = "neoverse-v2", .binary = "bin/app-v2", .match = .{
        \\        .{ .bit = .sve2 },
        \\        .{ .source = .hwcap, .mask = 0x400000, .expected = 0x400000 },
        \\    } },
        \\    // The fallback: no match at all, and no name — it derives
        \\    // from the payload basename.
        \\    .{ .binary = "bin/app-generic" },
        \\} }
    ;
    const buf = try arena.allocSentinel(u8, source.len, 0);
    @memcpy(buf, source);
    var diag: zon.parse.Diagnostics = .{};
    const config = zon.parse.fromSliceAlloc(Config, arena, buf, &diag, .{
        .free_on_error = false,
    }) catch |err| {
        stdio.print(.err, "parse failed: {f}", .{&diag});
        return err;
    };

    try testing.expectEqual(@as(usize, 2), config.variants.len);
    try testing.expectEqualStrings("neoverse-v2", config.variants[0].name.?);
    try testing.expectEqual(@as(usize, 2), config.variants[0].match.len);
    try testing.expectEqual(Bit.sve2, config.variants[0].match[0].bit.?);
    try testing.expectEqual(format.Source.hwcap, config.variants[0].match[1].source.?);
    // No match = the fallback; no name in the file = null until derived.
    try testing.expect(config.variants[1].name == null);
    try testing.expectEqual(@as(usize, 0), config.variants[1].match.len);

    // Normalization fills the derived name (payload basename).
    const named = try normalizeConfig(arena, config);
    try testing.expectEqualStrings("app-generic", named[1].name);
    try testing.expectEqualStrings("neoverse-v2", named[0].name);
}

test "compileMatches: bit name implies source and expected" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    stdio.init(testing.io);

    const v: NamedVariant = .{
        .name = "v2",
        .binary = "bin/app-v2",
        .match = &.{.{ .bit = .sve2 }},
    };
    const conditions = try compileMatches(arena, v);
    try testing.expectEqual(@as(usize, 1), conditions.len);
    try testing.expectEqual(@as(u64, 1 << 1), conditions[0].mask);
    try testing.expectEqual(@as(u64, 1 << 1), conditions[0].expected);
    try testing.expectEqual(format.Source.hwcap2, conditions[0].source);
}

test "ZON rejects unknown bits at parse time" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    stdio.init(testing.io);

    // A bad bit name is a type error now — line:column from the parser,
    // not a runtime configFail.
    const source =
        \\.{ .variants = .{
        \\    .{ .name = "x", .binary = "b", .match = .{ .{ .bit = .totally_real } } },
        \\    .{ .name = "generic", .binary = "g" },
        \\} }
    ;
    const buf = try arena.allocSentinel(u8, source.len, 0);
    @memcpy(buf, source);
    var diag: zon.parse.Diagnostics = .{};
    try testing.expectError(error.ParseZon, zon.parse.fromSliceAlloc(
        Config,
        arena,
        buf,
        &diag,
        .{ .free_on_error = false },
    ));
}

test "compileMatches: rejects mixed and incomplete forms" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    stdio.init(testing.io);

    // Bit form with raw fields set.
    try testing.expectError(error.Config, compileMatches(arena, .{
        .name = "v", .binary = "b",
        .match = &.{.{ .bit = .sve2, .mask = 1 }},
    }));
    // Raw form missing expected.
    try testing.expectError(error.Config, compileMatches(arena, .{
        .name = "v", .binary = "b",
        .match = &.{.{ .source = .hwcap2, .mask = 1 }},
    }));
    // No form at all.
    try testing.expectError(error.Config, compileMatches(arena, .{
        .name = "v", .binary = "b", .match = &.{.{}},
    }));
    // MIDR source is gated until the stub can read it (step 7).
    try testing.expectError(error.Config, compileMatches(arena, .{
        .name = "v", .binary = "b",
        .match = &.{.{ .source = .midr, .mask = 1, .expected = 1 }},
    }));
}

test "elfCheck: machine + program-ness" {
    stdio.init(testing.io);
    const e_type_off = @offsetOf(elf.Elf64_Ehdr, "e_type");
    const e_machine_off = @offsetOf(elf.Elf64_Ehdr, "e_machine");
    const e_entry_off = @offsetOf(elf.Elf64_Ehdr, "e_entry");

    // EXEC with an entry: a program.
    var prog: [64]u8 = @splat(0xAA);
    prog[0..4].* = .{ 0x7f, 'E', 'L', 'F' };
    format.writeInt(u16, prog[e_type_off..][0..2], @intFromEnum(elf.ET.EXEC));
    format.writeInt(u16, prog[e_machine_off..][0..2], @intFromEnum(elf.EM.AARCH64));
    format.writeInt(u64, prog[e_entry_off..][0..8], 0x1000);
    const ident = try elfCheck("prog", &prog);
    try testing.expectEqual(@intFromEnum(elf.EM.AARCH64), ident.machine);
    try testing.expect(ident.is_program);

    // DYN (shared object) with no entry: not a program — the libm lesson.
    var lib: [64]u8 = @splat(0xBB);
    lib[0..4].* = .{ 0x7f, 'E', 'L', 'F' };
    format.writeInt(u16, lib[e_type_off..][0..2], @intFromEnum(elf.ET.DYN));
    format.writeInt(u16, lib[e_machine_off..][0..2], @intFromEnum(elf.EM.AARCH64));
    format.writeInt(u64, lib[e_entry_off..][0..8], 0);
    try testing.expect(!(try elfCheck("lib", &lib)).is_program);

    const not_elf = [_]u8{0} ** 64;
    try testing.expectError(error.NotAnElf, elfCheck("payload", &not_elf));
}

test "writeFat: two-variant round-trip through a real file" {
    const io = testing.io;
    stdio.init(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const e_type_off = @offsetOf(elf.Elf64_Ehdr, "e_type");
    const e_machine_off = @offsetOf(elf.Elf64_Ehdr, "e_machine");
    const e_entry_off = @offsetOf(elf.Elf64_Ehdr, "e_entry");

    const stub: [100]u8 = @splat(0xAA);
    var payload_0: [300]u8 = @splat(0xB0);
    payload_0[0..4].* = .{ 0x7f, 'E', 'L', 'F' };
    format.writeInt(u16, payload_0[e_type_off..][0..2], @intFromEnum(elf.ET.EXEC));
    format.writeInt(u16, payload_0[e_machine_off..][0..2], @intFromEnum(elf.EM.AARCH64));
    format.writeInt(u64, payload_0[e_entry_off..][0..8], 0x1000);
    var payload_1: [37]u8 = @splat(0xB1);
    payload_1[0..4].* = .{ 0x7f, 'E', 'L', 'F' };
    format.writeInt(u16, payload_1[e_type_off..][0..2], @intFromEnum(elf.ET.EXEC));
    format.writeInt(u16, payload_1[e_machine_off..][0..2], @intFromEnum(elf.EM.AARCH64));
    format.writeInt(u64, payload_1[e_entry_off..][0..8], 0x1000);

    const machine = @intFromEnum(elf.EM.AARCH64);
    const loaded = [_]LoadedVariant{
        .{
            .cfg = .{ .name = "v2", .binary = "p0", .match = &.{.{ .bit = .sve2 }} },
            .payload = &payload_0,
            .conditions = try compileMatches(arena, .{
                .name = "v2", .binary = "p0", .match = &.{.{ .bit = .sve2 }},
            }),
        },
        .{
            .cfg = .{ .name = "generic", .binary = "p1", .match = &.{} },
            .payload = &payload_1,
            .conditions = &.{},
        },
    };

    const lay = try writeFat(io, arena, tmp.dir, "fat.bin", &stub, machine, &loaded);
    const stat = try tmp.dir.statFile(io, "fat.bin", .{});
    try testing.expectEqual(lay.size, stat.size);
    try testing.expect(stat.permissions.toMode() & 0o111 != 0);

    const fat = try readFile(io, arena, tmp.dir, "fat.bin");

    // The stub's discovery path: footer from EOF alone.
    const footer = try format.findFooter(fat);
    try testing.expectEqual(@as(u32, 2), footer.variant_count);
    try testing.expectEqual(machine, footer.machine);
    try testing.expectEqual(lay.table_offset, footer.table_offset);

    // Both entries decode in table order and describe their payloads.
    const entries = try arena.alloc(format.VariantEntry, 2);
    for (entries, 0..) |*e, i| {
        const at: usize = @intCast(footer.table_offset + i * @sizeOf(format.VariantEntry));
        e.* = try format.decode(format.VariantEntry, fat[at..]);
    }
    try testing.expectEqual(@as(u64, payload_0.len), entries[0].payload_size);
    try testing.expectEqual(@as(u8, 0), entries[0].is_default);
    try testing.expectEqual(@as(u32, 1), entries[0].condition_count);
    try testing.expectEqual(@as(u8, 1), entries[1].is_default);
    try testing.expectEqual(@as(u32, 0), entries[1].condition_count);

    // Payload bytes verbatim at their page-aligned offsets.
    const p0_at: usize = @intCast(entries[0].payload_offset);
    try testing.expectEqualSlices(u8, &payload_0, fat[p0_at..][0..payload_0.len]);
    const p1_at: usize = @intCast(entries[1].payload_offset);
    try testing.expectEqualSlices(u8, &payload_1, fat[p1_at..][0..payload_1.len]);

    // Conditions decode at the entry's offset: SVE2 bit, hwcap2, expected set.
    const c0 = try format.decode(
        format.Condition,
        fat[@intCast(entries[0].condition_offset)..],
    );
    try testing.expectEqual(@as(u64, 1 << 1), c0.mask);
    try testing.expectEqual(@as(u64, 1 << 1), c0.expected);
    try testing.expectEqual(format.Source.hwcap2, c0.source);
}
