//! The app every variant of the fat binary is built from. The variant
//! shows only in what the compiler baked in: the CPU model name.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    try stdout.interface.print(
        "app built for CPU model: {s}\n",
        .{@import("builtin").cpu.model.name},
    );
    try stdout.interface.flush();
}
