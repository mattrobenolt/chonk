//! Freestanding dispatcher (direction.md §7 step 4): the naked `_start`
//! walks the initial stack, finds its own file via AT_EXECFN, reads the
//! trailer from EOF, and dispatches to the winning variant. No libc, no
//! CRT; the only kernel calls are raw syscalls.
//!
//! Two modes, compiled as separate artifacts (chonk's build sets the
//! `files` option):
//!  - embedded: stream the payload out of this file into a memfd and
//!    `execveat` it (`AT_EMPTY_PATH`). One self-contained binary.
//!  - files: the payloads are separate files beside the shim, named
//!    `<shim>.d/<variant>`; a plain `execve` of a real path, which path-based
//!    LSM profiles (AppArmor) can mediate. The memfd is never created.
//!
//! Dispatch semantics are identical in both modes: first variant in table
//! order whose conditions all pass wins (an is_default entry, or one with
//! no conditions, matches unconditionally); conditions AND — aarch64
//! against AT_HWCAP/AT_HWCAP2, x86_64 against CPUID and the OS state in
//! XCR0.

const std = @import("std");
const linux = std.os.linux;
const elf = std.elf;
const builtin = @import("builtin");
const build_options = @import("build_options");

const format = @import("format.zig");
const x86 = @import("x86.zig");

/// The trailer mode this artifact understands. A comptime constant, so the
/// other mode's exec path is not even analyzed into the binary.
const my_mode: format.Mode = if (build_options.files) .files else .embedded;

/// Linux PATH_MAX. A longer path cannot be resolved by the kernel anyway.
const path_max = 4096;

/// The auxv record types this stub reads. `std.elf.AT` is keyed by OS, and a
/// freestanding target falls to the set that stops at NOTELF, so the Linux
/// ABI values live here.
const at = struct {
    const terminator = 0;
    const hwcap = 16;
    const hwcap2 = 26;
    const execfn = 31;
};

/// This stub's species — selected at comptime by the build target.
const my_machine: u16 = switch (builtin.cpu.arch) {
    .aarch64 => @backingInt(elf.EM.AARCH64),
    .x86_64 => @backingInt(elf.EM.X86_64),
    else => @compileError("chonk stub: unsupported arch"),
};

/// Kernel entry point. `callconv(.naked)` = the compiler emits ONLY this
/// asm, no prologue, so sp still points at the initial stack block the
/// kernel built:
///
///   [argc: u64][argv[0..argc]: u64 ptrs][NULL][envp: u64 ptrs][NULL]
///   [auxv: (a_type, a_val) u64 pairs...][AT_NULL, 0]
///
/// Both arms mirror std.start's entries verbatim: zero the frame pointer
/// (this is the first userspace frame — unwinder hygiene), pass the
/// ORIGINAL sp as the first argument, realign sp to 16, and never come
/// back (aarch64 tail-branches; x86_64 calls — both arms are one-way).
export fn _start() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov fp, #0
            \\ mov lr, #0
            \\ mov x0, sp
            \\ and sp, x0, #-16
            \\ b %[walk]
            :
            : [_start] "X" (&_start), // self-reference: forces emission
              [walk] "X" (&walk),
        ),
        .x86_64 => asm volatile (
            \\ xorl %%ebp, %%ebp
            \\ movq %%rsp, %%rdi
            \\ andq $-16, %%rsp
            \\ callq %[walk:P]
            :
            : [_start] "X" (&_start),
              [walk] "X" (&walk),
        ),
        else => @compileError("chonk stub: unsupported arch"),
    }
}

/// Read MIDR_EL1 — aarch64 only. The kernel traps and emulates this read
/// at EL0, but only when HWCAP_CPUID (AT_HWCAP bit 11) is advertised;
/// callers must gate on it or the read faults.
fn readMidr() u64 {
    return asm volatile ("mrs x0, midr_el1"
        : [out] "={x0}" (-> u64),
    );
}

/// Walk the initial stack (x0 = the original sp), then dispatch.
fn walk(argc_argv_ptr: [*]usize) callconv(.c) noreturn {
    // Same posture as std.start: no TLS exists yet, so a safety panic would
    // itself crash before it could report anything. The walk and dispatch
    // run with runtime safety off; the trailer's explicit validation still
    // guards every read.
    @setRuntimeSafety(false);

    const argc = argc_argv_ptr[0];
    const argv: [*]const ?[*:0]const u8 = @ptrCast(argc_argv_ptr + 1);

    // envp starts right after argv's NULL terminator.
    const envp = argv + argc + 1;
    var envp_count: usize = 0;
    while (envp[envp_count] != null) : (envp_count += 1) {}

    // auxv: (a_type, a_val) pairs, right after envp's NULL terminator.
    const auxv: [*]const elf.Auxv = @ptrCast(@alignCast(envp + envp_count + 1));

    // AT_EXECFN points at the kernel's own record of the file it exec'd —
    // the honest way to find ourselves. argv[0] is caller-controlled and
    // readlink("/proc/self/exe") needs /proc mounted; AT_EXECFN needs neither.
    // HWCAP/HWCAP2 are the CPU's advertised feature words — what conditions
    // are evaluated against.
    var execfn: ?[*:0]const u8 = null;
    var hwcap: u64 = 0;
    var hwcap2: u64 = 0;
    var i: usize = 0;
    while (auxv[i].a_type != at.terminator) : (i += 1) {
        switch (auxv[i].a_type) {
            at.execfn => execfn = @ptrFromInt(auxv[i].a_un.a_val),
            at.hwcap => hwcap = auxv[i].a_un.a_val,
            at.hwcap2 => hwcap2 = auxv[i].a_un.a_val,
            else => {},
        }
    }

    const path = execfn orelse fatal("no AT_EXECFN in auxv");
    dispatch(path, argv, envp, hwcap, hwcap2);
}

fn dispatch(
    path: [*:0]const u8,
    argv: [*]const ?[*:0]const u8,
    envp: [*]const ?[*:0]const u8,
    hwcap: u64,
    hwcap2: u64,
) noreturn {
    @setRuntimeSafety(false);

    const fat_rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (linux.errno(fat_rc) != .SUCCESS) fatalSyscall("openat self", fat_rc);
    const fat_fd: linux.fd_t = @intCast(fat_rc);

    const size_rc = linux.lseek(fat_fd, 0, linux.SEEK.END);
    if (linux.errno(size_rc) != .SUCCESS) fatalSyscall("lseek self", size_rc);
    const file_size: u64 = @bitCast(size_rc);

    // Footer: always the last @sizeOf(Footer) bytes.
    var footer_bytes: [@sizeOf(format.Footer)]u8 = undefined;
    preadFull(fat_fd, &footer_bytes, @as(i64, @bitCast(file_size)) - @sizeOf(format.Footer));
    const footer = format.decode(format.Footer, &footer_bytes) catch
        fatal("footer does not decode");
    if (footer.magic != format.magic) fatal("bad footer magic — not a chonk binary");
    if (footer.format_version != format.format_version) fatal("unsupported trailer format version");
    if (footer.machine != my_machine) fatal("trailer is for a different machine");
    if (footer.mode != my_mode) fatal(switch (my_mode) {
        .embedded => "file-mode trailer — this is the embedded stub (use stub-*-files)",
        .files => "embedded fat binary — this is the file-mode stub (pack --files)",
    });

    // Entry table: variant_count entries at table_offset. The trailer is
    // untrusted — widen the u32 count before any arithmetic.
    if (@as(u64, footer.variant_count) * @sizeOf(format.VariantEntry) >
        file_size - @as(u64, @sizeOf(format.Footer)))
    {
        fatal("entry table out of range");
    }

    // First match wins, in table order. An is_default entry (or one with no
    // conditions) matches unconditionally — the packer puts the default
    // last, so it is the catch-all.
    var entry_index: usize = 0;
    while (entry_index < footer.variant_count) : (entry_index += 1) {
        const entry_at = footer.table_offset +
            entry_index * @sizeOf(format.VariantEntry);
        var entry_bytes: [@sizeOf(format.VariantEntry)]u8 = undefined;
        preadFull(fat_fd, &entry_bytes, @intCast(entry_at));
        const entry = format.decode(format.VariantEntry, &entry_bytes) catch
            fatal("entry does not decode");

        if (entry.is_default != 0 or entry.condition_count == 0 or
            matches(fat_fd, footer.table_offset, entry, hwcap, hwcap2))
        {
            if (my_mode == .files) {
                execFile(fat_fd, footer.table_offset, entry, path, argv, envp);
            } else {
                execVariant(fat_fd, footer.table_offset, entry, argv, envp);
            }
        }
    }
    fatal("no variant matched — malformed trailer (no default?)");
}

/// Evaluate one variant's conditions against the CPU: ANDed, all must pass.
fn matches(
    fat_fd: linux.fd_t,
    table_offset: u64,
    entry: format.VariantEntry,
    hwcap: u64,
    hwcap2: u64,
) bool {
    var cond_index: u32 = 0;
    while (cond_index < entry.condition_count) : (cond_index += 1) {
        // Widen before arithmetic — condition_count/offset are untrusted.
        const cond_at = @as(u64, entry.condition_offset) +
            @as(u64, cond_index) * @sizeOf(format.Condition);
        if (cond_at + @sizeOf(format.Condition) > table_offset) {
            fatal("conditions out of range");
        }
        var cond_bytes: [@sizeOf(format.Condition)]u8 = undefined;
        preadFull(fat_fd, &cond_bytes, @intCast(cond_at));
        const condition = format.decode(format.Condition, &cond_bytes) catch
            fatal("condition does not decode");

        // Per-source semantics (see format.Source). hwcap/hwcap2 compare
        // an auxv word; cpuid transports (leaf, subleaf, register, bit) and
        // tests the bit.
        const ok = switch (condition.source) {
            .hwcap => (hwcap & condition.mask) == condition.expected,
            .hwcap2 => (hwcap2 & condition.mask) == condition.expected,
            .cpuid => blk: {
                // Comptime-gated: the x86 asm is never analyzed on aarch64.
                if (builtin.cpu.arch == .x86_64) {
                    const leaf: u32 = @truncate(condition.mask >> 32);
                    const subleaf: u32 = @truncate(condition.mask);
                    const reg: u8 = @truncate(condition.expected >> 5);
                    const bit: u5 = @truncate(condition.expected);
                    const r = x86.Native.readCpuid(leaf, subleaf);
                    const word: u32 = switch (reg) {
                        0 => r.eax,
                        1 => r.ebx,
                        2 => r.ecx,
                        3 => r.edx,
                        else => fatal("cpuid condition has a bad register"),
                    };
                    break :blk (word >> bit) & 1 == 1;
                }
                fatal("cpuid condition on a non-x86_64 stub");
            },
            .xcr0 => blk: {
                if (builtin.cpu.arch == .x86_64) {
                    break :blk x86.matchesXcr0(x86.Native, condition.mask, condition.expected);
                }
                fatal("xcr0 condition on a non-x86_64 stub");
            },
            .midr => blk: {
                // Comptime-gated: the aarch64 asm is never analyzed on
                // x86_64 (same pattern as the cpuid prong).
                if (builtin.cpu.arch == .aarch64) {
                    // The kernel emulates the read only when HWCAP_CPUID
                    // is advertised. Without it the read would fault, so
                    // fail the condition instead — the dispatch falls to
                    // the next tier, which is the safe direction.
                    if (hwcap & (1 << 11) == 0) return false;
                    break :blk (readMidr() & condition.mask) == condition.expected;
                }
                fatal("midr condition on a non-aarch64 stub");
            },
        };
        if (!ok) return false;
    }
    return true;
}

/// Stream `entry`'s payload into a fresh memfd and become it (embedded
/// mode). sendfile does the copying in the kernel — no userspace buffer, no
/// whole-file residency.
fn execVariant(
    fat_fd: linux.fd_t,
    table_offset: u64,
    entry: format.VariantEntry,
    argv: [*]const ?[*:0]const u8,
    envp: [*]const ?[*:0]const u8,
) noreturn {
    // Payload must fit strictly between its offset and the entry table.
    if (entry.payload_offset >= table_offset or
        entry.payload_size > table_offset - entry.payload_offset)
        fatal("payload out of range");

    const name: [*:0]const u8 = "chonk-payload";
    const mem_rc = linux.memfd_create(name, linux.MFD.CLOEXEC);
    if (linux.errno(mem_rc) != .SUCCESS) fatalSyscall("memfd_create", mem_rc);
    const mem_fd: linux.fd_t = @intCast(mem_rc);

    var sent_off: i64 = @intCast(entry.payload_offset);
    var remaining: u64 = entry.payload_size;
    while (remaining > 0) {
        const sent = linux.sendfile(mem_fd, fat_fd, &sent_off, @intCast(remaining));
        if (linux.errno(sent) != .SUCCESS) fatalSyscall("sendfile", sent);
        if (sent == 0) fatal("fat binary truncated inside payload");
        remaining -= @intCast(sent);
    }

    // Become the payload. AT_EMPTY_PATH + the memfd: no /proc mount needed,
    // no path resolution at all. argv/envp pass through exactly as the
    // kernel handed them to us — same pointers, same order, same NULLs.
    const exec_rc = linux.execveat(
        mem_fd,
        "",
        @ptrCast(argv),
        @ptrCast(envp),
        .{ .SYMLINK_NOFOLLOW = false, .EMPTY_PATH = true },
    );
    // Success never returns.
    fatalSyscall("execveat", exec_rc);
}

/// File mode: build `<shim>.d/<name>` beside this executable and exec it.
/// A plain execve of a real path — no memfd, no execveat — so path-based
/// LSM profiles (AppArmor) can mediate the transition and name the payload
/// in their rules.
fn execFile(
    fat_fd: linux.fd_t,
    table_offset: u64,
    entry: format.VariantEntry,
    execfn: [*:0]const u8,
    argv: [*]const ?[*:0]const u8,
    envp: [*]const ?[*:0]const u8,
) noreturn {
    @setRuntimeSafety(false);

    // Name blob: untrusted like the rest of the trailer.
    if (entry.name_len == 0) fatal("variant has no name — repack in file mode");
    if (entry.name_len > format.max_name_len) fatal("variant name too long");
    if (@as(u64, entry.name_offset) + entry.name_len > table_offset)
        fatal("variant name out of range");

    var name: [format.max_name_len]u8 = undefined;
    preadFull(fat_fd, name[0..entry.name_len], @intCast(entry.name_offset));

    // The packer enforces this; the reader enforces it too, so a hand-built
    // shim cannot turn a name into a path traversal.
    for (name[0..entry.name_len]) |c| {
        if (c == '/' or c == 0) fatal("variant name is not a path component");
    }

    // Locate ourselves. /proc/self/exe follows symlinks, which matters when
    // PATH resolves through one; AT_EXECFN is the fallback when /proc is
    // not mounted.
    var self_buf: [path_max]u8 = undefined;
    const self_path = selfPath(execfn, &self_buf);

    var payload_path: [path_max]u8 = undefined;
    const len = payloadPath(self_path, name[0..entry.name_len], &payload_path) orelse
        fatal("payload path exceeds PATH_MAX");

    // argv/envp pass through exactly as the kernel handed them to us, so
    // the payload sees the same command line it would in embedded mode.
    const exec_rc = linux.execve(
        payload_path[0..len :0].ptr,
        @ptrCast(argv),
        @ptrCast(envp),
    );
    fatalExecPath(exec_rc, payload_path[0..len]);
}

/// The path the kernel executed: /proc/self/exe first (it resolves
/// symlinks), AT_EXECFN as the no-/proc fallback.
fn selfPath(execfn: [*:0]const u8, buf: *[path_max]u8) []const u8 {
    const rc = linux.readlinkat(linux.AT.FDCWD, "/proc/self/exe", buf, buf.len);
    if (linux.errno(rc) == .SUCCESS and rc > 0 and rc < buf.len) {
        return buf[0..rc];
    }
    return std.mem.span(execfn);
}

/// `<dirname(self)>/<basename(self)>.d/<name>`, NUL-terminated. Returns the
/// length without the terminator, or null when the result does not fit.
///
/// The directory derives from the resolved self path, so a symlinked entry
/// point finds the payloads beside the real file and a renamed shim looks
/// in its own renamed directory.
fn payloadPath(self_path: []const u8, name: []const u8, out: *[path_max]u8) ?usize {
    @setRuntimeSafety(false);

    // Everything through the last '/', including it — or nothing at all
    // when the exec path was a bare name.
    var prefix: usize = 0;
    for (self_path, 0..) |c, i| {
        if (c == '/') prefix = i + 1;
    }
    const base = self_path[prefix..];
    const total = prefix + base.len + ".d/".len + name.len;
    if (total + 1 > out.len) return null;

    @memcpy(out[0..prefix], self_path[0..prefix]);
    var cursor = prefix;
    @memcpy(out[cursor..][0..base.len], base);
    cursor += base.len;
    @memcpy(out[cursor..][0..".d/".len], ".d/");
    cursor += ".d/".len;
    @memcpy(out[cursor..][0..name.len], name);
    cursor += name.len;
    out[cursor] = 0;
    return cursor;
}

/// Read exactly `buf.len` bytes at `offset` from `fd`. Any shortfall is
/// fatal — the trailer is trusted with nothing.
fn preadFull(fd: linux.fd_t, buf: []u8, offset: i64) void {
    var done: usize = 0;
    while (done < buf.len) {
        const read_at = offset + @as(i64, @intCast(done));
        const rc = linux.pread(fd, buf.ptr + done, buf.len - done, read_at);
        if (linux.errno(rc) != .SUCCESS) fatalSyscall("pread", rc);
        if (rc == 0) fatal("fat binary truncated (short read)");
        done += rc;
    }
}

/// Report to stderr and die — dispatch either execs or ends here.
fn fatal(comptime what: []const u8) noreturn {
    @branchHint(.cold);
    var stderr_buffer: [128]u8 = undefined;
    var w: Writer = .init(linux.STDERR_FILENO, &stderr_buffer);
    w.append("chonk: ");
    w.append(what);
    w.append("\n");
    _ = linux.write(w.fd, w.slice().ptr, w.slice().len);
    linux.exit_group(1);
}

/// execve's errno plus the path it tried: the diagnostic a denied profile
/// or a missing payload directory needs.
fn fatalExecPath(rc: usize, path: []const u8) noreturn {
    @branchHint(.cold);
    var stderr_buffer: [256]u8 = undefined;
    var w: Writer = .init(linux.STDERR_FILENO, &stderr_buffer);
    w.append("chonk: execve payload: E");
    w.append(@tagName(linux.errno(rc)));
    w.append("\n    ");
    // Fixed buffer: clip an unusually long path rather than overflow.
    const room = w.remaining().len - 1; // leave the newline a slot
    w.append(path[0..@min(path.len, room)]);
    w.append("\n");
    _ = linux.write(w.fd, w.slice().ptr, w.slice().len);
    linux.exit_group(1);
}

fn fatalSyscall(comptime what: []const u8, rc: usize) noreturn {
    @branchHint(.cold);
    var stderr_buffer: [160]u8 = undefined;
    var w: Writer = .init(linux.STDERR_FILENO, &stderr_buffer);
    w.append("chonk: ");
    w.append(what);
    w.append(": ");
    w.append(@tagName(linux.errno(rc)));
    w.append("\n");
    _ = linux.write(w.fd, w.slice().ptr, w.slice().len);
    linux.exit_group(1);
}

/// Fixed-buffer writer — no allocator, no std.Io, nothing but us. Bounded by
/// construction: every message fits its buffer with room to spare.
const Writer = struct {
    fd: linux.fd_t,
    buf: []u8,
    len: u8 = 0,

    fn init(fd: linux.fd_t, buf: []u8) Writer {
        return .{ .fd = fd, .buf = buf };
    }

    fn append(w: *Writer, s: []const u8) void {
        var buf = w.remaining();
        @memcpy(buf[0..s.len], s);
        w.len += @intCast(s.len);
    }

    fn remaining(w: *Writer) []u8 {
        return w.buf[w.len..];
    }

    fn slice(w: *const Writer) []const u8 {
        return w.buf[0..w.len];
    }
};
