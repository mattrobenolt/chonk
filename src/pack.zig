//! packer v0 (direction.md §7 step 3): concatenate stub + one payload + an
//! always-matches trailer into a single executable fat binary. No config
//! file, no conditions, no bit names — those land in steps 5–6. All wire
//! bytes come from format.zig, the single source of truth shared with the
//! stub.
//!
//! Output layout:
//!
//!   [ stub ][ zero pad → page ][ payload ][ VariantEntry ][ Footer ]
//!                                              ↑ table_offset      ↑ EOF
//!
//! The packer is arch-blind: it stamps the footer's `machine` from the stub's
//! own ELF header and refuses stub/payload pairs whose machines disagree.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const elf = std.elf;

const format = @import("format.zig");
const stdio = @import("stdio.zig");

/// Not a format rule — a refusal to concatenate something absurd.
const max_file_size: u64 = 1 << 30;

/// `chonk pack <stub> <payload> <output>`. args = everything after the
/// subcommand word. stdio is initialized by the front door (main.zig).
pub fn run(io: Io, arena: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len != 3) {
        stdio.writeAll(.err, "usage: chonk pack <stub> <payload> <output>\n");
        return error.Usage;
    }

    const cwd = Io.Dir.cwd();
    // One-shot subcommand: reuse the process arena (freed at exit) — no
    // cleanup paths to get wrong, no leaks on error paths.
    const stub = try readFile(io, arena, cwd, args[0]);
    const payload = try readFile(io, arena, cwd, args[1]);

    const stub_machine = try elfMachine(args[0], stub);
    const payload_machine = try elfMachine(args[1], payload);
    if (stub_machine != payload_machine) {
        logFail(args[1], "machine mismatch with stub", error.MachineMismatch);
        return error.MachineMismatch;
    }

    const lay = try writeFat(io, cwd, args[2], stub, payload, stub_machine);

    stdio.print(
        .out,
        "packed: payload @ {d} (size {d}), table @ {d}, total {d}",
        .{ lay.payload_offset, payload.len, lay.table_offset, lay.size },
    );
    return 0;
}

/// Fat-binary offsets for v0. Pure math — testable without touching a file.
pub const Layout = struct {
    /// Absolute file offset of the payload (page-aligned).
    payload_offset: u64,
    /// Absolute file offset of `VariantEntry[0]`.
    table_offset: u64,
    /// Total output size.
    size: u64,
    /// Zero bytes between stub end and payload start.
    pad_len: usize,
};

pub fn layout(stub_len: u64, payload_len: u64) Layout {
    const payload_offset = mem.alignForward(u64, stub_len, format.page_size);
    const table_offset = payload_offset + payload_len;
    return .{
        .payload_offset = payload_offset,
        .table_offset = table_offset,
        .size = table_offset + @sizeOf(format.VariantEntry) + @sizeOf(format.Footer),
        .pad_len = @intCast(payload_offset - stub_len),
    };
}

/// Read a whole file. Logs the path on failure — "error.FileNotFound" with
/// no path is hostile from a CLI.
/// TODO: this should not read the entire file into memory, we should stream it!
fn readFile(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8) ![]u8 {
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

/// Validate ELF magic and extract `e_machine`. This is how the packer stays
/// arch-blind while keeping species from mixing.
fn elfMachine(path: []const u8, bytes: []const u8) !u16 {
    const machine_offset = @offsetOf(elf.Elf64_Ehdr, "e_machine");
    if (bytes.len < machine_offset + @sizeOf(u16) or
        !mem.eql(u8, bytes[0..4], elf.MAGIC))
    {
        logFail(path, "elf-check", error.NotAnElf);
        return error.NotAnElf;
    }
    return format.readInt(u16, bytes[machine_offset..][0..2]);
}

fn logFail(path: []const u8, action: []const u8, err: anyerror) void {
    stdio.print(.err, "pack: {s} {s}: {s}", .{ action, path, @errorName(err) });
}

/// Concatenate and write the fat binary. Creates the output with mode 0755
/// so it is executable as produced. The one v0 variant carries no
/// conditions and `is_default = 1`, so it matches unconditionally.
pub fn writeFat(
    io: Io,
    dir: Io.Dir,
    out_path: []const u8,
    stub: []const u8,
    payload: []const u8,
    machine: u16,
) !Layout {
    const lay = layout(stub.len, payload.len);

    const entry: format.VariantEntry = .{
        .payload_offset = lay.payload_offset,
        .payload_size = payload.len,
        .condition_offset = 0, // v0: no conditions
        .condition_count = 0,
        .is_default = 1,
    };
    const footer: format.Footer = .{
        .magic = format.magic,
        .table_offset = lay.table_offset,
        .variant_count = 1,
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
    // pad_len is always < page_size: alignForward rounds up by at most one
    // page, so a single zero page covers it.
    const zero_page: [format.page_size]u8 = @splat(0);
    try w.writeAll(zero_page[0..lay.pad_len]);
    try w.writeAll(payload);
    const entry_bytes = format.encode(format.VariantEntry, entry);
    try w.writeAll(&entry_bytes);
    const footer_bytes = format.encode(format.Footer, footer);
    try w.writeAll(&footer_bytes);
    try w.flush();

    return lay;
}

test "v0 layout" {
    const lay = layout(100, 0x2000);
    try testing.expectEqual(@as(u64, 4096), lay.payload_offset);
    try testing.expectEqual(@as(usize, 4096 - 100), lay.pad_len);
    try testing.expectEqual(@as(u64, 4096 + 0x2000), lay.table_offset);
    try testing.expectEqual(
        @as(u64, 4096 + 0x2000 + @sizeOf(format.VariantEntry) + @sizeOf(format.Footer)),
        lay.size,
    );
}

test "layout on exact page boundary needs no pad" {
    const lay = layout(4096, 10);
    try testing.expectEqual(@as(u64, 4096), lay.payload_offset);
    try testing.expectEqual(@as(usize, 0), lay.pad_len);
}

test "elfMachine extracts e_machine and rejects non-ELF" {
    // logFail writes through stdio.stderr — undefined until stdio.init runs.
    stdio.init(testing.io);
    var stub: [64]u8 = @splat(0xAA);
    stub[0..4].* = .{ 0x7f, 'E', 'L', 'F' };
    const e_machine_offset = @offsetOf(elf.Elf64_Ehdr, "e_machine");
    format.writeInt(u16, stub[e_machine_offset..][0..2], @intFromEnum(elf.EM.AARCH64));
    try testing.expectEqual(@intFromEnum(elf.EM.AARCH64), try elfMachine("stub", &stub));

    const not_elf = [_]u8{0} ** 64;
    try testing.expectError(error.NotAnElf, elfMachine("payload", &not_elf));
}

test "writeFat round-trips through a real file" {
    const io = testing.io;
    stdio.init(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Stand-in bytes, ELF-shaped where the packer looks: magic + e_machine.
    const e_machine_offset = @offsetOf(elf.Elf64_Ehdr, "e_machine");
    var stub: [100]u8 = @splat(0xAA);
    stub[0..4].* = .{ 0x7f, 'E', 'L', 'F' };
    format.writeInt(u16, stub[e_machine_offset..][0..2], @intFromEnum(elf.EM.AARCH64));
    var payload: [300]u8 = @splat(0xBB);
    payload[0..4].* = .{ 0x7f, 'E', 'L', 'F' };
    format.writeInt(u16, payload[e_machine_offset..][0..2], @intFromEnum(elf.EM.AARCH64));

    const machine = try elfMachine("stub", &stub);
    const lay = try writeFat(io, tmp.dir, "fat.bin", &stub, &payload, machine);
    const stat = try tmp.dir.statFile(io, "fat.bin", .{});
    try testing.expectEqual(lay.size, stat.size);
    // chmod +x landed.
    try testing.expect(stat.permissions.toMode() & 0o111 != 0);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fat = try readFile(io, arena.allocator(), tmp.dir, "fat.bin");

    // The stub's discovery path: footer findable from EOF alone.
    const footer = try format.findFooter(fat);
    try testing.expectEqual(lay.table_offset, footer.table_offset);
    try testing.expectEqual(@as(u32, 1), footer.variant_count);
    try testing.expectEqual(@intFromEnum(elf.EM.AARCH64), footer.machine);

    // Entry decodes at table_offset and describes the payload.
    const entry = try format.decode(format.VariantEntry, fat[@intCast(footer.table_offset)..]);
    try testing.expectEqual(lay.payload_offset, entry.payload_offset);
    try testing.expectEqual(@as(u64, payload.len), entry.payload_size);
    try testing.expectEqual(@as(u32, 0), entry.condition_count);
    try testing.expectEqual(@as(u8, 1), entry.is_default);

    // Bytes: stub verbatim up front, zero pad, payload verbatim at its
    // page-aligned offset.
    try testing.expectEqualSlices(u8, &stub, fat[0..stub.len]);
    for (fat[stub.len..][0..lay.pad_len]) |b| try testing.expectEqual(@as(u8, 0), b);
    const payload_start: usize = @intCast(lay.payload_offset);
    try testing.expectEqualSlices(u8, &payload, fat[payload_start..][0..payload.len]);
}
