const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// Blob is used to represent a SQLite BLOB value when binding a parameter or reading a column.
pub const Blob = struct { data: []const u8 };

/// Text is used to represent a SQLite TEXT value when binding a parameter or reading a column.
pub const Text = struct { data: []const u8 };

const BindMarker = union(enum) {
    Type: type,
    None: void,
};

pub const ParsedQuery = struct {
    const Self = @This();

    bind_markers: [128]BindMarker,
    nb_bind_markers: usize,

    query: [1024]u8,
    query_size: usize,

    pub fn from(comptime query: []const u8) Self {
        const State = enum {
            Start,
            BindMarker,
            BindMarkerType,
        };

        comptime var buf: [query.len]u8 = undefined;
        comptime var pos = 0;
        comptime var state = .Start;

        comptime var current_bind_marker_type: [256]u8 = undefined;
        comptime var current_bind_marker_type_pos = 0;

        comptime var parsed_query: ParsedQuery = undefined;
        parsed_query.nb_bind_markers = 0;

        inline for (query) |c, i| {
            switch (state) {
                .Start => switch (c) {
                    '?' => {
                        state = .BindMarker;
                        buf[pos] = c;
                        pos += 1;
                    },
                    else => {
                        buf[pos] = c;
                        pos += 1;
                    },
                },
                .BindMarker => switch (c) {
                    '{' => {
                        state = .BindMarkerType;
                        current_bind_marker_type_pos = 0;
                    },
                    else => {
                        @compileError("a bind marker start (the character ?) must be followed by a bind marker type, eg {integer}");
                    },
                },
                .BindMarkerType => switch (c) {
                    '}' => {
                        state = .Start;

                        const typ = parsed_query.parseType(current_bind_marker_type[0..current_bind_marker_type_pos]);

                        parsed_query.bind_markers[parsed_query.nb_bind_markers] = BindMarker{ .Type = typ };
                        parsed_query.nb_bind_markers += 1;
                    },
                    else => {
                        current_bind_marker_type[current_bind_marker_type_pos] = c;
                        current_bind_marker_type_pos += 1;
                    },
                },
                else => {
                    @compileError("invalid state " ++ @tagName(state));
                },
            }
        }
        if (state == .BindMarker) {
            @compileError("invalid final state " ++ @tagName(state) ++ ", this means you wrote a ? in last position without a bind marker type");
        }
        if (state == .BindMarkerType) {
            @compileError("invalid final state " ++ @tagName(state) ++ ", this means you wrote an incomplete bind marker type");
        }

        mem.copy(u8, &parsed_query.query, &buf);
        parsed_query.query_size = pos;

        return parsed_query;
    }

    fn parseType(comptime self: *Self, type_info: []const u8) type {
        if (type_info.len <= 0) @compileError("invalid type info " ++ type_info);

        // Integer
        if (mem.eql(u8, "usize", type_info)) return usize;
        if (mem.eql(u8, "isize", type_info)) return isize;

        if (type_info[0] == 'u' or type_info[0] == 'i') {
            return @Type(builtin.TypeInfo{
                .Int = builtin.TypeInfo.Int{
                    .is_signed = type_info[0] == 'i',
                    .bits = std.fmt.parseInt(usize, type_info[1..type_info.len], 10) catch {
                        @compileError("invalid type info " ++ type_info);
                    },
                },
            });
        }

        // Float
        if (mem.eql(u8, "f16", type_info)) return f16;
        if (mem.eql(u8, "f32", type_info)) return f32;
        if (mem.eql(u8, "f64", type_info)) return f64;
        if (mem.eql(u8, "f128", type_info)) return f128;

        // Strings
        if (mem.eql(u8, "[]const u8", type_info) or mem.eql(u8, "[]u8", type_info)) {
            return []const u8;
        }
        if (mem.eql(u8, "text", type_info)) return Text;
        if (mem.eql(u8, "blob", type_info)) return Blob;

        @compileError("invalid type info " ++ type_info);
    }

    pub fn getQuery(comptime self: *const Self) []const u8 {
        return self.query[0..self.query_size];
    }
};

test "parsed query: query" {
    const testCase = struct {
        query: []const u8,
        expected_query: []const u8,
    };

    const testCases = &[_]testCase{
        .{
            .query = "INSERT INTO user(id, name, age) VALUES(?{usize}, ?{[]const u8}, ?{u32})",
            .expected_query = "INSERT INTO user(id, name, age) VALUES(?, ?, ?)",
        },
        .{
            .query = "SELECT id, name, age FROM user WHER age > ?{u32} AND age < ?{u32}",
            .expected_query = "SELECT id, name, age FROM user WHER age > ? AND age < ?",
        },
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);
        std.debug.print("parsed query: {}\n", .{parsed_query.getQuery()});
        testing.expectEqualStrings(tc.expected_query, parsed_query.getQuery());
    }
}

test "parsed query: bind markers types" {
    const testCase = struct {
        query: []const u8,
        expected_marker: BindMarker,
    };

    const testCases = &[_]testCase{
        .{
            .query = "foobar ?{usize}",
            .expected_marker = .{ .Type = usize },
        },
        .{
            .query = "foobar ?{text}",
            .expected_marker = .{ .Type = Text },
        },
        .{
            .query = "foobar ?{blob}",
            .expected_marker = .{ .Type = Blob },
        },
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);
        std.debug.print("parsed query: {}\n", .{parsed_query.getQuery()});

        testing.expectEqual(1, parsed_query.nb_bind_markers);

        const bind_marker = parsed_query.bind_markers[0];
        testing.expectEqual(tc.expected_marker.Type, bind_marker.Type);
    }
}
