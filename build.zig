const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zgra", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const example_step = b.step("examples", "Build all exmaples");
    const examples_dir_path = b.path("examples");
    var examples_dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch {
        return;
    };
    defer examples_dir.close();

    var dir_iter = examples_dir.iterate();
    while (dir_iter.next() catch null) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".zig")) {
            const name = e.name[0 .. e.name.len - 4];
            const example_exe = b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .root_source_file = examples_dir_path.path(b, e.name),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zgra", .module = mod },
                    },
                }),
            });

            const install_example = b.addInstallArtifact(example_exe, .{
                .dest_dir = .{
                    .override = .{ .custom = "examples" },
                },
            });

            example_step.dependOn(&install_example.step);

            const run_example_step = b.step(
                b.fmt("run-{s}", .{name}),
                b.fmt("Run the {s} example", .{name}),
            );

            const example_cmd = b.addRunArtifact(example_exe);
            run_example_step.dependOn(&example_cmd.step);

            if (b.args) |args| {
                example_cmd.addArgs(args);
            }
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
