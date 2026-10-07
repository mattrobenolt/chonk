//! Buffered, error-free stdio: statically initialized singleton streams
//! for stderr and stdout. No init function, no allocator — import and
//! speak.
//!
//! The writers ride `std.Options.debug_io`, the statically initialized
//! single-threaded `Io` that `std.debug.print` uses. That `Io` supports
//! neither concurrency nor cancellation, so these streams belong to one
//! thread.
//!
//! No method returns an error. The first failed write latches the file
//! writer's failure mode, and every later write on that stream drops.
//! Output is buffered — nothing lands until `flush`, so a program must
//! flush before it exits, and an abort never reaches a flush: panic
//! reporting stays with `std.debug.print`. `print` is `Io.Writer.print`
//! without the error return; the caller ends the line, nothing appends a
//! newline.

const std = @import("std");
const Io = std.Io;
const io = std.Options.debug_io;

/// One buffered stream over a std file, with the buffer and the file
/// writer embedded, so an instance owns its whole state.
///
/// The method set is libc's `FILE*` write surface: `print` is fprintf,
/// `write`/`writeAll` are fwrite, `writeByte` is fputc, `flush` is
/// fflush. `print` formats exactly as `Io.Writer.print` does; nothing
/// appends a newline. The first failed write latches the writer's
/// failure mode, and later writes drop.
pub const Stream = struct {
    buffer: [4096]u8 = undefined,
    file_writer: Io.File.Writer,

    /// The `*Io.Writer` behind the stream, for the interfaces that take one.
    pub fn writer(self: *Stream) *Io.Writer {
        return &self.file_writer.interface;
    }

    pub fn print(self: *Stream, comptime fmt: []const u8, args: anytype) void {
        self.writer().print(fmt, args) catch return;
    }

    pub fn write(self: *Stream, bytes: []const u8) usize {
        return self.writer().write(bytes) catch 0;
    }

    pub fn writeAll(self: *Stream, bytes: []const u8) void {
        self.writer().writeAll(bytes) catch return;
    }

    pub fn writeByte(self: *Stream, byte: u8) void {
        self.writer().writeByte(byte) catch return;
    }

    pub fn flush(self: *Stream) void {
        self.writer().flush() catch return;
    }
};

var err_instance: Stream = .{ .file_writer = .initStreaming(.stderr(), io, &err_instance.buffer) };
var out_instance: Stream = .{ .file_writer = .initStreaming(.stdout(), io, &out_instance.buffer) };

/// The process's stderr.
pub const err: *Stream = &err_instance;

/// The process's stdout.
pub const out: *Stream = &out_instance;

/// Flush both streams. Buffered output does not land without this, so
/// call it before exit. A failed flush is dropped; one dead stream does
/// not stop the other from flushing.
pub fn flush() void {
    err.flush();
    out.flush();
}
