const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Blob = @import("sqlite.zig").Blob;

/// Text is used to represent a SQLite TEXT value when binding a parameter or reading a column.
pub const Text = struct { data: []const u8 };

const BindMarker = struct {
    typed: ?type = null, // null == untyped
    identifier: ?[]const u8 = null,
    idType: IdType = .Integer,

    pub const IdType = enum {
        Integer,
        String,
    };
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

        comptime var current_bind_marker_id: [256]u8 = undefined;
        comptime var current_bind_marker_id_pos = 0;

        comptime var parsed_query: ParsedQuery = undefined;
        parsed_query.nb_bind_markers = 0;

        inline for (query) |c| {
            switch (state) {
                .Start => switch (c) {
                    '?', ':', '@', '$' => {
                        parsed_query.bind_markers[parsed_query.nb_bind_markers] = BindMarker{};
                        current_bind_marker_type_pos = 0;
                        current_bind_marker_id_pos = 0;
                        parsed_query.bind_markers[parsed_query.nb_bind_markers].idType = if (c == '?') .Integer else .String;
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
                    '?', ':', '@', '$' => @compileError("unregconised multiple '?', ':', '$' or '@'."),
                    '{' => {
                        state = .BindMarkerType;
                    },
                    else => {
                        if (std.ascii.isAlpha(c) or std.ascii.isDigit(c)){
                            state = .BindMarkerIdentifier;
                            current_bind_marker_id[current_bind_marker_id_pos] = c;
                            current_bind_marker_id_pos += 1;
                        } else {
                            // This is a bind marker without a type.
                            state = .Start;

                            parsed_query.bind_markers[parsed_query.nb_bind_markers].typed = null;
                            parsed_query.nb_bind_markers += 1;
                        }
                        buf[pos] = c;
                        pos += 1;
                    },
                },
                .BindMarkerIdentifier => switch (c) {
                    '?', ':', '@', '$' => @compileError("unregconised multiple '?', ':', '$' or '@'."),
                    '{' => {
                        state = .BindMarkerType;
                        current_bind_marker_type_pos = 0;

                        // A bind marker with id and type: ?AAA{[]const u8}, we don't need move the pointer.
                        if (current_bind_marker_id_pos > 0){
                            parsed_query.bind_markers[parsed_query.nb_bind_markers].identifier = std.fmt.comptimePrint("{s}", .{current_bind_marker_id[0..current_bind_marker_id_pos]});
                        }
                    },
                    else => {
                        if (std.ascii.isAlpha(c) or std.ascii.isDigit(c)){
                            current_bind_marker_id[current_bind_marker_id_pos] = c;
                            current_bind_marker_id_pos += 1;
                        } else {
                            state = .Start;
                            if (current_bind_marker_id_pos > 0) {
                                parsed_query.bind_markers[parsed_query.nb_bind_markers].identifier = std.fmt.comptimePrint("{s}", .{current_bind_marker_id[0..current_bind_marker_id_pos]});
                            }
                        }
                        buf[pos] = c;
                        pos += 1;
                    },
                },
                .BindMarkerType => switch (c) {
                    '}' => {
                        state = .Start;

                        const typ = parseType(current_bind_marker_type[0..current_bind_marker_type_pos]);

                        parsed_query.bind_markers[parsed_query.nb_bind_markers].typed = typ;
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
            parsed_query.bind_markers[parsed_query.nb_bind_markers].typed = null;
            parsed_query.nb_bind_markers += 1;
        } else if (state == .BindMarkerIdentifier) {
            parsed_query.bind_markers[parsed_query.nb_bind_markers].identifier = std.fmt.comptimePrint("{s}", .{current_bind_marker_id[0..current_bind_marker_id_pos]});
            parsed_query.nb_bind_markers += 1;
        } else if (state == .BindMarkerType) {
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
            .expected_marker = .{ .typed = usize },
        },
        .{
            .query = "foobar ?{text}",
            .expected_marker = .{ .typed = Text },
        },
        .{
            .query = "foobar ?{blob}",
            .expected_marker = .{ .typed = Blob },
        },
        .{
            .query = "foobar ?",
            .expected_marker = .{ .typed = null },
        },
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);

        try testing.expectEqual(1, parsed_query.nb_bind_markers);

        const bind_marker = parsed_query.bind_markers[0];
        try testing.expectEqual(tc.expected_marker.typed, bind_marker.typed);
    }
}

test "parsed query: bind markers identifier" {
    const testCase = struct {
        query: []const u8,
        expected_marker: BindMarker,
    };

    const testCases = &[_]testCase{
        .{
            .query = "foobar @ABC{usize}",
            .expected_marker = .{ .identifier = "ABC" },
        },
        .{
            .query = "foobar ?123{text}",
            .expected_marker = .{ .identifier = "123" },
        },
        .{
            .query = "foobar $abc{blob}",
            .expected_marker = .{ .identifier = "abc" },
        },
        .{
            .query = "foobar ?123",
            .expected_marker = .{ .identifier = "123" },
        },
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);

        try testing.expectEqual(@as(usize, 1), parsed_query.nb_bind_markers);

        const bind_marker = parsed_query.bind_markers[0];
        try testing.expectEqualStrings(tc.expected_marker.identifier.?, bind_marker.identifier.?);
    }
}

test "parsed query: query bind identifier" {
    const testCase = struct {
        query: []const u8,
        expected_query: []const u8,
    };

    const testCases = &[_]testCase{
        .{
            .query = "INSERT INTO user(id, name, age) VALUES(@id{usize}, :name{[]const u8}, $age{u32})",
            .expected_query = "INSERT INTO user(id, name, age) VALUES(@id, :name, $age)",
        },
        .{
            .query = "SELECT id, name, age FROM user WHER age > :ageGT{u32} AND age < @ageLT{u32}",
            .expected_query = "SELECT id, name, age FROM user WHER age > :ageGT AND age < @ageLT",
        },
        .{
            .query = "SELECT id, name, age FROM user WHER age > :ageGT AND age < $ageLT",
            .expected_query = "SELECT id, name, age FROM user WHER age > :ageGT AND age < $ageLT",
        },
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);
        try testing.expectEqualStrings(tc.expected_query, parsed_query.getQuery());
    }
}

test "parsed query: bind markers identifier type" {
    const testCase = struct {
        query: []const u8,
        expected_marker: BindMarker,
    };

    const testCases = &[_]testCase{
        .{
            .query = "foobar @ABC{usize}",
            .expected_marker = .{ .idType = .String },
        },
        .{
            .query = "foobar ?123{text}",
            .expected_marker = .{ .idType = .Integer },
        },
        .{
            .query = "foobar $abc{blob}",
            .expected_marker = .{ .idType = .String },
        },
        .{
            .query = "foobar ?123",
            .expected_marker = .{ .idType = .Integer },
        },
        .{
            .query = "foobar :abc",
            .expected_marker = .{ .idType = .String },
        }
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);

        try testing.expectEqual(@as(usize, 1), parsed_query.nb_bind_markers);

        const bind_marker = parsed_query.bind_markers[0];
        try testing.expectEqual(tc.expected_marker.idType, bind_marker.idType);
    }
}
