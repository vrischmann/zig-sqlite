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

    const is_ci = b.option(bool, "is_ci", "Identifies if it runs in a CI environment") orelse false;

    var main_tests = b.addTest("sqlite.zig");
    main_tests.setBuildMode(mode);
    main_tests.addBuildOption(bool, "is_ci", is_ci);
    linkAll(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
