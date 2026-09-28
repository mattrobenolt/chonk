//! The payload the post-compile hook swaps in for the fallback variant:
//! a different build of the app, cheaper than the tiered variants. Its
//! marker is what proves the hook's return is what got packed — the
//! fallback tier prints this, not the factory-helper line.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    try stdout.interface.print("fallback build (post-processed payload)\n", .{});
    try stdout.interface.flush();
}
