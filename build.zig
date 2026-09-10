const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const mem = std.mem;
const ResolvedTarget = std.Build.ResolvedTarget;
const Query = std.Target.Query;
const builtin = @import("builtin");

// preprocessor: an external command (zig build run) that pre-processes
// sqlite3.h / sqlite3ext.h so the result can be consumed by `zig translate-c`.
// (The header manipulation logic lives in `build/Preprocessor.zig`.)

fn getTarget(original_target: ResolvedTarget) ResolvedTarget {
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

const TestTarget = struct {
    query: Query,
    single_threaded: bool = false,
};

const ci_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .abi = .musl } },
        },
        .windows => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .gnu } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .gnu } },
        },
        .macos => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        else => [_]TestTarget{},
    },
    else => [_]TestTarget{},
};

const all_test_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            TestTarget{ .query = .{} },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .riscv64, .abi = .musl } },
            // Disabled because it fails for some unknown reason
            // TestTarget{ .query = .{ .cpu_arch = .mips, .abi = .musl } },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .os_tag = .windows } },
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
            TestTarget{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        },
        .windows => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64, .abi = .gnu } },
            // Disabled due to https://github.com/ziglang/zig/issues/20047
            // TestTarget{ .query = .{ .cpu_arch = .x86, .abi = .gnu } },
        },
        .freebsd => [_]TestTarget{
            TestTarget{ .query = .{} },
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        .macos => [_]TestTarget{
            TestTarget{ .query = .{ .cpu_arch = .x86_64 } },
        },
        else => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
    },
    .aarch64 => switch (builtin.target.os.tag) {
        .linux, .windows, .freebsd, .macos => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
        else => [_]TestTarget{
            TestTarget{ .query = .{} },
        },
    },
    else => [_]TestTarget{
        TestTarget{ .query = .{} },
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

// This creates a SQLite static library from the SQLite dependency code.
fn makeSQLiteLib(b: *std.Build, dep: *std.Build.Dependency, c_flags: []const []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sqlite_c: enum { with, without }, module_suffix: []const u8) !*std.Build.Step.Compile {
    const mod_name = try std.fmt.allocPrint(b.allocator, "lib-sqlite-{s}{s}", .{ module_suffix, if (sqlite_c == .with) "-with" else "-without" });
    const mod = b.addModule(mod_name, .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = "sqlite",
        .linkage = .static,
        .root_module = mod,
    });

    lib.root_module.addIncludePath(dep.path("."));
    lib.root_module.addIncludePath(b.path("c"));
    if (sqlite_c == .with) {
        lib.root_module.addCSourceFile(.{
            .file = dep.path("sqlite3.c"),
            .flags = c_flags,
        });
    }
    lib.root_module.addCSourceFile(.{
        .file = b.path("c/workaround.c"),
        .flags = c_flags,
    });

    return lib;
}

pub fn build(b: *std.Build) !void {
    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const dbfile = b.option([]const u8, "dbfile", "Always use this database file instead of a temporary one");
    const ci = b.option(bool, "ci", "Build and test in the CI on GitHub");

    const query = b.standardTargetOptionsQueryOnly(.{});
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    // Upstream dependency
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    // Define C flags to use

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.append(b.allocator, "-std=c99");

    if (builtin.zig_version.minor <= 16) {
        // Zig 0.16 and earlier
        inline for (@typeInfo(EnableOptions).@"struct".fields) |field| {
            const opt = b.option(bool, field.name, "Enable " ++ field.name) orelse field.defaultValue().?;

            if (opt) {
                var buf: [field.name.len]u8 = undefined;
                const name = std.ascii.upperString(&buf, field.name);
                const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_ENABLE_{s}", .{name});

                try flags.append(b.allocator, flag);
            }
        }
    } else {
        // Zig 0.17+
        const s = @typeInfo(EnableOptions).@"struct";
        inline for (s.field_names) |name| {
            const opt = b.option(bool, name, "Enable " ++ name) orelse false;

            if (opt) {
                var buf: [name.len]u8 = undefined;
                const upper_name = std.ascii.upperString(&buf, name);
                const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_ENABLE_{s}", .{upper_name});

                try flags.append(b.allocator, flag);
            }
        }
    }

    const c_flags = flags.items;

    // Preprocess the upstream sqlite3.h / sqlite3ext.h into
    // c/loadable-ext-*.h so `zig translate-c` can produce the
    // c_bindings_ext module (used for loadable extensions).
    const preprocess_run = addPreprocessRun(b, sqlite_dep);

    // C bindings via translate-c (works for both Zig 0.16 and 0.17+)
    const c_bindings = b.addTranslateC(.{
        .root_source_file = b.path("c/c_bindings.c"),
        .target = target,
        .optimize = optimize,
    });
    c_bindings.addIncludePath(sqlite_dep.path("."));
    c_bindings.addIncludePath(b.path("c"));

    const c_bindings_ext = b.addTranslateC(.{
        .root_source_file = b.path("c/c_bindings_ext.c"),
        .target = target,
        .optimize = optimize,
    });
    c_bindings_ext.addIncludePath(b.path("c"));
    c_bindings_ext.step.dependOn(&preprocess_run.step);

    //
    // Main library and module
    //

    // const sqlite_lib, const sqlite_mod = blk: {
    const sqlite_lib, _ = blk: {
        const lib = try makeSQLiteLib(b, sqlite_dep, c_flags, target, optimize, .with, "main");

        const mod = b.addModule("sqlite", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = true,
        });
        mod.addImport("c_bindings", c_bindings.createModule());
        mod.linkLibrary(lib);

        break :blk .{ lib, mod };
    };
    b.installArtifact(sqlite_lib);

    // const sqliteext_mod = blk: {
    _ = blk: {
        const lib = try makeSQLiteLib(b, sqlite_dep, c_flags, target, optimize, .without, "ext");

        const mod = b.addModule("sqliteext", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = true,
        });
        mod.addImport("c_bindings", c_bindings_ext.createModule());
        mod.linkLibrary(lib);

        break :blk mod;
    };

    //
    // Tests
    //

    const test_targets = computeTestTargets(query.isNative(), ci) orelse &[_]TestTarget{.{
        .query = query,
    }};
    const test_step = b.step("test", "Run library tests");

    // By default the tests will only be execute for native test targets, however they will be compiled
    // for _all_ targets defined in `test_targets`.
    //
    // If you want to execute tests for other targets you can pass -fqemu, -fdarling, -fwine, -frosetta.

    for (test_targets) |test_target| {
        const cross_target = getTarget(b.resolveTargetQuery(test_target.query));
        const single_threaded_txt = if (test_target.single_threaded) "single" else "multi";
        const test_name = b.fmt("{s}-{s}-{s}", .{
            try cross_target.result.zigTriple(b.allocator),
            @tagName(optimize),
            single_threaded_txt,
        });

        const test_sqlite_lib = try makeSQLiteLib(b, sqlite_dep, c_flags, cross_target, optimize, .with, test_name);

        // Per-target C bindings
        const test_c_bindings = b.addTranslateC(.{
            .root_source_file = b.path("c/c_bindings.c"),
            .target = cross_target,
            .optimize = optimize,
        });
        test_c_bindings.addIncludePath(sqlite_dep.path("."));
        test_c_bindings.addIncludePath(b.path("c"));

        const mod = b.addModule(test_name, .{
            .target = cross_target,
            .optimize = optimize,
            .root_source_file = b.path("sqlite.zig"),
            .single_threaded = test_target.single_threaded,
        });

        const tests = b.addTest(.{
            .name = test_name,
            .root_module = mod,
        });
        tests.root_module.addImport("c_bindings", test_c_bindings.createModule());
        tests.root_module.linkLibrary(test_sqlite_lib);

        const tests_options = b.addOptions();
        tests.root_module.addImport("build_options", tests_options.createModule());

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);

        // Make sure the fork's own test build exercises the consumer-path
        // translate-c (which depends on the preprocessed headers). Without
        // this, a broken preprocessor would only surface in downstream
        // consumers' builds.
        test_c_bindings.step.dependOn(&preprocess_run.step);
    }

    // Top-level `preprocess-headers` step for manual regeneration of the
    // committed `c/loadable-ext-*.h` files (re-runs the same preprocessor).
    {
        const write_back = b.addUpdateSourceFiles();
        write_back.addCopyFileToSource(b.path("c/loadable-ext-sqlite3.h"), "c/loadable-ext-sqlite3.h");
        write_back.addCopyFileToSource(b.path("c/loadable-ext-sqlite3ext.h"), "c/loadable-ext-sqlite3ext.h");
        write_back.step.dependOn(&preprocess_run.step);

        const regenerate = b.step("preprocess-headers", "Regenerate c/loadable-ext-*.h from the fetched SQLite headers");
        regenerate.dependOn(&write_back.step);
    }
}

fn addZigcrypto(b: *std.Build, sqlite_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.InstallArtifact {
    const mod = b.addModule("zigcryto", .{
        .root_source_file = b.path("examples/zigcrypto.zig"),
        .target = getTarget(target),
        .optimize = optimize,
    });
    const exe = b.addLibrary(.{
        .name = "zigcrypto",
        .root_module = mod,
        .version = null,
        .linkage = .dynamic,
    });
    exe.root_module.addImport("sqlite", sqlite_mod);

    const install_artifact = b.addInstallArtifact(exe, .{});
    install_artifact.step.dependOn(&exe.step);

    return install_artifact;
}

fn addZigcryptoTestRun(b: *std.Build, sqlite_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Run {
    const mod = b.addModule("zigcryto-test", .{
        .root_source_file = b.path("examples/zigcrypto_test.zig"),
        .target = getTarget(target),
        .optimize = optimize,
    });
    const zigcrypto_test = b.addExecutable(.{
        .name = "zigcrypto-test",
        .root_module = mod,
    });
    zigcrypto_test.root_module.addImport("sqlite", sqlite_mod);

    const install = b.addInstallArtifact(zigcrypto_test, .{});
    install.step.dependOn(&zigcrypto_test.step);

    const run = b.addRunArtifact(zigcrypto_test);
    run.step.dependOn(&zigcrypto_test.step);

    return run;
}

// Builds a small host executable from `build/Preprocessor.zig` and returns a
// step that runs it twice (once for sqlite3.h, once for sqlite3ext.h).
//
// Running an actual binary (instead of using a custom Build step) lets the
// preprocess work uniformly on Zig 0.16 and 0.17+, whose Build step APIs
// diverge significantly.
fn addPreprocessRun(
    b: *std.Build,
    sqlite_dep: *std.Build.Dependency,
) *std.Build.Step.Run {
    const preprocess_mod = b.createModule(.{
        .root_source_file = b.path("build/Preprocessor.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const preprocess_exe = b.addExecutable(.{
        .name = "zig-sqlite-preprocess",
        .root_module = preprocess_mod,
    });
    b.installArtifact(preprocess_exe);

    // Resolve the four paths we need. We use `b.pathResolve` (cross-version
    // stdlib helper) to build path strings from the lazy path's
    // underlying root + sub_path. `LazyPath.getPath2` was removed in 0.17,
    // so we walk the path's tags ourselves.
    const resolveDep = struct {
        fn call(dep: *std.Build.Dependency, sub: []const u8) []u8 {
            const dep_b = dep.builder;
            // Build.root in 0.17 is `Cache.Path { root_dir: Directory, sub_path: []const u8 }`;
            // in 0.16 it's `Cache.Directory` directly. Both expose the root path
            // as `root_dir.path: ?[]const u8` (0.17) or `build_root.path: ?[]const u8` (0.16).
            const root_path = if (builtin.zig_version.minor <= 16)
                dep_b.build_root.path orelse "."
            else
                dep_b.root.root_dir.path orelse ".";
            return dep_b.pathResolve(&.{ root_path, sub });
        }
    }.call;
    const resolveUs = struct {
        fn call(us_b: *std.Build, sub: []const u8) []u8 {
            const root_path = if (builtin.zig_version.minor <= 16)
                us_b.build_root.path orelse "."
            else
                us_b.root.root_dir.path orelse ".";
            return us_b.pathResolve(&.{ root_path, sub });
        }
    }.call;
    const sqlite3_h = resolveDep(sqlite_dep, "sqlite3.h");
    const sqlite3ext_h = resolveDep(sqlite_dep, "sqlite3ext.h");
    const loadable_sqlite3_h = resolveUs(b, "c/loadable-ext-sqlite3.h");
    const loadable_sqlite3ext_h = resolveUs(b, "c/loadable-ext-sqlite3ext.h");

    // Run the preprocessor twice (once per mode) from the project root so
    // that `b.path("c/...")` resolves to the in-source tree for the fork and
    // to the consumer's checkout (for downstream users). Arguments are passed
    // via stdin as null-terminated tokens to keep the CLI cross-platform.
    // `Run.setStdIn` only stores the slice pointer, so the bytes must be
    // owned by the build arena (not a stack buffer).
    const run = b.addRunArtifact(preprocess_exe);
    run.setCwd(b.path(""));
    run.setStdIn(.{ .bytes = std.fmt.allocPrint(
        b.allocator,
        "{s}\x00{s}\x00{s}\x00{s}\x00",
        .{ "zig-sqlite-preprocess", "sqlite3", sqlite3_h, loadable_sqlite3_h },
    ) catch @panic("OOM") });

    const run_ext = b.addRunArtifact(preprocess_exe);
    run_ext.setCwd(b.path(""));
    run_ext.setStdIn(.{ .bytes = std.fmt.allocPrint(
        b.allocator,
        "{s}\x00{s}\x00{s}\x00{s}\x00",
        .{ "zig-sqlite-preprocess", "sqlite3ext", sqlite3ext_h, loadable_sqlite3ext_h },
    ) catch @panic("OOM") });

    run_ext.step.dependOn(&run.step);

    return run_ext;
}

// See https://www.sqlite.org/compile.html for flags
const EnableOptions = struct {
    // https://www.sqlite.org/fts5.html
    fts5: bool = false,
};
