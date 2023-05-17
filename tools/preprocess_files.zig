const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;

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

fn preprocessSqlite3HeaderFile(gpa: mem.Allocator) !void {
    var arena = heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    //

    var data = try readOriginalData(allocator, "c/sqlite3.h");

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

    // Write the result to the file
    var output_file = try std.fs.cwd().createFile("./c/loadable-ext-sqlite3.h", .{ .mode = 0o0644 });
    defer output_file.close();

    try processor.dump(output_file.writer());
}

fn preprocessSqlite3ExtHeaderFile(gpa: mem.Allocator) !void {
    var arena = heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    //

    var data = try readOriginalData(allocator, "c/sqlite3ext.h");

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

    // Write the result to the file
    var output_file = try std.fs.cwd().createFile("./c/loadable-ext-sqlite3ext.h", .{ .mode = 0o0644 });
    defer output_file.close();

    try processor.dump(output_file.writer());
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) debug.panic("leaks detected\n", .{});

    try preprocessSqlite3HeaderFile(gpa.allocator());
    try preprocessSqlite3ExtHeaderFile(gpa.allocator());
}
