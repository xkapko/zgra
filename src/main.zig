const std = @import("std");
const zgra = @import("zgra");

const Args = struct {
    _help: bool,
    _version: bool,
    _xd: bool,
    int: i128,
    uint: u64,
    flt: f16,
    msg: [:0]const u8,
    msg2: [:0]u8,
    msg3: []const u8,
    msg4: []u8,
    opt: ?bool = null,
};
const Parser = zgra.MakeParser(Args);

pub fn main() !void {
    var it = std.process.ArgIterator.init();
    var parser = Parser{ .template = .{
        ._help = false,
        ._version = false,
        ._xd = false,
        .int = 0,
        .uint = 0,
        .flt = 0.0,
        .msg = "",
        .msg2 = @constCast(""),
        .msg3 = "",
        .msg4 = "",
    } };
    const res = try parser.parse(&it);

    std.debug.print("{any}\n", .{res});
}
