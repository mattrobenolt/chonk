//! chonk — the CLI front door. Subcommands dispatch from here; the packer,
//! the wire format, and the freestanding stub live in their own files.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const stdio = @import("stdio.zig");
const packer = @import("packer.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    stdio.init(io);
    defer stdio.flush();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usageExit();

    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "pack")) {
        packer.run(io, arena, rest) catch |err| {
            stdio.flush();
            std.process.exit(if (err == error.Usage) 2 else 1);
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "inspect")) {
        stdio.stderr.print("chonk: inspect: not implemented yet\n", .{}) catch undefined;
        stdio.flush();
        std.process.exit(2);
    }

    stdio.stderr.print("chonk: unknown command '{s}'\n", .{cmd}) catch undefined;
    usageExit();
}

/// Print top-level usage and exit 2 — every direct `process.exit` path
/// flushes stdio by hand first, or buffered output would vanish.
fn usageExit() noreturn {
    stdio.stderr.print(
        "usage: chonk <command> [args]\n" ++
            "  chonk pack <stub> <payload> <output>   pack a fat binary\n" ++
            "  chonk inspect <binary>                print a fat binary's variant table\n",
        .{},
    ) catch undefined;
    stdio.flush();
    std.process.exit(2);
}

test {
    _ = @import("format.zig");
    _ = @import("packer.zig");
}
