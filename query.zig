const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Blob = @import("sqlite.zig").Blob;
const Text = @import("sqlite.zig").Text;

const BindMarker = struct {
    /// Name of the bind parameter in case it's named.
    name: ?[]const u8 = null,
    /// Contains the expected type for a bind parameter which will be checked
    /// at comptime when calling bind on a statement.
    ///
    /// A null means the bind parameter is untyped so there won't be comptime checking.
    typed: ?type = null,
};

fn isNamedIdentifierChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_';
}

fn bindMarkerForName(comptime markers: []const BindMarker, comptime name: []const u8) ?BindMarker {
    for (markers) |marker| {
        if (marker.name != null and std.mem.eql(u8, marker.name.?, name))
            return marker;
    }
    return null;
}

pub fn ParsedQuery(comptime tmp_query: []const u8) type {
    return struct {
        const Self = @This();

        const result = parse();

        pub const bind_markers = result.bind_markers[0..result.bind_markers_len];

        pub fn getQuery() []const u8 {
            return Self.result.query[0..Self.result.query_len];
        }

        const ParsedQueryResult = struct {
            bind_markers: [128]BindMarker,
            bind_markers_len: usize,
            query: [tmp_query.len]u8,
            query_len: usize,
        };

        fn parse() ParsedQueryResult {
            // This contains the final SQL query after parsing with our
            // own typed bind markers removed.
            var buf: [tmp_query.len]u8 = undefined;
            var pos = 0;
            var state = .start;

            // This holds the starting character of the string while
            // state is .inside_string so that we know which type of
            // string we're exiting from
            var string_starting_character: u8 = undefined;

            var current_bind_marker_type: [256]u8 = undefined;
            var current_bind_marker_type_pos = 0;

            // becomes part of our result
            var tmp_bind_markers: [128]BindMarker = undefined;
            var nb_tmp_bind_markers: usize = 0;

            // used for capturing slices, such as bind parameter name
            var hold_pos = 0;

            for (tmp_query) |c| {
                switch (state) {
                    .start => switch (c) {
                        '?', ':', '@', '$' => {
                            tmp_bind_markers[nb_tmp_bind_markers] = BindMarker{};
                            current_bind_marker_type_pos = 0;
                            state = .bind_marker;
                            buf[pos] = c;
                            pos += 1;
                        },
                        '\'', '"', '[', '`' => {
                            state = .inside_string;
                            string_starting_character = c;
                            buf[pos] = c;
                            pos += 1;
                        },
                        else => {
                            buf[pos] = c;
                            pos += 1;
                        },
                    },
                    .inside_string => switch (c) {
                        '\'' => {
                            if (string_starting_character == '\'') state = .start;
                            buf[pos] = c;
                            pos += 1;
                        },
                        '"' => {
                            if (string_starting_character == '"') state = .start;
                            buf[pos] = c;
                            pos += 1;
                        },
                        ']' => {
                            if (string_starting_character == '[') state = .start;
                            buf[pos] = c;
                            pos += 1;
                        },
                        '`' => {
                            if (string_starting_character == '`') state = .start;
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
                                hold_pos = pos + 1;
                            } else {
                                // This is a unnamed, untyped bind marker.
                                state = .start;

                                tmp_bind_markers[nb_tmp_bind_markers].typed = null;
                                nb_tmp_bind_markers += 1;
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
                                const name = buf[hold_pos - 1 .. pos];
                                // TODO(vincent): name retains a pointer to a comptime var, FIX !
                                if (bindMarkerForName(tmp_bind_markers[0..nb_tmp_bind_markers], name) == null) {
                                    const new_buf = buf;
                                    tmp_bind_markers[nb_tmp_bind_markers].name = new_buf[hold_pos - 1 .. pos];
                                    nb_tmp_bind_markers += 1;
                                }
                            }
                            buf[pos] = c;
                            pos += 1;
                        },
                    },
                    .bind_marker_type => switch (c) {
                        '}' => {
                            state = .start;

                            const type_info_string = current_bind_marker_type[0..current_bind_marker_type_pos];
                            // Handles optional types
                            const typ = if (type_info_string[0] == '?') blk: {
                                const child_type = ParseType(type_info_string[1..]);
                                break :blk @Type(std.builtin.Type{
                                    .optional = .{
                                        .child = child_type,
                                    },
                                });
                            } else blk: {
                                break :blk ParseType(type_info_string);
                            };

                            tmp_bind_markers[nb_tmp_bind_markers].typed = typ;
                            nb_tmp_bind_markers += 1;
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
                    tmp_bind_markers[nb_tmp_bind_markers].typed = null;
                    nb_tmp_bind_markers += 1;
                },
                .bind_marker_identifier => {
                    const new_buf = buf;
                    tmp_bind_markers[nb_tmp_bind_markers].name = @as([]const u8, new_buf[hold_pos - 1 .. pos]);
                    nb_tmp_bind_markers += 1;
                },
                .start => {},
                else => @compileError("invalid final state " ++ @tagName(state) ++ ", this means you wrote an incomplete bind marker type"),
            }

            const final_bind_markers = tmp_bind_markers;
            const final_bind_markers_len = nb_tmp_bind_markers;
            const final_buf = buf;
            const final_query_len = pos;

            return .{
                .bind_markers = final_bind_markers,
                .bind_markers_len = final_bind_markers_len,
                .query = final_buf,
                .query_len = final_query_len,
            };
        }
    };
}

fn ParseType(comptime type_info: []const u8) type {
    if (type_info.len <= 0) @compileError("invalid type info " ++ type_info);

    // Integer
    if (mem.eql(u8, "usize", type_info)) return usize;
    if (mem.eql(u8, "isize", type_info)) return isize;

    if (type_info[0] == 'u' or type_info[0] == 'i') {
        return @Type(std.builtin.Type{
            .int = std.builtin.Type.Int{
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
        const parsed_query = ParsedQuery(tc.query);
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
            .{
                .query = "foobar " ++ prefix ++ "{?[]const u8}",
                .expected_marker = .{ .typed = ?[]const u8 },
            },
        };

        inline for (testCases) |tc| {
            @setEvalBranchQuota(100000);
            const parsed_query = comptime ParsedQuery(tc.query);

            try testing.expectEqual(1, parsed_query.bind_markers.len);

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
            .expected_marker = .{ .typed = null, .name = "123" },
        },
        .{
            .query = "foobar :hola",
            .expected_marker = .{ .typed = null, .name = "hola" },
        },
        .{
            .query = "foobar @foo",
            .expected_marker = .{ .typed = null, .name = "foo" },
        },
    };

    inline for (testCases) |tc| {
        const parsed_query = comptime ParsedQuery(tc.query);

        try testing.expectEqual(@as(usize, 1), parsed_query.bind_markers.len);

        const bind_marker = parsed_query.bind_markers[0];
        if (bind_marker.name) |name| {
            try testing.expectEqualStrings(tc.expected_marker.name.?, name);
        }
        try testing.expectEqual(tc.expected_marker.typed, bind_marker.typed);
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
        .{
            .query = "SELECT id, name, age FROM user WHER age > $my_age{i32} AND age < :your_age{i32}",
            .expected_query = "SELECT id, name, age FROM user WHER age > $my_age AND age < :your_age",
            .expected_nb_bind_markers = 2,
        },
    };

    inline for (testCases) |tc| {
        @setEvalBranchQuota(100000);

        comptime {
            const parsed_query = ParsedQuery(tc.query);

            try testing.expectEqual(tc.expected_nb_bind_markers, parsed_query.bind_markers.len);
            try testing.expectEqualStrings(tc.expected_query, parsed_query.getQuery());
        }
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
        .{
            .query = "SELECT json_extract(metadata, '$[0]') AS name FROM foobar",
            .exp_bind_markers = 0,
            .exp = "SELECT json_extract(metadata, '$[0]') AS name FROM foobar",
        },
    };

    inline for (testCases) |tc| {
        @setEvalBranchQuota(100000);
        const parsed_query = ParsedQuery(tc.query);

        try testing.expectEqual(@as(usize, tc.exp_bind_markers), parsed_query.bind_markers.len);
        try testing.expectEqualStrings(tc.exp, parsed_query.getQuery());
    }
}
