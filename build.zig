const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const mem = std.mem;
const ResolvedTarget = std.Build.ResolvedTarget;
const Query = std.Target.Query;
const builtin = @import("builtin");
const Translator = @import("translate_c").Translator;

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

/// Translates `header` (which includes sqlite3.h) with the translate-c package,
/// which replaces `@cImport` and the deprecated `std.Build.addTranslateC`.
fn translateSQLite(b: *std.Build, dep: *std.Build.Dependency, header: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const translate_c = b.dependency("translate_c", .{});
    const t: Translator = .init(translate_c, .{
        .c_source_file = b.path(header),
        .target = target,
        .optimize = optimize,
        // Struct fields default to zero, as with @cImport, so struct literals such as
        // vtab.zig's sqlite3_module compile against every SQLite version.
        .default_init = true,
    });
    t.addIncludePath(dep.path("."));
    t.addIncludePath(b.path("c"));

    return t.mod;
}

// This creates a SQLite static library from the SQLite dependency code.
fn makeSQLiteLib(b: *std.Build, dep: *std.Build.Dependency, c_flags: []const []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sqlite_c: enum { with, without }) *std.Build.Step.Compile {
    const mod = b.createModule(.{
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

    const enable_info = @typeInfo(EnableOptions).@"struct";
    inline for (enable_info.field_names, enable_info.field_attrs) |field_name, field_attrs| {
        const opt = b.option(bool, field_name, "Enable " ++ field_name) orelse field_attrs.defaultValue(bool).?;

        if (opt) {
            var buf: [field_name.len]u8 = undefined;
            const name = std.ascii.upperString(&buf, field_name);
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_ENABLE_{s}", .{name});

            try flags.append(b.allocator, flag);
        }
    }

    inline for (@typeInfo(BoolFeatureOptions).@"enum".field_names) |field_name| {
        comptime var buf: [field_name.len]u8 = undefined;
        const name = comptime std.ascii.upperString(&buf, field_name);
        const opt = b.option(bool, field_name, "Set SQLITE_" ++ name);

        if (opt) |v| {
            const flag_value = if (v) "1" else "0";
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_" ++ name ++ "={s}", .{flag_value});

            try flags.append(b.allocator, flag);
        }
    }

    inline for (@typeInfo(DefineFeatureOptions).@"enum".field_names) |field_name| {
        comptime var buf: [field_name.len]u8 = undefined;
        const name = comptime std.ascii.upperString(&buf, field_name);
        const opt = b.option(bool, field_name, "Set SQLITE_" ++ name) orelse false;

        if (opt) {
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_" ++ name, .{});

            try flags.append(b.allocator, flag);
        }
    }

    const int_info = @typeInfo(IntFeatureOptions).@"struct";
    inline for (int_info.field_names, int_info.field_types) |field_name, field_type| {
        comptime var buf: [field_name.len]u8 = undefined;
        const name = comptime std.ascii.upperString(&buf, field_name);
        const opt = b.option(field_type, field_name, "Set SQLITE_" ++ name);

        if (opt) |v| {
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_" ++ name ++ "={}", .{v});

            try flags.append(b.allocator, flag);
        }
    }

    const c_flags = flags.items;

    //
    // Main library and module
    //

    // const sqlite_lib, const sqlite_mod = blk: {
    const sqlite_lib, _ = blk: {
        const lib = makeSQLiteLib(b, sqlite_dep, c_flags, target, optimize, .with);

        const mod = b.addModule("sqlite", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = true,
        });
        mod.addIncludePath(b.path("c"));
        mod.addIncludePath(sqlite_dep.path("."));
        mod.addImport("sqlite3_c", translateSQLite(b, sqlite_dep, "c/sqlite3_c.h", target, optimize));
        mod.linkLibrary(lib);

        break :blk .{ lib, mod };
    };
    b.installArtifact(sqlite_lib);

    _ = blk: {
        const lib = makeSQLiteLib(b, sqlite_dep, c_flags, target, optimize, .without);

        const mod = b.addModule("sqliteext", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = true,
        });
        mod.addIncludePath(b.path("c"));
        mod.addImport("sqlite3_ext_c", translateSQLite(b, sqlite_dep, "c/loadable_ext_c.h", target, optimize));
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

        const test_sqlite_lib = makeSQLiteLib(b, sqlite_dep, c_flags, cross_target, optimize, .with);

        const mod = b.createModule(.{
            .target = cross_target,
            .optimize = optimize,
            .root_source_file = b.path("sqlite.zig"),
            .single_threaded = test_target.single_threaded,
        });

        const tests = b.addTest(.{
            .name = test_name,
            .root_module = mod,
        });
        tests.root_module.addIncludePath(b.path("c"));
        tests.root_module.addIncludePath(sqlite_dep.path("."));
        tests.root_module.addImport("sqlite3_c", translateSQLite(b, sqlite_dep, "c/sqlite3_c.h", cross_target, optimize));
        tests.root_module.linkLibrary(test_sqlite_lib);

        const tests_options = b.addOptions();
        tests.root_module.addImport("build_options", tests_options.createModule());

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    // This builds an example shared library with the extension and a binary that tests it.

    //\ const zigcrypto_install_artifact = addZigcrypto(b, sqliteext_mod, target, optimize);
    //\ test_step.dependOn(&zigcrypto_install_artifact.step);
    //\ const zigcrypto_test_run = addZigcryptoTestRun(b, sqlite_mod, target, optimize);
    //\ zigcrypto_test_run.step.dependOn(&zigcrypto_install_artifact.step);
    //\ test_step.dependOn(&zigcrypto_test_run.step);

    //
    // Tools
    //

    addPreprocessStep(b, sqlite_dep);
}

fn addPreprocessStep(b: *std.Build, sqlite_dep: *std.Build.Dependency) void {
    const exe = b.addExecutable(.{
        .name = "preprocess",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/Preprocessor.zig"),
            .target = b.graph.host,
        }),
    });

    const run = b.addRunArtifact(exe);
    run.addFileArg(sqlite_dep.path("sqlite3.h"));
    run.addFileArg(sqlite_dep.path("sqlite3ext.h"));
    const loadable_sqlite3_h = run.addOutputFileArg2("loadable-ext-sqlite3.h", .{});
    const loadable_sqlite3ext_h = run.addOutputFileArg2("loadable-ext-sqlite3ext.h", .{});

    const w = b.addUpdateSourceFiles();
    w.addCopyFileToSource(loadable_sqlite3_h, "c/loadable-ext-sqlite3.h");
    w.addCopyFileToSource(loadable_sqlite3ext_h, "c/loadable-ext-sqlite3ext.h");

    const preprocess_headers = b.step("preprocess-headers", "Preprocess the headers for the loadable extensions");
    preprocess_headers.dependOn(&w.step);
}

fn addZigcrypto(b: *std.Build, sqlite_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.InstallArtifact {
    const mod = b.createModule(.{
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
    const mod = b.createModule(.{
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

// See https://www.sqlite.org/compile.html for flags
const EnableOptions = struct {
    api_armor: bool = false,
    atomic_write: bool = false,
    batch_atomic_write: bool = false,
    carray: bool = false,
    column_metadata: bool = false,
    dbpage_vtab: bool = false,
    dbstat_vtab: bool = false,
    explain_comments: bool = false,
    // https://www.sqlite.org/fts5.html
    fts5: bool = false,
    geopoly: bool = false,
    hidden_columns: bool = false,
    icu: bool = false,
    math_functions: bool = false,
    memsys3: bool = false,
    memsys5: bool = false,
    null_trim: bool = false,
    offset_sql_func: bool = false,
    percentile: bool = false,
    preupdate_hook: bool = false,
    RBU: bool = false,
    rtree: bool = false,
    session: bool = false,
    sorter_reference: bool = false,
    stmtvtab: bool = false,
    stat4: bool = false,
};

/// `false` = won't be defined
/// `true` = will be defined
const DefineFeatureOptions = enum {
    like_doesnt_match_blobs,
    omit_decltype,
    omit_deprecated,
    omit_progress_callback,
    omit_shared_cache,
    omit_autoinit,
    use_alloca,
    zero_malloc,
    debug,
    memdebug,
    win32_malloc,
    win32_heap_create,
    win32_malloc_validate,
};

/// - `null` = default
/// - `true` = `1`
/// - `false` = `0`
const BoolFeatureOptions = enum {
    default_memstatus,
    strict_subtype,
    os_other,
};

/// The compile-time options with an int argument.
const IntFeatureOptions = struct {
    DQS: std.math.IntFittingRange(0, 3),
    threadsafe: std.math.IntFittingRange(0, 2),
    default_wal_synchronous: std.math.IntFittingRange(0, 3),
    max_expr_depth: c_int,
};
