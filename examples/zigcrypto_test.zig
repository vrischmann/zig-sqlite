const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const sqlite = @import("sqlite");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    //

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .Memory = {} },
        .open_flags = .{ .write = true },
    });
    defer db.deinit();

    {
        const result = sqlite.c.sqlite3_enable_load_extension(db.db, 1);
        debug.assert(result == sqlite.c.SQLITE_OK);
    }

    {
        var pzErrMsg: [*c]u8 = undefined;
        const result = sqlite.c.sqlite3_load_extension(db.db, "./zig-out/lib/libzigcrypto", null, &pzErrMsg);
        if (result != sqlite.c.SQLITE_OK) {
            const err = sqlite.c.sqlite3_errstr(result);
            std.debug.panic("unable to load extension, err: {s}, err message: {s}\n", .{ err, std.mem.sliceTo(pzErrMsg, 0) });
        }
    }

    var diags = sqlite.Diagnostics{};

    const blake3_digest = db.oneAlloc([]const u8, allocator, "SELECT hex(blake3('foobar'))", .{ .diags = &diags }, .{}) catch |err| {
        debug.print("unable to get blake3 hash, err: {!}, diags: {s}\n", .{ err, diags });
        return err;
    };
    debug.assert(blake3_digest != null);
    debug.assert(mem.eql(u8, "AA51DCD43D5C6C5203EE16906FD6B35DB298B9B2E1DE3FCE81811D4806B76B7D", blake3_digest.?));

    const sha3_digest = db.oneAlloc([]const u8, allocator, "SELECT hex(sha3_512('foobar'))", .{ .diags = &diags }, .{}) catch |err| {
        debug.print("unable to get sha3 hash, err: {!}, diags: {s}\n", .{ err, diags });
        return err;
    };
    debug.assert(sha3_digest != null);
    debug.assert(mem.eql(u8, "FF32A30C3AF5012EA395827A3E99A13073C3A8D8410A708568FF7E6EB85968FCCFEBAEA039BC21411E9D43FDB9A851B529B9960FFEA8679199781B8F45CA85E2", sha3_digest.?));
}
