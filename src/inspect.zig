//! `chonk inspect <binary>` — the `unzip -l` of fat binaries: decode the
//! trailer and print the variant table in human form. Names never touch the
//! wire, so everything shown is reverse-mapped from the wire bytes through
//! chonk's vocabulary; anything the vocabulary does not know prints raw.
//! The trailer is untrusted input, same as the stub — every region is
//! bounds-checked before it is decoded.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

const format = @import("format.zig");
const pack = @import("pack.zig");
const stdio = @import("stdio.zig");

/// `chonk inspect <binary>`. args = everything after the subcommand word.
pub fn run(io: Io, arena: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len != 1) {
        stdio.writeAll(.err, "usage: chonk inspect <binary>");
        return error.Usage;
    }

    const fat = try pack.readFile(io, arena, Io.Dir.cwd(), args[0]);
    const footer = format.findFooter(fat) catch |err| {
        stdio.print(.err, "chonk: {s}: not a chonk binary ({s})", .{ args[0], @errorName(err) });
        return 1;
    };

    stdio.print(.out, "{s}: chonk fat binary", .{args[0]});
    stdio.print(
        .out,
        "  format version {d}, machine {s}, {d} variants, total {d} bytes",
        .{ footer.format_version, machineName(footer.machine), footer.variant_count, fat.len },
    );

    // Entry table: variant_count entries at table_offset, all before the
    // footer. Widen before arithmetic — the trailer is untrusted.
    const count = @as(u64, footer.variant_count) * @sizeOf(format.VariantEntry);
    if (footer.table_offset + count > fat.len - @as(u64, @sizeOf(format.Footer))) {
        stdio.print(.err, "chonk: {s}: entry table out of range", .{args[0]});
        return 1;
    }

    for (0..footer.variant_count) |i| {
        const at: usize = @intCast(footer.table_offset + i * @sizeOf(format.VariantEntry));
        const entry = try format.decode(format.VariantEntry, fat[at..]);

        const fallback = if (entry.is_default != 0 or entry.condition_count == 0)
            ", fallback"
        else
            "";
        stdio.print(
            .out,
            "  {d}: payload @ {d} ({d} bytes, {d} condition(s){s})",
            .{ i, entry.payload_offset, entry.payload_size, entry.condition_count, fallback },
        );

        // Conditions: count records at condition_offset, ending before the
        // entry table — the same constraint the stub enforces.
        for (0..entry.condition_count) |j| {
            const cond_at = @as(u64, entry.condition_offset) +
                @as(u64, j) * @sizeOf(format.Condition);
            if (cond_at + @sizeOf(format.Condition) > footer.table_offset) {
                stdio.print(.err, "chonk: {s}: conditions out of range", .{args[0]});
                return 1;
            }
            const condition = try format.decode(
                format.Condition,
                fat[@intCast(cond_at)..],
            );
            stdio.print(.out, "    {s}", .{describeCondition(arena, condition)});
        }
    }
    return 0;
}

fn machineName(machine: u16) []const u8 {
    return switch (machine) {
        @intFromEnum(std.elf.EM.AARCH64) => "aarch64",
        @intFromEnum(std.elf.EM.X86_64) => "x86_64",
        else => "unknown",
    };
}

/// One condition, human form: the vocabulary's name where it knows the
/// value, the raw comparison otherwise.
fn describeCondition(arena: Allocator, condition: format.Condition) []const u8 {
    switch (condition.source) {
        .hwcap, .hwcap2 => {
            // The same table inference reads — display is the reverse
            // direction of the same vocabulary.
            inline for (pack.aarch64_table) |e| {
                if (e.source == condition.source and e.mask == condition.mask and
                    condition.expected == e.mask)
                {
                    return @tagName(e.bit);
                }
            }
            return std.fmt.allocPrint(
                arena,
                "({s} & 0x{x}) == 0x{x}",
                .{ @tagName(condition.source), condition.mask, condition.expected },
            ) catch "oom";
        },
        .cpuid => {
            const leaf: u32 = @truncate(condition.mask >> 32);
            const subleaf: u32 = @truncate(condition.mask);
            const reg: u8 = @truncate(condition.expected >> 5);
            const bit: u5 = @truncate(condition.expected);
            // The same table inference reads — display names are the Zig
            // feature names the table is keyed by.
            inline for (pack.x86_table) |e| {
                if (e.cpuid.leaf == leaf and e.cpuid.subleaf == subleaf and
                    @intFromEnum(e.cpuid.register) == reg and e.cpuid.bit == bit)
                {
                    return @tagName(e.feature);
                }
            }
            const reg_name = switch (reg) {
                0 => "eax",
                1 => "ebx",
                2 => "ecx",
                3 => "edx",
                else => "?",
            };
            return std.fmt.allocPrint(
                arena,
                "cpuid({x}:{x}).{s}[{d}]",
                .{ leaf, subleaf, reg_name, bit },
            ) catch "oom";
        },
        .midr => return "midr (reserved — unsupported by the stub)",
    }
}

test "describeCondition names known values, raw otherwise" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A named aarch64 bit: sve2's own spec.
    const s = pack.spec(.sve2);
    try testing.expectEqualStrings(
        "sve2",
        describeCondition(arena, .{
            .mask = s.mask,
            .expected = s.mask,
            .source = s.source,
        }),
    );

    // A named CPUID bit: avx2.
    try testing.expectEqualStrings(
        "avx2",
        describeCondition(arena, .{
            .mask = (@as(u64, 7) << 32) | 0,
            .expected = (@as(u64, @intFromEnum(pack.Cpuid.Register.ebx)) << 5) | 5,
            .source = .cpuid,
        }),
    );

    // Unknown hwcap mask: raw comparison.
    try testing.expectEqualStrings(
        "(hwcap2 & 0x1) == 0x1",
        describeCondition(arena, .{ .mask = 1, .expected = 1, .source = .hwcap2 }),
    );
}
