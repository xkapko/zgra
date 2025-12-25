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
    return a == bool or
        a == i8 or
        a == i16 or
        a == i32 or
        a == i64 or
        a == i128 or
        a == isize or
        a == u8 or
        a == u16 or
        a == u32 or
        a == u64 or
        a == u128 or
        a == usize or
        a == []const u8 or
        a == []u8 or
        a == [:0]const u8 or
        a == [:0]u8 or
        a == f16 or
        a == f32 or
        a == f64 or
        a == f80 or
        a == f128;
}

pub const Arg = struct {
    name: [:0]const u8,
    type: enum {
        bool,
        int,
        uint,
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
                    i8, i16, i32, i64, i128, isize => .int,
                    u8, u16, u32, u64, u128, usize => .uint,
                    []const u8, []u8, [:0]const u8, [:0]u8 => .str,
                    f16, f32, f64, f80, f128 => .float,
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
                            inline for (fields[0], fields[1]) |arg_, sf| {
                                if (std.mem.eql(u8, ca.name, arg_.name)) {
                                    switch (sf.type) {
                                        [:0]const u8 => {
                                            @field(self.template, sf.name) = arg;
                                        },
                                        [:0]u8 => {
                                            @field(self.template, sf.name) = @constCast(arg);
                                        },
                                        []const u8 => @field(self.template, sf.name) = std.mem.span(arg.ptr),
                                        []u8 => @field(self.template, sf.name) = @constCast(std.mem.span(arg.ptr)),
                                        i8, i16, i32, i64, i128 => {
                                            @field(self.template, sf.name) = try std.fmt.parseInt(sf.type, arg, 10);
                                        },
                                        f16, f32, f64, f80, f128 => {
                                            @field(self.template, sf.name) = try std.fmt.parseFloat(sf.type, arg);
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
