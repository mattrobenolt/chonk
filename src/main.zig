const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("All your {s} are belong to us.\n", .{"codebase"});
    try stdout.flush();
}

test {
    _ = @import("format.zig");
    _ = @import("packer.zig");
}
