const std = @import("std");
const builtin = @import("builtin");

var sqlite3: ?*std.Build.Step.Compile = null;

fn linkSqlite(b: *std.Build.Step.Compile) void {
    if (sqlite3) |lib| {
        b.linkLibrary(lib);
    } else {
        b.linkLibC();
        b.linkSystemLibrary("sqlite3");
    }
}

fn getTarget(original_target: std.zig.CrossTarget, bundled: bool) std.zig.CrossTarget {
    if (bundled) {
        var tmp = original_target;

        if (tmp.isGnuLibC()) {
            const min_glibc_version = std.SemanticVersion{
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
    single_threaded: bool = false,
    bundled: bool,
};

const all_test_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            // Targets linux but other CPU archs.
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
                    .cpu_arch = .x86,
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
            // TODO(vincent): failing for some time for unknown reasons
            // TestTarget{
            //     .target = .{
            //         .cpu_arch = .arm,
            //         .abi = .musleabihf,
            //     },
            //     .bundled = true,
            // },
            // Targets windows
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                    .os_tag = .windows,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .x86,
                    .os_tag = .windows,
                },
                .bundled = true,
            },
            // Targets macOS
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                    .os_tag = .macos,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .aarch64,
                    .os_tag = .macos,
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
                    .cpu_arch = .x86,
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

pub fn build(b: *std.Build) !void {
    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const dbfile = b.option([]const u8, "dbfile", "Always use this database file instead of a temporary one");
    const use_bundled = b.option(bool, "use_bundled", "Use the bundled sqlite3 source instead of linking the system library (default false)");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Tool to preprocess the sqlite header files.
    //
    // Due to limitations of translate-c the standard header files can't be used for building loadable extensions
    // so we have this tool which creates usable header files.

    const preprocess_files_tool = b.addExecutable(.{
        .name = "preprocess-files",
        .root_source_file = .{ .path = "tools/preprocess_files.zig" },
        .target = getTarget(target, true),
        .optimize = optimize,
    });

    // Add a top-level step to run the preprocess-files tool
    const preprocess_files_run = b.step("preprocess-files", "Run the preprocess-files tool");

    const preprocess_files_tool_run = b.addRunArtifact(preprocess_files_tool);
    preprocess_files_run.dependOn(&preprocess_files_tool_run.step);

    // If the target is native we assume the user didn't change it with -Dtarget and run all test targets.
    // Otherwise we run a single test target.
    const test_targets = if (target.isNative())
        &all_test_targets
    else
        &[_]TestTarget{.{
            .target = target,
            .bundled = use_bundled orelse false,
        }};

    const test_step = b.step("test", "Run library tests");

    // By default the tests will only be execute for native test targets, however they will be compiled
    // for _all_ targets defined in `test_targets`.
    //
    // If you want to execute tests for other targets you can pass -fqemu, -fdarling, -fwine, -frosetta.

    for (test_targets) |test_target| {
        const bundled = use_bundled orelse test_target.bundled;
        const cross_target = getTarget(test_target.target, bundled);
        const single_threaded_txt = if (test_target.single_threaded) "single" else "multi";
        const test_name = b.fmt("{s}-{s}-{s}", .{
            try cross_target.zigTriple(b.allocator),
            @tagName(optimize),
            single_threaded_txt,
        });

        const tests = b.addTest(.{
            .name = test_name,
            .target = cross_target,
            .optimize = optimize,
            .root_source_file = .{ .path = "sqlite.zig" },
            .single_threaded = test_target.single_threaded,
        });

        if (bundled) {
            const lib = b.addStaticLibrary(.{
                .name = "sqlite",
                .target = cross_target,
                .optimize = optimize,
            });
            lib.addCSourceFile("c/sqlite3.c", &[_][]const u8{"-std=c99"});
            lib.linkLibC();
            sqlite3 = lib;
        }

        if (bundled) tests.addIncludePath("c");
        linkSqlite(tests);

        const lib = b.addStaticLibrary(.{
            .name = "zig-sqlite",
            .root_source_file = .{ .path = "sqlite.zig" },
            .target = cross_target,
            .optimize = optimize,
        });
        if (bundled) lib.addIncludePath("c");
        linkSqlite(lib);

        const tests_options = b.addOptions();
        tests.addOptions("build_options", tests_options);

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        test_step.dependOn(&tests.step);
    }

    // Fuzzing

    const lib = b.addStaticLibrary(.{
        .name = "sqlite",
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    lib.addCSourceFile("c/sqlite3.c", &[_][]const u8{"-std=c99"});
    lib.addIncludePath("c");
    lib.linkLibC();

    // The library
    const fuzz_lib = b.addStaticLibrary(.{
        .name = "fuzz-lib",
        .root_source_file = .{ .path = "fuzz/main.zig" },
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    fuzz_lib.addIncludePath("c");
    fuzz_lib.linkLibrary(lib);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.addAnonymousModule("sqlite", .{
        .source_file = .{ .path = "sqlite.zig" },
    });

    // Setup the output name
    const fuzz_executable_name = "fuzz";
    const fuzz_exe_path = try b.cache_root.join(b.allocator, &.{fuzz_executable_name});

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o", fuzz_exe_path });
    fuzz_compile.addArtifactArg(lib);
    fuzz_compile.addArtifactArg(fuzz_lib);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(.{ .path = fuzz_exe_path }, fuzz_executable_name);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step("fuzz", "Build executable for fuzz testing using afl-clang-lto");
    // fuzz_compile_run.dependOn(&fuzz_lib.step);
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(.{
        .name = "fuzz-debug",
        .root_source_file = .{ .path = "fuzz/main.zig" },
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    fuzz_debug_exe.addIncludePath("c");
    fuzz_debug_exe.linkLibrary(lib);
    fuzz_debug_exe.addAnonymousModule("sqlite", .{
        .source_file = .{ .path = "sqlite.zig" },
    });

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe);
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);

    //
    // Examples
    //

    // Loadable extension
    //
    // This builds an example shared library with the extension and a binary that tests it.

    const zigcrypto_loadable_ext = b.addSharedLibrary(.{
        .name = "zigcrypto",
        .root_source_file = .{ .path = "examples/zigcrypto.zig" },
        .version = null,
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    zigcrypto_loadable_ext.force_pic = true;
    zigcrypto_loadable_ext.addIncludePath("c");
    zigcrypto_loadable_ext.addAnonymousModule("sqlite", .{
        .source_file = .{ .path = "sqlite.zig" },
    });
    zigcrypto_loadable_ext.linkLibrary(lib);

    const install_zigcrypto_loadable_ext = b.addInstallArtifact(zigcrypto_loadable_ext);

    const zigcrypto_test = b.addExecutable(.{
        .name = "zigcrypto-test",
        .root_source_file = .{ .path = "examples/zigcrypto_test.zig" },
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    zigcrypto_test.addIncludePath("c");
    zigcrypto_test.addAnonymousModule("sqlite", .{
        .source_file = .{ .path = "sqlite.zig" },
    });
    zigcrypto_test.linkLibrary(lib);

    const install_zigcrypto_test = b.addInstallArtifact(zigcrypto_test);

    const zigcrypto_compile_run = b.step("zigcrypto", "Build the 'zigcrypto' SQLite loadable extension");
    zigcrypto_compile_run.dependOn(&install_zigcrypto_loadable_ext.step);
    zigcrypto_compile_run.dependOn(&install_zigcrypto_test.step);
}
