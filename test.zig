const std = @import("std");
const build_options = @import("build_options");
const mem = std.mem;
const testing = std.testing;

const Db = @import("sqlite.zig").Db;

pub fn getTestDb() !Db {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var mode = dbMode(fba.allocator());

    return try Db.init(.{
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .mode = mode,
    });
}

fn tmpDbPath(allocator: mem.Allocator) ![:0]const u8 {
    const tmp_dir = testing.tmpDir(.{});

    const path = try std.fs.path.join(allocator, &[_][]const u8{
        "zig-cache",
        "tmp",
        &tmp_dir.sub_path,
        "zig-sqlite.db",
    });
    defer allocator.free(path);

    return allocator.dupeZ(u8, path);
}

fn dbMode(allocator: mem.Allocator) Db.Mode {
    return if (build_options.in_memory) blk: {
        break :blk .{ .Memory = {} };
    } else blk: {
        if (build_options.dbfile) |dbfile| {
            return .{ .File = allocator.dupeZ(u8, dbfile) catch unreachable };
        }

        const path = tmpDbPath(allocator) catch unreachable;

        std.fs.cwd().deleteFile(path) catch {};
        break :blk .{ .File = path };
    };
}
