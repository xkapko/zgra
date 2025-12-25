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
    WriteFailed,
};

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
    optional: bool,
    skip: bool,
    help: []u8 = "",
};

const ZgraMeta = struct {
    help: []const u8 = "",
    usage: []const u8 = "",
    program: []const u8 = "",
    version: []const u8 = "",
};

const Zgra = struct {
    currentArg: ?Arg = undefined,
    state: enum {
        arg,
        value,
    } = .arg,
};

pub const ZgraHelp = struct {
    items: []const ZgraArg,
};

pub const ZgraArg = struct {
    name: []const u8,
    help: []const u8,
};

pub fn MakeParser(comptime Template: type, helpInfo: ZgraHelp) type {
    const info = @typeInfo(Template).@"struct";
    const fields = comptime make_fields: {
        var fields: [info.fields.len]Arg = undefined;
        var sfields: [info.fields.len]StructField = undefined;
        var meta: ZgraMeta = .{};
        for (
            info.fields,
            0..,
        ) |f, i| {
            const optionalField = switch (@typeInfo(f.type)) {
                .optional => |x| .{ x.child, true },
                else => .{ f.type, false },
            };
            const help = std.mem.eql(u8, "__help", f.name);
            const usage = std.mem.eql(u8, "__usage", f.name);
            const version = std.mem.eql(u8, "__version", f.name);
            const program = std.mem.eql(u8, "__program", f.name);
            const skip = help or version or usage or program;
            // meta args
            if (help) {
                meta.help = f.defaultValue().?;
            } else if (version) {
                meta.version = f.defaultValue().?;
            } else if (usage) {
                meta.usage = f.defaultValue().?;
            } else if (program) {
                meta.program = f.defaultValue().?;
            } else if (f.name.len > 2 and f.name[0] == '_' and f.name == '_') {
                @compileError("not a supported meta value: " ++ f.name);
            }

            // regular args
            fields[i] = Arg{ .name = f.name, .type = switch (optionalField[0]) {
                bool => .bool,
                i8, i16, i32, i64, i128, isize => .int,
                u8, u16, u32, u64, u128, usize => .uint,
                []const u8, []u8, [:0]const u8, [:0]u8 => .str,
                f16, f32, f64, f80, f128 => .float,
                else => @compileError("unsupported field type"),
            }, .short = f.name[0] == '_', .optional = optionalField[1], .skip = skip, .help = getinfo: {
                for (helpInfo.items) |ai| {
                    if (std.mem.eql(u8, ai.name, f.name)) {
                        break :getinfo @constCast(ai.help);
                    }
                }
                break :getinfo "";
            } };
            sfields[i] = f;
        }
        break :make_fields .{ fields, sfields, meta };
    };
    return struct {
        parser: Zgra = .{},
        meta: ZgraMeta = fields[2],
        template: Template,

        pub fn parse(self: *@This(), it: *std.process.ArgIterator, w: *std.Io.Writer) ZgraError!Template {
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
                            if (std.mem.eql(u8, "--help", arg)) {
                                try self.help(w);
                            }
                            if (std.mem.eql(u8, "--version", arg)) {
                                try self.version(w);
                            }
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
                                if (b == 'h') {
                                    try self.help(w);
                                }
                                if (b == 'V') {
                                    try self.version(w);
                                }
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

        fn help(self: *@This(), w: *std.Io.Writer) !noreturn {
            try w.print("Program:\n\t{s} {s}\nAbout:\n\t{s}\nUsage:\n\t{s} {s}\n", .{ self.meta.program, self.meta.version, self.meta.help, self.meta.program, self.meta.usage });
            try w.print("Arguments:\n", .{});
            try w.print("\t-h, --help\t\tPrint this help message and exit.\n", .{});
            try w.print("\t-v, --version\t\tPrint version information and exit.\n", .{});
            inline for (fields[0]) |arg| {
                if (arg.skip) {
                    continue;
                } else if (arg.short) {
                    try w.print("\t-{c}, --{s}", .{ arg.name[1], arg.name[1..] });
                } else {
                    try w.print("\t--{s}", .{arg.name});
                }
                try w.print("\t\t\t{s}\n", .{arg.help});
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
