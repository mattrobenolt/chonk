//! chonk — the CLI front door. Subcommands dispatch from here; the packer,
//! the wire format, and the freestanding stub live in their own files.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const stringToEnum = std.meta.stringToEnum;
const cli = @import("cli");

const inspect = @import("inspect.zig");
const pack = @import("pack.zig");
const stdio = @import("stdio.zig");
const stderr = stdio.err;
const stdout = stdio.out;

const Cmd = enum {
    pack,
    inspect,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    defer stdio.flush();

    var args = try cli.Args.initAllocator(init.minimal.args, arena);
    defer args.deinit();

    const cmd = switch (args.next() orelse return usageExit()) {
        .positional => |name| name,
        .option => |opt| {
            if (opt.isSwitch("help", 'h')) {
                stdout.writeAll(top_usage);
                return 0;
            }
            stderr.print("chonk: unknown option '{f}'\n", .{opt});
            return usageExit();
        },
    };

    switch (stringToEnum(Cmd, cmd) orelse {
        stderr.print("chonk: unknown command '{s}'\n", .{cmd});
        return usageExit();
    }) {
        .pack => {
            return pack.run(io, arena, &args) catch |err| {
                return if (err == error.Usage) 2 else 1;
            };
        },
        .inspect => return inspect.run(io, arena, &args) catch |err| switch (err) {
            error.Usage => 2,
            else => return err,
        },
    }
}

const top_usage =
    \\usage: chonk <command> [args]
    \\  chonk pack <stub> <config.zon> <output>  pack a fat binary from a config
    \\  chonk inspect <binary>                   print a fat binary's variant table
    \\  chonk --help                             print this help
    \\
;

/// Print top-level usage and return exit code 2.
fn usageExit() u8 {
    stderr.writeAll(top_usage);
    return 2;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("inspect.zig");
    _ = @import("build.zig");
}
