const std = @import("std");
const StructField = std.builtin.Type.StructField;

const PositionalKind = union(enum) {
    many_one,
    many_zero,
    exact: usize,
};

const SpecialKind = union(enum) {
    description: []const u8,
    usage: []const u8,
    version: []const u8,
    program: []const u8,
};

const ArgumentKind = union(enum) {
    Optional: struct {
        short: u8,
        long: [:0]const u8,
    },
    Positional: PositionalKind,
    Special: SpecialKind,
};

const ArgType = union(enum) {
    bool,
    int,
    uint,
    float,
    str,
    enum_: []const [:0]const u8,
};

const Argument = struct {
    name: [:0]const u8,
    help: []const u8 = "",
    type: ArgType,
    kind: ArgumentKind,

    fn renameLong(comptime buf: []const u8) []const u8 {
        const new_buf: [buf.len]u8 = comptime blk: {
            var new_buf: [buf.len]u8 = undefined;
            for (buf, 0..) |b, i| {
                new_buf[i] = if (b == '_') '-' else b;
            }
            break :blk new_buf;
        };
        return &new_buf;
    }

    fn parseFieldAsMeta(comptime field: StructField) ?SpecialKind {
        if (field.name.len > 2 and field.name[0] == '_' and field.name[1] == '_') {
            const choices = std.meta.stringToEnum(enum {
                __usage,
                __version,
                __program,
                __description,
            }, field.name) orelse @compileError("not a supported metadata field" ++ field.name ++ "; field names starting with '__' are reserved");
            return switch (choices) {
                .__description => SpecialKind{ .description = field.defaultValue().? },
                .__version => SpecialKind{ .version = field.defaultValue().? },
                .__usage => SpecialKind{ .usage = field.defaultValue().? },
                .__program => SpecialKind{ .program = field.defaultValue().? },
            };
        }
        return null;
    }

    fn parseFieldAsPositional(comptime field: StructField) ?struct { []const u8, PositionalKind } {
        const field_name = field.name;
        const split_index = comptime blk: {
            for (field_name, 0..) |char, i| {
                if (char == ':') {
                    break :blk i;
                }
            }
            return null;
        };

        comptime {
            for (field_name[0..split_index]) |char| {
                if (!std.ascii.isUpper(char) and char != '_') {
                    return null;
                }
            }
        }

        const name_slice = field_name[0..split_index];
        const kind_slice = field_name[split_index + 1 ..];
        switch (kind_slice.len) {
            1 => {
                switch (kind_slice[0]) {
                    '*' => return .{ name_slice, .many_zero },
                    '+' => return .{ name_slice, .many_one },
                    '0'...'9' => return .{ name_slice, PositionalKind{ .exact = try std.fmt.parseUnsigned(usize, kind_slice, 10) } },
                    else => {
                        @compileError("bad positional kind specifier: '" ++ field_name ++ "'");
                    },
                }
            },
            else => {
                return .{ name_slice, PositionalKind{ .exact = try std.fmt.parseUnsigned(usize, kind_slice, 10) } };
            },
        }
    }

    fn parseFieldAsOptional(
        comptime field: StructField,
    ) ?struct { []const u8, ?u8, ?[]const u8 } {
        const field_name = field.name;

        comptime var colon_count: usize = 0;
        comptime var colon_pos: [2]usize = undefined;

        comptime {
            for (field_name, 0..) |b, i| {
                if (b == ':') {
                    if (colon_count == 2) {
                        @compileError("too many ':' separators in field name '" ++ field_name ++ "'");
                    }
                    colon_pos[colon_count] = i;
                    colon_count += 1;
                }
            }
        }

        const name_start: usize = 0;
        const name_end: usize = if (colon_count > 0) colon_pos[0] else field_name.len;

        const short_start: usize = if (colon_count > 0) colon_pos[0] + 1 else 0;
        const short_end: usize = if (colon_count > 1) colon_pos[1] else if (colon_count > 0) field_name.len else 1;

        const long_start: usize = if (colon_count > 1) colon_pos[1] + 1 else 0;
        const long_end: usize = if (colon_count > 1) field_name.len else if (colon_count > 0) colon_pos[0] else field_name.len;

        const name = field_name[name_start..name_end];

        comptime {
            for (name) |c| {
                if (!std.ascii.isLower(c) and c != '_') {
                    return null;
                }
            }
        }

        comptime var short: ?u8 = field_name[0];

        if (colon_count > 0) {
            const short_len = short_end - short_start;
            if (short_len != 1) {
                @compileError("short name must be exactly one character in field '" ++ field_name ++ "'");
            }

            const c = field_name[short_start];
            if (c == '_') {
                short = null;
            } else if (!std.ascii.isAlphanumeric(c)) {
                @compileError("short name must be alphanumeric in field '" ++ field_name ++ "'");
            } else {
                short = c;
            }
        }

        comptime var long: ?[]const u8 = renameLong(field_name[name_start..name_end]);

        if (colon_count > 1) {
            const long_len = long_end - long_start;
            if (long_len == 1 and field_name[long_start] == '_') {
                long = null;
            } else {
                long = field_name[long_start..long_end];
            }
        }

        return .{ name, short, long };
    }
};

test "rename" {
    const a: [:0]const u8 = "hello_world";
    const result = Argument.renameLong(a);
    try std.testing.expectEqualStrings("hello-world", result);

    const b: [:0]const u8 = "bad_";
    const result_ = Argument.renameLong(b);
    try std.testing.expectEqualStrings("bad-", result_);
}

test "destructuring" {
    const a = [3]u8{
        1,
        2,
        3,
    };

    const fst, const snd, const trd = a;

    try std.testing.expect(fst == 1);
    try std.testing.expect(snd == 2);
    try std.testing.expect(trd == 3);
}

test "field_names" {
    const expect = std.testing.expect;
    const eqString = std.testing.expectEqualStrings;
    const S = struct {
        basic: u8,
        @"short:S": u16,
        @"longer:L:long": u16,
        with_rename: u32,
        @"no_short:_": u32,
        @"no_long:n:_": u32,
        @"no_short_and_long:_:_": u32,
        NULL: u32,
    };

    const fields = @typeInfo(S).@"struct".fields;

    const result0 = comptime Argument.parseFieldAsOptional(fields[0]);
    try expect(result0 != null);
    try eqString("basic", result0.?[0]);
    try expect('b' == result0.?[1].?);
    try eqString("basic", result0.?[2].?);

    const result1 = comptime Argument.parseFieldAsOptional(fields[1]);
    try expect(result1 != null);
    try eqString("short", result1.?[0]);
    try expect('S' == result1.?[1].?);
    try eqString("short", result1.?[2].?);

    const result2 = comptime Argument.parseFieldAsOptional(fields[2]);
    try expect(result2 != null);
    try eqString("longer", result2.?[0]);
    try expect('L' == result2.?[1].?);
    try eqString("long", result2.?[2].?);

    const result3 = comptime Argument.parseFieldAsOptional(fields[3]);
    try expect(result3 != null);
    try eqString("with_rename", result3.?[0]);
    try expect('w' == result3.?[1].?);
    try eqString("with-rename", result3.?[2].?);

    const result4 = comptime Argument.parseFieldAsOptional(fields[4]);
    try expect(result4 != null);
    try eqString("no_short", result4.?[0]);
    try expect(result4.?[1] == null);
    try eqString("no-short", result4.?[2].?);

    const result5 = comptime Argument.parseFieldAsOptional(fields[5]);
    try expect(result5 != null);
    try eqString("no_long", result5.?[0]);
    try expect('n' == result5.?[1].?);
    try expect(result5.?[2] == null);

    const result6 = comptime Argument.parseFieldAsOptional(fields[6]);
    try expect(result6 != null);
    try eqString("no_short_and_long", result6.?[0]);
    try expect(result6.?[1] == null);
    try expect(result6.?[2] == null);

    const result7 = comptime Argument.parseFieldAsOptional(fields[7]);
    try expect(result7 == null);
}

test "positional" {
    const expect = std.testing.expect;
    const eqString = std.testing.expectEqualStrings;
    const S = struct {
        @"FST:*": []const u8,
        @"SND:+": []const u8,
        @"TRD:7": []const u8,
        @"FOURTH:125": usize,
        NULL: usize,
        @"opt:O:optional-arg": usize,
    };

    const fields = @typeInfo(S).@"struct".fields;
    const result1 = comptime Argument.parseFieldAsPositional(fields[0]);
    try expect(result1 != null);
    try eqString("FST", result1.?[0]);
    try expect(result1.?[1] == .many_zero);

    const result2 = comptime Argument.parseFieldAsPositional(fields[1]);
    try expect(result2 != null);
    try eqString("SND", result2.?[0]);
    try expect(result2.?[1] == .many_one);

    const result3 = comptime Argument.parseFieldAsPositional(fields[2]);
    try expect(result3 != null);
    try eqString("TRD", result3.?[0]);
    try expect(result3.?[1].exact == 7);

    const result4 = comptime Argument.parseFieldAsPositional(fields[3]);
    try expect(result4 != null);
    try eqString("FOURTH", result4.?[0]);
    try expect(result4.?[1].exact == 125);

    const result5 = comptime Argument.parseFieldAsPositional(fields[4]);
    try expect(result5 == null);

    const result6 = comptime Argument.parseFieldAsPositional(fields[5]);
    try expect(result6 == null);
}

test "special" {
    const expect = std.testing.expect;
    const eqString = std.testing.expectEqualStrings;
    const S = struct {
        __description: []const u8 = "this is a description",
        __usage: []const u8 = "usage string",
        __version: []const u8 = "v0.1.0",
        __program: []const u8 = "test",
        other: u32,
    };

    const fields = @typeInfo(S).@"struct".fields;

    const result0 = comptime Argument.parseFieldAsMeta(fields[0]);
    try expect(result0 != null);
    try eqString(result0.?.description, "this is a description");

    const result1 = comptime Argument.parseFieldAsMeta(fields[1]);
    try expect(result1 != null);
    try eqString(result1.?.usage, "usage string");

    const result2 = comptime Argument.parseFieldAsMeta(fields[2]);
    try expect(result2 != null);
    try eqString(result2.?.version, "v0.1.0");

    const result3 = comptime Argument.parseFieldAsMeta(fields[3]);
    try expect(result3 != null);
    try eqString(result3.?.program, "test");

    const result4 = comptime Argument.parseFieldAsMeta(fields[4]);
    try expect(result4 == null);
}

test "splitting" {
    const name = "hello_world:H:world_hello";
    var it = std.mem.splitScalar(u8, name, ':');
    try std.testing.expectEqualStrings("hello_world", it.next().?);
    try std.testing.expectEqualStrings("H", it.next().?);
    try std.testing.expectEqualStrings("world_hello", it.next().?);
    try std.testing.expect(it.next() == null);
}
