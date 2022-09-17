const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const Sha3_512 = std.crypto.hash.sha3.Sha3_512;

const sqlite = @import("sqlite");
const c = sqlite.c;

const name = "zigcrypto";

pub const loadable_extension = true;

var module_allocator: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var module_context: sqlite.vtab.ModuleContext = undefined;

const logger = std.log.scoped(.zigcrypto);

fn createAllFunctions(db: *sqlite.Db) !void {
    try db.createScalarFunction(
        "blake3",
        struct {
            fn run(input: []const u8) [Blake3.digest_length]u8 {
                var output: [Blake3.digest_length]u8 = undefined;
                Blake3.hash(input, output[0..], .{});
                return output;
            }
        }.run,
        .{},
    );
    try db.createScalarFunction(
        "sha3_512",
        struct {
            fn run(input: []const u8) [Sha3_512.digest_length]u8 {
                var output: [Sha3_512.digest_length]u8 = undefined;
                Sha3_512.hash(input, output[0..], .{});
                return output;
            }
        }.run,
        .{},
    );
}

pub export fn sqlite3_zigcrypto_init(raw_db: *c.sqlite3, err_msg: [*c][*c]u8, api: *c.sqlite3_api_routines) callconv(.C) c_int {
    _ = err_msg;

    c.sqlite3_api = api;

    module_allocator = std.heap.GeneralPurposeAllocator(.{}){};

    var db = sqlite.Db{
        .db = raw_db,
    };

    createAllFunctions(&db) catch |err| {
        logger.err("unable to create all SQLite functions, err: {!}", .{err});
        return c.SQLITE_ERROR;
    };

    return c.SQLITE_OK;
}
