//! The app every listed variant is built from. The variant shows only in
//! what the compiler baked in: the CPU model name and the helper's tag.

const std = @import("std");
const helper = @import("helper");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    try stdout.interface.print(
        "{s} built for {s}\n",
        .{ helper.tag(), @import("builtin").cpu.model.name },
    );
    try stdout.interface.flush();
}
