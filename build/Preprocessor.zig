//! Standalone CLI that pre-processes sqlite3.h / sqlite3ext.h so the result can
//! be consumed by `zig translate-c` when building loadable extensions.
//!
//! The original SQLite headers either define every SQLite API as a function
//! (sqlite3.h) or via `#define sqlite3_X sqlite3_api->X` macros
//! (sqlite3ext.h). `zig translate-c` cannot follow those macros, so we strip
//! the function definitions / macros and emit modified copies of the headers.
//!
//! Built and run as a host binary by `build.zig` (see `addPreprocessRun`).
//! Also exposed as a top-level `preprocess-headers` step for manual
//! regeneration of the committed `c/loadable-ext-*.h` files.
//!
//! Usage:
//!     zig build run -Dinput=path/to/sqlite3.h -Doutput=path/to/loadable-ext-sqlite3.h
//!     zig build run -Dinput=path/to/sqlite3ext.h -Doutput=path/to/loadable-ext-sqlite3ext.h
//!
//! Or use the bundled `preprocess-headers` step which runs both passes and
//! copies the results into the source tree.

const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const Io = std.Io;

const Mode = enum { sqlite3, sqlite3ext };

fn readOriginalData(allocator: mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
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
                    try writer.interface.writeAll(to_write);
                    pos = dr.end;
                },
                .replace => |rr| {
                    const to_write = self.data[pos..rr.start];
                    try writer.interface.writeAll(to_write);
                    try writer.interface.writeAll(rr.replacement);
                    pos = rr.end;
                },
            }
        }

        // Finally append the remaining data in the buffer (the last range
        // will probably not be the end of the file).
        if (pos < self.data.len) {
            const remaining_data = self.data[pos..];
            try writer.interface.writeAll(remaining_data);
        }
    }
};

fn process(allocator: mem.Allocator, io: Io, mode: Mode, input_path: []const u8, output_path: []const u8) !void {
    const data = try readOriginalData(allocator, io, input_path);
    defer allocator.free(data);

    var processor = try Processor.init(allocator, data);
    defer processor.ranges.deinit(allocator);

    switch (mode) {
        .sqlite3 => {
            // Every function definition is declared with SQLITE_API.
            // Stop the loop if there's none in the remaining data.
            while (true) {
                if (!processor.skipUntil("SQLITE_API ")) break;

                // If the byte just before is not a LF, it's not a function
                // definition (a couple of `SQLITE_API` mentions in comments).
                const previous_byte = processor.previousByte() orelse 0;
                if (previous_byte != '\n') {
                    processor.consume("SQLITE_API ");
                    continue;
                }

                // We're at the start of a function definition; mark and skip
                // the whole definition.
                processor.rangeStart();

                processor.consume("SQLITE_API ");
                if (processor.startsWith("SQLITE_EXTERN ")) {
                    // Not a function definition, just a declaration; ignore.
                    continue;
                }

                _ = processor.skipUntil(");\n");
                processor.consume(");\n");

                processor.rangeDelete();
            }
        },
        .sqlite3ext => {
            // Replace the `#include "sqlite3.h"` line.
            debug.assert(processor.skipUntil("#include \"sqlite3.h\""));

            processor.rangeStart();
            processor.consume("#include \"sqlite3.h\"");
            processor.rangeReplace("#include \"loadable-ext-sqlite3.h\"");

            // Strip all `#define sqlite3_X ...` macros.
            while (true) {
                if (!processor.skipUntil("#define sqlite3_")) break;

                processor.rangeStart();
                processor.consume("#define sqlite3_");
                _ = processor.skipUntil("\n");
                processor.consume("\n");
                processor.rangeDelete();
            }
        },
    }

    var output_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer output_file.close(io);

    var write_buff: [1028]u8 = undefined;
    var w = output_file.writer(io, &write_buff);

    const banner = switch (mode) {
        .sqlite3 => "/* sqlite3.h edited by the zig-sqlite build script */\n",
        .sqlite3ext => "/* sqlite3ext.h edited by the zig-sqlite build script */\n",
    };
    try w.interface.writeAll(banner);
    try processor.dump(&w);
    try w.interface.flush();
}

pub fn main() !void {
    var threaded = Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Args are passed as a single line of null-terminated tokens on stdin so
    // the CLI is fully cross-platform (no platform-specific `argv` lookup).
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const stdin_data = try stdin_reader.interface.allocRemaining(allocator, .limited(1 << 16));
    defer allocator.free(stdin_data);

    var tokens = mem.splitScalar(u8, stdin_data, 0);
    const exe = tokens.next() orelse "zig-sqlite-preprocess";
    const mode_str = tokens.next() orelse {
        std.debug.print("usage: {s} <sqlite3|sqlite3ext> <input> <output>  (args via stdin)\n", .{exe});
        std.process.exit(1);
    };
    const input_path = tokens.next() orelse {
        std.debug.print("missing <input> argument on stdin\n", .{});
        std.process.exit(1);
    };
    const output_path = tokens.next() orelse {
        std.debug.print("missing <output> argument on stdin\n", .{});
        std.process.exit(1);
    };

    const mode = std.meta.stringToEnum(Mode, mode_str) orelse {
        std.debug.print("unknown mode: {s} (expected 'sqlite3' or 'sqlite3ext')\n", .{mode_str});
        std.process.exit(1);
    };

    try process(allocator, io, mode, input_path, output_path);
}
