const std = @import("std");
const zgra = @import("zgra");

const Args = struct {
    __program: []const u8 = "zgra_showcase",
    __usage: []const u8 = "[-o [value] | --option [value]...]",
    __desc: []const u8 = "showcase of the zgra zig command line argument parsing library",
    __version: []const u8 = "v0.0.1",
    int: i128 = 0,
    uint: u64 = 0,
    _flt: f16 = 0,
    str: [:0]const u8 = "",
    choice: enum {
        abc,
        def,
        ghi,
    } = .abc,
    flag: bool = false,
    @"NAME:*": f32 = 0,
};

const Parser = zgra.MakeParser(
    Args,
    .{
        .int = "parse an integer value",
        .uint = "parse an integer value",
        ._flt = "parse a floating point value",
        .str = "parse a string",
        .choice = "parse a string based on 3 choices",
        .flag = "simple yes/no flag",
    },
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    var alloc = gpa.allocator();
    var buff: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buff);
    var it = std.process.ArgIterator.init();
    var parser = Parser{ .template = .{} };
    const res, const val = try parser.parse(&it, &w.interface, &alloc);

    std.debug.print("{any}\n", .{res});
    for (val) |x| {
        std.debug.print("{d}\n", .{x});
    }
}
