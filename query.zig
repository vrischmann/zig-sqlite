const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Blob = @import("sqlite.zig").Blob;

/// Text is used to represent a SQLite TEXT value when binding a parameter or reading a column.
pub const Text = struct { data: []const u8 };

pub const ParsedQuery = struct {
    const Self = @This();

    // query can't be a slice currently because two comptime slices can't ever be the same
    // and this breaks the function `fn pragma`.
    query: [1024]u8,
    query_size: usize,

    pub fn from(comptime query: []const u8) Self {
        comptime var parsed_query: ParsedQuery = undefined;

        mem.copy(u8, &parsed_query.query, query);
        parsed_query.query_size = query.len;

        return parsed_query;
    }

    pub fn getQuery(comptime self: *const Self) []const u8 {
        return self.query[0..self.query_size];
    }
};
