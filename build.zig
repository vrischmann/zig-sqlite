const std = @import("std");
const builtin = @import("builtin");
const Step = std.Build.Step;
const ResolvedTarget = std.Build.ResolvedTarget;
const Query = std.Target.Query;

fn getTarget(original_target: ResolvedTarget, bundled: bool) ResolvedTarget {
    if (bundled) {
        var tmp = original_target;

        if (tmp.result.isGnuLibC()) {
            const min_glibc_version = std.SemanticVersion{
                .major = 2,
                .minor = 28,
                .patch = 0,
            };
            const ver = tmp.result.os.version_range.linux.glibc;
            if (ver.order(min_glibc_version) == .lt) {
                std.debug.panic("sqlite requires glibc version >= 2.28", .{});
            }
        }

        return tmp;
    }

    return original_target;
}

const TestTarget = struct {
    query: Query,
    single_threaded: bool = false,
    bundled: bool,
};

const ci_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .musl }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .musl }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .abi = .musl }, .bundled = true },
        },
        .windows => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .gnu }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .gnu }, .bundled = true },
        },
        .macos => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64 }, .bundled = true },
        },
        else => [_]TestTarget{},
    },
    else => [_]TestTarget{},
};

const all_test_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{ .query = .{}, .bundled = false },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .musl }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .musl }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .abi = .musl }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .riscv64, .abi = .musl }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .mips, .abi = .musl }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .x86, .os_tag = .windows }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .bundled = true },
        },
        .windows => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .gnu }, .bundled = true },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .gnu }, .bundled = true },
        },
        .freebsd => [_]TestTarget{
            TestTarget{ .query = .{}, .bundled = false },
            TestTarget{ .query = .{ .cpu_arch = .x86_64 }, .bundled = true },
        },
        .macos => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64 }, .bundled = true },
        },
        else => [_]TestTarget{
            TestTarget{ .query = .{}, .bundled = false },
        },
    },
    .aarch64 => switch (builtin.target.os.tag) {
        .linux, .windows, .freebsd, .macos => [_]TestTarget{
            TestTarget{ .query = .{}, .bundled = true },
        },
        else => [_]TestTarget{
            TestTarget{ .query = .{}, .bundled = false },
        },
    },
    else => [_]TestTarget{
        TestTarget{ .query = .{}, .bundled = false },
    },
};

fn computeTestTargets(isNative: bool, ci: ?bool) ?[]const TestTarget {
    if (ci != null and ci.?) return &ci_targets;

    if (isNative) {
        // If the target is native we assume the user didn't change it with -Dtarget and run all test targets.
        return &all_test_targets;
    }

    // Otherwise we run a single test target.
    return null;
}

pub fn build(b: *std.Build) !void {
    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const dbfile = b.option([]const u8, "dbfile", "Always use this database file instead of a temporary one");
    const use_bundled = b.option(bool, "use_bundled", "Use the bundled sqlite3 source instead of linking the system library (default false)");
    const ci = b.option(bool, "ci", "Build and test in the CI on GitHub");

    const query = b.standardTargetOptionsQueryOnly(.{});
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    const c_flags = &[_][]const u8{"-std=c99"};

    const sqlite_lib = b.addStaticLibrary(.{
        .name = "sqlite",
        .target = target,
        .optimize = optimize,
    });

    sqlite_lib.addIncludePath(b.path("c/"));
    sqlite_lib.addCSourceFiles(.{
        .files = &[_][]const u8{
            "c/sqlite3.c",
            "c/workaround.c",
        },
        .flags = c_flags,
    });
    sqlite_lib.linkLibC();
    sqlite_lib.installHeader(b.path("c/sqlite3.h"), "sqlite3.h");

    b.installArtifact(sqlite_lib);

    // Create the public 'sqlite' module to be exported
    const sqlite_mod = b.addModule("sqlite", .{
        .root_source_file = b.path("sqlite.zig"),
        .link_libc = true,
    });
    sqlite_mod.addIncludePath(b.path("c/"));
    sqlite_mod.linkLibrary(sqlite_lib);

    // Tool to preprocess the sqlite header files.
    //
    // Due to limitations of translate-c the standard header files can't be used for building loadable extensions
    // so we have this tool which creates usable header files.

    const preprocess_files_tool = b.addExecutable(.{
        .name = "preprocess-files",
        .root_source_file = b.path("tools/preprocess_files.zig"),
        .target = getTarget(target, true),
        .optimize = optimize,
    });

    // Add a top-level step to run the preprocess-files tool
    const preprocess_files_run = b.step("preprocess-files", "Run the preprocess-files tool");

    const preprocess_files_tool_run = b.addRunArtifact(preprocess_files_tool);
    preprocess_files_run.dependOn(&preprocess_files_tool_run.step);

    const test_targets = computeTestTargets(query.isNative(), ci) orelse &[_]TestTarget{.{
        .query = query,
        .bundled = use_bundled orelse false,
    }};
    const test_step = b.step("test", "Run library tests");

    // By default the tests will only be execute for native test targets, however they will be compiled
    // for _all_ targets defined in `test_targets`.
    //
    // If you want to execute tests for other targets you can pass -fqemu, -fdarling, -fwine, -frosetta.

    for (test_targets) |test_target| {
        const bundled = use_bundled orelse test_target.bundled;
        const cross_target = getTarget(b.resolveTargetQuery(test_target.query), bundled);
        const single_threaded_txt = if (test_target.single_threaded) "single" else "multi";
        const test_name = b.fmt("{s}-{s}-{s}", .{
            try cross_target.result.zigTriple(b.allocator),
            @tagName(optimize),
            single_threaded_txt,
        });

        const test_sqlite_lib = b.addStaticLibrary(.{
            .name = "sqlite",
            .target = cross_target,
            .optimize = optimize,
        });
        test_sqlite_lib.addCSourceFiles(.{
            .files = &[_][]const u8{
                "c/sqlite3.c",
                "c/workaround.c",
            },
            .flags = c_flags,
        });
        test_sqlite_lib.linkLibC();

        const tests = b.addTest(.{
            .name = test_name,
            .target = cross_target,
            .optimize = optimize,
            .root_source_file = b.path("sqlite.zig"),
            .single_threaded = test_target.single_threaded,
        });
        tests.addIncludePath(b.path("c"));
        if (bundled) {
            tests.linkLibrary(test_sqlite_lib);
        } else {
            tests.linkLibC();
            tests.addCSourceFile(.{ .file = b.path("c/workaround.c"), .flags = c_flags });
            tests.linkSystemLibrary("sqlite3");
        }

        const tests_options = b.addOptions();
        tests.root_module.addImport("build_options", tests_options.createModule());

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    // Fuzzing

    const lib = b.addStaticLibrary(.{
        .name = "sqlite",
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    lib.addCSourceFile(.{ .file = b.path("c/sqlite3.c"), .flags = c_flags });
    lib.addIncludePath(b.path("c"));
    lib.linkLibC();

    // The library
    const fuzz_lib = b.addStaticLibrary(.{
        .name = "fuzz-lib",
        .root_source_file = b.path("fuzz/main.zig"),
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    fuzz_lib.addIncludePath(b.path("c"));
    fuzz_lib.linkLibrary(lib);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.root_module.addImport("sqlite", sqlite_mod);

    // Setup the output name
    const fuzz_executable_name = "fuzz";
    const fuzz_exe_path = try b.cache_root.join(b.allocator, &.{fuzz_executable_name});

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o", fuzz_exe_path });
    fuzz_compile.addArtifactArg(lib);
    fuzz_compile.addArtifactArg(fuzz_lib);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(.{ .cwd_relative = fuzz_exe_path }, fuzz_executable_name);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step("fuzz", "Build executable for fuzz testing using afl-clang-lto");
    // fuzz_compile_run.dependOn(&fuzz_lib.step);
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(.{
        .name = "fuzz-debug",
        .root_source_file = b.path("fuzz/main.zig"),
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    fuzz_debug_exe.addIncludePath(b.path("c"));
    fuzz_debug_exe.linkLibrary(lib);
    fuzz_debug_exe.root_module.addImport("sqlite", sqlite_mod);

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe, .{});
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);

    //
    // Examples
    //

    // Loadable extension
    //
    // This builds an example shared library with the extension and a binary that tests it.

    const zigcrypto_loadable_ext = b.addSharedLibrary(.{
        .name = "zigcrypto",
        .root_source_file = b.path("examples/zigcrypto.zig"),
        .version = null,
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    zigcrypto_loadable_ext.addIncludePath(b.path("c"));
    zigcrypto_loadable_ext.root_module.addImport("sqlite", sqlite_mod);
    zigcrypto_loadable_ext.linkLibrary(lib);

    const install_zigcrypto_loadable_ext = b.addInstallArtifact(zigcrypto_loadable_ext, .{});

    const zigcrypto_test = b.addExecutable(.{
        .name = "zigcrypto-test",
        .root_source_file = b.path("examples/zigcrypto_test.zig"),
        .target = getTarget(target, true),
        .optimize = optimize,
    });
    zigcrypto_test.addIncludePath(b.path("c"));
    zigcrypto_test.root_module.addImport("sqlite", sqlite_mod);
    zigcrypto_test.linkLibrary(lib);

    const install_zigcrypto_test = b.addInstallArtifact(zigcrypto_test, .{});

    const zigcrypto_compile_run = b.step("zigcrypto", "Build the 'zigcrypto' SQLite loadable extension");
    zigcrypto_compile_run.dependOn(&install_zigcrypto_loadable_ext.step);
    zigcrypto_compile_run.dependOn(&install_zigcrypto_test.step);
}
