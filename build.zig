const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "ohsnap",
        .root_source_file = b.path("src/ohsnap.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/ohsnap.zig"),
        .target = target,
        .optimize = optimize,
        .filter = b.option([]const u8, "filter", "Filter strings for tests"),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    if (b.lazyDependency("pretty", .{
        .target = target,
        .optimize = optimize,
    })) |pretty_dep| {
        lib.root_module.addImport("pretty", pretty_dep.module("pretty"));
        lib_unit_tests.root_module.addImport("pretty", pretty_dep.module("pretty"));
    }

    if (b.lazyDependency("diffz", .{
        .target = target,
        .optimize = optimize,
    })) |diffz_dep| {
        lib.root_module.addImport("diffz", diffz_dep.module("diffz"));
        lib_unit_tests.root_module.addImport("diffz", diffz_dep.module("diffz"));
    }

    if (b.lazyDependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    })) |mvzr_dep| {
        lib.root_module.addImport("mvzr", mvzr_dep.module("mvzr"));
        lib_unit_tests.root_module.addImport("mvzr", mvzr_dep.module("mvzr"));
    }

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
