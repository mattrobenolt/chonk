//! chonk — the CLI front door. Subcommands dispatch from here; the packer,
//! the wire format, and the freestanding stub live in their own files.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const stringToEnum = std.meta.stringToEnum;

const pack = @import("pack.zig");
const stdio = @import("stdio.zig");

const Cmd = enum {
    pack,
    inspect,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    stdio.init(io);
    defer stdio.flush();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usageExit();

    const cmd = args[1];
    const rest = args[2..];

    switch (stringToEnum(Cmd, cmd) orelse {
        stdio.print(.err, "chonk: unknown command '{s}'", .{cmd});
        return usageExit();
    }) {
        .pack => {
            return pack.run(io, arena, rest) catch |err| {
                return if (err == error.Usage) 2 else 1;
            };
        },
        .inspect => {
            stdio.writeAll(.err, "chonk: inspect: not implemented yet\n");
            return 2;
        },
    }
}

/// Print top-level usage and return exit code 2.
fn usageExit() u8 {
    const usage =
        \\ usage: chonk <command> [args]
        \\   chonk pack <stub> <config.zon> <output>  pack a fat binary from a config
        \\   chonk inspect <binary>                   print a fat binary's variant table
    ;
    stdio.writeAll(.err, usage ++ "\n");
    return 2;
}

test {
    std.testing.refAllDecls(@This());
}
