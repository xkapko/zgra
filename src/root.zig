const std = @import("std");
const Type = std.builtin.Type;
const StructField = std.builtin.Type.StructField;
const EnumField = std.builtin.Type.EnumField;
const eql = std.mem.eql;

pub const ZgraError = error{
    NotAStruct,
    UnsupportedFieldType,
    UnknownArgument,
    InvalidArgumentOrder,
    Overflow,
    InvalidCharacter,
    WriteFailed,
    UnknownEnumVariant,
    NoSpaceLeft,
};

/// Inner representation of a parsed command line argument.
const Arg = struct {
    // name of the argument
    name: [:0]const u8,
    // type of the argument, used for parsing
    type: enum {
        bool,
        int,
        uint,
        float,
        str,
        enume,
    },
    values: ?[]const [:0]const u8 = null,
    short: bool,
    optional: bool,
    skip: bool,
    help: []u8 = "",
};

/// Program metadata such as the program name, version, usage info and short program description.
///
/// Used for automatically generating the help messages.
const ZgraMeta = struct {
    description: []const u8 = "",
    usage: []const u8 = "",
    program: []const u8 = "",
    version: []const u8 = "",
};

const Parser = struct {
    currentArg: ?Arg = undefined,
    state: enum {
        arg,
        value,
    } = .arg,
};

/// This type is used to automatically generate help messages for the commands you use.
pub const ZgraHelp = struct {
    items: []const ZgraArg,
};

/// Used to provide a help message to an argument.
pub const ZgraArg = struct {
    name: []const u8,
    help: []const u8,
};

/// Given a type and a help structure, create a new command line argument parser at compile time. After creating the
/// parsers, the user needs to instantiate it with the default values and then call the `.parse()` method on the
/// instance. The returned value is the initial type with with the values of each field matching the ones received from
/// parsing.
pub fn MakeParser(comptime Template: type, helpInfo: ZgraHelp) type {
    const info = @typeInfo(Template).@"struct";
    const comptimeState = comptime make_fields: {
        var args: [info.fields.len]Arg = undefined;
        var structFields: [info.fields.len]StructField = undefined;
        var meta: ZgraMeta = .{};
        for (
            info.fields,
            0..,
        ) |f, i| {
            const optionalField = switch (@typeInfo(f.type)) {
                .optional => |x| .{ x.child, true, null },
                .@"enum" => |e| enfields: {
                    const efields = blk: {
                        var tmp: [e.fields.len][:0]const u8 = undefined;
                        for (e.fields, 0..) |ef, ii| {
                            tmp[ii] = ef.name;
                        }
                        break :blk tmp;
                    };
                    break :enfields .{ f.type, false, &efields };
                },
                else => .{ f.type, false, null },
            };
            const help = eql(u8, "__desc", f.name);
            const usage = eql(u8, "__usage", f.name);
            const version = eql(u8, "__version", f.name);
            const program = eql(u8, "__program", f.name);
            const skip = help or version or usage or program;
            // meta arguments
            if (help) {
                meta.description = f.defaultValue().?;
            } else if (version) {
                meta.version = f.defaultValue().?;
            } else if (usage) {
                meta.usage = f.defaultValue().?;
            } else if (program) {
                meta.program = f.defaultValue().?;
            } else if (f.name.len > 2 and f.name[0] == '_' and f.name[1] == '_') {
                @compileError("not a supported meta value: " ++ f.name);
            }

            // regular arguments
            args[i] = Arg{
                .name = f.name,
                .type = switch (optionalField[0]) {
                    bool => .bool,
                    i8, i16, i32, i64, i128, isize => .int,
                    u8, u16, u32, u64, u128, usize => .uint,
                    []const u8, []u8, [:0]const u8, [:0]u8 => .str,
                    f16, f32, f64, f80, f128 => .float,
                    else => switch (@typeInfo(optionalField[0])) {
                        .@"enum" => .enume,
                        else => |x| {
                            @compileLog("unsupported type: {any}", .{x});
                            @compileError("unsupported field type");
                        },
                    },
                },
                .short = f.name[0] == '_',
                .optional = optionalField[1],
                .skip = skip,
                .help = getinfo: {
                    for (helpInfo.items) |ai| {
                        if (eql(u8, ai.name, f.name)) {
                            break :getinfo @constCast(ai.help);
                        }
                    }
                    break :getinfo "";
                },
                .values = optionalField[2],
            };
            structFields[i] = f;
        }
        break :make_fields .{ args, structFields, meta };
    };
    return struct {
        parser: Parser = .{},
        meta: ZgraMeta = comptimeState[2],
        template: Template,

        pub fn parse(self: *@This(), it: *std.process.ArgIterator, w: *std.Io.Writer) ZgraError!Template {
            self.parser.state = .arg;
            // skip program name
            _ = it.next();
            while (it.next()) |arg| {
                switch (self.parser.state) {
                    .arg => {
                        if (eql(
                            u8,
                            "--",
                            arg[0..2],
                        )) {
                            if (eql(u8, "--help", arg)) {
                                try self.help(w);
                            }
                            if (eql(u8, "--version", arg)) {
                                try self.version(w);
                            }
                            inline for (comptimeState[0], comptimeState[1]) |arg_, sf| {
                                if (eql(u8, arg_.name, arg[2..])) {
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
                                if (b == 'h') {
                                    try self.help(w);
                                }
                                if (b == 'V') {
                                    try self.version(w);
                                }
                                inline for (comptimeState[0], comptimeState[1]) |arg_, sf| {
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
                            inline for (comptimeState[0], comptimeState[1]) |arg_, sf| {
                                if (eql(u8, ca.name, arg_.name)) {
                                    const argumentType = switch (@typeInfo(sf.type)) {
                                        .optional => |o| o.child,
                                        else => sf.type,
                                    };
                                    switch (argumentType) {
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
                                        else => |t| switch (@typeInfo(t)) {
                                            .@"enum" => {
                                                var done = false;
                                                for (arg_.values.?, 0..) |enumField, i| {
                                                    if (eql(u8, enumField, arg)) {
                                                        @field(self.template, sf.name) = @enumFromInt(i);
                                                        done = true;
                                                    }
                                                }
                                                if (!done) {
                                                    return ZgraError.UnknownEnumVariant;
                                                }
                                            },
                                            else => return ZgraError.UnsupportedFieldType,
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

        // TODO: Use a nice formatting
        fn help(self: *@This(), w: *std.Io.Writer) !noreturn {
            try w.print("Program:\n\t{s} {s}\nAbout:\n\t{s}\nUsage:\n\t{s} {s}\n", .{ self.meta.program, self.meta.version, self.meta.description, self.meta.program, self.meta.usage });
            try w.print("Arguments:\n", .{});
            var maxLen: usize = 0;
            maxLen = @max(std.fmt.count("-h, --help", .{}), maxLen);
            maxLen = @max(std.fmt.count("-v, --version", .{}), maxLen);

            for (comptimeState[0]) |arg| {
                if (arg.skip) {
                    continue;
                } else if (arg.short) {
                    const argLen = std.fmt.count("-{c}, --{s}", .{ arg.name[1], arg.name[1..] });
                    if (arg.values) |v| {
                        var valLen: usize = 1;
                        for (v, 0..) |value, i| {
                            valLen += std.fmt.count("{s}", .{value});
                            if (i != v.len - 1) {
                                valLen += std.fmt.count(" | ", .{});
                            } else {
                                valLen += std.fmt.count(")", .{});
                            }
                        }
                        maxLen = @max(argLen + valLen, maxLen);
                    } else {
                        maxLen = @max(argLen, maxLen);
                    }
                } else {
                    const argLen = std.fmt.count("--{s}", .{arg.name});
                    if (arg.values) |v| {
                        var valLen: usize = 1;
                        for (v, 0..) |value, i| {
                            valLen += std.fmt.count("{s}", .{value});
                            if (i != v.len - 1) {
                                valLen += std.fmt.count(" | ", .{});
                            } else {
                                valLen += std.fmt.count(")", .{});
                            }
                        }
                        maxLen = @max(argLen + valLen, maxLen);
                    } else {
                        maxLen = @max(argLen, maxLen);
                    }
                }
            }

            try w.print("\t{[value]s: <[width]}\tPrint this help message and exit.\n", .{ .value = "-h, --help", .width = maxLen });
            try w.print("\t{[value]s: <[width]}\tPrint version information and exit.\n", .{ .value = "-v, --version", .width = maxLen });
            for (comptimeState[0]) |arg| {
                var buff: [1024]u8 = undefined;
                if (arg.skip) {
                    continue;
                } else if (arg.short) {
                    var off = (try std.fmt.bufPrint(&buff, "-{c}, --{s}", .{ arg.name[1], arg.name[1..] })).len;
                    if (arg.values) |v| {
                        for (v, 0..) |value, i| {
                            if (i == 0) {
                                off += (try std.fmt.bufPrint(buff[off..], " (", .{})).len;
                            }
                            off += (try std.fmt.bufPrint(buff[off..], "{s}", .{value})).len;
                            if (i != v.len - 1) {
                                off += (try std.fmt.bufPrint(buff[off..], " | ", .{})).len;
                            } else {
                                off += (try std.fmt.bufPrint(buff[off..], ")", .{})).len;
                            }
                        }
                    }
                    try w.print("\t{[buf]s: <[width]}", .{ .buf = buff[0..off], .width = maxLen });
                } else {
                    var off = (try std.fmt.bufPrint(&buff, "--{s}", .{arg.name})).len;
                    if (arg.values) |v| {
                        for (v, 0..) |value, i| {
                            if (i == 0) {
                                off += (try std.fmt.bufPrint(buff[off..], " (", .{})).len;
                            }
                            off += (try std.fmt.bufPrint(buff[off..], "{s}", .{value})).len;
                            if (i != v.len - 1) {
                                off += (try std.fmt.bufPrint(buff[off..], " | ", .{})).len;
                            } else {
                                off += (try std.fmt.bufPrint(buff[off..], ")", .{})).len;
                            }
                        }
                    }
                    try w.print("\t{[val]s: <[width]}", .{ .val = buff[0..off], .width = maxLen });
                }
                try w.print("\t{s}\n", .{arg.help});
            }
            try w.flush();
            std.process.exit(0);
        }

        fn version(self: *@This(), w: *std.Io.Writer) !noreturn {
            try w.print("{s}\n", .{self.meta.version});
            try w.flush();
            std.process.exit(0);
        }
    };
}
