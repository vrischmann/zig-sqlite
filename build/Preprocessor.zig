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

const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const Io = std.Io;

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

        if (pos < self.data.len) {
            const remaining_data = self.data[pos..];
            try writer.interface.writeAll(remaining_data);
        }
    }
};

pub fn sqlite3(allocator: mem.Allocator, io: Io, input_path: []const u8, output_path: []const u8) !void {
    const data = try readOriginalData(allocator, io, input_path);
    defer allocator.free(data);

    var processor = try Processor.init(allocator, data);
    defer processor.ranges.deinit(allocator);

    while (true) {
        if (!processor.skipUntil("SQLITE_API ")) break;

        const previous_byte = processor.previousByte() orelse 0;
        if (previous_byte != '\n') {
            processor.consume("SQLITE_API ");
            continue;
        }

        processor.rangeStart();

        processor.consume("SQLITE_API ");
        if (processor.startsWith("SQLITE_EXTERN ")) {
            continue;
        }

        _ = processor.skipUntil(");\n");
        processor.consume(");\n");

        processor.rangeDelete();
    }

    var output_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer output_file.close(io);

    var write_buff: [1028]u8 = undefined;
    var w = output_file.writer(io, &write_buff);

    try w.interface.writeAll("/* sqlite3.h edited by the zig-sqlite build script */\n");
    try processor.dump(&w);
    try w.interface.flush();
}

pub fn sqlite3ext(allocator: mem.Allocator, io: Io, input_path: []const u8, output_path: []const u8) !void {
    const data = try readOriginalData(allocator, io, input_path);
    defer allocator.free(data);

    var processor = try Processor.init(allocator, data);
    defer processor.ranges.deinit(allocator);

    debug.assert(processor.skipUntil("#include \"sqlite3.h\""));

    processor.rangeStart();
    processor.consume("#include \"sqlite3.h\"");
    processor.rangeReplace("#include \"loadable-ext-sqlite3.h\"");

    while (true) {
        if (!processor.skipUntil("#define sqlite3_")) break;

        processor.rangeStart();
        processor.consume("#define sqlite3_");
        _ = processor.skipUntil("\n");
        processor.consume("\n");

        processor.rangeDelete();
    }

    var output_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer output_file.close(io);

    var write_buff: [1028]u8 = undefined;
    var w = output_file.writer(io, &write_buff);

    try w.interface.writeAll("/* sqlite3ext.h edited by the zig-sqlite build script */\n");
    try processor.dump(&w);
    try w.interface.flush();
}
