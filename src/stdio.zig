//! Buffered stdio for the main thread — the one place in the process that
//! owns writing to stdout/stderr.
//!
//! `init` runs once from main, before anything can log; the buffers are
//! process-lifetime globals (4 KiB each, BSS), so no allocator is involved.
//! Flush failures are ignored on the exit path — there is nothing left to
//! do about a dead stderr while the process is going away.

const std = @import("std");
const Io = std.Io;
const heap = std.heap;

var stdout_buffer: [4096]u8 align(heap.page_size_min) = undefined;
var stderr_buffer: [4096]u8 align(heap.page_size_min) = undefined;

var stderr_writer: Io.File.Writer = undefined;
var stdout_writer: Io.File.Writer = undefined;

/// The process's stderr, buffered. Initialized by `init`.
pub var stderr: *Io.Writer = undefined;

/// The process's stdout, buffered. Initialized by `init`.
pub var stdout: *Io.Writer = undefined;

/// Create the buffered writers. Must run once, from main, before any stdio
/// use — the globals are `undefined` until it does.
pub fn init(io: Io) void {
    stderr_writer = .init(.stderr(), io, &stderr_buffer);
    stdout_writer = .init(.stdout(), io, &stdout_buffer);

    stderr = &stderr_writer.interface;
    stdout = &stdout_writer.interface;
}

pub const Where = enum {
    err,
    out,

    fn writer(w: Where) *Io.Writer {
        return switch (w) {
            .err => stderr,
            .out => stdout,
        };
    }
};

pub fn print(comptime w: Where, comptime fmt: []const u8, args: anytype) void {
    var f = w.writer();
    f.print(fmt ++ "\n", args) catch return;
}

pub fn writeAll(comptime w: Where, bytes: []const u8) void {
    var f = w.writer();
    f.writeAll(bytes) catch return;
}

/// Flush both streams. Main's exit defer calls this; direct
/// `std.process.exit` callers must call it by hand first.
pub fn flush() void {
    stderr.flush() catch undefined;
    stdout.flush() catch undefined;
}
