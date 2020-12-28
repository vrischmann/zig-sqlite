const std = @import("std");
const Builder = std.build.Builder;

fn linkAll(obj: *std.build.LibExeObjStep) void {
    obj.linkLibC();
    obj.linkSystemLibrary("sqlite3");
}

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zig-sqlite", "sqlite.zig");
    lib.setBuildMode(mode);
    linkAll(lib);
    lib.install();

    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory") orelse false;

    var main_tests = b.addTest("sqlite.zig");
    main_tests.setBuildMode(mode);
    main_tests.addBuildOption(bool, "in_memory", in_memory);
    linkAll(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
