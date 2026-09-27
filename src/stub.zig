//! Freestanding dispatcher prototype (direction.md §7 step 2): naked `_start`
//! walks the initial stack — argc / argv / envp / auxv — reads AT_HWCAP and
//! AT_HWCAP2, prints both, exits. No libc, no CRT; the only kernel calls are
//! raw `write` and `exit_group`.

const std = @import("std");
const linux = std.os.linux;
const elf = std.elf;

/// Kernel entry point. `callconv(.naked)` = the compiler emits ONLY this asm,
/// no prologue, so sp still points at the initial stack block the kernel
/// built:
///
///   [argc: u64][argv[0..argc]: u64 ptrs][NULL][envp: u64 ptrs][NULL]
///   [auxv: (a_type, a_val) u64 pairs...][AT_NULL, 0]
///
/// Mirrors std.start's aarch64 entry: zero fp/lr (this is the first
/// userspace frame — unwinder hygiene), pass the ORIGINAL sp in x0,
/// realign sp to 16, tail-branch into Zig code.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ mov fp, #0
        \\ mov lr, #0
        \\ mov x0, sp
        \\ and sp, x0, #-16
        \\ b %[walk]
        :
        : [_start] "X" (&_start), // self-reference: forces emission
          [walk] "X" (&walk),
    );
}

/// Walk the initial stack. x0 on entry = the original sp (see `_start`).
fn walk(argc_argv_ptr: [*]usize) callconv(.c) noreturn {
    // Nothing is initialized yet (no TLS) — a safety panic here would itself
    // crash before it could report anything, so the walk runs with runtime
    // safety off. Same call std.start makes.
    @setRuntimeSafety(false);

    const argc = argc_argv_ptr[0];
    const argv: [*]const ?[*:0]const u8 = @ptrCast(argc_argv_ptr + 1);

    // envp starts right after argv's NULL terminator.
    const envp = argv + argc + 1;
    var envp_count: usize = 0;
    while (envp[envp_count] != null) : (envp_count += 1) {}

    // auxv: (a_type, a_val) pairs, right after envp's NULL terminator.
    const auxv: [*]const elf.Auxv = @ptrCast(@alignCast(envp + envp_count + 1));

    var hwcap: u64 = 0;
    var hwcap2: u64 = 0;
    var i: usize = 0;
    while (auxv[i].a_type != elf.AT_NULL) : (i += 1) {
        switch (auxv[i].a_type) {
            elf.AT_HWCAP => hwcap = auxv[i].a_un.a_val,
            elf.AT_HWCAP2 => hwcap2 = auxv[i].a_un.a_val,
            else => {},
        }
    }

    // Report, e.g.: argc=1 hwcap=0xeff3ffff hwcap2=0x801bf3bf
    var line: [80]u8 = undefined;
    var w: Writer = .{ .buf = &line };
    w.append("argc=");
    w.dec(argc);
    w.append(" hwcap=0x");
    w.hex(hwcap);
    w.append(" hwcap2=0x");
    w.hex(hwcap2);
    w.append("\n");

    // Prototype: if the write fails there is nothing left to do anyway.
    _ = linux.write(1, w.constSlice().ptr, w.constSlice().len);
    linux.exit_group(0);
}

/// Fixed-buffer writer — no allocator, no std.Io, nothing but us. Bounded by
/// construction: the report line fits `line`'s 80 bytes with room to spare.
const Writer = struct {
    buf: []u8,
    len: u8 = 0,

    fn append(w: *Writer, s: []const u8) void {
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += @intCast(s.len);
    }

    fn hex(w: *Writer, val: u64) void {
        const digits = "0123456789abcdef";
        for (0..16) |i| {
            const digit: u4 = @truncate(val >> @intCast(60 - 4 * i));
            w.buf[w.len] = digits[digit];
            w.len += 1;
        }
    }

    fn dec(w: *Writer, val: u64) void {
        // u64 max is 20 digits. Emit reversed, then reverse in place.
        var tmp: [20]u8 = undefined;
        var n: usize = 0;
        var v = val;
        while (true) {
            tmp[n] = @intCast('0' + v % 10);
            n += 1;
            v /= 10;
            if (v == 0) break;
        }
        while (n > 0) {
            n -= 1;
            w.buf[w.len] = tmp[n];
            w.len += 1;
        }
    }

    fn constSlice(w: *const Writer) []const u8 {
        return w.buf[0..w.len];
    }
};
