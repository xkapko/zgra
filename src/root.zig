const std = @import("std");
const Type = std.builtin.Type;
const StructField = std.builtin.Type.StructField;
const EnumField = std.builtin.Type.EnumField;
const eql = std.mem.eql;
const print = std.fmt.comptimePrint;

pub const ZgraError = error{
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
/// parser, the user needs to instantiate it with the default values and then call the `.parse()` method on the
/// instance. The returned value is the initial type with with the values of each field matching the ones received from
/// parsing.
///
/// The default return type of the `parse()` function is
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
        for (info.fields, 0..) |field, i| {
            const field_type_info = @typeInfo(field.type);

            const is_positional, const name, const kind, const field_type = helpers.tryParsePositionalArgument(field);
            if (is_positional and positional_index == null) {
                positional_index = i;
                positional_type = field_type;
            } else if (is_positional and positional_index != null) {
                @compileError("multiple positional arguments are forbidden");
            }

            const should_skip = helpers.tryParseMetaArg(&metadata, field);

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
                        @compileError("unsupported Template field type");
                    },
                },
            };

            const values = switch (field_type_info) {
                .@"enum" => |e| enfields: {
                    const enum_fields = blk: {
                        var temp_enum_fields: [e.fields.len][:0]const u8 = undefined;
                        for (e.fields, 0..) |ef, ii| {
                            temp_enum_fields[ii] = ef.name;
                        }
                        break :blk temp_enum_fields;
                    };
                    break :enfields &enum_fields;
                },
                else => null,
            };

            args[i] = Arg{
                .name = if (is_positional) name else field.name,
                .type = arg_type,
                .short = field.name[0] == '_',
                .skip = should_skip or is_positional,
                .help = switch (should_skip or is_positional) {
                    true => "",
                    else => @constCast(@field(helpInfo, field.name)),
                },
                .values = values,
                .positional = if (is_positional) .{
                    .kind = kind,
                } else null,
            };
            template_fields[i] = field;
        }
        break :make_state .{
            args,
            template_fields,
            metadata,
            positional_index,
            positional_type,
        };
    };
    const return_type = if (pos_type == null) ZgraError!Template else ZgraError!struct { Template, []pos_type.? };
    const include_alist = pos_type != null;

    return struct {
        parser: Parser = .{},
        meta: ZgraMeta = metadata,
        template: Template,
        alist: if (include_alist)
            std.ArrayList(pos_type.?)
        else
            void = if (include_alist) .empty else {},

        /// Parse the command line arguments.
        pub fn parse(self: *@This(), it: *std.process.ArgIterator, w: *std.Io.Writer, alloc: *std.mem.Allocator) return_type {
            // skip program name
            var pos_arg_count: usize = 0;
            _ = it.next();
            while (it.next()) |arg| {
                switch (self.parser.state) {
                    .arg => {
                        const kind = helpers.getKind(arg);
                        switch (kind) {
                            .long => try self.long(arg, w),
                            .short => try self.short(arg, w),
                            .pos => {
                                self.parser.state = .positional;
                                if (index == null) {
                                    return ZgraError.UnknownArgument;
                                }
                                pos_arg_count += try self.pos(arg, alloc);
                            },
                        }
                    },
                    .value => {
                        const ca = self.parser.currentArg.?;
                        inline for (args, struct_fields) |_, sf| {
                            if (try helpers.setValue(
                                &self.template,
                                arg,
                                ca,
                                sf,
                            )) {
                                self.parser.state = .arg;
                                self.parser.currentArg = null;
                            }
                        }
                    },
                    .positional => {
                        if (index == null) {
                            return ZgraError.UnknownArgument;
                        }
                        if (arg[0] == '-') {
                            return ZgraError.InvalidArgumentOrder;
                        }
                        pos_arg_count += try self.pos(arg, alloc);
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

        /// Used to parse a long optional argument.
        fn long(self: *@This(), arg: [:0]const u8, w: *std.Io.Writer) !void {
            if (eql(u8, "--help", arg)) {
                try self.help(w);
            }
            if (eql(u8, "--version", arg)) {
                try self.version(w);
            }
            inline for (args, struct_fields) |arg_, sf| {
                if (eql(u8, arg_.name, arg[2..])) {
                    try self.tryParseFlag(arg_, sf);
                    return;
                }
            }
        }

        /// Used to parse short optional arguments.
        fn short(self: *@This(), arg: [:0]const u8, w: *std.Io.Writer) !void {
            for (arg[1..], 0..) |b, i| {
                switch (b) {
                    'h' => try self.help(w),
                    'V' => try self.version(w),
                    else => {},
                }
                inline for (args, struct_fields) |arg_, sf| {
                    if (arg_.short and arg_.name[1] == b) {
                        // non-flags are only allowed in the last position of compound short arguments
                        if (arg_.type != .bool and i < arg[1..].len - 1) {
                            return ZgraError.InvalidArgumentOrder;
                        }
                        try self.tryParseFlag(arg_, sf);
                        return;
                    }
                }
            }
        }

        /// Try to parse a flag argument, if the argument is not a flag, switch the state to parse a value in the next
        /// argument.
        inline fn tryParseFlag(self: *@This(), arg: Arg, sf: StructField) !void {
            switch (arg.type) {
                .bool => @field(self.template, sf.name) = true,
                else => {
                    if (self.parser.currentArg != null) {
                        return ZgraError.InvalidArgumentOrder;
                    }
                    self.parser.currentArg = arg;
                    self.parser.state = .value;
                },
            }
        }

        /// Used to parse a positional argument.
        fn pos(self: *@This(), arg: [:0]const u8, alloc: *std.mem.Allocator) !usize {
            const arg_, const sf = .{ args[index.?], struct_fields[index.?] };
            try self.alist.append(alloc.*, out: {
                const Value = helpers.ValueParser(sf.type);
                break :out try Value.parse(arg, arg_.values);
            });
            return 1;
        }

        /// Count the maximum width of the longest option.
        fn helpMaxWidth() comptime_int {
            // "-V, --version".len == 13
            comptime var max_len = 13;

            inline for (args) |arg| {
                comptime var arg_len = 0;
                if (arg.skip) {
                    continue;
                }

                arg_len = switch (arg.short) {
                    true => (print("-{c}, --{s}", .{ arg.name[1], arg.name[1..] })).len,
                    else => (print("--{s}", .{arg.name})).len,
                };
                arg_len += switch (arg.type) {
                    .float => 5,
                    .str, .int => 3,
                    .uint => 4,
                    else => 0,
                } + 1; // +1 is for the space

                if (arg.values) |v| {
                    comptime var val_len = 1;
                    inline for (v) |value| {
                        // "{value} | "
                        val_len += value.len + 3;
                    }
                    // last value ends with ")", so we subtract 2 here
                    val_len -= 2;
                    max_len = @max(arg_len + val_len, max_len);
                } else {
                    max_len = @max(arg_len, max_len);
                }
            }
            return max_len;
        }

        /// Used to generate the help message string at compile time.
        fn generateHelp() [:0]const u8 {
            const positional: [:0]const u8 = if (include_alist) switch (args[index.?].positional.?.kind) {
                .exact => |n| print("{s}({d})", .{ args[index.?].name, n.n }),
                .many_zero => print("[{s}]...", .{args[index.?].name}),
                .many_one => print("{s}...", .{args[index.?].name ++ "..."}),
            } else "";
            const header = print(
                \\Program:
                \\        {s} {s}
                \\About:
                \\        {s}
                \\Usage:
                \\        {s} {s} {s}
                \\Options:
                \\
            ,
                .{ metadata.program, metadata.version, metadata.description, metadata.program, metadata.usage, positional },
            );

            const max_len = helpMaxWidth();

            comptime var arg_slice: [:0]const u8 = undefined;
            arg_slice = print("\t{[value]s: <[width]}\tPrint this help message and exit.\n", .{ .value = "-h, --help", .width = max_len });
            arg_slice = arg_slice ++ print("\t{[value]s: <[width]}\tPrint version information and exit.\n", .{ .value = "-v, --version", .width = max_len });
            inline for (args) |arg| {
                if (arg.skip) {
                    continue;
                }
                comptime var current_arg: [:0]const u8 = switch (arg.short) {
                    true => print("-{c}, --{s}", .{ arg.name[1], arg.name[1..] }),
                    else => print("--{s}", .{arg.name}),
                };
                current_arg = current_arg ++ switch (arg.type) {
                    .str => " STR",
                    .int => " INT",
                    .uint => " UINT",
                    .float => " FLOAT",
                    else => "",
                };

                if (arg.values) |v| {
                    current_arg = current_arg ++ " ";
                    inline for (v, 0..) |value, i| {
                        comptime var flag: [:0]const u8 = if (i == 0) "(" else "";

                        flag = flag ++ print("{s}", .{value});

                        switch (i != v.len - 1) {
                            true => flag = flag ++ print(" | ", .{}),
                            else => flag = flag ++ print(")", .{}),
                        }

                        current_arg = current_arg ++ flag;
                    }
                }
                arg_slice = arg_slice ++ print("\t{[buf]s: <[width]}", .{ .buf = current_arg, .width = max_len });
                arg_slice = arg_slice ++ print("\t{s}\n", .{arg.help});
            }

            return header ++ arg_slice;
        }

        /// Write the generated help message to the provided writer.
        fn help(self: *@This(), w: *std.Io.Writer) !noreturn {
            _ = self;
            try w.print("{s}", .{generateHelp()});
            try w.flush();
            std.process.exit(0);
        }

        /// Write the version to the provided writer.
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

    /// Check whether a `StructField` name identifies a valid positional argument.
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

    /// Try to parse a structure fields as a positional argument.
    fn tryParsePositionalArgument(comptime field: StructField) struct { bool, [:0]const u8, PosKind, type } {
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
        const field_type = field.type;

        const name = (field.name[0..sep_index] ++ .{0})[0..sep_index :0];
        const special = field.name[sep_index + 1 ..];
        switch (special[0]) {
            '*' => return .{ true, name, .many_zero, field_type },
            '+' => return .{ true, name, .many_one, field_type },
            else => |x| {
                if (std.ascii.isDigit(x)) {
                    return .{ true, name, .{ .exact = .{ .n = try std.fmt.parseUnsigned(usize, special[0..], 10) } }, field_type };
                }
            },
        }
        return .{ false, field.name, .many_zero, field.type };
    }

    /// Get the kind of a command line argument.
    fn getKind(arg: [:0]const u8) ArgKind {
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') return .long;
        if (arg.len > 1 and arg[0] == '-') return .short;
        return .pos;
    }

    /// Set the value of the Template structure after parsing an argument.
    fn setValue(
        s: anytype,
        arg: [:0]const u8,
        ca: Arg,
        sf: StructField,
    ) !bool {
        if (eql(u8, ca.name, sf.name)) {
            const ValParser = ValueParser(sf.type);
            @field(s, sf.name) = try ValParser.parse(arg, ca.values);
        }
        return false;
    }

    /// Try to parse a structure field for program metadata.
    fn tryParseMetaArg(meta: *ZgraMeta, f: StructField) bool {
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

    /// Returns a structure with a single function for parsing a null-terminated slice into the appropriate type.
    fn ValueParser(comptime T: type) type {
        return struct {
            fn parse(value: [:0]const u8, enum_values: ?[]const [:0]const u8) ZgraError!T {
                return switch (T) {
                    [:0]const u8 => value,
                    [:0]u8 => @constCast(value),
                    []const u8 => std.mem.span(value.ptr),
                    []u8 => @constCast(std.mem.span(value.ptr)),
                    i8, i16, i32, i64, i128 => try std.fmt.parseInt(T, value, 10),
                    f16, f32, f64, f80, f128 => try std.fmt.parseFloat(T, value),
                    else => |t| switch (@typeInfo(t)) {
                        .@"enum" => blk: {
                            for (enum_values.?, 0..) |enumField, i| {
                                if (eql(u8, enumField, value)) {
                                    break :blk @enumFromInt(i);
                                }
                            }
                            return ZgraError.UnknownEnumVariant;
                        },
                        else => unreachable,
                    },
                };
            }
        };
    }
};
