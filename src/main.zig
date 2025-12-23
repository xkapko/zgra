const std = @import("std");
const zgra = @import("zgra");

const Template = struct {
    _help: bool,
    _version: bool,
    _xd: bool,
    num: i32,
    flt: f32,
    msg: [:0]const u8,
};
const Parser = zgra.MakeParser(Template);

pub fn main() !void {
    var it = std.process.ArgIterator.init();
    var parser = Parser{ .template = .{
        ._help = false,
        ._version = false,
        ._xd = false,
        .num = 0,
        .flt = 0.0,
        .msg = "",
    } };
    const res = try parser.parse(&it);

    std.debug.print("{any}\n", .{res});
}
