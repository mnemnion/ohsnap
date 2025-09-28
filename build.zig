const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();

    const mod_names: []const []const u8 = b.option(
        []const []const u8,
        "module_name",
        "Name of a module with a non-standard directory.",
    ) orelse &.{};

    options.addOption([]const []const u8, "module_name", mod_names);

    const mod_dirs: []const []const u8 = b.option(
        []const []const u8,
        "root_directory",
        "Non-standard directory in which the corresponding `module_name` is found (relative to repo).",
    ) orelse &.{};

    options.addOption([]const []const u8, "root_directory", mod_dirs);

    // Export as module to be available for @import("ohsnap") on user site
    const snap_module = b.addModule("ohsnap", .{
        .root_source_file = b.path("src/ohsnap.zig"),
        .target = target,
        .optimize = optimize,
    });

    snap_module.addOptions("config", options);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = snap_module,
        .filters = test_filters,
    });

    lib_unit_tests.root_module.addOptions("config", options);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    if (b.lazyDependency("pretty", .{
        .target = target,
        .optimize = optimize,
    })) |pretty_dep| {
        lib_unit_tests.root_module.addImport("pretty", pretty_dep.module("pretty"));
        snap_module.addImport("pretty", pretty_dep.module("pretty"));
    }

    if (b.lazyDependency("muad_diff", .{
        .target = target,
        .optimize = optimize,
    })) |muad_dep| {
        lib_unit_tests.root_module.addImport("diffz", muad_dep.module("dmp"));
        snap_module.addImport("diffz", muad_dep.module("dmp"));
    }

    if (b.lazyDependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    })) |mvzr_dep| {
        lib_unit_tests.root_module.addImport("mvzr", mvzr_dep.module("mvzr"));
        snap_module.addImport("mvzr", mvzr_dep.module("mvzr"));
    }

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
