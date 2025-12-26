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
    OutOfMemory,
    NoSpaceLeft,
    WrongNumberOfArguments,
    OptionAfterPositional,
};

const PosKind = union(enum) {
    exact: struct {
        n: usize,
    },
    many_zero,
    many_one,
};

const ArgType = enum {
    bool,
    int,
    uint,
    float,
    str,
    enume,
};

/// Inner representation of a parsed command line argument.
const Arg = struct {
    // name of the argument
    name: [:0]const u8,
    // type of the argument, used for parsing
    type: ArgType,
    values: ?[]const [:0]const u8 = null,
    short: bool,
    skip: bool,
    help: []u8 = "",
    positional: ?struct {
        kind: PosKind,
    } = null,
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
        positional,
    } = .arg,
};

/// Given a type and a help structure, create a new command line argument parser at compile time. After creating the
/// parsers, the user needs to instantiate it with the default values and then call the `.parse()` method on the
/// instance. The returned value is the initial type with with the values of each field matching the ones received from
/// parsing.
pub fn MakeParser(comptime Template: type, helpInfo: anytype) type {
    const template_type_info = @typeInfo(Template);
    const info = switch (template_type_info) {
        .@"struct" => |s| s,
        else => @compileError("Template is not a struct"),
    };

    const args, const struct_fields, const metadata, const index, const pos_type = comptime make_state: {
        var args: [info.fields.len]Arg = undefined;
        var template_fields: [info.fields.len]StructField = undefined;
        var metadata: ZgraMeta = .{};
        var positional_index: ?usize = null;
        var positional_type: ?type = null;
        for (
            info.fields,
            0..,
        ) |f, i| {
            const field_type_info = @typeInfo(f.type);

            const is_positional, const name, const kind, const field_type = helpers.parsePositionalArgument(f);
            if (is_positional and positional_index == null) {
                positional_index = i;
                positional_type = field_type;
            } else if (is_positional and positional_index != null) {
                @compileError("more than one positional argumet is not allowed");
            }

            const skip = helpers.parseMetaArg(&metadata, f);

            const arg_type = switch (field_type) {
                bool => .bool,
                i8, i16, i32, i64, i128, isize => .int,
                u8, u16, u32, u64, u128, usize => .uint,
                []const u8, []u8, [:0]const u8, [:0]u8 => .str,
                f16, f32, f64, f80, f128 => .float,
                else => switch (field_type_info) {
                    .@"enum" => .enume,
                    else => |x| {
                        @compileLog("unsupported struct field type: {any}", .{x});
                        @compileError("unsupported field type");
                    },
                },
            };

            const values = switch (field_type_info) {
                .@"enum" => |e| enfields: {
                    const efields = blk: {
                        var tmp: [e.fields.len][:0]const u8 = undefined;
                        for (e.fields, 0..) |ef, ii| {
                            tmp[ii] = ef.name;
                        }
                        break :blk tmp;
                    };
                    break :enfields &efields;
                },
                else => null,
            };

            args[i] = Arg{
                .name = if (is_positional) name else f.name,
                .type = arg_type,
                .short = f.name[0] == '_',
                .skip = skip or is_positional,
                .help = switch (skip or is_positional) {
                    true => "",
                    else => @constCast(@field(helpInfo, f.name)),
                },
                .values = values,
                .positional = if (is_positional) .{
                    .kind = kind,
                } else null,
            };
            template_fields[i] = f;
        }
        break :make_state .{
            args,
            template_fields,
            metadata,
            positional_index,
            positional_type,
        };
    };
    const return_type = if (pos_type == null) ZgraError!struct { Template } else ZgraError!struct { Template, []pos_type.? };
    const include_alist = pos_type != null;

    return struct {
        parser: Parser = .{},
        meta: ZgraMeta = metadata,
        template: Template,
        alist: if (include_alist)
            std.ArrayList(pos_type.?)
        else
            void = if (include_alist) .empty else {},

        pub fn parse(self: *@This(), it: *std.process.ArgIterator, w: *std.Io.Writer, alloc: *std.mem.Allocator) return_type {
            // skip program name
            var pos_arg_count: usize = 0;
            _ = it.next();
            while (it.next()) |arg| {
                switch (self.parser.state) {
                    .arg => {
                        const kind = helpers.getKind(arg);
                        switch (kind) {
                            .long => {
                                if (eql(u8, "--help", arg)) {
                                    try self.help(w);
                                }
                                if (eql(u8, "--version", arg)) {
                                    try self.version(w);
                                }
                                inline for (args, struct_fields) |arg_, sf| {
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
                            },
                            .short => {
                                const slice = arg[1..];
                                for (slice, 0..) |b, i| {
                                    if (b == 'h') {
                                        try self.help(w);
                                    }
                                    if (b == 'V') {
                                        try self.version(w);
                                    }
                                    inline for (args, struct_fields) |arg_, sf| {
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
                            },
                            .pos => {
                                if (index == null) {
                                    return ZgraError.UnknownArgument;
                                }
                                self.parser.state = .positional;
                                const arg_, const sf = .{ args[index.?], struct_fields[index.?] };
                                switch (arg_.positional.?.kind) {
                                    .many_one => {},
                                    .many_zero => {},
                                    .exact => |_| {},
                                }
                                try self.alist.append(alloc.*, out: {
                                    const argument_type = switch (@typeInfo(sf.type)) {
                                        .optional => |o| o.child,
                                        else => sf.type,
                                    };
                                    switch (argument_type) {
                                        [:0]const u8 => {
                                            break :out arg;
                                        },
                                        [:0]u8 => {
                                            break :out @constCast(arg);
                                        },
                                        []const u8 => {
                                            break :out std.mem.span(arg.ptr);
                                        },
                                        []u8 => {
                                            break :out @constCast(std.mem.span(arg.ptr));
                                        },
                                        i8, i16, i32, i64, i128 => {
                                            break :out try std.fmt.parseInt(sf.type, arg, 10);
                                        },
                                        f16, f32, f64, f80, f128 => {
                                            break :out try std.fmt.parseFloat(sf.type, arg);
                                        },
                                        else => |t| break :out switch (@typeInfo(t)) {
                                            .@"enum" => out2: {
                                                for (arg_.values.?, 0..) |enumField, i| {
                                                    if (eql(u8, enumField, arg)) {
                                                        break :out2 @enumFromInt(i);
                                                    }
                                                }
                                                return ZgraError.UnsupportedFieldType;
                                            },
                                            else => return ZgraError.UnsupportedFieldType,
                                        },
                                    }
                                });
                                pos_arg_count += 1;
                            },
                        }
                    },
                    .value => {
                        if (self.parser.currentArg) |ca| {
                            inline for (args, struct_fields) |_, sf| {
                                if (try helpers.parseValue(
                                    &self.template,
                                    arg,
                                    ca,
                                    sf,
                                )) {
                                    self.parser.state = .arg;
                                    self.parser.currentArg = null;
                                }
                            }
                        }
                    },
                    .positional => {
                        if (index == null) {
                            return ZgraError.UnknownArgument;
                        }
                        if (arg[0] == '-') {
                            return ZgraError.OptionAfterPositional;
                        }
                        const arg_, const sf = .{ args[index.?], struct_fields[index.?] };
                        try self.alist.append(alloc.*, out: {
                            const argument_type = switch (@typeInfo(sf.type)) {
                                .optional => |o| o.child,
                                else => sf.type,
                            };
                            switch (argument_type) {
                                [:0]const u8 => {
                                    break :out arg;
                                },
                                [:0]u8 => {
                                    break :out @constCast(arg);
                                },
                                []const u8 => {
                                    break :out std.mem.span(arg.ptr);
                                },
                                []u8 => {
                                    break :out @constCast(std.mem.span(arg.ptr));
                                },
                                i8, i16, i32, i64, i128 => {
                                    break :out try std.fmt.parseInt(sf.type, arg, 10);
                                },
                                f16, f32, f64, f80, f128 => {
                                    break :out try std.fmt.parseFloat(sf.type, arg);
                                },
                                else => |t| break :out switch (@typeInfo(t)) {
                                    .@"enum" => out2: {
                                        for (arg_.values.?, 0..) |enumField, i| {
                                            if (eql(u8, enumField, arg)) {
                                                break :out2 @enumFromInt(i);
                                            }
                                        }
                                        return ZgraError.UnsupportedFieldType;
                                    },
                                    else => return ZgraError.UnsupportedFieldType,
                                },
                            }
                        });
                        pos_arg_count += 1;
                    },
                }
            }
            if (include_alist) {
                switch (args[index.?].positional.?.kind) {
                    .exact => |n| {
                        if (n.n != pos_arg_count) {
                            return ZgraError.WrongNumberOfArguments;
                        }
                    },
                    .many_one => {
                        if (pos_arg_count < 1) {
                            return ZgraError.WrongNumberOfArguments;
                        }
                    },
                    else => {},
                }
                return .{ self.template, try self.alist.toOwnedSlice(alloc.*) };
            }
            return .{self.template};
        }

        fn help(self: *@This(), w: *std.Io.Writer) !noreturn {
            const positional = if (include_alist) comptime blk: {
                switch (args[index.?].positional.?.kind) {
                    .exact => |n| {
                        var buf: [20]u8 = undefined;
                        break :blk args[index.?].name ++ try std.fmt.bufPrint(&buf, "({d})", .{n.n});
                    },
                    .many_zero => {
                        break :blk "[" ++ args[index.?].name ++ "]...";
                    },
                    .many_one => {
                        break :blk args[index.?].name ++ "...";
                    },
                }
            } else "";
            try w.print(
                "Program:\n\t{s} {s}\nAbout:\n\t{s}\nUsage:\n\t{s} {s} {s}\n",
                .{ self.meta.program, self.meta.version, self.meta.description, self.meta.program, self.meta.usage, positional },
            );
            try w.print("Arguments:\n", .{});
            var max_len: usize = 0;
            max_len = @max(std.fmt.count("-h, --help", .{}), max_len);
            max_len = @max(std.fmt.count("-v, --version", .{}), max_len);

            for (args) |arg| {
                if (arg.skip) {
                    continue;
                } else if (arg.short) {
                    const arg_len = std.fmt.count("-{c}, --{s}", .{ arg.name[1], arg.name[1..] });
                    if (arg.values) |v| {
                        var val_len: usize = 1;
                        for (v, 0..) |value, i| {
                            val_len += std.fmt.count("{s}", .{value});
                            if (i != v.len - 1) {
                                val_len += std.fmt.count(" | ", .{});
                            } else {
                                val_len += std.fmt.count(")", .{});
                            }
                        }
                        max_len = @max(arg_len + val_len, max_len);
                    } else {
                        max_len = @max(arg_len, max_len);
                    }
                } else {
                    const arg_len = std.fmt.count("--{s}", .{arg.name});
                    if (arg.values) |v| {
                        var val_len: usize = 1;
                        for (v, 0..) |value, i| {
                            val_len += std.fmt.count("{s}", .{value});
                            if (i != v.len - 1) {
                                val_len += std.fmt.count(" | ", .{});
                            } else {
                                val_len += std.fmt.count(")", .{});
                            }
                        }
                        max_len = @max(arg_len + val_len, max_len);
                    } else {
                        max_len = @max(arg_len, max_len);
                    }
                }
            }

            try w.print("\t{[value]s: <[width]}\tPrint this help message and exit.\n", .{ .value = "-h, --help", .width = max_len });
            try w.print("\t{[value]s: <[width]}\tPrint version information and exit.\n", .{ .value = "-v, --version", .width = max_len });
            for (args) |arg| {
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
                    try w.print("\t{[buf]s: <[width]}", .{ .buf = buff[0..off], .width = max_len });
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
                    try w.print("\t{[val]s: <[width]}", .{ .val = buff[0..off], .width = max_len });
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

const helpers = struct {
    const ArgKind = enum {
        short,
        long,
        pos,
    };

    fn isPositionalName(comptime field: StructField) bool {
        const s = enum {
            name,
            specifiers,
            finished,
        };
        var state = s.name;
        for (field.name, 0..) |b, i| {
            switch (state) {
                .name => {
                    switch (b) {
                        'A'...'Z' => {},
                        ':' => {
                            if (i > 0) {
                                state = .specifiers;
                            } else {
                                @compileError("separator ':' in first place");
                            }
                        },
                        else => return false,
                    }
                },
                .specifiers => {
                    switch (b) {
                        '0'...'9' => {},
                        '+', '*' => state = .finished,
                        else => @compileError("invalid byte '" ++ .{b} ++ "' in field: " ++ field.name),
                    }
                },
                .finished => @compileError("multiple terminating characters"),
            }
        }
        return true;
    }

    fn parsePositionalArgument(comptime field: StructField) struct { bool, [:0]const u8, PosKind, type } {
        if (!isPositionalName(field)) {
            return .{ false, field.name, .many_one, field.type };
        }
        var sep_index: usize = 0;
        for (field.name, 0..) |b, i| {
            if (b == ':') {
                sep_index = i;
                break;
            }
        }
        const t = field.type;

        const y = field.name[0..sep_index] ++ .{0};
        const name = y[0..sep_index :0];
        const special = field.name[sep_index + 1 ..];
        switch (special[0]) {
            '*' => return .{ true, name, .many_zero, t },
            '+' => return .{ true, name, .many_one, t },
            else => |x| {
                if (std.ascii.isDigit(x)) {
                    return .{ true, name, .{ .exact = .{ .n = try std.fmt.parseUnsigned(usize, special[0..], 10) } }, t };
                }
            },
        }
        @compileLog("name: {any}\n", .{field.name});
        return .{ false, field.name, .many_zero, field.type };
    }

    fn getKind(arg: [:0]const u8) ArgKind {
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') return .long;
        if (arg.len > 1 and arg[0] == '-') return .short;
        return .pos;
    }

    fn parseValue(
        s: anytype,
        arg: [:0]const u8,
        ca: Arg,
        sf: StructField,
    ) !bool {
        if (eql(u8, ca.name, sf.name)) {
            const argument_type = switch (@typeInfo(sf.type)) {
                .optional => |o| o.child,
                else => sf.type,
            };
            switch (argument_type) {
                [:0]const u8 => {
                    @field(s, sf.name) = arg;
                },
                [:0]u8 => {
                    @field(s, sf.name) = @constCast(arg);
                },
                []const u8 => @field(s, sf.name) = std.mem.span(arg.ptr),
                []u8 => @field(s, sf.name) = @constCast(std.mem.span(arg.ptr)),
                i8, i16, i32, i64, i128 => {
                    @field(s, sf.name) = try std.fmt.parseInt(sf.type, arg, 10);
                },
                f16, f32, f64, f80, f128 => {
                    @field(s, sf.name) = try std.fmt.parseFloat(sf.type, arg);
                },
                else => |t| switch (@typeInfo(t)) {
                    .@"enum" => {
                        var done = false;
                        for (ca.values.?, 0..) |enumField, i| {
                            if (eql(u8, enumField, arg)) {
                                @field(s, sf.name) = @enumFromInt(i);
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
            return true;
        }
        return false;
    }

    fn parseMetaArg(meta: *ZgraMeta, f: StructField) bool {
        if (f.name.len > 2 and f.name[0] == '_' and f.name[1] == '_') {
            const choices = std.meta.stringToEnum(enum {
                __usage,
                __version,
                __program,
                __desc,
            }, f.name) orelse @compileError("not a supported metadata field" ++ f.name ++ "; field names starting with '__' are reserved");
            switch (choices) {
                .__desc => meta.description = f.defaultValue().?,
                .__version => meta.version = f.defaultValue().?,
                .__usage => meta.usage = f.defaultValue().?,
                .__program => meta.program = f.defaultValue().?,
            }
            return true;
        }
        return false;
    }
};

test "arrayinfo" {
    const A = [7][:0]const u8;
    const type_info = @typeInfo(A);
    const array = switch (type_info) {
        .pointer => |p| p,
        .array => |a| a,
        else => @compileError("not a slice or a pointer"),
    };

    std.debug.print("{any}\n", .{array});
}
