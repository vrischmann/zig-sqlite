const std = @import("std");
const build_options = @import("build_options");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
});

usingnamespace @import("query.zig");
usingnamespace @import("error.zig");

const logger = std.log.scoped(.sqlite);

/// ThreadingMode controls the threading mode used by SQLite.
///
/// See https://sqlite.org/threadsafe.html
pub const ThreadingMode = enum {
    /// SingleThread makes SQLite unsafe to use with more than a single thread at once.
    SingleThread,
    /// MultiThread makes SQLite safe to use with multiple threads at once provided that
    /// a single database connection is not by more than a single thread at once.
    MultiThread,
    /// Serialized makes SQLite safe to use with multiple threads at once with no restriction.
    Serialized,
};

pub const InitOptions = struct {
    /// mode controls how the database is opened.
    ///
    /// Defaults to a in-memory database.
    mode: Db.Mode = .Memory,

    /// open_flags controls the flags used when opening a database.
    ///
    /// Defaults to a read only database.
    open_flags: Db.OpenFlags = .{},

    /// threading_mode controls the threading mode used by SQLite.
    ///
    /// Defaults to Serialized.
    threading_mode: ThreadingMode = .Serialized,
};

/// DetailedError contains a SQLite error code and error message.
pub const DetailedError = struct {
    code: usize,
    message: []const u8,
};

fn isThreadSafe() bool {
    return c.sqlite3_threadsafe() > 0;
}

fn getDetailedErrorFromResultCode(code: c_int) DetailedError {
    return .{
        .code = @intCast(usize, code),
        .message = blk: {
            const msg = c.sqlite3_errstr(code);
            break :blk mem.spanZ(msg);
        },
    };
}

fn getLastDetailedErrorFromDb(db: *c.sqlite3) DetailedError {
    return .{
        .code = @intCast(usize, c.sqlite3_extended_errcode(db)),
        .message = blk: {
            const msg = c.sqlite3_errmsg(db);
            break :blk mem.spanZ(msg);
        },
    };
}

/// Db is a wrapper around a SQLite database, providing high-level functions for executing queries.
/// A Db can be opened with a file database or a in-memory database:
///
///     // File database
///     var db: sqlite.Db = undefined;
///     try db.init(.{ .mode = { .File = "/tmp/data.db" } });
///
///     // In memory database
///     var db: sqlite.Db = undefined;
///     try db.init(.{ .mode = { .Memory = {} } });
///
pub const Db = struct {
    const Self = @This();

    db: *c.sqlite3,

    /// Mode determines how the database will be opened.
    pub const Mode = union(enum) {
        File: [:0]const u8,
        Memory,
    };

    /// OpenFlags contains various flags used when opening a SQLite databse.
    pub const OpenFlags = struct {
        write: bool = false,
        create: bool = false,
    };

    /// init creates a database with the provided `mode`.
    pub fn init(self: *Self, options: InitOptions) !void {
        // Validate the threading mode
        if (options.threading_mode != .SingleThread and !isThreadSafe()) {
            return error.CannotUseSingleThreadedSQLite;
        }

        // Compute the flags
        var flags: c_int = 0;
        flags |= @as(c_int, if (options.open_flags.write) c.SQLITE_OPEN_READWRITE else c.SQLITE_OPEN_READONLY);
        if (options.open_flags.create) {
            flags |= c.SQLITE_OPEN_CREATE;
        }
        switch (options.threading_mode) {
            .MultiThread => flags |= c.SQLITE_OPEN_NOMUTEX,
            .Serialized => flags |= c.SQLITE_OPEN_FULLMUTEX,
            else => {},
        }

        switch (options.mode) {
            .File => |path| {
                logger.info("opening {s}", .{path});

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(path, &db, flags, null);
                if (result != c.SQLITE_OK or db == null) {
                    return errorFromResultCode(result);
                }

                self.db = db.?;
            },
            .Memory => {
                logger.info("opening in memory", .{});

                flags |= c.SQLITE_OPEN_MEMORY;

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(":memory:", &db, flags, null);
                if (result != c.SQLITE_OK or db == null) {
                    return errorFromResultCode(result);
                }

                self.db = db.?;
            },
        }
    }

    /// deinit closes the database.
    pub fn deinit(self: *Self) void {
        _ = c.sqlite3_close(self.db);
    }

    // getDetailedError returns the detailed error for the last API call if it failed.
    pub fn getDetailedError(self: *Self) DetailedError {
        return getLastDetailedErrorFromDb(self.db);
    }

    fn getPragmaQuery(comptime buf: []u8, comptime name: []const u8, comptime arg: anytype) []const u8 {
        return if (arg.len == 1) blk: {
            break :blk try std.fmt.bufPrint(buf, "PRAGMA {s} = {s}", .{ name, arg[0] });
        } else blk: {
            break :blk try std.fmt.bufPrint(buf, "PRAGMA {s}", .{name});
        };
    }

    /// pragmaAlloc is like `pragma` but can allocate memory.
    ///
    /// Useful when the pragma command returns text, for example:
    ///
    ///     const journal_mode = try db.pragma([]const u8, allocator, .{}, "journal_mode", .{});
    ///
    pub fn pragmaAlloc(self: *Self, comptime Type: type, allocator: *mem.Allocator, options: anytype, comptime name: []const u8, comptime arg: anytype) !?Type {
        comptime var buf: [1024]u8 = undefined;
        comptime var query = getPragmaQuery(&buf, name, arg);

        var stmt = try self.prepare(query);
        defer stmt.deinit();

        return try stmt.oneAlloc(Type, allocator, options, .{});
    }

    /// pragma is a convenience function to use the PRAGMA statement.
    ///
    /// Here is how to set a pragma value:
    ///
    ///     try db.pragma(void, "foreign_keys", .{}, .{1});
    ///
    /// Here is how to query a pragama value:
    ///
    ///     const journal_mode = try db.pragma([128:0]const u8, .{}, "journal_mode", .{});
    ///
    /// The pragma name must be known at comptime.
    ///
    /// This cannot allocate memory. If your pragma command returns text you must use an array or call `pragmaAlloc`.
    pub fn pragma(self: *Self, comptime Type: type, options: anytype, comptime name: []const u8, arg: anytype) !?Type {
        comptime var buf: [1024]u8 = undefined;
        comptime var query = getPragmaQuery(&buf, name, arg);

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

    /// one is a convenience function which prepares a statement and reads a single row from the result set.
    pub fn one(self: *Self, comptime Type: type, comptime query: []const u8, options: anytype, values: anytype) !?Type {
        var stmt = try self.prepare(query);
        defer stmt.deinit();
        return try stmt.one(Type, options, values);
    }

    /// oneAlloc is like `one` but can allocate memory.
    pub fn oneAlloc(self: *Self, comptime Type: type, allocator: *mem.Allocator, comptime query: []const u8, options: anytype, values: anytype) !?Type {
        var stmt = try self.prepare(query);
        defer stmt.deinit();
        return try stmt.oneAlloc(Type, allocator, options, values);
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

        // next scans the next row using the prepared statement.
        // If it returns null iterating is done.
        //
        // This cannot allocate memory. If you need to read TEXT or BLOB columns you need to use arrays or alternatively call nextAlloc.
        pub fn next(self: *Self, options: anytype) !?Type {
            var result = c.sqlite3_step(self.stmt);
            if (result == c.SQLITE_DONE) {
                return null;
            }
            if (result != c.SQLITE_ROW) {
                return errorFromResultCode(result);
            }

            const columns = c.sqlite3_column_count(self.stmt);

            switch (TypeInfo) {
                .Int => {
                    debug.assert(columns == 1);
                    return try self.readInt(Type, 0);
                },
                .Float => {
                    debug.assert(columns == 1);
                    return try self.readFloat(Type, 0);
                },
                .Bool => {
                    debug.assert(columns == 1);
                    return try self.readBool(0);
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
                    return try self.readStruct(.{});
                },
                else => @compileError("cannot read into type " ++ @typeName(Type) ++ " ; if dynamic memory allocation is required use nextAlloc"),
            }
        }

        // nextAlloc is like `next` but can allocate memory.
        pub fn nextAlloc(self: *Self, allocator: *mem.Allocator, options: anytype) !?Type {
            var result = c.sqlite3_step(self.stmt);
            if (result == c.SQLITE_DONE) {
                return null;
            }
            if (result != c.SQLITE_ROW) {
                return errorFromResultCode(result);
            }

            const columns = c.sqlite3_column_count(self.stmt);

            switch (Type) {
                []const u8, []u8 => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Type, allocator, 0, .Text);
                },
                Blob => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Blob, allocator, 0, .Blob);
                },
                Text => {
                    debug.assert(columns == 1);
                    return try self.readBytes(Text, allocator, 0, .Text);
                },
                else => {},
            }

            switch (TypeInfo) {
                .Int => {
                    debug.assert(columns == 1);
                    return try self.readInt(Type, 0);
                },
                .Float => {
                    debug.assert(columns == 1);
                    return try self.readFloat(Type, 0);
                },
                .Bool => {
                    debug.assert(columns == 1);
                    return try self.readBool(0);
                },
                .Void => {
                    debug.assert(columns == 1);
                },
                .Array => {
                    debug.assert(columns == 1);
                    return try self.readArray(Type, 0);
                },
                .Pointer => {
                    debug.assert(columns == 1);
                    return try self.readPointer(Type, allocator, 0);
                },
                .Struct => {
                    std.debug.assert(columns == TypeInfo.Struct.fields.len);
                    return try self.readStruct(.{
                        .allocator = allocator,
                    });
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
            const type_info = @typeInfo(ArrayType);

            var ret: ArrayType = undefined;
            switch (type_info) {
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
        fn readInt(self: *Self, comptime IntType: type, i: usize) !IntType {
            const n = c.sqlite3_column_int64(self.stmt, @intCast(c_int, i));
            return @intCast(IntType, n);
        }

        // readFloat reads a sqlite REAL column into a float.
        fn readFloat(self: *Self, comptime FloatType: type, i: usize) !FloatType {
            const d = c.sqlite3_column_double(self.stmt, @intCast(c_int, i));
            return @floatCast(FloatType, d);
        }

        // readFloat reads a sqlite INTEGER column into a bool (true is anything > 0, false is anything <= 0).
        fn readBool(self: *Self, i: usize) !bool {
            const d = c.sqlite3_column_int64(self.stmt, @intCast(c_int, i));
            return d > 0;
        }

        const ReadBytesMode = enum {
            Blob,
            Text,
        };

        // dupeWithSentinel is like dupe/dupeZ but allows for any sentinel value.
        fn dupeWithSentinel(comptime SliceType: type, allocator: *mem.Allocator, data: []const u8) !SliceType {
            const type_info = @typeInfo(SliceType);
            switch (type_info) {
                .Pointer => |ptr_info| {
                    if (ptr_info.sentinel) |sentinel| {
                        const slice = try allocator.alloc(u8, data.len + 1);
                        mem.copy(u8, slice, data);
                        slice[data.len] = sentinel;

                        return slice[0..data.len :sentinel];
                    } else {
                        return try allocator.dupe(u8, data);
                    }
                },
                else => @compileError("cannot dupe type " ++ @typeName(SliceType)),
            }
        }

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
        fn readBytes(self: *Self, comptime BytesType: type, allocator: *mem.Allocator, _i: usize, comptime mode: ReadBytesMode) !BytesType {
            const i = @intCast(c_int, _i);
            const type_info = @typeInfo(BytesType);

            var ret: BytesType = switch (BytesType) {
                Text, Blob => .{ .data = "" },
                else => try dupeWithSentinel(BytesType, allocator, ""),
            };

            switch (mode) {
                .Blob => {
                    const data = c.sqlite3_column_blob(self.stmt, i);
                    if (data == null) {
                        return switch (BytesType) {
                            Text, Blob => .{ .data = try allocator.dupe(u8, "") },
                            else => try dupeWithSentinel(BytesType, allocator, ""),
                        };
                    }

                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));
                    const ptr = @ptrCast([*c]const u8, data)[0..size];

                    if (BytesType == Blob) {
                        return Blob{ .data = try allocator.dupe(u8, ptr) };
                    }
                    return try dupeWithSentinel(BytesType, allocator, ptr);
                },
                .Text => {
                    const data = c.sqlite3_column_text(self.stmt, i);
                    if (data == null) {
                        return switch (BytesType) {
                            Text, Blob => .{ .data = try allocator.dupe(u8, "") },
                            else => try dupeWithSentinel(BytesType, allocator, ""),
                        };
                    }

                    const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));
                    const ptr = @ptrCast([*c]const u8, data)[0..size];

                    if (BytesType == Text) {
                        return Text{ .data = try allocator.dupe(u8, ptr) };
                    }
                    return try dupeWithSentinel(BytesType, allocator, ptr);
                },
            }
        }

        fn readPointer(self: *Self, comptime PointerType: type, allocator: *mem.Allocator, i: usize) !PointerType {
            const type_info = @typeInfo(PointerType);

            var ret: PointerType = undefined;
            switch (type_info) {
                .Pointer => |ptr| {
                    switch (ptr.size) {
                        .One => {
                            ret = try allocator.create(ptr.child);
                            errdefer allocator.destroy(ret);

                            ret.* = try self.readField(ptr.child, i, .{ .allocator = allocator });
                        },
                        .Slice => switch (ptr.child) {
                            u8 => ret = try self.readBytes(PointerType, allocator, i, .Text),
                            else => @compileError("cannot read pointer of type " ++ @typeName(PointerType)),
                        },
                        else => @compileError("cannot read pointer of type " ++ @typeName(PointerType)),
                    }
                },
                else => @compileError("cannot read pointer of type " ++ @typeName(PointerType)),
            }

            return ret;
        }

        fn readOptional(self: *Self, comptime OptionalType: type, options: anytype, _i: usize) !OptionalType {
            const i = @intCast(c_int, _i);
            const type_info = @typeInfo(OptionalType);

            var ret: OptionalType = undefined;
            switch (type_info) {
                .Optional => |opt| {
                    // Easy way to know if the column represents a null value.
                    const value = c.sqlite3_column_value(self.stmt, i);
                    const datatype = c.sqlite3_value_type(value);

                    if (datatype == c.SQLITE_NULL) {
                        return null;
                    } else {
                        const val = try self.readField(opt.child, _i, options);
                        ret = val;
                        return ret;
                    }
                },
                else => @compileError("cannot read optional of type " ++ @typeName(OptionalType)),
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

                const ret = try self.readField(field.field_type, i, options);

                @field(value, field.name) = ret;
            }

            return value;
        }

        fn readField(self: *Self, comptime FieldType: type, i: usize, options: anytype) !FieldType {
            const field_type_info = @typeInfo(FieldType);

            return switch (FieldType) {
                Blob => try self.readBytes(Blob, options.allocator, i, .Blob),
                Text => try self.readBytes(Text, options.allocator, i, .Text),
                else => switch (field_type_info) {
                    .Int => try self.readInt(FieldType, i),
                    .Float => try self.readFloat(FieldType, i),
                    .Bool => try self.readBool(i),
                    .Void => {},
                    .Array => try self.readArray(FieldType, i),
                    .Pointer => try self.readPointer(FieldType, options.allocator, i),
                    .Optional => try self.readOptional(FieldType, options, i),
                    else => @compileError("cannot populate field of type " ++ @typeName(FieldType)),
                },
            };
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
/// Look at each function for more complete documentation.
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
                    return errorFromResultCode(result);
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

                const field_value = @field(values, struct_field.name);

                self.bindField(struct_field.field_type, struct_field.name, _i, field_value);
            }
        }

        fn bindField(self: *Self, comptime FieldType: type, comptime field_name: []const u8, i: c_int, field: FieldType) void {
            const field_type_info = @typeInfo(FieldType);
            const column = i + 1;

            switch (FieldType) {
                Text => _ = c.sqlite3_bind_text(self.stmt, column, field.data.ptr, @intCast(c_int, field.data.len), null),
                Blob => _ = c.sqlite3_bind_blob(self.stmt, column, field.data.ptr, @intCast(c_int, field.data.len), null),
                else => switch (field_type_info) {
                    .Int, .ComptimeInt => _ = c.sqlite3_bind_int64(self.stmt, column, @intCast(c_longlong, field)),
                    .Float, .ComptimeFloat => _ = c.sqlite3_bind_double(self.stmt, column, field),
                    .Bool => _ = c.sqlite3_bind_int64(self.stmt, column, @boolToInt(field)),
                    .Pointer => |ptr| switch (ptr.size) {
                        .One => self.bindField(ptr.child, field_name, i, field.*),
                        .Slice => switch (ptr.child) {
                            u8 => {
                                _ = c.sqlite3_bind_text(self.stmt, column, field.ptr, @intCast(c_int, field.len), null);
                            },
                            else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
                        },
                        else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
                    },
                    .Array => |arr| {
                        switch (arr.child) {
                            u8 => {
                                const data: []const u8 = field[0..field.len];

                                _ = c.sqlite3_bind_text(self.stmt, column, data.ptr, @intCast(c_int, data.len), null);
                            },
                            else => @compileError("cannot bind field " ++ field_name ++ " of type array of " ++ @typeName(arr.child)),
                        }
                    },
                    .Optional => |opt| if (field) |non_null_field| {
                        self.bindField(opt.child, field_name, i, non_null_field);
                    } else {
                        _ = c.sqlite3_bind_null(self.stmt, column);
                    },
                    .Null => _ = c.sqlite3_bind_null(self.stmt, column),
                    else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
                },
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
                c.SQLITE_BUSY => return errorFromResultCode(result),
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
        ///             name: [400]u8,
        ///             age: usize,
        ///         },
        ///         .{},
        ///         .{ .foo = "bar", .age = 500 },
        ///     );
        ///
        /// The `options` tuple is used to provide additional state in some cases.
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        /// This cannot allocate memory. If you need to read TEXT or BLOB columns you need to use arrays or alternatively call `oneAlloc`.
        pub fn one(self: *Self, comptime Type: type, options: anytype, values: anytype) !?Type {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to iterator must be a struct");
            }

            var iter = try self.iterator(Type, values);

            const row = (try iter.next(options)) orelse return null;
            return row;
        }

        /// oneAlloc is like `one` but can allocate memory.
        pub fn oneAlloc(self: *Self, comptime Type: type, allocator: *mem.Allocator, options: anytype, values: anytype) !?Type {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to iterator must be a struct");
            }

            var iter = try self.iterator(Type, values);

            const row = (try iter.nextAlloc(allocator, options)) orelse return null;
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
        ///         allocator,
        ///         .{},
        ///         .{ .foo = "bar", .age = 500 },
        ///     );
        ///
        /// The `options` tuple is used to provide additional state in some cases.
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        /// Note that this allocates all rows into a single slice: if you read a lot of data this can use a lot of memory.
        pub fn all(self: *Self, comptime Type: type, allocator: *mem.Allocator, options: anytype, values: anytype) ![]Type {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to iterator must be a struct");
            }
            var iter = try self.iterator(Type, values);

            var rows = std.ArrayList(Type).init(allocator);
            while (true) {
                const row = (try iter.nextAlloc(allocator, options)) orelse break;
                try rows.append(row);
            }

            return rows.toOwnedSlice();
        }
    };
}

const TestUser = struct {
    name: []const u8,
    id: usize,
    age: usize,
    weight: f32,
};

const test_users = &[_]TestUser{
    .{ .name = "Vincent", .id = 20, .age = 33, .weight = 85.4 },
    .{ .name = "Julien", .id = 40, .age = 35, .weight = 100.3 },
    .{ .name = "José", .id = 60, .age = 40, .weight = 240.2 },
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
        try db.exec("INSERT INTO user(name, id, age, weight) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32})", user);

        const rows_inserted = db.rowsAffected();
        testing.expectEqual(@as(usize, 1), rows_inserted);
    }
}

test "sqlite: db init" {
    var db = try getTestDb();
}

test "sqlite: db pragma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();

    const foreign_keys = try db.pragma(usize, .{}, "foreign_keys", .{});
    testing.expect(foreign_keys != null);
    testing.expectEqual(@as(usize, 0), foreign_keys.?);

    const arg = .{"wal"};

    if (build_options.in_memory) {
        {
            const journal_mode = try db.pragma([128:0]u8, .{}, "journal_mode", arg);
            testing.expect(journal_mode != null);
            testing.expectEqualStrings("memory", mem.spanZ(&journal_mode.?));
        }

        {
            const journal_mode = try db.pragmaAlloc([]const u8, &arena.allocator, .{}, "journal_mode", arg);
            testing.expect(journal_mode != null);
            testing.expectEqualStrings("memory", journal_mode.?);
        }
    } else {
        {
            const journal_mode = try db.pragma([128:0]u8, .{}, "journal_mode", arg);
            testing.expect(journal_mode != null);
            testing.expectEqualStrings("wal", mem.spanZ(&journal_mode.?));
        }

        {
            const journal_mode = try db.pragmaAlloc([]const u8, &arena.allocator, .{}, "journal_mode", arg);
            testing.expect(journal_mode != null);
            testing.expectEqualStrings("wal", journal_mode.?);
        }
    }
}

test "sqlite: statement exec" {
    var db = try getTestDb();
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

    var db = try getTestDb();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT name, id, age, weight FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var rows = try stmt.all(TestUser, &arena.allocator, .{}, .{
        .id = @as(usize, 20),
    });
    for (rows) |row| {
        testing.expectEqual(test_users[0].id, row.id);
        testing.expectEqualStrings(test_users[0].name, row.name);
        testing.expectEqual(test_users[0].age, row.age);
    }

    // Read a row with db.one()
    {
        var row = try db.one(
            struct {
                name: [128:0]u8,
                id: usize,
                age: usize,
            },
            "SELECT name, id, age FROM user WHERE id = ?{usize}",
            .{},
            .{@as(usize, 20)},
        );
        testing.expect(row != null);

        const exp = test_users[0];
        testing.expectEqual(exp.id, row.?.id);
        testing.expectEqualStrings(exp.name, mem.spanZ(&row.?.name));
        testing.expectEqual(exp.age, row.?.age);
    }

    // Read a row with db.oneAlloc()
    {
        var row = try db.oneAlloc(
            struct {
                name: Text,
                id: usize,
                age: usize,
            },
            &arena.allocator,
            "SELECT name, id, age FROM user WHERE id = ?{usize}",
            .{},
            .{@as(usize, 20)},
        );
        testing.expect(row != null);

        const exp = test_users[0];
        testing.expectEqual(exp.id, row.?.id);
        testing.expectEqualStrings(exp.name, row.?.name.data);
        testing.expectEqual(exp.age, row.?.age);
    }
}

test "sqlite: read all users into a struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT name, id, age, weight FROM user");
    defer stmt.deinit();

    var rows = try stmt.all(TestUser, &arena.allocator, .{}, .{});
    testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row, i| {
        const exp = test_users[i];
        testing.expectEqual(exp.id, row.id);
        testing.expectEqualStrings(exp.name, row.name);
        testing.expectEqual(exp.age, row.age);
        testing.expectEqual(exp.weight, row.weight);
    }
}

test "sqlite: read in an anonymous struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT name, id, name, age, id, weight FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var row = try stmt.oneAlloc(
        struct {
            name: []const u8,
            id: usize,
            name_2: [200:0xAD]u8,
            age: usize,
            is_id: bool,
            weight: f64,
        },
        &arena.allocator,
        .{},
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

    var db = try getTestDb();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT name, id, age FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var row = try stmt.oneAlloc(
        struct {
            name: Text,
            id: usize,
            age: usize,
        },
        &arena.allocator,
        .{},
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

    var db = try getTestDb();
    try addTestData(&db);

    const types = &[_]type{
        // Slices
        []const u8,
        []u8,
        [:0]const u8,
        [:0]u8,
        [:0xAD]const u8,
        [:0xAD]u8,
        // Array
        [8:0]u8,
        [8:0xAD]u8,
        // Specific text or blob
        Text,
        Blob,
    };

    inline for (types) |typ| {
        const query = "SELECT name FROM user WHERE id = ?{usize}";

        var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
        defer stmt.deinit();

        const name = try stmt.oneAlloc(typ, &arena.allocator, .{}, .{
            .id = @as(usize, 20),
        });
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
    var db = try getTestDb();
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

        var age = try stmt.one(typ, .{}, .{
            .id = @as(usize, 20),
        });
        testing.expect(age != null);

        testing.expectEqual(@as(typ, 33), age.?);
    }
}

test "sqlite: read a single value into void" {
    var db = try getTestDb();
    try addTestData(&db);

    const query = "SELECT age FROM user WHERE id = ?{usize}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    _ = try stmt.one(void, .{}, .{
        .id = @as(usize, 20),
    });
}

test "sqlite: read a single value into bool" {
    var db = try getTestDb();
    try addTestData(&db);

    const query = "SELECT id FROM user WHERE id = ?{usize}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(bool, .{}, .{
        .id = @as(usize, 20),
    });
    testing.expect(b != null);
    testing.expect(b.?);
}

test "sqlite: insert bool and bind bool" {
    var db = try getTestDb();
    try addTestData(&db);

    try db.exec("INSERT INTO article(id, author_id, is_published) VALUES(?{usize}, ?{usize}, ?{bool})", .{
        .id = @as(usize, 1),
        .author_id = @as(usize, 20),
        .is_published = true,
    });

    const query = "SELECT id FROM article WHERE is_published = ?{bool}";

    var stmt: Statement(.{}, ParsedQuery.from(query)) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(bool, .{}, .{
        .is_published = true,
    });
    testing.expect(b != null);
    testing.expect(b.?);
}

test "sqlite: bind string literal" {
    var db = try getTestDb();
    try addTestData(&db);

    try db.exec("INSERT INTO article(id, data) VALUES(?, ?)", .{
        @as(usize, 10),
        "foobar",
    });

    const query = "SELECT id FROM article WHERE data = ?";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(usize, .{}, .{"foobar"});
    testing.expect(b != null);
    testing.expectEqual(@as(usize, 10), b.?);
}

test "sqlite: bind pointer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    const query = "SELECT name FROM user WHERE id = ?";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    for (test_users) |test_user, i| {
        stmt.reset();

        const name = try stmt.oneAlloc([]const u8, &arena.allocator, .{}, .{&test_user.id});
        testing.expect(name != null);
        testing.expectEqualStrings(test_users[i].name, name.?);
    }
}

test "sqlite: read pointers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    const query = "SELECT id, name, age, weight FROM user";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const rows = try stmt.all(
        struct {
            id: *usize,
            name: *[]const u8,
            age: *u32,
            weight: *f32,
        },
        &arena.allocator,
        .{},
        .{},
    );

    testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row, i| {
        const exp = test_users[i];
        testing.expectEqual(exp.id, row.id.*);
        testing.expectEqualStrings(exp.name, row.name.*);
        testing.expectEqual(exp.age, row.age.*);
        testing.expectEqual(exp.weight, row.weight.*);
    }
}

test "sqlite: optional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    try addTestData(&db);

    try db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?, ?)", .{ 1, null, true });

    var stmt = try db.prepare("SELECT data, is_published FROM article");
    defer stmt.deinit();

    const row = try stmt.one(
        struct {
            data: ?[128:0]u8,
            is_published: ?bool,
        },
        .{},
        .{},
    );

    testing.expect(row != null);
    testing.expect(row.?.data == null);
    testing.expectEqual(true, row.?.is_published.?);
}

test "sqlite: statement reset" {
    var db = try getTestDb();
    try addTestData(&db);

    // Add data

    var stmt = try db.prepare("INSERT INTO user(name, id, age, weight) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32})");
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

    var db = try getTestDb();
    try addTestData(&db);

    // Cleanup first
    try db.exec("DELETE FROM user", .{});

    // Add data
    var stmt = try db.prepare("INSERT INTO user(name, id, age, weight) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32})");
    defer stmt.deinit();

    var expected_rows = std.ArrayList(TestUser).init(allocator);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "Vincent {d}", .{i});
        const user = TestUser{ .id = i, .name = name, .age = i + 200, .weight = @intToFloat(f32, i + 200) };

        try expected_rows.append(user);

        stmt.reset();
        try stmt.exec(user);

        const rows_inserted = db.rowsAffected();
        testing.expectEqual(@as(usize, 1), rows_inserted);
    }

    // Get data with a non-allocating iterator.
    {
        var stmt2 = try db.prepare("SELECT name, age FROM user");
        defer stmt2.deinit();

        const RowType = struct {
            name: [128:0]u8,
            age: usize,
        };

        var iter = try stmt2.iterator(RowType, .{});

        var rows = std.ArrayList(RowType).init(allocator);
        while (true) {
            const row = (try iter.next(.{})) orelse break;
            try rows.append(row);
        }

        // Check the data
        testing.expectEqual(expected_rows.items.len, rows.items.len);

        for (rows.items) |row, j| {
            const exp_row = expected_rows.items[j];
            testing.expectEqualStrings(exp_row.name, mem.spanZ(&row.name));
            testing.expectEqual(exp_row.age, row.age);
        }
    }

    // Get data with an iterator
    {
        var stmt2 = try db.prepare("SELECT name, age FROM user");
        defer stmt2.deinit();

        const RowType = struct {
            name: Text,
            age: usize,
        };

        var iter = try stmt2.iterator(RowType, .{});

        var rows = std.ArrayList(RowType).init(allocator);
        while (true) {
            const row = (try iter.nextAlloc(allocator, .{})) orelse break;
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
}

test "sqlite: failing open" {
    var db: Db = undefined;
    const res = db.init(.{
        .open_flags = .{},
        .mode = .{ .File = "/tmp/not_existing.db" },
    });
    testing.expectError(error.SQLiteCantOpen, res);
}

test "sqlite: failing prepare statement" {
    var db = try getTestDb();

    const result = db.prepare("SELECT id FROM foobar");
    testing.expectError(error.SQLiteError, result);

    const detailed_err = db.getDetailedError();
    testing.expectEqual(@as(usize, 1), detailed_err.code);
    testing.expectEqualStrings("no such table: foobar", detailed_err.message);
}

fn getTestDb() !Db {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var mode = dbMode(&fba.allocator);

    var db: Db = undefined;
    try db.init(.{
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .mode = mode,
    });

    return db;
}

fn tmpDbPath(allocator: *mem.Allocator) ![:0]const u8 {
    const tmp_dir = testing.tmpDir(.{});

    const path = try std.fs.path.join(allocator, &[_][]const u8{
        "zig-cache",
        "tmp",
        &tmp_dir.sub_path,
        "zig-sqlite.db",
    });
    defer allocator.free(path);

    return allocator.dupeZ(u8, path);
}

fn dbMode(allocator: *mem.Allocator) Db.Mode {
    return if (build_options.in_memory) blk: {
        break :blk .{ .Memory = {} };
    } else blk: {
        const path = tmpDbPath(allocator) catch unreachable;

        std.fs.cwd().deleteFile(path) catch {};
        break :blk .{ .File = path };
    };
}
