const std = @import("std");
const Type = std.builtin.Type;
const StructField = std.builtin.Type.StructField;

pub const ZgraError = error{
    NotAStruct,
    UnsupportedFieldType,
    UnknownArgument,
    InvalidArgumentOrder,
    Overflow,
    InvalidCharacter,
};

fn isSupportedType(comptime a: type) bool {
    return a == bool or a == [:0]const u8 or a == i32 or a == f32;
}

pub const Arg = struct {
    name: [:0]const u8,
    type: enum {
        bool,
        int,
        float,
        str,
    },
    short: bool,
};

pub const Zgra = struct {
    currentArg: ?Arg = undefined,
    state: enum {
        arg,
        value,
    } = .arg,
};

// first support only structs
//      1. bool fields - flags
//      2. string, int, double - options
pub fn MakeParser(comptime Template: type) type {
    const info = @typeInfo(Template).@"struct";
    const fields = comptime make_fields: {
        var fields: [info.fields.len]Arg = undefined;
        var sfields: [info.fields.len]StructField = undefined;
        for (info.fields, 0..) |f, i| {
            if (!isSupportedType(f.type)) {
                @compileError("unsupported field type");
            }
            fields[i] = Arg{
                .name = f.name,
                .type = switch (f.type) {
                    bool => .bool,
                    i32 => .int,
                    [:0]const u8 => .str,
                    f32 => .float,
                    else => @compileError("unsupported field type"),
                },
                .short = f.name[0] == '_',
            };
            sfields[i] = f;
        }
        break :make_fields .{ fields, sfields };
    };
    return struct {
        parser: Zgra = .{},
        template: Template,

        pub fn parse(self: *@This(), it: *std.process.ArgIterator) ZgraError!Template {
            self.parser.state = .arg;
            // skip program name
            _ = it.next();
            while (it.next()) |arg| {
                switch (self.parser.state) {
                    .arg => {
                        if (std.mem.eql(
                            u8,
                            "--",
                            arg[0..2],
                        )) {
                            inline for (fields[0], fields[1]) |arg_, sf| {
                                if (std.mem.eql(u8, arg_.name, arg[2..])) {
                                    switch (arg_.type) {
                                        .bool => @field(self.template, sf.name) = true,
                                        else => {
                                            self.parser.currentArg = arg_;
                                            self.parser.state = .value;
                                        },
                                    }
                                    break;
                                }
                            }
                        } else if (arg[0] == '-') {
                            const slice = arg[1..];
                            for (slice, 0..) |b, i| {
                                inline for (fields[0], fields[1]) |arg_, sf| {
                                    if (arg_.short and arg_.name[1] == b) {
                                        if (arg_.type != .bool and i < slice.len - 1) {
                                            return ZgraError.InvalidArgumentOrder;
                                        }
                                        if (arg_.type == .bool) {
                                            @field(self.template, sf.name) = true;
                                        } else {
                                            self.parser.currentArg = arg_;
                                            self.parser.state = .value;
                                        }
                                    }
                                }
                            }
                        } else {
                            return ZgraError.UnknownArgument;
                        }
                    },
                    .value => {
                        if (self.parser.currentArg) |ca| {
                            @setRuntimeSafety(false);
                            inline for (fields[0], fields[1]) |arg_, sf| {
                                if (std.mem.eql(u8, ca.name, arg_.name)) {
                                    switch (sf.type) {
                                        [:0]const u8 => {
                                            @field(self.template, sf.name) = arg;
                                        },
                                        i32 => {
                                            @field(self.template, sf.name) = try std.fmt.parseInt(i32, arg, 10);
                                        },
                                        f32 => {
                                            @field(self.template, sf.name) = try std.fmt.parseFloat(f32, arg);
                                        },
                                        else => {
                                            return ZgraError.UnsupportedFieldType;
                                        },
                                    }
                                    self.parser.state = .arg;
                                    self.parser.currentArg = null;
                                }
                            }
                            continue;
                        }
                        return ZgraError.UnknownArgument;
                    },
                }
            }
            return self.template;
        }
    };
}

test "field_types" {
    try std.testing.expect(isSupportedType(bool));
    try std.testing.expect(isSupportedType([]u8));
    try std.testing.expect(isSupportedType(i32));
    try std.testing.expect(isSupportedType(f32));
}
