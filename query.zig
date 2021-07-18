const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Blob = @import("sqlite.zig").Blob;

/// Text is used to represent a SQLite TEXT value when binding a parameter or reading a column.
pub const Text = struct { data: []const u8 };

pub const Column = union(enum) {
    Typed: type,
    Untyped: void,
};

pub const BindMarker = union(enum) {
    Typed: type,
    Untyped: void,
};

pub const ParsedQuery = struct {
    const Self = @This();

    bind_markers: [128]BindMarker,
    nb_bind_markers: usize,

    query: [1024]u8,
    query_size: usize,

    pub fn from(comptime query: []const u8) Self {
        comptime var buf: [query.len]u8 = undefined;
        comptime var pos = 0;
        comptime var state = .Start;

        comptime var current_bind_marker_type: [256]u8 = undefined;
        comptime var current_bind_marker_type_pos = 0;

        comptime var parsed_query: ParsedQuery = undefined;
        parsed_query.nb_bind_markers = 0;

        inline for (query) |c| {
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
                        // This is a bind marker without a type.
                        state = .Start;

                        parsed_query.bind_markers[parsed_query.nb_bind_markers] = BindMarker{ .Untyped = {} };
                        parsed_query.nb_bind_markers += 1;

                        buf[pos] = c;
                        pos += 1;
                    },
                },
                .BindMarkerType => switch (c) {
                    '}' => {
                        state = .Start;

                        const typ = parseType(current_bind_marker_type[0..current_bind_marker_type_pos]);

                        parsed_query.bind_markers[parsed_query.nb_bind_markers] = BindMarker{ .Typed = typ };
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

        // The last character was ? so this must be an untyped bind marker.
        if (state == .BindMarker) {
            parsed_query.bind_markers[parsed_query.nb_bind_markers] = BindMarker{ .Untyped = {} };
            parsed_query.nb_bind_markers += 1;
        }

        if (state == .BindMarkerType) {
            @compileError("invalid final state " ++ @tagName(state) ++ ", this means you wrote an incomplete bind marker type");
        }

        mem.copy(u8, &parsed_query.query, &buf);
        parsed_query.query_size = pos;

        return parsed_query;
    }

    fn parseType(type_info: []const u8) type {
        if (type_info.len <= 0) @compileError("invalid type info " ++ type_info);

        // Integer
        if (mem.eql(u8, "usize", type_info)) return usize;
        if (mem.eql(u8, "isize", type_info)) return isize;

        if (type_info[0] == 'u' or type_info[0] == 'i') {
            return @Type(std.builtin.TypeInfo{
                .Int = std.builtin.TypeInfo.Int{
                    .signedness = if (type_info[0] == 'i') .signed else .unsigned,
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

        // Bool
        if (mem.eql(u8, "bool", type_info)) return bool;

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
        .{
            .query = "SELECT id, name, age FROM user WHER age > ? AND age < ?",
            .expected_query = "SELECT id, name, age FROM user WHER age > ? AND age < ?",
        },
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);
        try testing.expectEqualStrings(tc.expected_query, parsed_query.getQuery());
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
            .expected_marker = .{ .Typed = usize },
        },
        .{
            .query = "foobar ?{text}",
            .expected_marker = .{ .Typed = Text },
        },
        .{
            .query = "foobar ?{blob}",
            .expected_marker = .{ .Typed = Blob },
        },
        .{
            .query = "foobar ?",
            .expected_marker = .{ .Untyped = {} },
        },
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);

        try testing.expectEqual(1, parsed_query.nb_bind_markers);

        const bind_marker = parsed_query.bind_markers[0];
        switch (tc.expected_marker) {
            .Typed => |typ| try testing.expectEqual(typ, bind_marker.Typed),
            .Untyped => |typ| try testing.expectEqual(typ, bind_marker.Untyped),
        }
    }
}
