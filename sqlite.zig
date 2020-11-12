const std = @import("std");
const build_options = @import("build_options");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
});

usingnamespace @import("query.zig");

const logger = std.log.scoped(.sqlite);

/// Db is a wrapper around a SQLite database, providing high-level functions for executing queries.
/// A Db can be opened with a file database or a in-memory database:
///
///     // File database
///     var db: sqlite.Db = undefined;
///     try db.init(allocator, .{ .mode = { .File = "/tmp/data.db" } });
///
///     // In memory database
///     var db: sqlite.Db = undefined;
///     try db.init(allocator, .{ .mode = { .Memory = {} } });
///
pub const Db = struct {
    const Self = @This();

    allocator: *mem.Allocator,
    db: *c.sqlite3,

    /// Mode determines how the database will be opened.
    pub const Mode = union(enum) {
        File: []const u8,
        Memory,
    };

    /// init creates a database with the provided `mode`.
    pub fn init(self: *Self, allocator: *mem.Allocator, options: anytype) !void {
        self.allocator = allocator;

        const mode: Mode = if (@hasField(@TypeOf(options), "mode")) options.mode else .Memory;

        switch (mode) {
            .File => |path| {
                logger.info("opening {}", .{path});

                // Need a null-terminated string here.
                const pathZ = try allocator.dupeZ(u8, path);
                defer allocator.free(pathZ);

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(
                    pathZ,
                    &db,
                    c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
                    null,
                );
                if (result != c.SQLITE_OK or db == null) {
                    logger.warn("unable to open database, result: {}", .{result});
                    return error.CannotOpenDatabase;
                }

                self.db = db.?;
            },
            .Memory => {
                logger.info("opening in memory", .{});

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(
                    ":memory:",
                    &db,
                    c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_MEMORY,
                    null,
                );
                if (result != c.SQLITE_OK or db == null) {
                    logger.warn("unable to open database, result: {}", .{result});
                    return error.CannotOpenDatabase;
                }

                self.db = db.?;
            },
        }
    }

    /// deinit closes the database.
    pub fn deinit(self: *Self) void {
        _ = c.sqlite3_close(self.db);
    }

    /// exec is a convenience function which prepares a statement and executes it directly.
    pub fn exec(self: *Self, comptime query: []const u8, values: anytype) !void {
        var stmt = try self.prepare(query);
        defer stmt.deinit();
        try stmt.exec(values);
    }

    /// prepare prepares a statement for the `query` provided.
    ///
    /// The query is analysed at comptime to search for bind markers.
    /// prepare enforces having as much fields in the `values` tuple as there are bind markers.
    ///
    /// Example usage:
    ///
    ///     var stmt = try db.prepare("INSERT INTO foo(id, name) VALUES(?, ?)");
    ///     defer stmt.deinit();
    ///
    /// The statement returned is only compatible with the number of bind markers in the input query.
    /// This is done because we type check the bind parameters when executing the statement later.
    ///
    pub fn prepare(self: *Self, comptime query: []const u8) !Statement(.{}, ParsedQuery.from(query)) {
        @setEvalBranchQuota(3000);
        const parsed_query = ParsedQuery.from(query);
        return Statement(.{}, comptime parsed_query).prepare(self, 0);
    }

    /// rowsAffected returns the number of rows affected by the last statement executed.
    pub fn rowsAffected(self: *Self) usize {
        return @intCast(usize, c.sqlite3_changes(self.db));
    }
};

/// Iterator allows iterating over a result set.
///
/// Each call to `next` returns the next row of the result set, or null if the result set is exhausted.
/// Each row will have the type `Type` so the columns returned in the result set must be compatible with this type.
///
/// Here is an example of how to use the iterator:
///
///     const User = struct {
///         name: Text,
///         age: u16,
///     };
///
///     var stmt = try db.prepare("SELECT name, age FROM user");
///     defer stmt.deinit();
///
///     var iter = try stmt.iterator(User, .{});
///     while (true) {
///         const row: User = (try iter.next(.{})) orelse break;
///         ...
///     }
///
/// The iterator _must not_ outlive the statement.
pub fn Iterator(comptime Type: type) type {
    return struct {
        const Self = @This();

        const TypeInfo = @typeInfo(Type);

        stmt: *c.sqlite3_stmt,

        pub fn next(self: *Self, options: anytype) !?Type {
            var result = c.sqlite3_step(self.stmt);
            if (result == c.SQLITE_DONE) {
                return null;
            }

            if (result != c.SQLITE_ROW) {
                logger.err("unable to iterate, result: {}", .{result});
                return error.SQLiteStepError;
            }

            const columns = c.sqlite3_column_count(self.stmt);

            return switch (TypeInfo) {
                .Int => blk: {
                    debug.assert(columns == 1);
                    break :blk try self.readInt(options);
                },
                .Float => blk: {
                    debug.assert(columns == 1);
                    break :blk try self.readFloat(options);
                },
                .Struct => blk: {
                    std.debug.assert(columns == TypeInfo.Struct.fields.len);
                    break :blk try self.readStruct(options);
                },
                else => @compileError("cannot read into type " ++ @typeName(Type)),
            };
        }

        fn readInt(self: *Self, options: anytype) !Type {
            const n = c.sqlite3_column_int64(self.stmt, 0);
            return @intCast(Type, n);
        }

        fn readFloat(self: *Self, options: anytype) !Type {
            const d = c.sqlite3_column_double(self.stmt, 0);
            return @floatCast(Type, d);
        }

        const ReadBytesMode = enum {
            Blob,
            Text,
        };

        fn readBytes(self: *Self, options: anytype, mode: ReadBytesMode, _i: usize, ptr: *[]const u8) !void {
            const i = @intCast(c_int, _i);
            switch (mode) {
                .Blob => {
                    const data = c.sqlite3_column_blob(self.stmt, i);
                    if (data == null) ptr.* = "";

                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));

                    var tmp = try options.allocator.alloc(u8, size);
                    mem.copy(u8, tmp, @ptrCast([*c]const u8, data)[0..size]);

                    ptr.* = tmp;
                },
                .Text => {
                    const data = c.sqlite3_column_text(self.stmt, i);
                    if (data == null) ptr.* = "";

                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));

                    var tmp = try options.allocator.alloc(u8, size);
                    mem.copy(u8, tmp, @ptrCast([*c]const u8, data)[0..size]);

                    ptr.* = tmp;
                },
            }
        }

        fn readStruct(self: *Self, options: anytype) !Type {
            var value: Type = undefined;

            inline for (@typeInfo(Type).Struct.fields) |field, _i| {
                const i = @as(usize, _i);
                const field_type_info = @typeInfo(field.field_type);

                switch (field.field_type) {
                    []const u8, []u8 => {
                        try self.readBytes(options, .Blob, i, &@field(value, field.name));
                    },
                    Blob => {
                        try self.readBytes(options, .Blob, i, &@field(value, field.name).data);
                    },
                    Text => {
                        try self.readBytes(options, .Text, i, &@field(value, field.name).data);
                    },
                    else => switch (field_type_info) {
                        .Int => {
                            const n = c.sqlite3_column_int64(self.stmt, i);
                            @field(value, field.name) = @intCast(field.field_type, n);
                        },
                        .Float => {
                            const f = c.sqlite3_column_double(self.stmt, i);
                            @field(value, field.name) = f;
                        },
                        .Void => {
                            @field(value, field.name) = {};
                        },
                        .Array => |arr| {
                            switch (arr.child) {
                                u8 => {
                                    const data = c.sqlite3_column_blob(self.stmt, i);
                                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));

                                    if (size > @as(usize, arr.len)) return error.ArrayTooSmall;

                                    mem.copy(u8, @field(value, field.name)[0..], @ptrCast([*c]const u8, data)[0..size]);
                                },
                                else => @compileError("cannot populate field " ++ field.name ++ " of type array of " ++ @typeName(arr.child)),
                            }
                        },
                        else => @compileError("cannot populate field " ++ field.name ++ " of type " ++ @typeName(field.field_type)),
                    },
                }
            }

            return value;
        }
    };
}

pub const StatementOptions = struct {};

/// Statement is a wrapper around a SQLite statement, providing high-level functions to execute
/// a statement and retrieve rows for SELECT queries.
///
/// The exec function can be used to execute a query which does not return rows:
///
///     var stmt = try db.prepare("UPDATE foo SET id = ? WHERE name = ?");
///     defer stmt.deinit();
///
///     try stmt.exec(.{
///         .id = 200,
///         .name = "José",
///     });
///
/// The one function can be used to select a single row:
///
///     var stmt = try db.prepare("SELECT name FROM foo WHERE id = ?");
///     defer stmt.deinit();
///
///     const name = try stmt.one([]const u8, .{}, .{ .id = 200 });
///
/// The all function can be used to select all rows:
///
///     var stmt = try db.prepare("SELECT id, name FROM foo");
///     defer stmt.deinit();
///
///     const Row = struct {
///         id: usize,
///         name: []const u8,
///     };
///     const rows = try stmt.all(Row, .{ .allocator = allocator }, .{});
///
/// Look at aach function for more complete documentation.
///
pub fn Statement(comptime opts: StatementOptions, comptime query: ParsedQuery) type {
    return struct {
        const Self = @This();

        stmt: *c.sqlite3_stmt,

        fn prepare(db: *Db, flags: c_uint) !Self {
            var stmt = blk: {
                const real_query = query.getQuery();

                var tmp: ?*c.sqlite3_stmt = undefined;
                const result = c.sqlite3_prepare_v3(
                    db.db,
                    real_query.ptr,
                    @intCast(c_int, real_query.len),
                    flags,
                    &tmp,
                    null,
                );
                if (result != c.SQLITE_OK) {
                    logger.warn("unable to prepare statement, result: {}", .{result});
                    return error.CannotPrepareStatement;
                }
                break :blk tmp.?;
            };

            return Self{
                .stmt = stmt,
            };
        }

        /// deinit releases the prepared statement.
        ///
        /// After a call to `deinit` the statement must not be used.
        pub fn deinit(self: *Self) void {
            const result = c.sqlite3_finalize(self.stmt);
            if (result != c.SQLITE_OK) {
                logger.err("unable to finalize prepared statement, result: {}", .{result});
            }
        }

        /// reset resets the prepared statement to make it reusable.
        pub fn reset(self: *Self) void {
            const result = c.sqlite3_clear_bindings(self.stmt);
            if (result != c.SQLITE_OK) {
                logger.err("unable to clear prepared statement bindings, result: {}", .{result});
            }

            const result2 = c.sqlite3_reset(self.stmt);
            if (result2 != c.SQLITE_OK) {
                logger.err("unable to reset prepared statement, result: {}", .{result2});
            }
        }

        /// bind binds values to every bind marker in the prepared statement.
        ///
        /// The `values` variable must be a struct where each field has the type of the corresponding bind marker.
        /// For example this query:
        ///   SELECT 1 FROM user WHERE name = ?{text} AND age < ?{u32}
        ///
        /// Has two bind markers, so `values` must have at least the following fields:
        ///   struct {
        ///     name: Text,
        ///     age: u32
        ///   }
        ///
        /// The types are checked at comptime.
        fn bind(self: *Self, values: anytype) void {
            const StructType = @TypeOf(values);
            const StructTypeInfo = @typeInfo(StructType).Struct;

            if (comptime query.nb_bind_markers != StructTypeInfo.fields.len) {
                @compileError("number of bind markers not equal to number of fields");
            }

            inline for (StructTypeInfo.fields) |struct_field, _i| {
                const bind_marker = query.bind_markers[_i];
                switch (bind_marker) {
                    .Typed => |typ| if (struct_field.field_type != typ) {
                        @compileError("value type " ++ @typeName(struct_field.field_type) ++ " is not the bind marker type " ++ @typeName(typ));
                    },
                    .Untyped => {},
                }

                const i = @as(usize, _i);
                const field_type_info = @typeInfo(struct_field.field_type);
                const field_value = @field(values, struct_field.name);
                const column = i + 1;

                switch (struct_field.field_type) {
                    []const u8, []u8 => {
                        _ = c.sqlite3_bind_text(self.stmt, column, field_value.ptr, @intCast(c_int, field_value.len), null);
                    },
                    Text => _ = c.sqlite3_bind_text(self.stmt, column, field_value.data.ptr, @intCast(c_int, field_value.data.len), null),
                    Blob => _ = c.sqlite3_bind_blob(self.stmt, column, field_value.data.ptr, @intCast(c_int, field_value.data.len), null),
                    else => switch (field_type_info) {
                        .Int, .ComptimeInt => _ = c.sqlite3_bind_int64(self.stmt, column, @intCast(c_longlong, field_value)),
                        .Float, .ComptimeFloat => _ = c.sqlite3_bind_double(self.stmt, column, field_value),
                        .Array => |arr| {
                            switch (arr.child) {
                                u8 => {
                                    const data: []const u8 = field_value[0..field_value.len];

                                    _ = c.sqlite3_bind_text(self.stmt, column, data.ptr, @intCast(c_int, data.len), null);
                                },
                                else => @compileError("cannot bind field " ++ field.name ++ " of type array of " ++ @typeName(arr.child)),
                            }
                        },
                        else => @compileError("cannot bind field " ++ struct_field.name ++ " of type " ++ @typeName(struct_field.field_type)),
                    },
                }
            }
        }

        /// exec executes a statement which does not return data.
        ///
        /// The `values` variable is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        pub fn exec(self: *Self, values: anytype) !void {
            self.bind(values);

            const result = c.sqlite3_step(self.stmt);
            switch (result) {
                c.SQLITE_DONE => {},
                c.SQLITE_BUSY => return error.SQLiteBusy,
                else => std.debug.panic("invalid result {}", .{result}),
            }
        }

        /// iterator returns an iterator to read data from the result set, one row at a time.
        ///
        /// The data in the row is used to populate a value of the type `Type`.
        /// This means that `Type` must have as many fields as is returned in the query
        /// executed by this statement.
        /// This also means that the type of each field must be compatible with the SQLite type.
        ///
        /// Here is an example of how to use the iterator:
        ///
        ///     var iter = try stmt.iterator(usize, .{});
        ///     while (true) {
        ///         const row = (try iter.next(.{})) orelse break;
        ///         ...
        ///     }
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        /// The iterator _must not_ outlive the statement.
        pub fn iterator(self: *Self, comptime Type: type, values: anytype) !Iterator(Type) {
            self.bind(values);

            var res: Iterator(Type) = undefined;
            res.stmt = self.stmt;

            return res;
        }

        /// one reads a single row from the result set of this statement.
        ///
        /// The data in the row is used to populate a value of the type `Type`.
        /// This means that `Type` must have as many fields as is returned in the query
        /// executed by this statement.
        /// This also means that the type of each field must be compatible with the SQLite type.
        ///
        /// Here is an example of how to use an anonymous struct type:
        ///
        ///     const row = try stmt.one(
        ///         struct {
        ///             id: usize,
        ///             name: []const u8,
        ///             age: usize,
        ///         },
        ///         .{ .allocator = allocator },
        ///         .{ .foo = "bar", .age = 500 },
        ///     );
        ///
        /// The `options` tuple is used to provide additional state in some cases, for example
        /// an allocator used to read text and blobs.
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        pub fn one(self: *Self, comptime Type: type, options: anytype, values: anytype) !?Type {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to iterator must be a struct");
            }

            var iter = try self.iterator(Type, values);

            const row = (try iter.next(options)) orelse return null;
            return row;
        }

        /// all reads all rows from the result set of this statement.
        ///
        /// The data in each row is used to populate a value of the type `Type`.
        /// This means that `Type` must have as many fields as is returned in the query
        /// executed by this statement.
        /// This also means that the type of each field must be compatible with the SQLite type.
        ///
        /// Here is an example of how to use an anonymous struct type:
        ///
        ///     const rows = try stmt.all(
        ///         struct {
        ///             id: usize,
        ///             name: []const u8,
        ///             age: usize,
        ///         },
        ///         .{ .allocator = allocator },
        ///         .{ .foo = "bar", .age = 500 },
        ///     );
        ///
        /// The `options` tuple is used to provide additional state in some cases.
        /// Note that for this function the allocator is mandatory.
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        /// Note that this allocates all rows into a single slice: if you read a lot of data this can
        /// use a lot of memory.
        ///
        pub fn all(self: *Self, comptime Type: type, options: anytype, values: anytype) ![]Type {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to iterator must be a struct");
            }
            var iter = try self.iterator(Type, values);

            var rows = std.ArrayList(Type).init(options.allocator);
            while (true) {
                const row = (try iter.next(options)) orelse break;
                try rows.append(row);
            }

            return rows.span();
        }
    };
}

const AllDDL = &[_][]const u8{
    \\CREATE TABLE user(
    \\ id integer PRIMARY KEY,
    \\ name text,
    \\ age integer
    \\)
    ,
    \\CREATE TABLE article(
    \\  id integer PRIMARY KEY,
    \\  author_id integer,
    \\  data text,
    \\  FOREIGN KEY(author_id) REFERENCES user(id)
    \\)
};

const TestUser = struct {
    id: usize,
    name: []const u8,
    age: usize,
};

test "sqlite: db init" {
    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try db.init(testing.allocator, .{});
}

test "sqlite: statement exec" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });

    // Create the tables
    inline for (AllDDL) |ddl| {
        try db.exec(ddl, .{});
    }

    // Add data
    const users = &[_]TestUser{
        .{ .id = 20, .name = "Vincent", .age = 33 },
        .{ .id = 40, .name = "Julien", .age = 35 },
        .{ .id = 60, .name = "José", .age = 40 },
    };

    for (users) |user| {
        try db.exec("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{[]const u8}, ?{usize})", user);

        const rows_inserted = db.rowsAffected();
        testing.expectEqual(@as(usize, 1), rows_inserted);
    }

    // Read a single user

    {
        var stmt = try db.prepare("SELECT id, name, age FROM user WHERE id = ?{usize}");
        defer stmt.deinit();

        var rows = try stmt.all(TestUser, .{ .allocator = allocator }, .{ .id = @as(usize, 20) });
        for (rows) |row| {
            testing.expectEqual(users[0].id, row.id);
            testing.expectEqualStrings(users[0].name, row.name);
            testing.expectEqual(users[0].age, row.age);
        }
    }

    // Read all users

    {
        var stmt = try db.prepare("SELECT id, name, age FROM user");
        defer stmt.deinit();

        var rows = try stmt.all(TestUser, .{ .allocator = allocator }, .{});
        testing.expectEqual(@as(usize, 3), rows.len);
        for (rows) |row, i| {
            const exp = users[i];
            testing.expectEqual(exp.id, row.id);
            testing.expectEqualStrings(exp.name, row.name);
            testing.expectEqual(exp.age, row.age);
        }
    }

    // Test with anonymous structs

    {
        var stmt = try db.prepare("SELECT id, name, age FROM user WHERE id = ?{usize}");
        defer stmt.deinit();

        var row = try stmt.one(
            struct {
                id: usize,
                name: []const u8,
                age: usize,
            },
            .{ .allocator = allocator },
            .{ .id = @as(usize, 20) },
        );
        testing.expect(row != null);

        const exp = users[0];
        testing.expectEqual(exp.id, row.?.id);
        testing.expectEqualStrings(exp.name, row.?.name);
        testing.expectEqual(exp.age, row.?.age);
    }

    // Test with a single integer or float

    {
        const types = &[_]type{
            u8,
            u16,
            u32,
            u64,
            u128,
            usize,
            f16,
            f32,
            f64,
            f128,
        };

        inline for (types) |typ| {
            const query = "SELECT age FROM user WHERE id = ?{usize}";

            @setEvalBranchQuota(5000);
            var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
            defer stmt.deinit();

            var age = try stmt.one(typ, .{}, .{ .id = @as(usize, 20) });
            testing.expect(age != null);

            testing.expectEqual(@as(typ, 33), age.?);
        }
    }

    // Test with a Blob struct
    {
        try db.exec("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{blob}, ?{u32})", .{
            .id = @as(usize, 200),
            .name = Blob{ .data = "hello" },
            .age = @as(u32, 20),
        });
    }

    // Test with a Text struct
    {
        try db.exec("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{text}, ?{u32})", .{
            .id = @as(usize, 201),
            .name = Text{ .data = "hello" },
            .age = @as(u32, 20),
        });
    }

    // Read in a Text struct
    {
        var stmt = try db.prepare("SELECT id, name, age FROM user WHERE id = ?{usize}");
        defer stmt.deinit();

        var row = try stmt.one(
            struct {
                id: usize,
                name: Text,
                age: usize,
            },
            .{ .allocator = allocator },
            .{@as(usize, 20)},
        );
        testing.expect(row != null);

        const exp = users[0];
        testing.expectEqual(exp.id, row.?.id);
        testing.expectEqualStrings(exp.name, row.?.name.data);
        testing.expectEqual(exp.age, row.?.age);
    }
}

test "sqlite: statement reset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });

    // Create the tables
    inline for (AllDDL) |ddl| {
        try db.exec(ddl, .{});
    }

    // Add data

    var stmt = try db.prepare("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{[]const u8}, ?{usize})");
    defer stmt.deinit();

    const users = &[_]TestUser{
        .{ .id = 20, .name = "Vincent", .age = 33 },
        .{ .id = 40, .name = "Julien", .age = 35 },
        .{ .id = 60, .name = "José", .age = 40 },
    };

    for (users) |user| {
        stmt.reset();
        try stmt.exec(user);

        const rows_inserted = db.rowsAffected();
        testing.expectEqual(@as(usize, 1), rows_inserted);
    }
}

test "sqlite: statement iterator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });

    // Create the tables
    inline for (AllDDL) |ddl| {
        try db.exec(ddl, .{});
    }

    // Add data
    var stmt = try db.prepare("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{[]const u8}, ?{usize})");
    defer stmt.deinit();

    var expected_rows = std.ArrayList(TestUser).init(allocator);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "Vincent {}", .{i});
        const user = TestUser{ .id = i, .name = name, .age = i + 200 };

        try expected_rows.append(user);

        stmt.reset();
        try stmt.exec(user);

        const rows_inserted = db.rowsAffected();
        testing.expectEqual(@as(usize, 1), rows_inserted);
    }

    // Get the data with an iterator
    var stmt2 = try db.prepare("SELECT name, age FROM user");
    defer stmt2.deinit();

    const Type = struct {
        name: Text,
        age: usize,
    };

    var iter = try stmt2.iterator(Type, .{});

    var rows = std.ArrayList(Type).init(allocator);
    while (true) {
        const row = (try iter.next(.{ .allocator = allocator })) orelse break;
        try rows.append(row);
    }

    // Check the data
    testing.expectEqual(expected_rows.span().len, rows.span().len);

    for (rows.span()) |row, j| {
        const exp_row = expected_rows.span()[j];
        testing.expectEqualStrings(exp_row.name, row.name.data);
        testing.expectEqual(exp_row.age, row.age);
    }
}

fn dbMode() Db.Mode {
    return if (build_options.is_ci) blk: {
        break :blk .{ .Memory = {} };
    } else blk: {
        const path = "/tmp/zig-sqlite.db";
        std.fs.cwd().deleteFile(path) catch {};
        break :blk .{ .File = path };
    };
}
