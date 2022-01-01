const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Blob = @import("sqlite.zig").Blob;

/// Text is used to represent a SQLite TEXT value when binding a parameter or reading a column.
pub const Text = struct { data: []const u8 };

const BindMarker = struct {
    /// Contains the expected type for a bind parameter which will be checked
    /// at comptime when calling bind on a statement.
    ///
    /// A null means the bind parameter is untyped so there won't be comptime checking.
    typed: ?type = null,
};

fn isNamedIdentifierChar(c: u8) bool {
    return std.ascii.isAlpha(c) or std.ascii.isDigit(c);
}

pub const ParsedQuery = struct {
    const Self = @This();

    bind_markers: [128]BindMarker,
    nb_bind_markers: usize,

    query: [1024]u8,
    query_size: usize,

    pub fn from(comptime query: []const u8) Self {
        // This contains the final SQL query after parsing with our
        // own typed bind markers removed.
        comptime var buf: [query.len]u8 = undefined;
        comptime var pos = 0;
        comptime var state = .start;

        comptime var current_bind_marker_type: [256]u8 = undefined;
        comptime var current_bind_marker_type_pos = 0;

        comptime var parsed_query: ParsedQuery = undefined;
        parsed_query.nb_bind_markers = 0;

        inline for (query) |c| {
            switch (state) {
                .start => switch (c) {
                    '?', ':', '@', '$' => {
                        parsed_query.bind_markers[parsed_query.nb_bind_markers] = BindMarker{};
                        current_bind_marker_type_pos = 0;
                        state = .bind_marker;
                        buf[pos] = c;
                        pos += 1;
                    },
                    '\'', '"' => {
                        state = .inside_string;
                        buf[pos] = c;
                        pos += 1;
                    },
                    else => {
                        buf[pos] = c;
                        pos += 1;
                    },
                },
                .inside_string => switch (c) {
                    '\'', '"' => {
                        state = .start;
                        buf[pos] = c;
                        pos += 1;
                    },
                    else => {
                        buf[pos] = c;
                        pos += 1;
                    },
                },
                .bind_marker => switch (c) {
                    '?', ':', '@', '$' => @compileError("invalid multiple '?', ':', '$' or '@'."),
                    '{' => {
                        state = .bind_marker_type;
                    },
                    else => {
                        if (isNamedIdentifierChar(c)) {
                            // This is the start of a named bind marker.
                            state = .bind_marker_identifier;
                        } else {
                            // This is a unnamed, untyped bind marker.
                            state = .start;

                            parsed_query.bind_markers[parsed_query.nb_bind_markers].typed = null;
                            parsed_query.nb_bind_markers += 1;
                        }
                        buf[pos] = c;
                        pos += 1;
                    },
                },
                .bind_marker_identifier => switch (c) {
                    '?', ':', '@', '$' => @compileError("unregconised multiple '?', ':', '$' or '@'."),
                    '{' => {
                        state = .bind_marker_type;
                        current_bind_marker_type_pos = 0;
                    },
                    else => {
                        if (!isNamedIdentifierChar(c)) {
                            // This marks the end of the named bind marker.
                            state = .start;
                            parsed_query.nb_bind_markers += 1;
                        }
                        buf[pos] = c;
                        pos += 1;
                    },
                },
                .bind_marker_type => switch (c) {
                    '}' => {
                        state = .start;

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

        // The last character was a bind marker prefix so this must be an untyped bind marker.
        switch (state) {
            .bind_marker => {
                parsed_query.bind_markers[parsed_query.nb_bind_markers].typed = null;
                parsed_query.nb_bind_markers += 1;
            },
            .bind_marker_identifier => {
                parsed_query.nb_bind_markers += 1;
            },
            .start => {},
            else => @compileError("invalid final state " ++ @tagName(state) ++ ", this means you wrote an incomplete bind marker type"),
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
        @setEvalBranchQuota(100000);
        comptime var parsed_query = ParsedQuery.from(tc.query);
        try testing.expectEqualStrings(tc.expected_query, parsed_query.getQuery());
    }
}

test "parsed query: bind markers types" {
    const testCase = struct {
        query: []const u8,
        expected_marker: BindMarker,
    };

    const prefixes = &[_][]const u8{
        "?",
        "?123",
        ":",
        ":hello",
        "$",
        "$foobar",
        "@",
        "@name",
    };

    inline for (prefixes) |prefix| {
        const testCases = &[_]testCase{
            .{
                .query = "foobar " ++ prefix ++ "{usize}",
                .expected_marker = .{ .typed = usize },
            },
            .{
                .query = "foobar " ++ prefix ++ "{text}",
                .expected_marker = .{ .typed = Text },
            },
            .{
                .query = "foobar " ++ prefix ++ "{blob}",
                .expected_marker = .{ .typed = Blob },
            },
            .{
                .query = "foobar " ++ prefix,
                .expected_marker = .{ .typed = null },
            },
        };

        inline for (testCases) |tc| {
            @setEvalBranchQuota(100000);
            comptime var parsed_query = ParsedQuery.from(tc.query);

            try testing.expectEqual(1, parsed_query.nb_bind_markers);

            const bind_marker = parsed_query.bind_markers[0];
            try testing.expectEqual(tc.expected_marker.typed, bind_marker.typed);
        }
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
            .expected_marker = .{ .typed = usize },
        },
        .{
            .query = "foobar ?123{text}",
            .expected_marker = .{ .typed = Text },
        },
        .{
            .query = "foobar $abc{blob}",
            .expected_marker = .{ .typed = Blob },
        },
        .{
            .query = "foobar :430{u32}",
            .expected_marker = .{ .typed = u32 },
        },
        .{
            .query = "foobar ?123",
            .expected_marker = .{},
        },
        .{
            .query = "foobar :hola",
            .expected_marker = .{},
        },
        .{
            .query = "foobar @foo",
            .expected_marker = .{},
        },
    };

    inline for (testCases) |tc| {
        comptime var parsed_query = ParsedQuery.from(tc.query);

        try testing.expectEqual(@as(usize, 1), parsed_query.nb_bind_markers);

        const bind_marker = parsed_query.bind_markers[0];
        try testing.expectEqual(tc.expected_marker, bind_marker);
    }
}

test "parsed query: query bind identifier" {
    const testCase = struct {
        query: []const u8,
        expected_query: []const u8,
        expected_nb_bind_markers: usize,
    };

    const testCases = &[_]testCase{
        .{
            .query = "INSERT INTO user(id, name, age) VALUES(@id{usize}, :name{[]const u8}, $age{u32})",
            .expected_query = "INSERT INTO user(id, name, age) VALUES(@id, :name, $age)",
            .expected_nb_bind_markers = 3,
        },
        .{
            .query = "INSERT INTO user(id, name, age) VALUES($id, $name, $age)",
            .expected_query = "INSERT INTO user(id, name, age) VALUES($id, $name, $age)",
            .expected_nb_bind_markers = 3,
        },
        .{
            .query = "SELECT id, name, age FROM user WHER age > :ageGT{u32} AND age < @ageLT{u32}",
            .expected_query = "SELECT id, name, age FROM user WHER age > :ageGT AND age < @ageLT",
            .expected_nb_bind_markers = 2,
        },
        .{
            .query = "SELECT id, name, age FROM user WHER age > :ageGT AND age < $ageLT",
            .expected_query = "SELECT id, name, age FROM user WHER age > :ageGT AND age < $ageLT",
            .expected_nb_bind_markers = 2,
        },
    };

    inline for (testCases) |tc| {
        @setEvalBranchQuota(100000);
        comptime var parsed_query = ParsedQuery.from(tc.query);
        try testing.expectEqualStrings(tc.expected_query, parsed_query.getQuery());
        try testing.expectEqual(tc.expected_nb_bind_markers, parsed_query.nb_bind_markers);
    }
}

test "parsed query: bind marker character inside string" {
    const testCase = struct {
        query: []const u8,
        exp_bind_markers: comptime_int,
        exp: []const u8,
    };

    const testCases = &[_]testCase{
        .{
            .query = "SELECT json_extract(metadata, '$.name') AS name FROM foobar",
            .exp_bind_markers = 0,
            .exp = "SELECT json_extract(metadata, '$.name') AS name FROM foobar",
        },
        .{
            .query = "SELECT json_extract(metadata, '$.name') AS name FROM foobar WHERE name = $name{text}",
            .exp_bind_markers = 1,
            .exp = "SELECT json_extract(metadata, '$.name') AS name FROM foobar WHERE name = $name",
        },
    };

    inline for (testCases) |tc| {
        @setEvalBranchQuota(100000);
        comptime var parsed_query = ParsedQuery.from(tc.query);

        try testing.expectEqual(@as(usize, tc.exp_bind_markers), parsed_query.nb_bind_markers);
        try testing.expectEqualStrings(tc.exp, parsed_query.getQuery());
    }
}
