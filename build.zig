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

const TestTarget = struct {
    target: std.zig.CrossTarget = @as(std.zig.CrossTarget, .{}),
    mode: std.builtin.Mode = .Debug,
    single_threaded: bool = false,
    bundled: bool,
};

const all_test_targets = switch (std.Target.current.cpu.arch) {
    .x86_64 => switch (std.Target.current.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{
                .target = .{},
                .bundled = false,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .i386,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .aarch64,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .riscv64,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .mips,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .arm,
                    .abi = .musleabihf,
                },
                .bundled = true,
            },
        },
        .windows => [_]TestTarget{
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                    .abi = .gnu,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .i386,
                    .abi = .gnu,
                },
                .bundled = true,
            },
        },
        .freebsd => [_]TestTarget{
            TestTarget{
                .target = .{},
                .bundled = false,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                },
                .bundled = true,
            },
        },
        .macos => [_]TestTarget{
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                },
                .bundled = true,
            },
        },
        else => [_]TestTarget{
            TestTarget{
                .target = .{},
                .bundled = false,
            },
        },
    },
    else => [_]TestTarget{
        TestTarget{
            .target = .{},
            .bundled = false,
        },
    },
};

pub fn build(b: *std.build.Builder) void {
    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const dbfile = b.option([]const u8, "dbfile", "Always use this database file instead of a temporary one");
    const use_bundled = b.option(bool, "use_bundled", "Use the bundled sqlite3 source instead of linking the system library (default false)");
    const enable_qemu = b.option(bool, "enable_qemu", "Enable qemu for running tests (default false)") orelse false;

    const target = b.standardTargetOptions(.{});

    const test_targets = if (target.isNative())
        &all_test_targets
    else
        &[_]TestTarget{.{
            .target = target,
            .bundled = use_bundled orelse false,
        }};

    const test_step = b.step("test", "Run library tests");
    for (test_targets) |test_target| {
        const bundled = use_bundled orelse test_target.bundled;
        const cross_target = getTarget(test_target.target, bundled);

        const tests = b.addTest("sqlite.zig");

        if (bundled) {
            const lib = b.addStaticLibrary("sqlite", null);
            lib.addCSourceFile("c/sqlite3.c", &[_][]const u8{"-std=c99"});
            lib.linkLibC();
            lib.setTarget(cross_target);
            lib.setBuildMode(test_target.mode);
            sqlite3 = lib;
        }

        const lib = b.addStaticLibrary("zig-sqlite", "sqlite.zig");
        lib.addIncludeDir("c");
        linkSqlite(lib);
        lib.setTarget(cross_target);
        lib.setBuildMode(test_target.mode);

        const single_threaded_txt = if (test_target.single_threaded) "single" else "multi";
        tests.setNamePrefix(b.fmt("{s}-{s}-{s} ", .{
            cross_target.zigTriple(b.allocator),
            @tagName(test_target.mode),
            single_threaded_txt,
        }));
        tests.single_threaded = test_target.single_threaded;
        tests.setBuildMode(test_target.mode);
        tests.setTarget(cross_target);
        tests.addIncludeDir("c");
        linkSqlite(tests);
        tests.enable_qemu = enable_qemu;

        const tests_options = b.addOptions();
        tests.addOptions("build_options", tests_options);

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        test_step.dependOn(&tests.step);
    }
}
