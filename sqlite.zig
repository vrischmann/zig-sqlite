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

    /// pragma is a convenience function to use the PRAGMA statement.
    ///
    /// Here is how to set a pragma value:
    ///
    ///     try db.pragma(void, "foreign_keys", .{}, .{1});
    ///
    /// Here is how to query a pragama value:
    ///
    ///     const journal_mode = try db.pragma(
    ///         []const u8,
    ///         "journal_mode",
    ///         .{ .allocator = allocator },
    ///         .{},
    ///     );
    ///
    /// The pragma name must be known at comptime.
    pub fn pragma(self: *Self, comptime Type: type, comptime name: []const u8, options: anytype, arg: anytype) !?Type {
        comptime var buf: [1024]u8 = undefined;
        comptime var query = if (arg.len == 1) blk: {
            break :blk try std.fmt.bufPrint(&buf, "PRAGMA {} = {}", .{ name, arg[0] });
        } else blk: {
            break :blk try std.fmt.bufPrint(&buf, "PRAGMA {}", .{name});
        };

        var stmt = try self.prepare(query);
        defer stmt.deinit();

        return try stmt.one(Type, options, .{});
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
        @setEvalBranchQuota(10000);
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

        // next scans the next row using the preapred statement.
        //
        // If it returns null iterating is done.
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

            switch (Type) {
                []const u8, []u8 => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Type, 0, .Text, options);
                },
                Blob => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Blob, 0, .Blob, options);
                },
                Text => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Text, 0, .Text, options);
                },
                else => {},
            }

            switch (TypeInfo) {
                .Int => {
                    debug.assert(columns == 1);
                    return try self.readInt(Type, 0, options);
                },
                .Float => {
                    debug.assert(columns == 1);
                    return try self.readFloat(Type, 0, options);
                },
                .Bool => {
                    debug.assert(columns == 1);
                    return try self.readBool(0, options);
                },
                .Void => {
                    debug.assert(columns == 1);
                },
                .Array => {
                    debug.assert(columns == 1);
                    return try self.readArray(Type, 0);
                },
                .Struct => {
                    std.debug.assert(columns == TypeInfo.Struct.fields.len);
                    return try self.readStruct(options);
                },
                else => @compileError("cannot read into type " ++ @typeName(Type)),
            }
        }

        // readArray reads a sqlite BLOB or TEXT column into an array of u8.
        //
        // We also require the array to have a sentinel because otherwise we have no way
        // of communicating the end of the data to the caller.
        //
        // If the array is too small for the data an error will be returned.
        fn readArray(self: *Self, comptime ArrayType: type, _i: usize) error{ArrayTooSmall}!ArrayType {
            const i = @intCast(c_int, _i);
            const array_type_info = @typeInfo(ArrayType);

            var ret: ArrayType = undefined;
            switch (array_type_info) {
                .Array => |arr| {
                    comptime if (arr.sentinel == null) {
                        @compileError("cannot populate array of " ++ @typeName(arr.child) ++ ", arrays must have a sentinel");
                    };

                    switch (arr.child) {
                        u8 => {
                            const data = c.sqlite3_column_blob(self.stmt, i);
                            const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));

                            if (size >= @as(usize, arr.len)) return error.ArrayTooSmall;

                            const ptr = @ptrCast([*c]const u8, data)[0..size];

                            mem.copy(u8, ret[0..], ptr);
                            ret[size] = arr.sentinel.?;
                        },
                        else => @compileError("cannot populate field " ++ field.name ++ " of type array of " ++ @typeName(arr.child)),
                    }
                },
                else => @compileError("cannot populate field " ++ field.name ++ " of type array of " ++ @typeName(arr.child)),
            }
            return ret;
        }

        // readInt reads a sqlite INTEGER column into an integer.
        fn readInt(self: *Self, comptime IntType: type, i: usize, options: anytype) !IntType {
            const n = c.sqlite3_column_int64(self.stmt, @intCast(c_int, i));
            return @intCast(IntType, n);
        }

        // readFloat reads a sqlite REAL column into a float.
        fn readFloat(self: *Self, comptime FloatType: type, i: usize, options: anytype) !FloatType {
            const d = c.sqlite3_column_double(self.stmt, @intCast(c_int, i));
            return @floatCast(FloatType, d);
        }

        // readFloat reads a sqlite INTEGER column into a bool (true is anything > 0, false is anything <= 0).
        fn readBool(self: *Self, i: usize, options: anytype) !bool {
            const d = c.sqlite3_column_int64(self.stmt, @intCast(c_int, i));
            return d > 0;
        }

        const ReadBytesMode = enum {
            Blob,
            Text,
        };

        // readBytes reads a sqlite BLOB or TEXT column.
        //
        // The mode controls which sqlite function is used to retrieve the data:
        // * .Blob uses sqlite3_column_blob
        // * .Text uses sqlite3_column_text
        //
        // When using .Blob you can only read into either []const u8, []u8 or Blob.
        // When using .Text you can only read into either []const u8, []u8 or Text.
        //
        // The options must contain an `allocator` field which will be used to create a copy of the data.
        fn readBytes(self: *Self, comptime BytesType: type, _i: usize, comptime mode: ReadBytesMode, options: anytype) !BytesType {
            const i = @intCast(c_int, _i);

            var ret: BytesType = switch (BytesType) {
                Text, Blob => .{ .data = "" },
                else => "", // TODO(vincent): I think with a []u8 this will crash if the caller attempts to modify it...
            };

            switch (mode) {
                .Blob => {
                    const data = c.sqlite3_column_blob(self.stmt, i);
                    if (data == null) return ret;

                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));
                    const ptr = @ptrCast([*c]const u8, data)[0..size];

                    return switch (BytesType) {
                        []const u8, []u8 => try options.allocator.dupe(u8, ptr),
                        Blob => blk: {
                            var tmp: Blob = undefined;
                            tmp.data = try options.allocator.dupe(u8, ptr);
                            break :blk tmp;
                        },
                        else => @compileError("cannot read blob into type " ++ @typeName(BytesType)),
                    };
                },
                .Text => {
                    const data = c.sqlite3_column_text(self.stmt, i);
                    if (data == null) return ret;

                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));
                    const ptr = @ptrCast([*c]const u8, data)[0..size];

                    return switch (BytesType) {
                        []const u8, []u8 => try options.allocator.dupe(u8, ptr),
                        Text => blk: {
                            var tmp: Text = undefined;
                            tmp.data = try options.allocator.dupe(u8, ptr);
                            break :blk tmp;
                        },
                        else => @compileError("cannot read text into type " ++ @typeName(BytesType)),
                    };
                },
            }
        }

        // readStruct reads an entire sqlite row into a struct.
        //
        // Each field correspond to a column; its position in the struct determines the column used for it.
        // For example, given the following query:
        //
        //   SELECT id, name, age FROM user
        //
        // The struct must have the following fields:
        //
        //   struct {
        //     id: usize,
        //     name: []const u8,
        //     age: u16,
        //   }
        //
        // The field `id` will be associated with the column `id` and so on.
        //
        // This function relies on the fact that there are the same number of fields than columns and
        // that the order is correct.
        //
        // TODO(vincent): add comptime checks for the fields/columns.
        fn readStruct(self: *Self, options: anytype) !Type {
            var value: Type = undefined;

            inline for (@typeInfo(Type).Struct.fields) |field, _i| {
                const i = @as(usize, _i);
                const field_type_info = @typeInfo(field.field_type);

                const ret = switch (field.field_type) {
                    []const u8, []u8 => try self.readBytes(field.field_type, i, .Blob, options),
                    Blob => try self.readBytes(Blob, i, .Blob, options),
                    Text => try self.readBytes(Text, i, .Text, options),
                    else => switch (field_type_info) {
                        .Int => try self.readInt(field.field_type, i, options),
                        .Float => try self.readFloat(field.field_type, i, options),
                        .Bool => try self.readBool(i, options),
                        .Void => {},
                        .Array => try self.readArray(field.field_type, i),
                        else => @compileError("cannot populate field " ++ field.name ++ " of type " ++ @typeName(field.field_type)),
                    },
                };

                @field(value, field.name) = ret;
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
                        .Bool => _ = c.sqlite3_bind_int64(self.stmt, column, @boolToInt(field_value)),
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

            return rows.toOwnedSlice();
        }
    };
}

const TestUser = struct {
    id: usize,
    name: []const u8,
    age: usize,
    weight: f32,
};

const test_users = &[_]TestUser{
    .{ .id = 20, .name = "Vincent", .age = 33, .weight = 85.4 },
    .{ .id = 40, .name = "Julien", .age = 35, .weight = 100.3 },
    .{ .id = 60, .name = "José", .age = 40, .weight = 240.2 },
};

fn addTestData(db: *Db) !void {
    const AllDDL = &[_][]const u8{
        \\CREATE TABLE user(
        \\ id integer PRIMARY KEY,
        \\ name text,
        \\ age integer,
        \\ weight real
        \\)
        ,
        \\CREATE TABLE article(
        \\  id integer PRIMARY KEY,
        \\  author_id integer,
        \\  data text,
        \\  is_published integer,
        \\  FOREIGN KEY(author_id) REFERENCES user(id)
        \\)
    };

    // Create the tables
    inline for (AllDDL) |ddl| {
        try db.exec(ddl, .{});
    }

    for (test_users) |user| {
        try db.exec("INSERT INTO user(id, name, age, weight) VALUES(?{usize}, ?{[]const u8}, ?{usize}, ?{f32})", user);

        const rows_inserted = db.rowsAffected();
        testing.expectEqual(@as(usize, 1), rows_inserted);
    }
}

test "sqlite: db init" {
    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try db.init(testing.allocator, .{});
}

test "sqlite: db pragma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });

    const foreign_keys = try db.pragma(usize, "foreign_keys", .{}, .{});
    testing.expect(foreign_keys != null);
    testing.expectEqual(@as(usize, 0), foreign_keys.?);

    if (build_options.is_ci) {
        const journal_mode = try db.pragma(
            []const u8,
            "journal_mode",
            .{ .allocator = &arena.allocator },
            .{"wal"},
        );
        testing.expect(journal_mode != null);
        testing.expectEqualStrings("memory", journal_mode.?);
    } else {
        const journal_mode = try db.pragma(
            []const u8,
            "journal_mode",
            .{ .allocator = &arena.allocator },
            .{"wal"},
        );
        testing.expect(journal_mode != null);
        testing.expectEqualStrings("wal", journal_mode.?);
    }
}

test "sqlite: statement exec" {
    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

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
}

test "sqlite: read a single user into a struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    var stmt = try db.prepare("SELECT id, name, age, weight FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var rows = try stmt.all(
        TestUser,
        .{ .allocator = &arena.allocator },
        .{ .id = @as(usize, 20) },
    );
    for (rows) |row| {
        testing.expectEqual(test_users[0].id, row.id);
        testing.expectEqualStrings(test_users[0].name, row.name);
        testing.expectEqual(test_users[0].age, row.age);
    }
}

test "sqlite: read all users into a struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    var stmt = try db.prepare("SELECT id, name, age, weight FROM user");
    defer stmt.deinit();

    var rows = try stmt.all(
        TestUser,
        .{ .allocator = &arena.allocator },
        .{},
    );
    testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row, i| {
        const exp = test_users[i];
        testing.expectEqual(exp.id, row.id);
        testing.expectEqualStrings(exp.name, row.name);
        testing.expectEqual(exp.age, row.age);
    }
}

test "sqlite: read in an anonymous struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    var stmt = try db.prepare("SELECT id, name, name, age, id, weight FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var row = try stmt.one(
        struct {
            id: usize,
            name: []const u8,
            name_2: [200:0xAD]u8,
            age: usize,
            is_id: bool,
            weight: f64,
        },
        .{ .allocator = &arena.allocator },
        .{ .id = @as(usize, 20) },
    );
    testing.expect(row != null);

    const exp = test_users[0];
    testing.expectEqual(exp.id, row.?.id);
    testing.expectEqualStrings(exp.name, row.?.name);
    testing.expectEqualStrings(exp.name, mem.spanZ(&row.?.name_2));
    testing.expectEqual(exp.age, row.?.age);
    testing.expect(row.?.is_id);
    testing.expectEqual(exp.weight, @floatCast(f32, row.?.weight));
}

test "sqlite: read in a Text struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    var stmt = try db.prepare("SELECT id, name, age FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var row = try stmt.one(
        struct {
            id: usize,
            name: Text,
            age: usize,
        },
        .{ .allocator = &arena.allocator },
        .{@as(usize, 20)},
    );
    testing.expect(row != null);

    const exp = test_users[0];
    testing.expectEqual(exp.id, row.?.id);
    testing.expectEqualStrings(exp.name, row.?.name.data);
    testing.expectEqual(exp.age, row.?.age);
}

test "sqlite: read a single text value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    // TODO(vincent): implement the following
    // [:0]const u8
    // [:0]u8

    const types = &[_]type{
        // Slices
        []const u8,
        []u8,
        // Array
        [8:0]u8,
        // Specific text or blob
        Text,
        Blob,
    };

    inline for (types) |typ| {
        const query = "SELECT name FROM user WHERE id = ?{usize}";

        var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
        defer stmt.deinit();

        const name = try stmt.one(
            typ,
            .{ .allocator = &arena.allocator },
            .{ .id = @as(usize, 20) },
        );
        testing.expect(name != null);
        switch (typ) {
            Text, Blob => {
                testing.expectEqualStrings("Vincent", name.?.data);
            },
            else => {
                const span = blk: {
                    const type_info = @typeInfo(typ);
                    break :blk switch (type_info) {
                        .Pointer => name.?,
                        .Array => mem.spanZ(&(name.?)),
                        else => @compileError("invalid type " ++ @typeName(typ)),
                    };
                };

                testing.expectEqualStrings("Vincent", span);
            },
        }
    }
}

test "sqlite: read a single integer value" {
    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

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

test "sqlite: read a single value into void" {
    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    const query = "SELECT age FROM user WHERE id = ?{usize}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    _ = try stmt.one(void, .{}, .{ .id = @as(usize, 20) });
}

test "sqlite: read a single value into bool" {
    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    const query = "SELECT id FROM user WHERE id = ?{usize}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(bool, .{}, .{ .id = @as(usize, 20) });
    testing.expect(b != null);
    testing.expect(b.?);
}

test "sqlite: insert bool and bind bool" {
    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    try db.exec("INSERT INTO article(id, author_id, is_published) VALUES(?{usize}, ?{usize}, ?{bool})", .{
        .id = @as(usize, 1),
        .author_id = @as(usize, 20),
        .is_published = true,
    });

    const query = "SELECT id FROM article WHERE is_published = ?{bool}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(bool, .{}, .{ .is_published = true });
    testing.expect(b != null);
    testing.expect(b.?);
}

test "sqlite: statement reset" {
    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });
    try addTestData(&db);

    // Add data

    var stmt = try db.prepare("INSERT INTO user(id, name, age, weight) VALUES(?{usize}, ?{[]const u8}, ?{usize}, ?{f32})");
    defer stmt.deinit();

    const users = &[_]TestUser{
        .{ .id = 200, .name = "Vincent", .age = 33, .weight = 10.0 },
        .{ .id = 400, .name = "Julien", .age = 35, .weight = 12.0 },
        .{ .id = 600, .name = "José", .age = 40, .weight = 14.0 },
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
    try addTestData(&db);

    // Cleanup first
    try db.exec("DELETE FROM user", .{});

    // Add data
    var stmt = try db.prepare("INSERT INTO user(id, name, age, weight) VALUES(?{usize}, ?{[]const u8}, ?{usize}, ?{f32})");
    defer stmt.deinit();

    var expected_rows = std.ArrayList(TestUser).init(allocator);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "Vincent {}", .{i});
        const user = TestUser{ .id = i, .name = name, .age = i + 200, .weight = @intToFloat(f32, i + 200) };

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
    testing.expectEqual(expected_rows.items.len, rows.items.len);

    for (rows.items) |row, j| {
        const exp_row = expected_rows.items[j];
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
