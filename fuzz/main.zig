const std = @import("std");
const sqlite = @import("sqlite");

pub export fn main() callconv(.C) void {
    zigMain() catch unreachable;
}

pub fn zigMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == false);
    const allocator = gpa.allocator();

    // Read the data from stdin
    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    var db = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{
            .write = true,
            .create = true,
        },
    });
    defer db.deinit();

    try db.exec("CREATE TABLE test(id integer primary key, name text, data blob)", .{}, .{});

    db.execDynamic(data, .{}, .{}) catch |err| switch (err) {
        error.SQLiteError => return,
        else => return err,
    };

    db.execDynamic(
        "INSERT INTO test(name, data) VALUES($name, $data)",
        .{},
        .{
            .name = data,
            .data = data,
        },
    ) catch |err| switch (err) {
        error.SQLiteError => return,
        else => return err,
    };
}
