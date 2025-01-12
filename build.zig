const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const mem = std.mem;
const ResolvedTarget = std.Build.ResolvedTarget;
const Query = std.Target.Query;
const builtin = @import("builtin");

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
fn makeSQLiteLib(b: *std.Build, dep: *std.Build.Dependency, c_flags: []const []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sqlite_c: enum { with, without }) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "sqlite",
        .target = target,
        .optimize = optimize,
    });

    lib.addIncludePath(dep.path("."));
    lib.addIncludePath(b.path("c"));
    if (sqlite_c == .with) {
        lib.addCSourceFile(.{
            .file = dep.path("sqlite3.c"),
            .flags = c_flags,
        });
    }
    lib.addCSourceFile(.{
        .file = b.path("c/workaround.c"),
        .flags = c_flags,
    });
    lib.linkLibC();

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

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.append("-std=c99");

    inline for (std.meta.fields(EnableOptions)) |field| {
        const opt = b.option(bool, field.name, "Enable " ++ field.name) orelse field.defaultValue().?;

        if (opt) {
            var buf: [field.name.len]u8 = undefined;
            const name = std.ascii.upperString(&buf, field.name);
            const flag = try std.fmt.allocPrint(b.allocator, "-DSQLITE_ENABLE_{s}", .{name});

            try flags.append(flag);
        }
    }

    const c_flags = flags.items;

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

        const tests = b.addTest(.{
            .name = test_name,
            .target = cross_target,
            .optimize = optimize,
            .root_source_file = b.path("sqlite.zig"),
            .single_threaded = test_target.single_threaded,
        });
        tests.addIncludePath(b.path("c"));
        tests.addIncludePath(sqlite_dep.path("."));
        tests.linkLibrary(test_sqlite_lib);

        const tests_options = b.addOptions();
        tests.root_module.addImport("build_options", tests_options.createModule());

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    //
    // Main library and module
    //

    const sqlite_lib, const sqlite_mod = blk: {
        const lib = makeSQLiteLib(b, sqlite_dep, c_flags, target, optimize, .with);

        const mod = b.addModule("sqlite", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = true,
        });
        mod.addIncludePath(b.path("c"));
        mod.addIncludePath(sqlite_dep.path("."));
        mod.linkLibrary(lib);

        break :blk .{ lib, mod };
    };
    _ = sqlite_lib;

    const sqliteext_mod = blk: {
        const lib = makeSQLiteLib(b, sqlite_dep, c_flags, target, optimize, .without);

        const mod = b.addModule("sqliteext", .{
            .root_source_file = b.path("sqlite.zig"),
            .link_libc = true,
        });
        mod.addIncludePath(b.path("c"));
        mod.linkLibrary(lib);

        break :blk mod;
    };

    //
    // Tools
    //

    addPreprocessStep(b, sqlite_dep);

    //
    // Examples
    //

    // Loadable extension
    //
    // This builds an example shared library with the extension and a binary that tests it.

    addZigcrypto(b, sqliteext_mod, target, optimize);
    addZigcryptoTest(b, sqlite_mod, target, optimize);
}

fn addPreprocessStep(b: *std.Build, sqlite_dep: *std.Build.Dependency) void {
    var wf = b.addWriteFiles();

    // Preprocessing step
    const preprocess = PreprocessStep.create(b, .{
        .source = sqlite_dep.path("."),
        .target = wf.getDirectory(),
    });
    preprocess.step.dependOn(&wf.step);

    const w = b.addUpdateSourceFiles();
    w.addCopyFileToSource(preprocess.target.join(b.allocator, "loadable-ext-sqlite3.h") catch @panic("OOM"), "c/loadable-ext-sqlite3.h");
    w.addCopyFileToSource(preprocess.target.join(b.allocator, "loadable-ext-sqlite3ext.h") catch @panic("OOM"), "c/loadable-ext-sqlite3ext.h");
    w.step.dependOn(&preprocess.step);

    const preprocess_headers = b.step("preprocess-headers", "Preprocess the headers for the loadable extensions");
    preprocess_headers.dependOn(&w.step);
}

fn addZigcrypto(b: *std.Build, sqlite_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const exe = b.addSharedLibrary(.{
        .name = "zigcrypto",
        .root_source_file = b.path("examples/zigcrypto.zig"),
        .version = null,
        .target = getTarget(target),
        .optimize = optimize,
    });
    exe.root_module.addImport("sqlite", sqlite_mod);

    const install_artifact = b.addInstallArtifact(exe, .{});
    install_artifact.step.dependOn(&exe.step);

    const run_step = b.step("zigcrypto", "Build the 'zigcrypto' SQLite loadable extension");
    run_step.dependOn(&install_artifact.step);
}

fn addZigcryptoTest(b: *std.Build, sqlite_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const zigcrypto_test = b.addExecutable(.{
        .name = "zigcrypto-test",
        .root_source_file = b.path("examples/zigcrypto_test.zig"),
        .target = getTarget(target),
        .optimize = optimize,
    });
    zigcrypto_test.root_module.addImport("sqlite", sqlite_mod);

    const install = b.addInstallArtifact(zigcrypto_test, .{});
    install.step.dependOn(&zigcrypto_test.step);

    const run = b.addRunArtifact(zigcrypto_test);
    run.step.dependOn(&zigcrypto_test.step);

    const runner_step = b.step("zigcrypto-test", "Build the 'zigcrypto' SQLite loadable extension runner");
    runner_step.dependOn(&run.step);
    runner_step.dependOn(&install.step);
}

// See https://www.sqlite.org/compile.html for flags
const EnableOptions = struct {
    // https://www.sqlite.org/fts5.html
    fts5: bool = false,
};

pub const PreprocessStep = struct {
    pub const Config = struct {
        source: std.Build.LazyPath,
        target: std.Build.LazyPath,
    };

    step: std.Build.Step,

    source: std.Build.LazyPath,
    target: std.Build.LazyPath,

    pub fn create(owner: *std.Build, config: Config) *PreprocessStep {
        const step = owner.allocator.create(PreprocessStep) catch @panic("OOM");
        step.* = .{
            .step = std.Build.Step.init(.{
                .id = std.Build.Step.Id.custom,
                .name = "preprocess",
                .owner = owner,
                .makeFn = make,
            }),
            .source = config.source,
            .target = config.target,
        };

        return step;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const ps: *PreprocessStep = @fieldParentPtr("step", step);
        const owner = step.owner;

        const sqlite3_h = try ps.source.path(owner, "sqlite3.h").getPath3(owner, step).toString(owner.allocator);
        const sqlite3ext_h = try ps.source.path(owner, "sqlite3ext.h").getPath3(owner, step).toString(owner.allocator);

        const loadable_sqlite3_h = try ps.target.path(owner, "loadable-ext-sqlite3.h").getPath3(owner, step).toString(owner.allocator);
        const loadable_sqlite3ext_h = try ps.target.path(owner, "loadable-ext-sqlite3ext.h").getPath3(owner, step).toString(owner.allocator);

        try Preprocessor.sqlite3(owner.allocator, sqlite3_h, loadable_sqlite3_h);
        try Preprocessor.sqlite3ext(owner.allocator, sqlite3ext_h, loadable_sqlite3ext_h);
    }
};

// This tool is used to preprocess the sqlite3 headers to make them usable to build loadable extensions.
//
// Due to limitations of `zig translate-c` (used by @cImport) the code produced by @cImport'ing the sqlite3ext.h header is unusable.
// The sqlite3ext.h header redefines the SQLite API like this:
//
//     #define sqlite3_open_v2 sqlite3_api->open_v2
//
// This is not supported by `zig translate-c`, if there's already a definition for a function the aliasing macros won't do anything:
// translate-c keeps generating the code for the function defined in sqlite3.h
//
// Even if there's no definition already (we could for example remove the definition manually from the sqlite3.h file),
// the code generated fails to compile because it references the variable sqlite3_api which is not defined
//
// And even if the sqlite3_api is defined before, the generated code fails to compile because the functions are defined as consts and
// can only reference comptime stuff, however sqlite3_api is a runtime variable.
//
// The only viable option is to completely reomve the original function definitions and redefine all functions in Zig which forward
// calls to the sqlite3_api object.
//
// This works but it requires fairly extensive modifications of both sqlite3.h and sqlite3ext.h which is time consuming to do manually;
// this tool is intended to automate all these modifications.

const Preprocessor = struct {
    fn readOriginalData(allocator: mem.Allocator, path: []const u8) ![]const u8 {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var reader = file.reader();

        const data = reader.readAllAlloc(allocator, 1024 * 1024);
        return data;
    }

    const Processor = struct {
        const Range = union(enum) {
            delete: struct {
                start: usize,
                end: usize,
            },
            replace: struct {
                start: usize,
                end: usize,
                replacement: []const u8,
            },
        };

        allocator: mem.Allocator,

        data: []const u8,
        pos: usize,

        range_start: usize,
        ranges: std.ArrayList(Range),

        fn init(allocator: mem.Allocator, data: []const u8) !Processor {
            return .{
                .allocator = allocator,
                .data = data,
                .pos = 0,
                .range_start = 0,
                .ranges = try std.ArrayList(Range).initCapacity(allocator, 4096),
            };
        }

        fn readable(self: *Processor) []const u8 {
            if (self.pos >= self.data.len) return "";

            return self.data[self.pos..];
        }

        fn previousByte(self: *Processor) ?u8 {
            if (self.pos <= 0) return null;
            return self.data[self.pos - 1];
        }

        fn skipUntil(self: *Processor, needle: []const u8) bool {
            const pos = mem.indexOfPos(u8, self.data, self.pos, needle);
            if (pos) |p| {
                self.pos = p;
                return true;
            }
            return false;
        }

        fn consume(self: *Processor, needle: []const u8) void {
            debug.assert(self.startsWith(needle));

            self.pos += needle.len;
        }

        fn startsWith(self: *Processor, needle: []const u8) bool {
            if (self.pos >= self.data.len) return false;

            const data = self.data[self.pos..];
            return mem.startsWith(u8, data, needle);
        }

        fn rangeStart(self: *Processor) void {
            self.range_start = self.pos;
        }

        fn rangeDelete(self: *Processor) void {
            self.ranges.appendAssumeCapacity(Range{
                .delete = .{
                    .start = self.range_start,
                    .end = self.pos,
                },
            });
        }

        fn rangeReplace(self: *Processor, replacement: []const u8) void {
            self.ranges.appendAssumeCapacity(Range{
                .replace = .{
                    .start = self.range_start,
                    .end = self.pos,
                    .replacement = replacement,
                },
            });
        }

        fn dump(self: *Processor, writer: anytype) !void {
            var pos: usize = 0;
            for (self.ranges.items) |range| {
                switch (range) {
                    .delete => |dr| {
                        const to_write = self.data[pos..dr.start];
                        try writer.writeAll(to_write);
                        pos = dr.end;
                    },
                    .replace => |rr| {
                        const to_write = self.data[pos..rr.start];
                        try writer.writeAll(to_write);
                        try writer.writeAll(rr.replacement);
                        pos = rr.end;
                    },
                }

                // debug.print("excluded range: start={d} end={d} slice=\"{s}\"\n", .{
                //     range.start,
                //     range.end,
                //     processor.data[range.start..range.end],
                // });
            }

            // Finally append the remaining data in the buffer (the last range will probably not be the end of the file)
            if (pos < self.data.len) {
                const remaining_data = self.data[pos..];
                try writer.writeAll(remaining_data);
            }
        }
    };

    fn sqlite3(gpa: mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
        var arena = heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const allocator = arena.allocator();

        //

        const data = try readOriginalData(allocator, input_path);

        var processor = try Processor.init(allocator, data);

        while (true) {
            // Everything function definition is declared with SQLITE_API.
            // Stop the loop if there's none in the remaining data.
            if (!processor.skipUntil("SQLITE_API ")) break;

            // If the byte just before is not a LN it's not a function definition.
            // There are a couple instances where SQLITE_API appears in a comment.
            const previous_byte = processor.previousByte() orelse 0;
            if (previous_byte != '\n') {
                processor.consume("SQLITE_API ");
                continue;
            }

            // Now we assume we're at the start of a function definition.
            //
            // We keep track of every function definition by marking its start and end position in the data.

            processor.rangeStart();

            processor.consume("SQLITE_API ");
            if (processor.startsWith("SQLITE_EXTERN ")) {
                // This is not a function definition, ignore it.
                // try processor.unmark();
                continue;
            }

            _ = processor.skipUntil(");\n");
            processor.consume(");\n");

            processor.rangeDelete();
        }

        // Write the result

        var output_file = try std.fs.cwd().createFile(output_path, .{ .mode = 0o0644 });
        defer output_file.close();

        try output_file.writeAll("/* sqlite3.h edited by the zig-sqlite build script */");
        try processor.dump(output_file.writer());
    }

    fn sqlite3ext(gpa: mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
        var arena = heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const allocator = arena.allocator();

        //

        const data = try readOriginalData(allocator, input_path);

        var processor = try Processor.init(allocator, data);

        // Replace the include line

        debug.assert(processor.skipUntil("#include \"sqlite3.h\""));

        processor.rangeStart();
        processor.consume("#include \"sqlite3.h\"");
        processor.rangeReplace("#include \"loadable-ext-sqlite3.h\"");

        // Delete all #define macros

        while (true) {
            if (!processor.skipUntil("#define sqlite3_")) break;

            processor.rangeStart();

            processor.consume("#define sqlite3_");
            _ = processor.skipUntil("\n");
            processor.consume("\n");

            processor.rangeDelete();
        }

        // Write the result

        var output_file = try std.fs.cwd().createFile(output_path, .{ .mode = 0o0644 });
        defer output_file.close();

        try output_file.writeAll("/* sqlite3ext.h edited by the zig-sqlite build script */");
        try processor.dump(output_file.writer());
    }
};
