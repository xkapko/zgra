> zgra: argz, but backwards

# About

`zgra` is a simple Zig library for command line argument parsing. **For the impatient; jump right in with the [examples](#Examples).**

`zgra` takes a user defined *template* structure, fields of which represent the command line arguments. The template is used to construct a parser at compile-time. Arguments are parsed at runtime, returning an instance of the user defined template structure with the field values matching those provided on the command line. Should be similar to [`clap-rs`](https://docs.rs/clap) `derive` feature.

`zgra` offers:

- Declarative approach.
- Strict typing with support for string slices, numerical types and choice arguments based on
  `enums`.
- Automatic `--help` and `--version` output generation.
- Efficiency: everything that can be generated at `comptime`, is generate at `comptime`.

# Installation

Fetch the library by running:

```sh
zig fetch --save git+https://github.com/xkapko/zgra
```

Add the following lines to `build.zig`:

```zig
const zgra = b.dependency(
    "zgra",
    .{
        .target = target,
        .optimize = optimize,
    },
);

exe.root_module.addImport("zgra", zgra.module("zgra"));
```

# API

## 1. The argument structure

The user declares a template structure, each field represents an argument:

```zig
const MyArgumnets = struct {
    arg1: []const u8 = "default value",
    arg2: u32, // no default value
    // ...
};
```

## 2. Template structure fields

Different field names imply different arguments and semantics:

### 2.1 Meta fields

Field names starting with two underscores (`__`) are called meta fields and they are reserved. Currently the following four meta fields
are supported:

1. `__desc: []const u8` - A short description of the program.
2. `__usage: []const u8` - A usage string.
3. `__program: []const u8` - Name of the program.
4. `__version: []const u8` - Version information.

Meta fields are currently only used to automatically generate the `--help` and `--version` messages.

While **technically not required**, it is usually best to include them and set them to some sane values.

### 2.2 Optional argument fields

Fields which do not start with `__` represent optional arguments. For example, the field`format: []const u8` matches the arguments `--format` followed by a string which does not start with `--` or `-`, such as `--format "%Y-%m-%d"`.

Fields starting with a single underscore (`_`) imply that the argument also has a short form, which is derived from the first letter of the field name. As an example, consider a modified version of the previous example; the field `_format: []const u8` can match either `-f  "%Y-%m-%d"` or `--format "%Y-%m-%d"`.

**There is currently no way for an optional argument to only have short form.**

### 2.3 Positional argument fields

Fields for positional arguments have more complex naming rules. The name consists of two parts, separated by the colon(`:`) character. The first part is the name of the field which consists of uppercase letters. The second part is one of the following:

- a single plus character(`+`); accepts 1 or more positional arguments
- a single star character(`*`): accepts 0 or more positional arguments
- a sequence of ASCII digits: accepts exactly `N` arguments

Examples:

```zig
@"FILE:+": []const u8 // one or more argument
@"NAME:*": []const u8 // zero or more arguments
@"NUM:2": f64         // exactly two arguments
```

### 2.4 Supported types

The Zig types are supported:

- unsigned integers: `u8, u16, u32, u64, u128`
- signed integers: `i8, i16, i32, i64, i128`
- floating point numbers: `f16, f32, f64, f80, f128`
- strings: `[]u8, [:0]u8, []const u8, [:0]const u8`
- `bool` values are treated as flags
- `enum` are used for choices

Examples:

```zig
const Arg = struct {
  uint: u32 = 0,
  int: i32 = 0,
  float: f32 = 0,
  str: []u8 = "",
  flag: bool = false,
  choice: enum { // only accepted values for this argument are `a`, `b` and `c`, everything else is an error
    a,
    b,
    c,
  },
};
```

## 3. `MakeParser`

The `zgra.MakeParser` function is used to create a new `Parser` type. The function requires two arguments, the template structure we defined earlier and an anonymous `struct` with field names matching the field names of the template structure. The values of the anonymous structure should be strings. They are used as help comments for automatically generating the help messages. **The help structure and the help fields are required**.


## 4. Parse method

Calling `MakeParser` returns a new type. The user instantiates it with the default values of the template structure. After that, the user can call the `.parse()` method which takes the following arguments:

1. command line argument iterator pointer: `*std.process.ArgIterator`
2. a writer pointer, for automatically writing out the help and version messages: `*std.Io.Writer`
3. an allocator pointer: `*std.mem.Allocator` which is only used when allocating positional arguments.

The return type of the `parse()` changes based on the provided template:

- If there are **no positional argument fields** in the template, the return type is simply the instantiated template structure.
- If there **are** positional argument fields, the return type is a tuple of the instantiated argument structure and an owned slice of the positional argument values.

<!-- TODO: talk about errors -->

# Examples

A very simple example of how `zgra` is used.

```zig
const std = @import("std");
const zgra = @import("zgra");

const Args = struct {
    // Fields starting with '__' are called meta fields, they represent extra information about the program and are used
    // when generating help messages.
    __program: []const u8 = "my_program",
    __usage: []const u8 = "[-o [value] | --option [value]...]",
    __desc: []const u8 = "my awesome program",
    __version: []const u8 = "v1.0",

    // An optional argument expecting a single string value.
    format: []const u8 = "{s}", // matches argument '--format "some string"'
    // Fields starting with a single '_' allow the argument to also have a short form.
    _verbose: u8 = 0, // matches argument '-v 1' or '--verbose 2'
    // Boolean fields represent flags.
    _short: bool = false, // matches flag '-s' or '--short'
    // Upper case field names represent positional arguments.
    @"FILE:*": []const u8 = null, // matches zero or more strings
};

// MakeParser creates  the parser at compile time.
const Parser = zgra.MakeParser(
    Args,
    // second argument is a tuple with help strings
    .{
        .format = "the expect format of the output",
        ._verbose = "sets the verbosity level",
        ._short = "shorten the output",
        .@"FILE:*" = "FILEs for processing"
    },
);

pub fn main() !void {
    // ...
    // alloc = an allocator used for allocating positional arguments.
    // w = writer used for printing help and version information.
    var it = std.process.ArgIterator.init();
    // The template field is used to instantiate default values.
    // Since Args already has the default values provided, we can simply leave this empty.
    var parser = Parser{ .template = .{} };
    // The .parse() method returns the initial structure and an owned slice of parsed positional arguments.
    const parsing_result: Args, const positionals: [][]const u8 = try parser.parse(&it, &w, &alloc);
    // ...
}
```
