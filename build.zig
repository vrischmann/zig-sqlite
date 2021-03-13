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

fn getTarget(original_target: std.zig.CrossTarget, bundled: bool) std.zig.CrossTarget {
    if (bundled) {
        var tmp = original_target;

        if (tmp.isGnuLibC()) {
            const min_glibc_version = std.builtin.Version{
                .major = 2,
                .minor = 28,
                .patch = 0,
            };
            if (tmp.glibc_version) |ver| {
                if (ver.order(min_glibc_version) == .lt) {
                    std.debug.panic("sqlite requires glibc version >= 2.28", .{});
                }
            } else {
                tmp.setGnuLibCVersion(2, 28, 0);
            }
        }

        return tmp;
    }

    return original_target;
}

pub fn build(b: *std.build.Builder) void {
    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const dbfile = b.option([]const u8, "dbfile", "Always use this database file instead of a temporary one");
    const use_bundled = b.option(bool, "use_bundled", "Use the bundled sqlite3 source instead of linking the system library (default false)") orelse false;

    const target = getTarget(b.standardTargetOptions(.{}), use_bundled);
    const mode = b.standardReleaseOptions();

    // Build sqlite from source if asked
    if (use_bundled) {
        const lib = b.addStaticLibrary("sqlite", null);
        lib.addCSourceFile("c/sqlite3.c", &[_][]const u8{"-std=c99"});
        lib.linkLibC();
        lib.setTarget(target);
        lib.setBuildMode(mode);
        sqlite3 = lib;
    }

    const lib = b.addStaticLibrary("zig-sqlite", "sqlite.zig");
    lib.addIncludeDir("c");
    linkSqlite(lib);
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("sqlite.zig");
    main_tests.addIncludeDir("c");
    linkSqlite(main_tests);
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    main_tests.setBuildMode(mode);
    main_tests.addBuildOption(bool, "in_memory", in_memory);
    main_tests.addBuildOption(?[]const u8, "dbfile", dbfile);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
