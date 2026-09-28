//! Wire format shared between `stub` (freestanding dispatcher) and `packer`
//! (hosted build tool): the single source of truth for the trailer contract
//! (direction.md §3, §6). Fixed-width records only — no variable-length
//! encoding inside records. All multi-byte integers are little-endian on the
//! wire. The footer is always the last `@sizeOf(Footer)` bytes of the file.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Footer magic: `"CHONKv01"` little-endian.
pub const magic: u64 = 0x3130_764b_4e4f_4843;

pub const format_version: u32 = 1;

/// Payload alignment within the fat file: absolute file offset must be a
/// multiple of this. Absolute (not relative) so mmap-based dispatch stays
/// possible later — mmap requires page-aligned file offsets.
pub const page_size = 4096;

/// Where a condition reads its value from. Per-source semantics:
///
///  - `hwcap`/`hwcap2`: `(value & mask) == expected`, value from the
///    auxv word.
///  - `cpuid` (x86_64): `mask` transports `(leaf << 32) | subleaf`,
///    `expected` transports `(register << 5) | bit`; the bit must be set.
///  - `midr`: reserved — the packer rejects it until the stub learns to
///    read it (direction.md step 7).
pub const Source = enum(u8) {
    /// `AT_HWCAP` (auxv type 16).
    hwcap = 0,
    /// `AT_HWCAP2` (auxv type 26).
    hwcap2 = 1,
    /// `MIDR_EL1`, readable at EL0 — Linux traps and emulates this read.
    midr = 2,
    /// x86_64 `CPUID` — unprivileged, read directly by the stub. Transport
    /// encoding in the enum doc above.
    cpuid = 3,
};

/// Fixed footer, always the last `@sizeOf(Footer)` bytes of the file.
/// The stub locates it by seeking to EOF and checking `magic`.
pub const Footer = extern struct {
    magic: u64,
    /// Absolute file offset of `VariantEntry[0]`.
    table_offset: u64,
    variant_count: u32,
    format_version: u32,
    /// ELF `e_machine` of the stub and payloads. The packer stamps it from
    /// the stub's own ELF header; the stub validates it against its own
    /// arch before trusting anything else in the file.
    machine: u16,
    _pad: [6]u8 = @splat(0),
};

/// One per variant, in match order (table order = config file order).
/// First variant whose conditions all pass wins. A variant with
/// `is_default != 0` matches unconditionally; the packer validates that
/// exactly one such variant exists.
pub const VariantEntry = extern struct {
    /// Absolute file offset of the payload ELF. Multiple of `page_size`.
    payload_offset: u64,
    payload_size: u64,
    /// Absolute file offset of `Condition[0]` for this variant.
    condition_offset: u32,
    condition_count: u32,
    is_default: u8,
    _pad: [7]u8 = @splat(0),
};

/// One condition. A variant matches when all of its conditions pass — AND
/// only, no OR logic. List two variants pointing at the same payload instead.
pub const Condition = extern struct {
    /// Bits to check.
    mask: u64,
    /// `(value & mask) == expected` passes.
    expected: u64,
    source: Source,
    _pad: [7]u8 = @splat(0),
};

// Field order puts u64s first so every padding byte is explicit — no hidden
// C-layout padding (direction.md's original sketch had u8 source + u64 mask
// at offset 4, which cannot exist with natural alignment).

pub const Error = error{
    Truncated,
    BadMagic,
    UnsupportedVersion,
    InvalidSource,
};

comptime {
    // Wire layout is pinned by these asserts; changing it is a
    // `format_version` bump.
    assert(@sizeOf(Footer) == 32);
    assert(@offsetOf(Footer, "table_offset") == 8);
    assert(@offsetOf(Footer, "machine") == 24);
    assert(@sizeOf(VariantEntry) == 32);
    assert(@offsetOf(VariantEntry, "payload_size") == 8);
    assert(@offsetOf(VariantEntry, "is_default") == 24);
    assert(@sizeOf(Condition) == 24);
    assert(@offsetOf(Condition, "expected") == 8);
    assert(@offsetOf(Condition, "source") == 16);
}

/// Encode `value` as little-endian wire bytes. `_pad` fields default to zero
/// and are copied as-is.
pub fn encode(comptime T: type, value: T) [@sizeOf(T)]u8 {
    var out: [@sizeOf(T)]u8 = @splat(0);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const offset: usize = @offsetOf(T, field.name);
        switch (@typeInfo(field.type)) {
            .int => |info| {
                const byte_count = @divExact(info.bits, 8);
                writeInt(
                    field.type,
                    out[offset .. offset + byte_count],
                    @field(value, field.name),
                );
            },
            .@"enum" => out[offset] = @intFromEnum(@field(value, field.name)),
            .array => |info| if (info.child == u8) {
                @memcpy(out[offset .. offset + info.len], &@field(value, field.name));
            } else @compileError("format: unsupported array field " ++ field.name),
            else => @compileError("format: unsupported field type " ++ @typeName(field.type)),
        }
    }
    return out;
}

/// Decode a wire record from `bytes`. Bounds-checked; enum fields are
/// validated against the known tag values.
pub fn decode(comptime T: type, bytes: []const u8) Error!T {
    if (bytes.len < @sizeOf(T)) return error.Truncated;
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const offset: usize = @offsetOf(T, field.name);
        switch (@typeInfo(field.type)) {
            .int => |info| {
                const byte_count = @divExact(info.bits, 8);
                @field(result, field.name) = readInt(
                    field.type,
                    bytes[offset .. offset + byte_count],
                );
            },
            .@"enum" => @field(result, field.name) = try enumFromByte(field.type, bytes[offset]),
            .array => |info| if (info.child == u8) {
                @memcpy(&@field(result, field.name), bytes[offset .. offset + info.len]);
            } else @compileError("format: unsupported array field " ++ field.name),
            else => @compileError("format: unsupported field type " ++ @typeName(field.type)),
        }
    }
    return result;
}

fn enumFromByte(comptime E: type, raw: u8) Error!E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (field.value == raw) return @enumFromInt(raw);
    }
    return error.InvalidSource;
}

pub inline fn readInt(comptime T: type, buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return std.mem.readInt(T, buffer, .little);
}

pub inline fn writeInt(
    comptime T: type,
    buffer: *[@divExact(@typeInfo(T).int.bits, 8)]u8,
    value: T,
) void {
    std.mem.writeInt(T, buffer, value, .little);
}

/// Locate and decode the footer at the end of `file`.
pub fn findFooter(file: []const u8) Error!Footer {
    if (file.len < @sizeOf(Footer)) return error.Truncated;
    const footer = try decode(Footer, file[file.len - @sizeOf(Footer) ..]);
    if (footer.magic != magic) return error.BadMagic;
    if (footer.format_version != format_version) return error.UnsupportedVersion;
    return footer;
}

test "magic is CHONKv01 little-endian" {
    const magic_bytes = [_]u8{ 'C', 'H', 'O', 'N', 'K', 'v', '0', '1' };
    try testing.expectEqual(magic, readInt(u64, &magic_bytes));
}

test "footer encode pins little-endian byte layout" {
    const footer: Footer = .{
        .magic = magic,
        .table_offset = 0x0102_0304_0506_0708,
        .variant_count = 0x090a_0b0c,
        .format_version = 0x0d0e_0f10,
        .machine = 0x1415,
    };
    const bytes = encode(Footer, footer);
    try testing.expectEqualSlices(u8, &[_]u8{
        'C',  'H',  'O',  'N',  'K',  'v',  '0',  '1',
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x0c, 0x0b, 0x0a, 0x09,
        0x10, 0x0f, 0x0e, 0x0d,
        0x15, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }, &bytes);
}

test "footer round-trip" {
    const footer: Footer = .{
        .magic = magic,
        .table_offset = 0x1234_5678_9abc_def0,
        .variant_count = 3,
        .format_version = format_version,
        .machine = 0xb7,
    };
    const bytes = encode(Footer, footer);
    try testing.expectEqual(footer, try decode(Footer, &bytes));
}

test "variant entry round-trip" {
    const entry: VariantEntry = .{
        .payload_offset = 0x0001_2340,
        .payload_size = 0x1000,
        .condition_offset = 0x20,
        .condition_count = 2,
        .is_default = 1,
    };
    const bytes = encode(VariantEntry, entry);
    try testing.expectEqual(entry, try decode(VariantEntry, &bytes));
}

test "condition round-trip" {
    const cond: Condition = .{
        .source = .hwcap2,
        .mask = 1 << 1, // HWCAP2_SVE2
        .expected = 1 << 1,
    };
    const bytes = encode(Condition, cond);
    try testing.expectEqual(cond, try decode(Condition, &bytes));
}

test "decode rejects unknown source" {
    const bytes = encode(Condition, .{ .source = .hwcap, .mask = 0, .expected = 0 });
    var corrupt = bytes;
    corrupt[@offsetOf(Condition, "source")] = 99;
    try testing.expectError(error.InvalidSource, decode(Condition, &corrupt));
}

test "decode rejects truncated buffer" {
    const bytes = encode(Footer, .{
        .magic = magic,
        .table_offset = 0,
        .variant_count = 0,
        .format_version = format_version,
        .machine = 0xb7,
    });
    try testing.expectError(error.Truncated, decode(Footer, bytes[0 .. bytes.len - 1]));
}

test "findFooter at EOF" {
    const payload: [64]u8 = @splat(0xAA); // stand-in payload bytes
    const footer: Footer = .{
        .magic = magic,
        .table_offset = 8,
        .variant_count = 2,
        .format_version = format_version,
        .machine = @intFromEnum(std.elf.EM.AARCH64),
    };
    const footer_bytes = encode(Footer, footer);
    var fat: [payload.len + footer_bytes.len]u8 = undefined;
    @memcpy(fat[0..payload.len], &payload);
    @memcpy(fat[payload.len..], &footer_bytes);
    try testing.expectEqual(footer, try findFooter(&fat));
}

test "findFooter rejects short file, bad magic, bad version" {
    try testing.expectError(error.Truncated, findFooter(&([_]u8{0} ** 23)));
    const no_magic: [@sizeOf(Footer)]u8 = @splat(0);
    try testing.expectError(error.BadMagic, findFooter(&no_magic));
    const wrong_version = encode(Footer, .{
        .magic = magic,
        .table_offset = 0,
        .variant_count = 0,
        .format_version = format_version + 1,
        .machine = 0xb7,
    });
    try testing.expectError(error.UnsupportedVersion, findFooter(&wrong_version));
}
