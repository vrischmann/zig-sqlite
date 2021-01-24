const std = @import("std");

var sqlite3: ?*std.build.LibExeObjStep = null;

fn linkSqlite(b: *std.build.LibExeObjStep) void {
    b.linkLibC();

    if (sqlite3) |lib| {
        b.linkLibrary(lib);
    } else {
        b.linkSystemLibrary("sqlite3");
    }
}

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const use_bundled = b.option(bool, "use_bundled", "Use the bundled sqlite3 source instead of linking the system library (default false)") orelse false;

    // Build sqlite from source if asked
    if (use_bundled) {
        const lib = b.addStaticLibrary("sqlite", null);
        lib.addCSourceFile("sqlite3.c", &[_][]const u8{"-std=c99"});
        lib.linkLibC();
        lib.setTarget(target);
        lib.setBuildMode(mode);
        sqlite3 = lib;
    }

    const lib = b.addStaticLibrary("zig-sqlite", "sqlite.zig");
    lib.addIncludeDir(".");
    linkSqlite(lib);
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("sqlite.zig");
    main_tests.addIncludeDir(".");
    linkSqlite(main_tests);
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    main_tests.setBuildMode(mode);
    main_tests.addBuildOption(bool, "in_memory", in_memory);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
