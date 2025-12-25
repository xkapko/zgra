const std = @import("std");
const zgra = @import("zgra");

const Args = struct {
    __program: []const u8 = "zgra_showcase",
    __usage: []const u8 = "[-options] arguments",
    __help: []const u8 = "showcase of the zgra zig command line argument parsing library",
    __version: []const u8 = "v0.0.1",
    int: i128 = 0,
    uint: u64 = 0,
    flt: f16 = 0,
    msg: [:0]const u8 = "",
    msg2: [:0]u8 = @constCast(""),
    msg3: []const u8 = "",
    msg4: []u8 = "",
    opt: ?bool = null,
};

const Parser = zgra.MakeParser(
    Args,
    zgra.ZgraHelp{ .items = &.{
        .{ .name = "int", .help = "parse a signed integer" },
        .{ .name = "uint", .help = "parse an unsigned integer" },
        .{ .name = "flt", .help = "parse a float" },
        .{ .name = "msg", .help = "parse a string" },
    } },
);

pub fn main() !void {
    var buff: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buff);
    var it = std.process.ArgIterator.init();
    var parser = Parser{
        .template = .{},
    };
    const res = try parser.parse(&it, &w.interface);

    std.debug.print("{any}\n", .{res});
}
