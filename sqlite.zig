const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const debug = std.debug;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const testing = std.testing;

pub const c = @import("c.zig").c;
const versionGreaterThanOrEqualTo = @import("c.zig").versionGreaterThanOrEqualTo;

pub const ParsedQuery = @import("query.zig").ParsedQuery;

const errors = @import("errors.zig");
pub const errorFromResultCode = errors.errorFromResultCode;
pub const Error = errors.Error;
pub const DetailedError = errors.DetailedError;
const getLastDetailedErrorFromDb = errors.getLastDetailedErrorFromDb;
const getDetailedErrorFromResultCode = errors.getDetailedErrorFromResultCode;

const getTestDb = @import("test.zig").getTestDb;
pub const vtab = @import("vtab.zig");
const helpers = @import("helpers.zig");

test {
    _ = @import("vtab.zig");
}

const logger = std.log.scoped(.sqlite);

/// Text is used to represent a SQLite TEXT value when binding a parameter or reading a column.
pub const Text = struct { data: []const u8 };

/// ZeroBlob is a blob with a fixed length containing only zeroes.
///
/// A ZeroBlob is intended to serve as a placeholder; content can later be written with incremental i/o.
///
/// Here is an example allowing you to write up to 1024 bytes to a blob with incremental i/o.
///
///    try db.exec("INSERT INTO user VALUES(1, ?)", .{}, .{sqlite.ZeroBlob{ .length = 1024 }});
///    const row_id = db.getLastInsertRowID();
///
///    var blob = try db.openBlob(.main, "user", "data", row_id, .{ .write = true });
///
///    var blob_writer = blob.writer();
///    try blob_writer.writeAll("foobar");
///
///    try blob.close();
///
/// Search for "zeroblob" on https://sqlite.org/c3ref/blob_open.html for more details.
pub const ZeroBlob = struct {
    length: usize,
};

/// Blob is a wrapper for a sqlite BLOB.
///
/// This type is useful when reading or binding data and for doing incremental i/o.
pub const Blob = struct {
    const Self = @This();

    pub const OpenFlags = struct {
        read: bool = true,
        write: bool = false,
    };

    pub const DatabaseName = union(enum) {
        main,
        temp,
        attached: [:0]const u8,

        fn toString(self: @This()) [:0]const u8 {
            return switch (self) {
                .main => "main",
                .temp => "temp",
                .attached => |name| name,
            };
        }
    };

    // Used when reading or binding data.
    data: []const u8,

    // Used for incremental i/o.
    handle: *c.sqlite3_blob = undefined,
    offset: c_int = 0,
    size: c_int = 0,

    /// close closes the blob.
    pub fn close(self: *Self) Error!void {
        const result = c.sqlite3_blob_close(self.handle);
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }
    }

    pub const Reader = io.Reader(*Self, errors.Error, read);

    /// reader returns a io.Reader.
    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    fn read(self: *Self, buffer: []u8) Error!usize {
        if (self.offset >= self.size) {
            return 0;
        }

        var tmp_buffer = blk: {
            const remaining = @intCast(usize, self.size) - @intCast(usize, self.offset);
            break :blk if (buffer.len > remaining) buffer[0..remaining] else buffer;
        };

        const result = c.sqlite3_blob_read(
            self.handle,
            tmp_buffer.ptr,
            @intCast(c_int, tmp_buffer.len),
            self.offset,
        );
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }

        self.offset += @intCast(c_int, tmp_buffer.len);

        return tmp_buffer.len;
    }

    pub const Writer = io.Writer(*Self, Error, write);

    /// writer returns a io.Writer.
    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    fn write(self: *Self, data: []const u8) Error!usize {
        const result = c.sqlite3_blob_write(
            self.handle,
            data.ptr,
            @intCast(c_int, data.len),
            self.offset,
        );
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }

        self.offset += @intCast(c_int, data.len);

        return data.len;
    }

    /// Reset the offset used for reading and writing.
    pub fn reset(self: *Self) void {
        self.offset = 0;
    }

    pub const ReopenError = error{
        CannotReopenBlob,
    };

    /// reopen moves this blob to another row of the same table.
    ///
    /// See https://sqlite.org/c3ref/blob_reopen.html.
    pub fn reopen(self: *Self, row: i64) ReopenError!void {
        const result = c.sqlite3_blob_reopen(self.handle, row);
        if (result != c.SQLITE_OK) {
            return error.CannotReopenBlob;
        }

        self.size = c.sqlite3_blob_bytes(self.handle);
        self.offset = 0;
    }

    pub const OpenError = error{
        CannotOpenBlob,
    };

    /// open opens a blob for incremental i/o.
    fn open(db: *c.sqlite3, db_name: DatabaseName, table: [:0]const u8, column: [:0]const u8, row: i64, comptime flags: OpenFlags) OpenError!Blob {
        comptime if (!flags.read and !flags.write) {
            @compileError("must open a blob for either read, write or both");
        };

        const open_flags: c_int = if (flags.write) 1 else 0;

        var blob: Blob = undefined;
        const result = c.sqlite3_blob_open(
            db,
            db_name.toString(),
            table,
            column,
            row,
            open_flags,
            @ptrCast([*c]?*c.sqlite3_blob, &blob.handle),
        );
        if (result == c.SQLITE_MISUSE) debug.panic("sqlite misuse while opening a blob", .{});
        if (result != c.SQLITE_OK) {
            return error.CannotOpenBlob;
        }

        blob.size = c.sqlite3_blob_bytes(blob.handle);
        blob.offset = 0;

        return blob;
    }
};

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

/// Diagnostics can be used by the library to give more information in case of failures.
pub const Diagnostics = struct {
    message: []const u8 = "",
    err: ?DetailedError = null,

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.err) |err| {
            if (self.message.len > 0) {
                _ = try writer.print("{{message: {s}, detailed error: {s}}}", .{ self.message, err });
                return;
            }

            _ = try err.format(fmt, options, writer);
            return;
        }

        if (self.message.len > 0) {
            _ = try writer.write(self.message);
            return;
        }

        _ = try writer.write("none");
    }
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

    /// shared_cache controls whether or not concurrent SQLite
    /// connections share the same cache.
    ///
    /// Defaults to false.
    shared_cache: bool = false,

    /// if provided, diags will be populated in case of failures.
    diags: ?*Diagnostics = null,
};

fn isThreadSafe() bool {
    return c.sqlite3_threadsafe() > 0;
}

/// Db is a wrapper around a SQLite database, providing high-level functions for executing queries.
/// A Db can be opened with a file database or a in-memory database:
///
///     // File database
///     var db = try sqlite.Db.init(.{ .mode = .{ .File = "/tmp/data.db" } });
///
///     // In memory database
///     var db = try sqlite.Db.init(.{ .mode = .{ .Memory = {} } });
///
pub const Db = struct {
    const Self = @This();

    db: *c.sqlite3,

    /// Mode determines how the database will be opened.
    ///
    /// * File means opening the database at this path with sqlite3_open_v2.
    /// * Memory means opening the database in memory.
    ///   This works by opening the :memory: path with sqlite3_open_v2 with the flag SQLITE_OPEN_MEMORY.
    pub const Mode = union(enum) {
        File: [:0]const u8,
        Memory,
    };

    /// OpenFlags contains various flags used when opening a SQLite databse.
    ///
    /// These flags partially map to the flags defined in https://sqlite.org/c3ref/open.html
    ///  * write=false and create=false means SQLITE_OPEN_READONLY
    ///  * write=true and create=false means SQLITE_OPEN_READWRITE
    ///  * write=true and create=true means SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE
    pub const OpenFlags = struct {
        write: bool = false,
        create: bool = false,
    };

    pub const InitError = error{
        SQLiteBuildNotThreadSafe,
    } || Error;

    /// init creates a database with the provided options.
    pub fn init(options: InitOptions) InitError!Self {
        var dummy_diags = Diagnostics{};
        var diags = options.diags orelse &dummy_diags;

        // Validate the threading mode
        if (options.threading_mode != .SingleThread and !isThreadSafe()) {
            return error.SQLiteBuildNotThreadSafe;
        }

        // Compute the flags
        var flags: c_int = c.SQLITE_OPEN_URI;
        flags |= @as(c_int, if (options.open_flags.write) c.SQLITE_OPEN_READWRITE else c.SQLITE_OPEN_READONLY);
        if (options.open_flags.create) {
            flags |= c.SQLITE_OPEN_CREATE;
        }
        if (options.shared_cache) {
            flags |= c.SQLITE_OPEN_SHAREDCACHE;
        }
        switch (options.threading_mode) {
            .MultiThread => flags |= c.SQLITE_OPEN_NOMUTEX,
            .Serialized => flags |= c.SQLITE_OPEN_FULLMUTEX,
            else => {},
        }

        switch (options.mode) {
            .File => |path| {
                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(path.ptr, &db, flags, null);
                if (result != c.SQLITE_OK or db == null) {
                    if (db) |v| {
                        diags.err = getLastDetailedErrorFromDb(v);
                    } else {
                        diags.err = getDetailedErrorFromResultCode(result);
                    }
                    return errors.errorFromResultCode(result);
                }

                return Self{ .db = db.? };
            },
            .Memory => {
                flags |= c.SQLITE_OPEN_MEMORY;

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(":memory:", &db, flags, null);
                if (result != c.SQLITE_OK or db == null) {
                    if (db) |v| {
                        diags.err = getLastDetailedErrorFromDb(v);
                    } else {
                        diags.err = getDetailedErrorFromResultCode(result);
                    }
                    return errors.errorFromResultCode(result);
                }

                return Self{ .db = db.? };
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

    fn getPragmaQuery(comptime name: []const u8, comptime arg: ?[]const u8) []const u8 {
        if (arg) |a| {
            return std.fmt.comptimePrint("PRAGMA {s} = {s}", .{ name, a });
        }
        return std.fmt.comptimePrint("PRAGMA {s}", .{name});
    }

    /// getLastInsertRowID returns the last inserted rowid.
    pub fn getLastInsertRowID(self: *Self) i64 {
        const rowid = c.sqlite3_last_insert_rowid(self.db);
        return rowid;
    }

    /// pragmaAlloc is like `pragma` but can allocate memory.
    ///
    /// Useful when the pragma command returns text, for example:
    ///
    ///     const journal_mode = try db.pragma([]const u8, allocator, .{}, "journal_mode", null);
    ///
    pub fn pragmaAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, options: QueryOptions, comptime name: []const u8, comptime arg: ?[]const u8) !?Type {
        comptime var query = getPragmaQuery(name, arg);

        var stmt = try self.prepare(query);
        defer stmt.deinit();

        return try stmt.oneAlloc(Type, allocator, options, .{});
    }

    /// pragma is a convenience function to use the PRAGMA statement.
    ///
    /// Here is how to set a pragma value:
    ///
    ///     _ = try db.pragma(void, .{}, "foreign_keys", "1");
    ///
    /// Here is how to query a pragma value:
    ///
    ///     const journal_mode = try db.pragma([128:0]const u8, .{}, "journal_mode", null);
    ///
    /// The pragma name must be known at comptime.
    ///
    /// This cannot allocate memory. If your pragma command returns text you must use an array or call `pragmaAlloc`.
    pub fn pragma(self: *Self, comptime Type: type, options: QueryOptions, comptime name: []const u8, comptime arg: ?[]const u8) !?Type {
        comptime var query = getPragmaQuery(name, arg);

        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();

        return try stmt.one(Type, options, .{});
    }

    /// exec is a convenience function which prepares a statement and executes it directly.
    pub fn exec(self: *Self, comptime query: []const u8, options: QueryOptions, values: anytype) !void {
        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();
        try stmt.exec(options, values);
    }

    /// execDynamic is a convenience function which prepares a statement and executes it directly.
    pub fn execDynamic(self: *Self, query: []const u8, options: QueryOptions, values: anytype) !void {
        var stmt = try self.prepareDynamicWithDiags(query, options);
        defer stmt.deinit();
        try stmt.exec(options, values);
    }

    /// execAlloc is like `exec` but can allocate memory.
    pub fn execAlloc(self: *Self, allocator: mem.Allocator, comptime query: []const u8, options: QueryOptions, values: anytype) !void {
        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();
        try stmt.execAlloc(allocator, options, values);
    }

    /// one is a convenience function which prepares a statement and reads a single row from the result set.
    pub fn one(self: *Self, comptime Type: type, comptime query: []const u8, options: QueryOptions, values: anytype) !?Type {
        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();
        return try stmt.one(Type, options, values);
    }

    /// oneDynamic is a convenience function which prepares a statement and reads a single row from the result set.
    pub fn oneDynamic(self: *Self, comptime Type: type, query: []const u8, options: QueryOptions, values: anytype) !?Type {
        var stmt = try self.prepareDynamicWithDiags(query, options);
        defer stmt.deinit();
        return try stmt.one(Type, options, values);
    }

    /// oneAlloc is like `one` but can allocate memory.
    pub fn oneAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, comptime query: []const u8, options: QueryOptions, values: anytype) !?Type {
        var stmt = try self.prepareWithDiags(query, options);
        defer stmt.deinit();
        return try stmt.oneAlloc(Type, allocator, options, values);
    }

    /// oneDynamicAlloc is like `oneDynamic` but can allocate memory.
    pub fn oneDynamicAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, query: []const u8, options: QueryOptions, values: anytype) !?Type {
        var stmt = try self.prepareDynamicWithDiags(query, options);
        defer stmt.deinit();
        return try stmt.oneAlloc(Type, allocator, options, values);
    }

    /// prepareWithDiags is like `prepare` but takes an additional options argument.
    pub fn prepareWithDiags(self: *Self, comptime query: []const u8, options: QueryOptions) DynamicStatement.PrepareError!blk: {
        @setEvalBranchQuota(100000);
        break :blk StatementType(.{}, query);
    } {
        @setEvalBranchQuota(100000);
        return StatementType(.{}, query).prepare(self, options, 0);
    }

    /// prepareDynamicWithDiags is like `prepareDynamic` but takes an additional options argument.
    pub fn prepareDynamicWithDiags(self: *Self, query: []const u8, options: QueryOptions) DynamicStatement.PrepareError!DynamicStatement {
        return try DynamicStatement.prepare(self, query, options, 0);
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
    /// If you want additional error information in case of failures, use `prepareWithDiags`.
    pub fn prepare(self: *Self, comptime query: []const u8) DynamicStatement.PrepareError!blk: {
        @setEvalBranchQuota(100000);
        break :blk StatementType(.{}, query);
    } {
        @setEvalBranchQuota(100000);
        return StatementType(.{}, query).prepare(self, .{}, 0);
    }

    /// prepareDynamic prepares a dynamic statement for the `query` provided.
    ///
    /// The query will be directly sent to create statement without analysing.
    /// That means such statements does not support comptime type-checking.
    ///
    /// Dynamic statement supports host parameter names. See `DynamicStatement`.
    pub fn prepareDynamic(self: *Self, query: []const u8) DynamicStatement.PrepareError!DynamicStatement {
        return try self.prepareDynamicWithDiags(query, .{});
    }

    /// rowsAffected returns the number of rows affected by the last statement executed.
    pub fn rowsAffected(self: *Self) usize {
        return @intCast(usize, c.sqlite3_changes(self.db));
    }

    /// openBlob opens a blob for incremental i/o.
    ///
    /// Incremental i/o enables writing and reading data using a std.io.Writer and std.io.Reader:
    ///  * the writer type wraps sqlite3_blob_write, see https://sqlite.org/c3ref/blob_write.html
    ///  * the reader type wraps sqlite3_blob_read, see https://sqlite.org/c3ref/blob_read.html
    ///
    /// Note that:
    /// * the blob must exist before writing; you must use INSERT to create one first (either with data or using a placeholder with ZeroBlob).
    /// * the blob is not extensible, if you want to change the blob size you must use an UPDATE statement.
    ///
    /// You can get a std.io.Writer to write data to the blob:
    ///
    ///     var blob = try db.openBlob(.main, "mytable", "mycolumn", 1, .{ .write = true });
    ///     var blob_writer = blob.writer();
    ///
    ///     try blob_writer.writeAll(my_data);
    ///
    /// You can get a std.io.Reader to read the blob data:
    ///
    ///     var blob = try db.openBlob(.main, "mytable", "mycolumn", 1, .{});
    ///     var blob_reader = blob.reader();
    ///
    ///     const data = try blob_reader.readAlloc(allocator);
    ///
    /// See https://sqlite.org/c3ref/blob_open.html for more details on incremental i/o.
    ///
    pub fn openBlob(self: *Self, db_name: Blob.DatabaseName, table: [:0]const u8, column: [:0]const u8, row: i64, comptime flags: Blob.OpenFlags) Blob.OpenError!Blob {
        return Blob.open(self.db, db_name, table, column, row, flags);
    }

    /// savepoint starts a new named transaction.
    ///
    /// The returned type is a helper useful for managing commits and rollbacks, for example:
    ///
    ///     var savepoint = try db.savepoint("foobar");
    ///     defer savepoint.rollback();
    ///
    ///     try db.exec("INSERT INTO foo(id, name) VALUES(?, ?)", .{ 1, "foo" });
    ///
    ///     savepoint.commit();
    ///
    pub fn savepoint(self: *Self, name: []const u8) Savepoint.InitError!Savepoint {
        return Savepoint.init(self, name);
    }

    /// CreateFunctionFlag controls the flags used when creating a custom SQL function.
    /// See https://sqlite.org/c3ref/c_deterministic.html.
    ///
    /// The flags SQLITE_UTF16LE, SQLITE_UTF16BE are not supported yet. SQLITE_UTF8 is the default and always on.
    ///
    /// SQLITE_DIRECTONLY is only available on SQLite >= 3.30.0 so we create a different type based on the SQLite version.
    ///
    /// TODO(vincent): allow these flags when we know how to handle UTF16 data.
    /// TODO(vincent): can we refactor this somehow to share the common stuff ?
    pub const CreateFunctionFlag = if (c.SQLITE_VERSION_NUMBER >= 3030000) struct {
        /// Equivalent to SQLITE_DETERMINISTIC
        deterministic: bool = true,
        /// Equivalent to SQLITE_DIRECTONLY
        direct_only: bool = true,

        fn toCFlags(self: *const @This()) c_int {
            var flags: c_int = c.SQLITE_UTF8;
            if (self.deterministic) {
                flags |= c.SQLITE_DETERMINISTIC;
            }
            if (self.direct_only) {
                flags |= c.SQLITE_DIRECTONLY;
            }
            return flags;
        }
    } else struct {
        /// Equivalent to SQLITE_DETERMINISTIC
        deterministic: bool = true,

        fn toCFlags(self: *const @This()) c_int {
            var flags: c_int = c.SQLITE_UTF8;
            if (self.deterministic) {
                flags |= c.SQLITE_DETERMINISTIC;
            }
            return flags;
        }
    };

    /// Creates an aggregate SQLite function with the given name.
    ///
    /// `step_func` and `finalize_func` must be two functions. The first argument of both functions _must_ be of the type FunctionContext.
    ///
    /// When the SQLite function is called in a statement, `step_func` will be called for each row with the input arguments.
    /// Each SQLite argument is converted to a Zig value according to the following rules:
    /// * TEXT values can be either sqlite.Text or []const u8
    /// * BLOB values can be either sqlite.Blob or []const u8
    /// * INTEGER values can be any Zig integer
    /// * REAL values can be any Zig float
    ///
    /// The final result of the SQL function call will be what `finalize_func` returns.
    pub fn createAggregateFunction(self: *Self, comptime name: [:0]const u8, user_ctx: anytype, comptime step_func: anytype, comptime finalize_func: anytype, comptime create_flags: CreateFunctionFlag) Error!void {
        // Validate the functions

        const step_fn_info = switch (@typeInfo(@TypeOf(step_func))) {
            .Fn => |fn_info| fn_info,
            else => @compileError("cannot use func, expecting a function"),
        };
        if (step_fn_info.is_generic) @compileError("step function can't be generic");
        if (step_fn_info.is_var_args) @compileError("step function can't be variadic");

        const finalize_fn_info = switch (@typeInfo(@TypeOf(finalize_func))) {
            .Fn => |fn_info| fn_info,
            else => @compileError("cannot use func, expecting a function"),
        };
        if (finalize_fn_info.args.len != 1) @compileError("finalize function must take exactly one argument");
        if (finalize_fn_info.is_generic) @compileError("finalize function can't be generic");
        if (finalize_fn_info.is_var_args) @compileError("finalize function can't be variadic");

        if (step_fn_info.args[0].arg_type.? != finalize_fn_info.args[0].arg_type.?) {
            @compileError("both step and finalize functions must have the same first argument and it must be a FunctionContext");
        }
        if (step_fn_info.args[0].arg_type.? != FunctionContext) {
            @compileError("both step and finalize functions must have a first argument of type FunctionContext");
        }

        // subtract the context argument
        const real_args_len = step_fn_info.args.len - 1;

        //

        const flags = create_flags.toCFlags();

        const result = c.sqlite3_create_function_v2(
            self.db,
            name,
            real_args_len,
            flags,
            user_ctx,
            null, // xFunc
            struct {
                fn xStep(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.C) void {
                    debug.assert(argc == real_args_len);

                    const sqlite_args = argv.?[0..real_args_len];

                    var args: std.meta.ArgsTuple(@TypeOf(step_func)) = undefined;

                    // Pass the function context
                    args[0] = FunctionContext{ .ctx = ctx };

                    comptime var i: usize = 0;
                    inline while (i < real_args_len) : (i += 1) {
                        // Remember the firt argument is always the function context
                        const arg = step_fn_info.args[i + 1];
                        const arg_ptr = &args[i + 1];

                        const ArgType = arg.arg_type.?;
                        helpers.setTypeFromValue(ArgType, arg_ptr, sqlite_args[i].?);
                    }

                    @call(.{}, step_func, args);
                }
            }.xStep,
            struct {
                fn xFinal(ctx: ?*c.sqlite3_context) callconv(.C) void {
                    var args: std.meta.ArgsTuple(@TypeOf(finalize_func)) = undefined;

                    // Pass the function context
                    args[0] = FunctionContext{ .ctx = ctx };

                    const result = @call(.{}, finalize_func, args);

                    helpers.setResult(ctx, result);
                }
            }.xFinal,
            null,
        );
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }
    }

    /// Creates a scalar SQLite function with the given name.
    ///
    /// When the SQLite function is called in a statement, `func` will be called with the input arguments.
    /// Each SQLite argument is converted to a Zig value according to the following rules:
    /// * TEXT values can be either sqlite.Text or []const u8
    /// * BLOB values can be either sqlite.Blob or []const u8
    /// * INTEGER values can be any Zig integer
    /// * REAL values can be any Zig float
    ///
    /// The return type of the function is converted to a SQLite value according to the same rules but reversed.
    ///
    pub fn createScalarFunction(self: *Self, func_name: [:0]const u8, comptime func: anytype, comptime create_flags: CreateFunctionFlag) Error!void {
        const Type = @TypeOf(func);

        const fn_info = switch (@typeInfo(Type)) {
            .Fn => |fn_info| fn_info,
            else => @compileError("expecting a function"),
        };
        if (fn_info.is_generic) @compileError("function can't be generic");
        if (fn_info.is_var_args) @compileError("function can't be variadic");

        const ArgTuple = std.meta.ArgsTuple(Type);

        //

        const flags = create_flags.toCFlags();

        const result = c.sqlite3_create_function_v2(
            self.db,
            func_name,
            fn_info.args.len,
            flags,
            null,
            struct {
                fn xFunc(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.C) void {
                    debug.assert(argc == fn_info.args.len);

                    const sqlite_args = argv.?[0..fn_info.args.len];

                    var fn_args: ArgTuple = undefined;
                    inline for (fn_info.args) |arg, i| {
                        const ArgType = arg.arg_type.?;
                        helpers.setTypeFromValue(ArgType, &fn_args[i], sqlite_args[i].?);
                    }

                    const result = @call(.{}, func, fn_args);

                    helpers.setResult(ctx, result);
                }
            }.xFunc,
            null,
            null,
            null,
        );
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }
    }

    /// This is a convenience function to run statements that do not need
    /// bindings to values, but have multiple commands inside.
    ///
    /// Exmaple: 'create table a(); create table b();'
    pub fn execMulti(self: *Self, query: []const u8, options: QueryOptions) !void {
        var new_options = options;
        var sql_tail_ptr: ?[*:0]const u8 = null;
        new_options.sql_tail_ptr = &sql_tail_ptr;

        while (true) {
            // continuously prepare and execute (dynamically as there's no
            // values to bind in this case)
            var stmt: DynamicStatement = undefined;
            if (sql_tail_ptr != null) {
                const new_query = std.mem.span(sql_tail_ptr.?);
                if (new_query.len == 0) break;
                stmt = try self.prepareDynamicWithDiags(new_query, new_options);
            } else {
                stmt = try self.prepareDynamicWithDiags(query, new_options);
            }

            defer stmt.deinit();
            try stmt.exec(new_options, .{});
        }
    }

    pub fn createVirtualTable(
        self: *Self,
        comptime name: [:0]const u8,
        module_context: *vtab.ModuleContext,
        comptime Table: type,
    ) !void {
        const VirtualTableType = vtab.VirtualTable(name, Table);

        const result = c.sqlite3_create_module_v2(
            self.db,
            name,
            &VirtualTableType.module,
            module_context,
            null,
        );
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }
    }
};

/// FunctionContext is the context passed as first parameter in the `step` and `finalize` functions used with `createAggregateFunction`.
/// It provides two functions:
/// * userContext to retrieve the user provided context
/// * aggregateContext to create or retrieve the aggregate context
///
/// Both functions take a type as parameter and take care of casting so the caller doesn't have to do it.
pub const FunctionContext = struct {
    ctx: ?*c.sqlite3_context,

    pub fn userContext(self: FunctionContext, comptime Type: type) ?Type {
        const Types = splitPtrTypes(Type);

        if (c.sqlite3_user_data(self.ctx)) |value| {
            return @ptrCast(
                Types.PointerType,
                @alignCast(@alignOf(Types.ValueType), value),
            );
        }
        return null;
    }

    pub fn aggregateContext(self: FunctionContext, comptime Type: type) ?Type {
        const Types = splitPtrTypes(Type);

        if (c.sqlite3_aggregate_context(self.ctx, @sizeOf(Types.ValueType))) |value| {
            return @ptrCast(
                Types.PointerType,
                @alignCast(@alignOf(Types.ValueType), value),
            );
        }
        return null;
    }

    const SplitPtrTypes = struct {
        ValueType: type,
        PointerType: type,
    };

    fn splitPtrTypes(comptime Type: type) SplitPtrTypes {
        switch (@typeInfo(Type)) {
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .One => return SplitPtrTypes{
                    .ValueType = ptr_info.child,
                    .PointerType = Type,
                },
                else => @compileError("cannot use type " ++ @typeName(Type) ++ ", must be a single-item pointer"),
            },
            .Void => return SplitPtrTypes{
                .ValueType = void,
                .PointerType = undefined,
            },
            else => @compileError("cannot use type " ++ @typeName(Type) ++ ", must be a single-item pointer"),
        }
    }
};

/// Savepoint is a helper type for managing savepoints.
///
/// A savepoint creates a transaction like BEGIN/COMMIT but they're named and can be nested.
/// See https://sqlite.org/lang_savepoint.html.
///
/// You can create a savepoint like this:
///
///     var savepoint = try db.savepoint("foobar");
///     defer savepoint.rollback();
///
///     ...
///
///     Savepoint.commit();
///
/// This is equivalent to BEGIN/COMMIT/ROLLBACK.
///
/// Savepoints are more useful for _nesting_ transactions, for example:
///
///     var savepoint = try db.savepoint("outer");
///     defer savepoint.rollback();
///
///     try db.exec("INSERT INTO foo(id, name) VALUES(?, ?)", .{ 1, "foo" });
///
///     {
///         var savepoint2 = try db.savepoint("inner");
///         defer savepoint2.rollback();
///
///         var i: usize = 0;
///         while (i < 30) : (i += 1) {
///             try db.exec("INSERT INTO foo(id, name) VALUES(?, ?)", .{ 2, "bar" });
///         }
///
///         savepoint2.commit();
///     }
///
///     try db.exec("UPDATE bar SET processed = ? WHERE id = ?", .{ true, 20 });
///
///     savepoint.commit();
///
/// In this example if any query in the inner transaction fail, all previously executed queries are discarded but the outer transaction is untouched.
///
pub const Savepoint = struct {
    const Self = @This();

    db: *Db,
    committed: bool,

    commit_stmt: DynamicStatement,
    rollback_stmt: DynamicStatement,

    pub const InitError = error{
        SavepointNameTooShort,
        SavepointNameTooLong,
        SavepointNameInvalid,

        // From execDynamic
        ExecReturnedData,
    } || std.fmt.AllocPrintError || Error;

    fn init(db: *Db, name: []const u8) InitError!Self {
        if (name.len < 1) return error.SavepointNameTooShort;
        if (name.len > 20) return error.SavepointNameTooLong;
        if (!std.ascii.isAlphabetic(name[0])) return error.SavepointNameInvalid;
        for (name) |b| {
            if (b != '_' and !std.ascii.isAlphanumeric(b)) {
                return error.SavepointNameInvalid;
            }
        }

        var buffer: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        var allocator = fba.allocator();

        const commit_query = try std.fmt.allocPrint(allocator, "RELEASE SAVEPOINT {s}", .{name});
        const rollback_query = try std.fmt.allocPrint(allocator, "ROLLBACK TRANSACTION TO SAVEPOINT {s}", .{name});

        var res = Self{
            .db = db,
            .committed = false,
            .commit_stmt = try db.prepareDynamic(commit_query),
            .rollback_stmt = try db.prepareDynamic(rollback_query),
        };

        try res.db.execDynamic(
            try std.fmt.allocPrint(allocator, "SAVEPOINT {s}", .{name}),
            .{},
            .{},
        );

        return res;
    }

    pub fn commit(self: *Self) void {
        self.commit_stmt.exec(.{}, .{}) catch |err| {
            const detailed_error = self.db.getDetailedError();
            logger.err("unable to release savepoint, error: {}, message: {s}", .{ err, detailed_error });
        };
        self.committed = true;
    }

    pub fn rollback(self: *Self) void {
        defer {
            self.commit_stmt.deinit();
            self.rollback_stmt.deinit();
        }

        if (self.committed) return;

        self.rollback_stmt.exec(.{}, .{}) catch |err| {
            const detailed_error = self.db.getDetailedError();
            std.debug.panic("unable to rollback transaction, error: {}, message: {s}\n", .{ err, detailed_error });
        };
    }
};

pub const QueryOptions = struct {
    /// if provided, diags will be populated in case of failures.
    diags: ?*Diagnostics = null,

    /// if provided, sql_tail_ptr will point to the last uncompiled statement
    /// in the prepare() call. this is useful for multiple-statements being
    /// processed.
    sql_tail_ptr: ?*?[*:0]const u8 = null,
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
///     while (try iter.next(.{})) |row| {
///         ...
///     }
///
/// The iterator _must not_ outlive the statement.
pub fn Iterator(comptime Type: type) type {
    return struct {
        const Self = @This();

        const TypeInfo = @typeInfo(Type);

        db: *c.sqlite3,
        stmt: *c.sqlite3_stmt,

        // next scans the next row using the prepared statement.
        // If it returns null iterating is done.
        //
        // This cannot allocate memory. If you need to read TEXT or BLOB columns you need to use arrays or alternatively call nextAlloc.
        pub fn next(self: *Self, options: QueryOptions) !?Type {
            var dummy_diags = Diagnostics{};
            var diags = options.diags orelse &dummy_diags;

            var result = c.sqlite3_step(self.stmt);
            if (result == c.SQLITE_DONE) {
                return null;
            }
            if (result != c.SQLITE_ROW) {
                diags.err = getLastDetailedErrorFromDb(self.db);
                return errors.errorFromResultCode(result);
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
                .Enum => |TI| {
                    debug.assert(columns == 1);

                    if (comptime std.meta.trait.isZigString(Type.BaseType)) {
                        @compileError("cannot read into type " ++ @typeName(Type) ++ " ; BaseType " ++ @typeName(Type.BaseType) ++ " requires allocation, use nextAlloc or oneAlloc");
                    }

                    if (@typeInfo(Type.BaseType) == .Int) {
                        const inner_value = try self.readField(Type.BaseType, options, 0);
                        return @intToEnum(Type, @intCast(TI.tag_type, inner_value));
                    }

                    @compileError("enum column " ++ @typeName(Type) ++ " must have a BaseType of either string or int");
                },
                .Struct => {
                    std.debug.assert(columns == TypeInfo.Struct.fields.len);
                    return try self.readStruct(options);
                },
                else => @compileError("cannot read into type " ++ @typeName(Type) ++ " ; if dynamic memory allocation is required use nextAlloc or oneAlloc"),
            }
        }

        // nextAlloc is like `next` but can allocate memory.
        pub fn nextAlloc(self: *Self, allocator: mem.Allocator, options: QueryOptions) !?Type {
            var dummy_diags = Diagnostics{};
            var diags = options.diags orelse &dummy_diags;

            var result = c.sqlite3_step(self.stmt);
            if (result == c.SQLITE_DONE) {
                return null;
            }
            if (result != c.SQLITE_ROW) {
                diags.err = getLastDetailedErrorFromDb(self.db);
                return errors.errorFromResultCode(result);
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
                    return try self.readPointer(Type, .{
                        .allocator = allocator,
                    }, 0);
                },
                .Enum => |TI| {
                    debug.assert(columns == 1);

                    const inner_value = try self.readField(Type.BaseType, .{ .allocator = allocator }, 0);

                    if (comptime std.meta.trait.isZigString(Type.BaseType)) {
                        // The inner value is never returned to the user, we must free it ourselves.
                        defer allocator.free(inner_value);

                        // TODO(vincent): don't use unreachable
                        return std.meta.stringToEnum(Type, inner_value) orelse unreachable;
                    }
                    if (@typeInfo(Type.BaseType) == .Int) {
                        return @intToEnum(Type, @intCast(TI.tag_type, inner_value));
                    }
                    @compileError("enum column " ++ @typeName(Type) ++ " must have a BaseType of either string or int");
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
        // We also require the array to be the exact size of the data, or have a sentinel;
        // otherwise we have no way of communicating the end of the data to the caller.
        //
        // If the array is too small for the data an error will be returned.
        fn readArray(self: *Self, comptime ArrayType: type, _i: usize) !ArrayType {
            const i = @intCast(c_int, _i);
            const type_info = @typeInfo(ArrayType);

            var ret: ArrayType = undefined;
            switch (type_info) {
                .Array => |arr| {
                    switch (arr.child) {
                        u8 => {
                            const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));

                            if (arr.sentinel) |sentinel_ptr| {
                                // An array with a sentinel need to be as big as the data, + 1 byte for the sentinel.
                                if (size >= @as(usize, arr.len)) {
                                    return error.ArrayTooSmall;
                                }

                                // Set the sentinel in the result at the correct position.
                                const sentinel = @ptrCast(*const arr.child, sentinel_ptr).*;
                                ret[size] = sentinel;
                            } else if (size != arr.len) {
                                // An array without a sentinel must have the exact same size as the data because we can't
                                // communicate the real size to the caller.
                                return error.ArraySizeMismatch;
                            }

                            const data = c.sqlite3_column_blob(self.stmt, i);
                            if (data != null) {
                                const ptr = @ptrCast([*c]const u8, data)[0..size];

                                mem.copy(u8, ret[0..], ptr);
                            }
                        },
                        else => @compileError("cannot read into array of " ++ @typeName(arr.child)),
                    }
                },
                else => @compileError("cannot read into type " ++ @typeName(ret)),
            }
            return ret;
        }

        // readInt reads a sqlite INTEGER column into an integer.
        fn readInt(self: *Self, comptime IntType: type, i: usize) error{Workaround}!IntType { // TODO remove the workaround once https://github.com/ziglang/zig/issues/5149 is resolved or if we actually return an error
            const n = c.sqlite3_column_int64(self.stmt, @intCast(c_int, i));
            return @intCast(IntType, n);
        }

        // readFloat reads a sqlite REAL column into a float.
        fn readFloat(self: *Self, comptime FloatType: type, i: usize) error{Workaround}!FloatType { // TODO remove the workaround once https://github.com/ziglang/zig/issues/5149 is resolved or if we actually return an error
            const d = c.sqlite3_column_double(self.stmt, @intCast(c_int, i));
            return @floatCast(FloatType, d);
        }

        // readFloat reads a sqlite INTEGER column into a bool (true is anything > 0, false is anything <= 0).
        fn readBool(self: *Self, i: usize) error{Workaround}!bool { // TODO remove the workaround once https://github.com/ziglang/zig/issues/5149 is resolved or if we actually return an error
            const d = c.sqlite3_column_int64(self.stmt, @intCast(c_int, i));
            return d > 0;
        }

        const ReadBytesMode = enum {
            Blob,
            Text,
        };

        // dupeWithSentinel is like dupe/dupeZ but allows for any sentinel value.
        fn dupeWithSentinel(comptime SliceType: type, allocator: mem.Allocator, data: []const u8) !SliceType {
            switch (@typeInfo(SliceType)) {
                .Pointer => |ptr_info| {
                    if (ptr_info.sentinel) |sentinel_ptr| {
                        const sentinel = @ptrCast(*const ptr_info.child, sentinel_ptr).*;

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
        fn readBytes(self: *Self, comptime BytesType: type, allocator: mem.Allocator, _i: usize, comptime mode: ReadBytesMode) !BytesType {
            const i = @intCast(c_int, _i);

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

        fn readPointer(self: *Self, comptime PointerType: type, options: anytype, i: usize) !PointerType {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to readPointer must be a struct");
            }
            if (!comptime std.meta.trait.hasField("allocator")(@TypeOf(options))) {
                @compileError("options passed to readPointer must have an allocator field");
            }

            var ret: PointerType = undefined;
            switch (@typeInfo(PointerType)) {
                .Pointer => |ptr| {
                    switch (ptr.size) {
                        .One => {
                            ret = try options.allocator.create(ptr.child);
                            errdefer options.allocator.destroy(ret);

                            ret.* = try self.readField(ptr.child, options, i);
                        },
                        .Slice => switch (ptr.child) {
                            u8 => ret = try self.readBytes(PointerType, options.allocator, i, .Text),
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
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to readOptional must be a struct");
            }

            var ret: OptionalType = undefined;
            switch (@typeInfo(OptionalType)) {
                .Optional => |opt| {
                    // Easy way to know if the column represents a null value.
                    const value = c.sqlite3_column_value(self.stmt, @intCast(c_int, _i));
                    const datatype = c.sqlite3_value_type(value);

                    if (datatype == c.SQLITE_NULL) {
                        return null;
                    } else {
                        const val = try self.readField(opt.child, options, _i);
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
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to readStruct must be a struct");
            }

            var value: Type = undefined;

            inline for (@typeInfo(Type).Struct.fields) |field, _i| {
                const i = @as(usize, _i);

                const ret = try self.readField(field.type, options, i);

                @field(value, field.name) = ret;
            }

            return value;
        }

        fn readField(self: *Self, comptime FieldType: type, options: anytype, i: usize) !FieldType {
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(options))) {
                @compileError("options passed to readField must be a struct");
            }

            const field_type_info = @typeInfo(FieldType);

            return switch (FieldType) {
                Blob => blk: {
                    if (!comptime std.meta.trait.hasField("allocator")(@TypeOf(options))) {
                        @compileError("options passed to readPointer must have an allocator field when reading a Blob");
                    }
                    break :blk try self.readBytes(Blob, options.allocator, i, .Blob);
                },
                Text => blk: {
                    if (!comptime std.meta.trait.hasField("allocator")(@TypeOf(options))) {
                        @compileError("options passed to readField must have an allocator field when reading a Text");
                    }
                    break :blk try self.readBytes(Text, options.allocator, i, .Text);
                },
                else => switch (field_type_info) {
                    .Int => try self.readInt(FieldType, i),
                    .Float => try self.readFloat(FieldType, i),
                    .Bool => try self.readBool(i),
                    .Void => {},
                    .Array => try self.readArray(FieldType, i),
                    .Pointer => try self.readPointer(FieldType, options, i),
                    .Optional => try self.readOptional(FieldType, options, i),
                    .Enum => |TI| {
                        const inner_value = try self.readField(FieldType.BaseType, options, i);

                        if (comptime std.meta.trait.isZigString(FieldType.BaseType)) {
                            // The inner value is never returned to the user, we must free it ourselves.
                            defer options.allocator.free(inner_value);

                            // TODO(vincent): don't use unreachable
                            return std.meta.stringToEnum(FieldType, inner_value) orelse unreachable;
                        }
                        if (@typeInfo(FieldType.BaseType) == .Int) {
                            return @intToEnum(FieldType, @intCast(TI.tag_type, inner_value));
                        }
                        @compileError("enum column " ++ @typeName(FieldType) ++ " must have a BaseType of either string or int");
                    },
                    .Struct => {
                        const inner_value = try self.readField(FieldType.BaseType, options, i);
                        return try FieldType.readField(options.allocator, inner_value);
                    },
                    else => @compileError("cannot populate field of type " ++ @typeName(FieldType)),
                },
            };
        }
    };
}

/// StatementType returns the type of a statement you would get by calling Db.prepare and derivatives.
///
/// Useful if you want to store a statement in a struct, for example:
///
///     const MyStatements = struct {
///         insert_stmt: sqlite.StatementType(.{}, insert_query),
///         delete_stmt: sqlite.StatementType(.{}, delete_query),
///     };
///
pub fn StatementType(comptime opts: StatementOptions, comptime query: []const u8) type {
    @setEvalBranchQuota(100000);
    return Statement(opts, ParsedQuery(query));
}

pub const StatementOptions = struct {};

/// DynamicStatement is a wrapper around a SQLite statement, providing high-level functions to execute
/// a statement and retrieve rows for SELECT queries.
///
/// The difference to `Statement` is that this type isn't bound to a single parsed query and can execute any query.
///
/// `DynamicStatement` supports "host parameter names", which can be used in a query to identify a bind marker:
///
///     SELECT email FROM users WHERE name = @name AND password = $password;
///
/// You can read more about these parameters in the sqlite documentation: https://sqlite.org/c3ref/bind_blob.html
///
/// To use these names use an anonymous struct with corresponding names like this:
///
///     const stmt = "SELECT * FROM users WHERE name = @name AND password = @pasdword";
///     const row = try stmt.one(Row, .{
///         .name = "Tankman",
///         .password = "Passw0rd",
///     });
///
/// This works regardless of the prefix you used in the query.
/// While using the same name with a different prefix is supported by sqlite, `DynamicStatement` doesn't support
/// it because we can't have multiple fields in a struct with the same name.
///
/// You can also use unnamed markers with a tuple:
///
///     const stmt = "SELECT email FROM users WHERE name = ? AND password = ?";
///     const row = try stmt.one(Row, .{"Tankman", "Passw0rd"});
///
/// You can only mix named and unnamed bind markers if:
/// * the bind values data is a tuple (without field names)
/// * the bind values data is a struct with the same field orders as in the query
/// This is because with a unnamed bind markers we use the field index in the struct as bind column; if the fields
/// are in the wrong order the query will not work correctly.
///
pub const DynamicStatement = struct {
    db: *c.sqlite3,
    stmt: *c.sqlite3_stmt,

    const Self = @This();

    pub const PrepareError = error{} || Error;

    fn prepare(db: *Db, query: []const u8, options: QueryOptions, flags: c_uint) PrepareError!Self {
        var dummy_diags = Diagnostics{};
        var diags = options.diags orelse &dummy_diags;
        var stmt = blk: {
            var tmp: ?*c.sqlite3_stmt = undefined;
            const result = c.sqlite3_prepare_v3(
                db.db,
                query.ptr,
                @intCast(c_int, query.len),
                flags,
                &tmp,
                options.sql_tail_ptr,
            );
            if (result != c.SQLITE_OK) {
                diags.err = getLastDetailedErrorFromDb(db.db);
                return errors.errorFromResultCode(result);
            }
            if (tmp == null) {
                diags.err = .{
                    .code = 0,
                    .near = -1,
                    .message = "the input query is not valid SQL (empty string or a comment)",
                };
                return error.SQLiteError;
            }
            break :blk tmp.?;
        };
        return Self{
            .db = db.db,
            .stmt = stmt,
        };
    }

    /// deinit releases the prepared statement.
    ///
    /// After a call to `deinit` the statement must not be used.
    pub fn deinit(self: *Self) void {
        const result = c.sqlite3_finalize(self.stmt);
        if (result != c.SQLITE_OK) {
            const detailed_error = getLastDetailedErrorFromDb(self.db);
            logger.err("unable to finalize prepared statement, result: {}, detailed error: {}", .{ result, detailed_error });
        }
    }

    /// reset resets the prepared statement to make it reusable.
    pub fn reset(self: *Self) void {
        const result = c.sqlite3_clear_bindings(self.stmt);
        if (result != c.SQLITE_OK) {
            const detailed_error = getLastDetailedErrorFromDb(self.db);
            logger.err("unable to clear prepared statement bindings, result: {}, detailed error: {}", .{ result, detailed_error });
        }
        const result2 = c.sqlite3_reset(self.stmt);
        if (result2 != c.SQLITE_OK) {
            const detailed_error = getLastDetailedErrorFromDb(self.db);
            logger.err("unable to reset prepared statement, result: {}, detailed error: {}", .{ result2, detailed_error });
        }
    }

    fn convertResultToError(result: c_int) !void {
        if (result != c.SQLITE_OK) {
            return errors.errorFromResultCode(result);
        }
    }

    fn bindField(self: *Self, comptime FieldType: type, options: anytype, comptime field_name: []const u8, i: c_int, field: FieldType) !void {
        const field_type_info = @typeInfo(FieldType);
        const column = i + 1;

        switch (FieldType) {
            Text => {
                const result = c.sqlite3_bind_text(self.stmt, column, field.data.ptr, @intCast(c_int, field.data.len), null);
                return convertResultToError(result);
            },
            Blob => {
                const result = c.sqlite3_bind_blob(self.stmt, column, field.data.ptr, @intCast(c_int, field.data.len), null);
                return convertResultToError(result);
            },
            ZeroBlob => {
                const result = c.sqlite3_bind_zeroblob64(self.stmt, column, field.length);
                return convertResultToError(result);
            },
            else => switch (field_type_info) {
                .Int, .ComptimeInt => {
                    const result = c.sqlite3_bind_int64(self.stmt, column, @intCast(c_longlong, field));
                    return convertResultToError(result);
                },
                .Float, .ComptimeFloat => {
                    const result = c.sqlite3_bind_double(self.stmt, column, field);
                    return convertResultToError(result);
                },
                .Bool => {
                    const result = c.sqlite3_bind_int64(self.stmt, column, @boolToInt(field));
                    return convertResultToError(result);
                },
                .Pointer => |ptr| switch (ptr.size) {
                    .One => {
                        try self.bindField(ptr.child, options, field_name, i, field.*);
                    },
                    .Slice => switch (ptr.child) {
                        u8 => {
                            const result = c.sqlite3_bind_text(self.stmt, column, field.ptr, @intCast(c_int, field.len), null);
                            return convertResultToError(result);
                        },
                        else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
                    },
                    else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
                },
                .Array => |arr| switch (arr.child) {
                    u8 => {
                        const data: []const u8 = field[0..field.len];

                        const result = c.sqlite3_bind_text(self.stmt, column, data.ptr, @intCast(c_int, data.len), null);
                        return convertResultToError(result);
                    },
                    else => @compileError("cannot bind field " ++ field_name ++ " of type array of " ++ @typeName(arr.child)),
                },
                .Optional => |opt| if (field) |non_null_field| {
                    try self.bindField(opt.child, options, field_name, i, non_null_field);
                } else {
                    const result = c.sqlite3_bind_null(self.stmt, column);
                    return convertResultToError(result);
                },
                .Null => {
                    const result = c.sqlite3_bind_null(self.stmt, column);
                    return convertResultToError(result);
                },
                .Enum => {
                    if (comptime std.meta.trait.isZigString(FieldType.BaseType)) {
                        try self.bindField(FieldType.BaseType, options, field_name, i, @tagName(field));
                    } else if (@typeInfo(FieldType.BaseType) == .Int) {
                        try self.bindField(FieldType.BaseType, options, field_name, i, @enumToInt(field));
                    } else {
                        @compileError("enum column " ++ @typeName(FieldType) ++ " must have a BaseType of either string or int to bind");
                    }
                },
                .Struct => {
                    if (!comptime std.meta.trait.hasFn("bindField")(FieldType)) {
                        @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType) ++ ", consider implementing the bindField() method");
                    }

                    const field_value = try field.bindField(options.allocator);

                    try self.bindField(FieldType.BaseType, options, field_name, i, field_value);
                },
                .Union => |info| {
                    if (info.tag_type) |UnionTagType| {
                        inline for (info.fields) |u_field| {
                            // This wasn't entirely obvious when I saw code like this elsewhere, it works because of type coercion.
                            // See https://ziglang.org/documentation/master/#Type-Coercion-unions-and-enums
                            const field_tag: std.meta.Tag(FieldType) = field;
                            const this_tag: std.meta.Tag(FieldType) = @field(UnionTagType, u_field.name);

                            if (field_tag == this_tag) {
                                const field_value = @field(field, u_field.name);

                                try self.bindField(u_field.type, options, u_field.name, i, field_value);
                            }
                        }
                    } else {
                        @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType));
                    }
                },
                else => @compileError("cannot bind field " ++ field_name ++ " of type " ++ @typeName(FieldType)),
            },
        }
    }

    // bind iterates over the fields in `values` and binds them using `bindField`.
    //
    // Depending on the query and the type of `values` the binding behaviour differs in regards to the column used.
    //
    // If `values` is a tuple (and therefore doesn't have field names) then the field _index_ is used.
    // This means that if you have a query like this:
    //
    //     SELECT id FROM user WHERE age = ? AND name = ?
    //
    // You must provide a tuple with the fields in the same order like this:
    //
    //     var iter = try stmt.iterator(.{30, "Vincent"});
    //
    //
    // If `values` is a struct (and therefore has field names) then we check sqlite to see if each field name might be a name bind marker.
    // This uses sqlite3_bind_parameter_index and supports bind markers prefixed with ":", "@" and "$".
    // For example if you have a query like this:
    //
    //     SELECT id FROM user WHERE age = :age AND name = @name
    //
    // Then we can provide a struct with fields in any order, like this:
    //
    //     var iter = try stmt.iterator(.{ .age = 30, .name = "Vincent" });
    //
    // Or
    //
    //     var iter = try stmt.iterator(.{ .name = "Vincent", .age = 30 });
    //
    // Both will bind correctly.
    //
    // If however there are no name bind markers then the behaviour will revert to using the field index in the struct, and the fields order must be correct.
    fn bind(self: *Self, options: anytype, values: anytype) !void {
        const Type = @TypeOf(values);

        switch (@typeInfo(Type)) {
            .Struct => |StructTypeInfo| {
                inline for (StructTypeInfo.fields) |struct_field, struct_field_i| {
                    const field_value = @field(values, struct_field.name);

                    const i = sqlite3BindParameterIndex(self.stmt, struct_field.name);
                    if (i >= 0) {
                        try self.bindField(struct_field.type, options, struct_field.name, i, field_value);
                    } else {
                        try self.bindField(struct_field.type, options, struct_field.name, struct_field_i, field_value);
                    }
                }
            },
            .Pointer => |PointerTypeInfo| {
                switch (PointerTypeInfo.size) {
                    .Slice => {
                        for (values) |value_to_bind, index| {
                            try self.bindField(PointerTypeInfo.child, options, "unknown", @intCast(c_int, index), value_to_bind);
                        }
                    },
                    else => @compileError("TODO support pointer size " ++ @tagName(PointerTypeInfo.size)),
                }
            },
            .Array => |ArrayTypeInfo| {
                for (values) |value_to_bind, index| {
                    try self.bindField(ArrayTypeInfo.child, options, "unknown", @intCast(c_int, index), value_to_bind);
                }
            },
            else => @compileError("Unsupported type for values: " ++ @typeName(Type)),
        }
    }

    fn sqlite3BindParameterIndex(stmt: *c.sqlite3_stmt, comptime name: []const u8) c_int {
        if (name.len == 0) return -1;

        inline for (.{ ":", "@", "$" }) |prefix| {
            const id = prefix ++ name;
            const i = c.sqlite3_bind_parameter_index(stmt, id);
            if (i > 0) return i - 1; // .bindField uses 0-based while sqlite3 uses 1-based index.
        }
        return -1;
    }

    /// exec executes a statement which does not return data.
    ///
    /// The `options` tuple is used to provide additional state in some cases.
    ///
    /// The `values` variable is used for the bind parameters. It must have as many fields as there are bind markers
    /// in the input query string.
    /// The values will be binded depends on the numberic name when it's a tuple, or the
    /// string name when it's a normal structure.
    ///
    /// Possible errors:
    /// - SQLiteError.SQLiteNotFound if some fields not found
    pub fn exec(self: *Self, options: QueryOptions, values: anytype) !void {
        try self.bind(.{}, values);

        var dummy_diags = Diagnostics{};
        var diags = options.diags orelse &dummy_diags;

        const result = c.sqlite3_step(self.stmt);
        switch (result) {
            c.SQLITE_DONE => {},
            c.SQLITE_ROW => return error.ExecReturnedData,
            else => {
                diags.err = getLastDetailedErrorFromDb(self.db);
                return errors.errorFromResultCode(result);
            },
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
    ///     while (try iter.next(.{})) |row| {
    ///         ...
    ///     }
    ///
    /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
    /// in the input query string.
    /// The values will be binded depends on the numberic name when it's a tuple, or the
    /// string name when it's a normal structure.
    ///
    /// The iterator _must not_ outlive the statement.
    ///
    /// Possible errors:
    /// - SQLiteError.SQLiteNotFound if some fields not found
    pub fn iterator(self: *Self, comptime Type: type, values: anytype) !Iterator(Type) {
        try self.bind(.{}, values);

        var res: Iterator(Type) = undefined;
        res.db = self.db;
        res.stmt = self.stmt;

        return res;
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
    ///     while (try iter.next(.{})) |row| {
    ///         ...
    ///     }
    ///
    /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
    /// in the input query string.
    /// The values will be binded depends on the numberic name when it's a tuple, or the
    /// string name when it's a normal structure.
    ///
    /// The iterator _must not_ outlive the statement.
    ///
    /// Possible errors:
    /// - SQLiteError.SQLiteNotFound if some fields not found
    pub fn iteratorAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, values: anytype) !Iterator(Type) {
        try self.bind(.{ .allocator = allocator }, values);

        var res: Iterator(Type) = undefined;
        res.db = self.db;
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
    pub fn one(self: *Self, comptime Type: type, options: QueryOptions, values: anytype) !?Type {
        var iter = try self.iterator(Type, values);

        const row = (try iter.next(options)) orelse return null;
        return row;
    }

    /// oneAlloc is like `one` but can allocate memory.
    pub fn oneAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, options: QueryOptions, values: anytype) !?Type {
        var iter = try self.iteratorAlloc(Type, allocator, values);

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
    pub fn all(self: *Self, comptime Type: type, allocator: mem.Allocator, options: QueryOptions, values: anytype) ![]Type {
        var iter = try self.iterator(Type, values);

        var rows = std.ArrayList(Type).init(allocator);
        while (try iter.nextAlloc(allocator, options)) |row| {
            try rows.append(row);
        }

        return rows.toOwnedSlice();
    }
};

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
pub fn Statement(comptime opts: StatementOptions, comptime query: anytype) type {
    _ = opts;

    return struct {
        const Self = @This();

        dynamic_stmt: DynamicStatement,

        fn prepare(db: *Db, options: QueryOptions, flags: c_uint) DynamicStatement.PrepareError!Self {
            return Self{
                .dynamic_stmt = try DynamicStatement.prepare(db, query.getQuery(), options, flags),
            };
        }

        pub fn dynamic(self: *Self) *DynamicStatement {
            return &self.dynamic_stmt;
        }

        /// deinit releases the prepared statement.
        ///
        /// After a call to `deinit` the statement must not be used.
        pub fn deinit(self: *Self) void {
            self.dynamic().deinit();
        }

        /// reset resets the prepared statement to make it reusable.
        pub fn reset(self: *Self) void {
            self.dynamic().reset();
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
        fn bind(self: *Self, options: anytype, values: anytype) !void {
            const StructType = @TypeOf(values);
            if (!comptime std.meta.trait.is(.Struct)(@TypeOf(values))) {
                @compileError("options passed to Statement.bind must be a struct (DynamicStatement supports runtime slices)");
            }

            const StructTypeInfo = @typeInfo(StructType).Struct;

            if (comptime query.nb_bind_markers != StructTypeInfo.fields.len) {
                @compileError(std.fmt.comptimePrint("expected {d} bind parameters but got {d}", .{
                    query.nb_bind_markers,
                    StructTypeInfo.fields.len,
                }));
            }

            inline for (StructTypeInfo.fields) |struct_field, _i| {
                const bind_marker = query.bind_markers[_i];
                if (bind_marker.typed) |typ| {
                    const FieldTypeInfo = @typeInfo(struct_field.type);
                    switch (FieldTypeInfo) {
                        .Struct, .Enum, .Union => comptime assertMarkerType(
                            if (@hasDecl(struct_field.type, "BaseType")) struct_field.type.BaseType else struct_field.type,
                            typ,
                        ),
                        else => comptime assertMarkerType(struct_field.type, typ),
                    }
                }
            }

            return self.dynamic().bind(options, values) catch |e| switch (e) {
                errors.Error.SQLiteNotFound => unreachable, // impossible to have non-exists field
                else => e,
            };
        }

        fn assertMarkerType(comptime Actual: type, comptime Expected: type) void {
            if (Actual != Expected) {
                @compileError("value type " ++ @typeName(Actual) ++ " is not the bind marker type " ++ @typeName(Expected));
            }
        }

        /// execAlloc is like `exec` but can allocate memory.
        pub fn execAlloc(self: *Self, allocator: mem.Allocator, options: QueryOptions, values: anytype) !void {
            try self.bind(.{ .allocator = allocator }, values);

            var dummy_diags = Diagnostics{};
            var diags = options.diags orelse &dummy_diags;

            const result = c.sqlite3_step(self.dynamic().stmt);
            switch (result) {
                c.SQLITE_DONE => {},
                else => {
                    diags.err = getLastDetailedErrorFromDb(self.dynamic().db);
                    return errors.errorFromResultCode(result);
                },
            }
        }

        /// exec executes a statement which does not return data.
        ///
        /// The `options` tuple is used to provide additional state in some cases.
        ///
        /// The `values` variable is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        pub fn exec(self: *Self, options: QueryOptions, values: anytype) !void {
            try self.bind(.{}, values);

            var dummy_diags = Diagnostics{};
            var diags = options.diags orelse &dummy_diags;

            const result = c.sqlite3_step(self.dynamic().stmt);
            switch (result) {
                c.SQLITE_DONE => {},
                else => {
                    diags.err = getLastDetailedErrorFromDb(self.dynamic().db);
                    return errors.errorFromResultCode(result);
                },
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
        ///     while (try iter.next(.{})) |row| {
        ///         ...
        ///     }
        ///
        /// The `values` tuple is used for the bind parameters. It must have as many fields as there are bind markers
        /// in the input query string.
        ///
        /// The iterator _must not_ outlive the statement.
        pub fn iterator(self: *Self, comptime Type: type, values: anytype) !Iterator(Type) {
            try self.bind(.{}, values);

            var res: Iterator(Type) = undefined;
            res.db = self.dynamic().db;
            res.stmt = self.dynamic().stmt;

            return res;
        }

        /// iteratorAlloc is like `iterator` but can allocate memory.
        pub fn iteratorAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, values: anytype) !Iterator(Type) {
            try self.bind(.{ .allocator = allocator }, values);

            var res: Iterator(Type) = undefined;
            res.db = self.dynamic().db;
            res.stmt = self.dynamic().stmt;

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
        pub fn one(self: *Self, comptime Type: type, options: QueryOptions, values: anytype) !?Type {
            var iter = try self.iterator(Type, values);

            const row = (try iter.next(options)) orelse return null;

            return row;
        }

        /// oneAlloc is like `one` but can allocate memory.
        pub fn oneAlloc(self: *Self, comptime Type: type, allocator: mem.Allocator, options: QueryOptions, values: anytype) !?Type {
            var iter = try self.iteratorAlloc(Type, allocator, values);

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
        pub fn all(self: *Self, comptime Type: type, allocator: mem.Allocator, options: QueryOptions, values: anytype) ![]Type {
            var iter = try self.iteratorAlloc(Type, allocator, values);

            var rows = std.ArrayList(Type).init(allocator);
            while (try iter.nextAlloc(allocator, options)) |row| {
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
    favorite_color: Color,

    pub const Color = enum {
        red,
        majenta,
        violet,
        indigo,
        blue,
        cyan,
        green,
        lime,
        yellow,
        //
        orange,
        //

        pub const BaseType = []const u8;
    };
};

const test_users = &[_]TestUser{
    .{ .name = "Vincent", .id = 20, .age = 33, .weight = 85.4, .favorite_color = .violet },
    .{ .name = "Julien", .id = 40, .age = 35, .weight = 100.3, .favorite_color = .green },
    .{ .name = "José", .id = 60, .age = 40, .weight = 240.2, .favorite_color = .indigo },
};

fn createTestTables(db: *Db) !void {
    const AllDDL = &[_][]const u8{
        "DROP TABLE IF EXISTS user",
        "DROP TABLE IF EXISTS article",
        "DROP TABLE IF EXISTS test_blob",
        \\CREATE TABLE user(
        \\ name text,
        \\ id integer PRIMARY KEY,
        \\ age integer,
        \\ weight real,
        \\ favorite_color text
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
        try db.exec(ddl, .{}, .{});
    }
}

fn addTestData(db: *Db) !void {
    try createTestTables(db);

    for (test_users) |user| {
        try db.exec("INSERT INTO user(name, id, age, weight, favorite_color) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32}, ?{[]const u8})", .{}, user);

        const rows_inserted = db.rowsAffected();
        try testing.expectEqual(@as(usize, 1), rows_inserted);
    }
}

test "sqlite: db init" {
    var db = try getTestDb();
    defer db.deinit();
}

test "sqlite: exec multi" {
    var db = try getTestDb();
    defer db.deinit();

    try db.execMulti("DROP TABLE IF EXISTS a;\nDROP TABLE IF EXISTS b;", .{});
    try db.execMulti("CREATE TABLE a(b int);\n\n--test comment\nCREATE TABLE b(c int);", .{});

    const val = try db.one(i32, "SELECT max(c) FROM b", .{}, .{});
    try testing.expectEqual(@as(?i32, 0), val);
}

test "sqlite: exec multi with single statement" {
    var db = try getTestDb();
    defer db.deinit();

    try db.exec("DROP TABLE IF EXISTS a", .{}, .{});
    try db.execMulti("CREATE TABLE a(b int);", .{});

    const val = try db.one(i32, "SELECT max(b) FROM a", .{}, .{});
    try testing.expectEqual(@as(?i32, 0), val);
}

test "sqlite: db pragma" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();

    const foreign_keys = try db.pragma(usize, .{}, "foreign_keys", null);
    try testing.expect(foreign_keys != null);
    try testing.expectEqual(@as(usize, 0), foreign_keys.?);

    if (build_options.in_memory) {
        {
            const journal_mode = try db.pragma([128:0]u8, .{}, "journal_mode", "wal");
            try testing.expect(journal_mode != null);
            try testing.expectEqualStrings("memory", mem.sliceTo(&journal_mode.?, 0));
        }

        {
            const journal_mode = try db.pragmaAlloc([]const u8, allocator, .{}, "journal_mode", "wal");
            try testing.expect(journal_mode != null);
            try testing.expectEqualStrings("memory", journal_mode.?);
        }
    } else {
        {
            const journal_mode = try db.pragma([128:0]u8, .{}, "journal_mode", "wal");
            try testing.expect(journal_mode != null);
            try testing.expectEqualStrings("wal", mem.sliceTo(&journal_mode.?, 0));
        }

        {
            const journal_mode = try db.pragmaAlloc([]const u8, allocator, .{}, "journal_mode", "wal");
            try testing.expect(journal_mode != null);
            try testing.expectEqualStrings("wal", journal_mode.?);
        }
    }
}

test "sqlite: last insert row id" {
    var db = try getTestDb();
    defer db.deinit();
    try createTestTables(&db);

    try db.exec("INSERT INTO user(name, age) VALUES(?, ?{u32})", .{}, .{
        .name = "test-user",
        .age = @as(u32, 400),
    });

    const id = db.getLastInsertRowID();
    try testing.expectEqual(@as(i64, 1), id);
}

test "sqlite: statement exec" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    // Test with a Blob struct
    {
        try db.exec("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{blob}, ?{u32})", .{}, .{
            .id = @as(usize, 200),
            .name = Blob{ .data = "hello" },
            .age = @as(u32, 20),
        });
    }

    // Test with a Text struct
    {
        try db.exec("INSERT INTO user(id, name, age) VALUES(?{usize}, ?{text}, ?{u32})", .{}, .{
            .id = @as(usize, 201),
            .name = Text{ .data = "hello" },
            .age = @as(u32, 20),
        });
    }
}

test "sqlite: statement execDynamic" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    // Test with a Blob struct
    {
        try db.execDynamic("INSERT INTO user(id, name, age) VALUES(@id, @name, @age)", .{}, .{
            .id = @as(usize, 200),
            .name = Blob{ .data = "hello" },
            .age = @as(u32, 20),
        });
    }

    // Test with a Text struct
    {
        try db.execDynamic("INSERT INTO user(id, name, age) VALUES(@id, @name, @age)", .{}, .{
            .id = @as(usize, 201),
            .name = Text{ .data = "hello" },
            .age = @as(u32, 20),
        });
    }
}

test "sqlite: db execAlloc" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    try db.execAlloc(testing.allocator, "INSERT INTO user(id, name, age) VALUES(@id, @name, @age)", .{}, .{
        .id = @as(usize, 502),
        .name = Blob{ .data = "hello" },
        .age = @as(u32, 20),
    });
}

test "sqlite: read a single user into a struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT * FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var rows = try stmt.all(TestUser, allocator, .{}, .{
        .id = @as(usize, 20),
    });
    for (rows) |row| {
        try testing.expectEqual(test_users[0].id, row.id);
        try testing.expectEqualStrings(test_users[0].name, row.name);
        try testing.expectEqual(test_users[0].age, row.age);
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
        try testing.expect(row != null);

        const exp = test_users[0];
        try testing.expectEqual(exp.id, row.?.id);
        try testing.expectEqualStrings(exp.name, mem.sliceTo(&row.?.name, 0));
        try testing.expectEqual(exp.age, row.?.age);
    }

    // Read a row with db.oneAlloc()
    {
        var row = try db.oneAlloc(
            struct {
                name: Text,
                id: usize,
                age: usize,
            },
            allocator,
            "SELECT name, id, age FROM user WHERE id = ?{usize}",
            .{},
            .{@as(usize, 20)},
        );
        try testing.expect(row != null);

        const exp = test_users[0];
        try testing.expectEqual(exp.id, row.?.id);
        try testing.expectEqualStrings(exp.name, row.?.name.data);
        try testing.expectEqual(exp.age, row.?.age);
    }
}

test "sqlite: read all users into a struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT * FROM user");
    defer stmt.deinit();

    var rows = try stmt.all(TestUser, allocator, .{}, .{});
    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row, i| {
        const exp = test_users[i];
        try testing.expectEqual(exp.id, row.id);
        try testing.expectEqualStrings(exp.name, row.name);
        try testing.expectEqual(exp.age, row.age);
        try testing.expectEqual(exp.weight, row.weight);
    }
}

test "sqlite: read in an anonymous struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
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
        allocator,
        .{},
        .{ .id = @as(usize, 20) },
    );
    try testing.expect(row != null);

    const exp = test_users[0];
    try testing.expectEqual(exp.id, row.?.id);
    try testing.expectEqualStrings(exp.name, row.?.name);
    try testing.expectEqualStrings(exp.name, mem.sliceTo(&row.?.name_2, 0xAD));
    try testing.expectEqual(exp.age, row.?.age);
    try testing.expect(row.?.is_id);
    try testing.expectEqual(exp.weight, @floatCast(f32, row.?.weight));
}

test "sqlite: read in a Text struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    var stmt = try db.prepare("SELECT name, id, age FROM user WHERE id = ?{usize}");
    defer stmt.deinit();

    var row = try stmt.oneAlloc(
        struct {
            name: Text,
            id: usize,
            age: usize,
        },
        allocator,
        .{},
        .{@as(usize, 20)},
    );
    try testing.expect(row != null);

    const exp = test_users[0];
    try testing.expectEqual(exp.id, row.?.id);
    try testing.expectEqualStrings(exp.name, row.?.name.data);
    try testing.expectEqual(exp.age, row.?.age);
}

test "sqlite: read a single text value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
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
        [7]u8,
        // Specific text or blob
        Text,
        Blob,
    };

    inline for (types) |typ| {
        const query = "SELECT name FROM user WHERE id = ?{usize}";

        var stmt: StatementType(.{}, query) = try db.prepare(query);
        defer stmt.deinit();

        const name = try stmt.oneAlloc(typ, allocator, .{}, .{
            .id = @as(usize, 20),
        });
        try testing.expect(name != null);
        switch (typ) {
            Text, Blob => {
                try testing.expectEqualStrings("Vincent", name.?.data);
            },
            else => {
                const type_info = @typeInfo(typ);
                switch (type_info) {
                    .Pointer => {
                        try testing.expectEqualStrings("Vincent", name.?);
                    },
                    .Array => |arr| if (arr.sentinel) |sentinel_ptr| {
                        const sentinel = @ptrCast(*const arr.child, sentinel_ptr).*;
                        const res = mem.sliceTo(&name.?, sentinel);
                        try testing.expectEqualStrings("Vincent", res);
                    } else {
                        const res = mem.span(&name.?);
                        try testing.expectEqualStrings("Vincent", res);
                    },
                    else => @compileError("invalid type " ++ @typeName(typ)),
                }
            },
        }
    }
}

test "sqlite: read a single integer value" {
    var db = try getTestDb();
    defer db.deinit();
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

        var stmt: StatementType(.{}, query) = try db.prepare(query);
        defer stmt.deinit();

        var age = try stmt.one(typ, .{}, .{
            .id = @as(usize, 20),
        });
        try testing.expect(age != null);

        try testing.expectEqual(@as(typ, 33), age.?);
    }
}

test "sqlite: read a single value into an enum backed by an integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try createTestTables(&db);

    try db.exec("INSERT INTO user(id, age) VALUES(?{usize}, ?{usize})", .{}, .{
        .id = @as(usize, 10),
        .age = @as(usize, 0),
    });

    const query = "SELECT age FROM user WHERE id = ?{usize}";

    const IntColor = enum {
        violet,

        pub const BaseType = u1;
    };

    // Use one
    {
        var stmt: StatementType(.{}, query) = try db.prepare(query);
        defer stmt.deinit();

        const b = try stmt.one(IntColor, .{}, .{
            .id = @as(usize, 10),
        });
        try testing.expect(b != null);
        try testing.expectEqual(IntColor.violet, b.?);
    }

    // Use oneAlloc
    {
        var stmt: StatementType(.{}, query) = try db.prepare(query);
        defer stmt.deinit();

        const b = try stmt.oneAlloc(IntColor, allocator, .{}, .{
            .id = @as(usize, 10),
        });
        try testing.expect(b != null);
        try testing.expectEqual(IntColor.violet, b.?);
    }
}

test "sqlite: read a single value into an enum backed by a string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try createTestTables(&db);

    try db.exec("INSERT INTO user(id, favorite_color) VALUES(?{usize}, ?{[]const u8})", .{}, .{
        .id = @as(usize, 10),
        .age = @as([]const u8, "violet"),
    });

    const query = "SELECT favorite_color FROM user WHERE id = ?{usize}";

    var stmt: StatementType(.{}, query) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.oneAlloc(TestUser.Color, allocator, .{}, .{
        .id = @as(usize, 10),
    });
    try testing.expect(b != null);
    try testing.expectEqual(TestUser.Color.violet, b.?);
}

test "sqlite: read a single value into void" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    const query = "SELECT age FROM user WHERE id = ?{usize}";

    var stmt: StatementType(.{}, query) = try db.prepare(query);
    defer stmt.deinit();

    _ = try stmt.one(void, .{}, .{
        .id = @as(usize, 20),
    });
}

test "sqlite: read a single value into bool" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    const query = "SELECT id FROM user WHERE id = ?{usize}";

    var stmt: StatementType(.{}, query) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(bool, .{}, .{
        .id = @as(usize, 20),
    });
    try testing.expect(b != null);
    try testing.expect(b.?);
}

test "sqlite: insert bool and bind bool" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    try db.exec("INSERT INTO article(id, author_id, is_published) VALUES(?{usize}, ?{usize}, ?{bool})", .{}, .{
        .id = @as(usize, 1),
        .author_id = @as(usize, 20),
        .is_published = true,
    });

    const query = "SELECT id FROM article WHERE is_published = ?{bool}";

    var stmt: StatementType(.{}, query) = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(bool, .{}, .{
        .is_published = true,
    });
    try testing.expect(b != null);
    try testing.expect(b.?);
}

test "sqlite: bind string literal" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    try db.exec("INSERT INTO article(id, data) VALUES(?, ?)", .{}, .{
        @as(usize, 10),
        "foobar",
    });

    const query = "SELECT id FROM article WHERE data = ?";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const b = try stmt.one(usize, .{}, .{"foobar"});
    try testing.expect(b != null);
    try testing.expectEqual(@as(usize, 10), b.?);
}

test "sqlite: bind pointer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    const query = "SELECT name FROM user WHERE id = ?";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    for (test_users) |test_user, i| {
        stmt.reset();

        const name = try stmt.oneAlloc([]const u8, allocator, .{}, .{&test_user.id});
        try testing.expect(name != null);
        try testing.expectEqualStrings(test_users[i].name, name.?);
    }
}

test "sqlite: read pointers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
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
        allocator,
        .{},
        .{},
    );

    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row, i| {
        const exp = test_users[i];
        try testing.expectEqual(exp.id, row.id.*);
        try testing.expectEqualStrings(exp.name, row.name.*);
        try testing.expectEqual(exp.age, row.age.*);
        try testing.expectEqual(exp.weight, row.weight.*);
    }
}

test "sqlite: optional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    const published: ?bool = true;

    {
        try db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?, ?)", .{}, .{ 1, null, published });

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

        try testing.expect(row != null);
        try testing.expect(row.?.data == null);
        try testing.expectEqual(true, row.?.is_published.?);
    }

    {
        const data: ?[]const u8 = "hello";
        try db.exec("INSERT INTO article(author_id, data) VALUES(?, :data{?[]const u8})", .{}, .{
            .author_id = 20,
            .dhe = data,
        });

        const row = try db.oneAlloc(
            []const u8,
            arena.allocator(),
            "SELECT data FROM article WHERE author_id = ?",
            .{},
            .{ .author_id = 20 },
        );
        try testing.expect(row != null);
        try testing.expectEqualStrings(data.?, row.?);
    }
}

test "sqlite: statement reset" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    // Add data

    var stmt = try db.prepare("INSERT INTO user(name, id, age, weight, favorite_color) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32}, ?{[]const u8})");
    defer stmt.deinit();

    const users = &[_]TestUser{
        .{ .id = 200, .name = "Vincent", .age = 33, .weight = 10.0, .favorite_color = .violet },
        .{ .id = 400, .name = "Julien", .age = 35, .weight = 12.0, .favorite_color = .green },
        .{ .id = 600, .name = "José", .age = 40, .weight = 14.0, .favorite_color = .indigo },
    };

    for (users) |user| {
        stmt.reset();
        try stmt.exec(.{}, user);

        const rows_inserted = db.rowsAffected();
        try testing.expectEqual(@as(usize, 1), rows_inserted);
    }
}

test "sqlite: statement iterator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    // Cleanup first
    try db.exec("DELETE FROM user", .{}, .{});

    // Add data
    var stmt = try db.prepare("INSERT INTO user(name, id, age, weight, favorite_color) VALUES(?{[]const u8}, ?{usize}, ?{usize}, ?{f32}, ?{[]const u8})");
    defer stmt.deinit();

    var expected_rows = std.ArrayList(TestUser).init(allocator);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "Vincent {d}", .{i});
        const user = TestUser{ .id = i, .name = name, .age = i + 200, .weight = @intToFloat(f32, i + 200), .favorite_color = .indigo };

        try expected_rows.append(user);

        stmt.reset();
        try stmt.exec(.{}, user);

        const rows_inserted = db.rowsAffected();
        try testing.expectEqual(@as(usize, 1), rows_inserted);
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
        while (try iter.next(.{})) |row| {
            try rows.append(row);
        }

        // Check the data
        try testing.expectEqual(expected_rows.items.len, rows.items.len);

        for (rows.items) |row, j| {
            const exp_row = expected_rows.items[j];
            try testing.expectEqualStrings(exp_row.name, mem.sliceTo(&row.name, 0));
            try testing.expectEqual(exp_row.age, row.age);
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
        while (try iter.nextAlloc(allocator, .{})) |row| {
            try rows.append(row);
        }

        // Check the data
        try testing.expectEqual(expected_rows.items.len, rows.items.len);

        for (rows.items) |row, j| {
            const exp_row = expected_rows.items[j];
            try testing.expectEqualStrings(exp_row.name, row.name.data);
            try testing.expectEqual(exp_row.age, row.age);
        }
    }
}

test "sqlite: blob open, reopen" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();

    const blob_data1 = "\xDE\xAD\xBE\xEFabcdefghijklmnopqrstuvwxyz0123456789";
    const blob_data2 = "\xCA\xFE\xBA\xBEfoobar";

    // Insert two blobs with a set length
    try db.exec("DROP TABLE IF EXISTS test_blob", .{}, .{});
    try db.exec("CREATE TABLE test_blob(id integer primary key, data blob)", .{}, .{});

    try db.exec("INSERT INTO test_blob(data) VALUES(?)", .{}, .{
        .data = ZeroBlob{ .length = blob_data1.len * 2 },
    });
    const rowid1 = db.getLastInsertRowID();

    try db.exec("INSERT INTO test_blob(data) VALUES(?)", .{}, .{
        .data = ZeroBlob{ .length = blob_data2.len * 2 },
    });
    const rowid2 = db.getLastInsertRowID();

    // Open the blob in the first row
    var blob = try db.openBlob(.main, "test_blob", "data", rowid1, .{ .write = true });

    {
        // Write the first blob data
        var blob_writer = blob.writer();
        try blob_writer.writeAll(blob_data1);
        try blob_writer.writeAll(blob_data1);

        blob.reset();

        var blob_reader = blob.reader();
        const data = try blob_reader.readAllAlloc(allocator, 8192);

        try testing.expectEqualSlices(u8, blob_data1 ** 2, data);
    }

    // Reopen the blob in the second row
    try blob.reopen(rowid2);

    {
        // Write the second blob data
        var blob_writer = blob.writer();
        try blob_writer.writeAll(blob_data2);
        try blob_writer.writeAll(blob_data2);

        blob.reset();

        var blob_reader = blob.reader();
        const data = try blob_reader.readAllAlloc(allocator, 8192);

        try testing.expectEqualSlices(u8, blob_data2 ** 2, data);
    }

    try blob.close();
}

test "sqlite: failing open" {
    var diags: Diagnostics = undefined;

    const res = Db.init(.{
        .diags = &diags,
        .open_flags = .{},
        .mode = .{ .File = "/tmp/not_existing.db" },
    });
    try testing.expectError(error.SQLiteCantOpen, res);
    try testing.expectEqual(@as(usize, 14), diags.err.?.code);
    try testing.expectEqualStrings("unable to open database file", diags.err.?.message);
}

test "sqlite: failing prepare statement" {
    var db = try getTestDb();
    defer db.deinit();

    var diags: Diagnostics = undefined;

    try db.exec("DROP TABLE IF EXISTS foobar", .{}, .{});

    const result = db.prepareWithDiags("SELECT id FROM foobar", .{ .diags = &diags });
    try testing.expectError(error.SQLiteError, result);

    const detailed_err = db.getDetailedError();
    try testing.expectEqual(@as(usize, 1), detailed_err.code);
    try testing.expectEqualStrings("no such table: foobar", detailed_err.message);
}

test "sqlite: diagnostics format" {
    const TestCase = struct {
        input: Diagnostics,
        exp: []const u8,
    };

    const testCases = &[_]TestCase{
        .{
            .input = .{},
            .exp = "my diagnostics: none",
        },
        .{
            .input = .{
                .message = "foobar",
            },
            .exp = "my diagnostics: foobar",
        },
        .{
            .input = .{
                .err = .{
                    .code = 20,
                    .near = -1,
                    .message = "barbaz",
                },
            },
            .exp = "my diagnostics: {code: 20, near: -1, message: barbaz}",
        },
        .{
            .input = .{
                .message = "foobar",
                .err = .{
                    .code = 20,
                    .near = 10,
                    .message = "barbaz",
                },
            },
            .exp = "my diagnostics: {message: foobar, detailed error: {code: 20, near: 10, message: barbaz}}",
        },
    };

    inline for (testCases) |tc| {
        var buf: [1024]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "my diagnostics: {s}", .{tc.input});

        try testing.expectEqualStrings(tc.exp, str);
    }
}

test "sqlite: exec with diags, failing statement" {
    var db = try getTestDb();
    defer db.deinit();

    var diags = Diagnostics{};

    const result = blk: {
        var stmt = try db.prepareWithDiags("ROLLBACK", .{ .diags = &diags });
        break :blk stmt.exec(.{ .diags = &diags }, .{});
    };

    try testing.expectError(error.SQLiteError, result);
    try testing.expect(diags.err != null);
    try testing.expectEqualStrings("cannot rollback - no transaction is active", diags.err.?.message);

    const detailed_err = db.getDetailedError();
    try testing.expectEqual(@as(usize, 1), detailed_err.code);
    try testing.expectEqualStrings("cannot rollback - no transaction is active", detailed_err.message);
}

test "sqlite: savepoint with no failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    {
        var savepoint = try db.savepoint("outer1");
        defer savepoint.rollback();

        try db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?, ?)", .{}, .{ 1, null, true });

        {
            var savepoint2 = try db.savepoint("inner1");
            defer savepoint2.rollback();

            try db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?, ?)", .{}, .{ 2, "foobar", true });

            savepoint2.commit();
        }

        savepoint.commit();
    }

    // No failures, expect to have two rows.

    var stmt = try db.prepare("SELECT data, author_id FROM article ORDER BY id ASC");
    defer stmt.deinit();

    var rows = try stmt.all(
        struct {
            data: []const u8,
            author_id: usize,
        },
        allocator,
        .{},
        .{},
    );

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(usize, 1), rows[0].author_id);
    try testing.expectEqualStrings("", rows[0].data);
    try testing.expectEqual(@as(usize, 2), rows[1].author_id);
    try testing.expectEqualStrings("foobar", rows[1].data);
}

test "sqlite: two nested savepoints with inner failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    {
        var savepoint = try db.savepoint("outer2");
        defer savepoint.rollback();

        try db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?, ?)", .{}, .{ 10, "barbaz", true });

        inner: {
            var savepoint2 = try db.savepoint("inner2");
            defer savepoint2.rollback();

            try db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?, ?)", .{}, .{ 20, null, true });

            // Explicitly fail
            db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?)", .{}, .{ 22, null }) catch {
                break :inner;
            };

            savepoint2.commit();
        }

        savepoint.commit();
    }

    // The inner transaction failed, expect to have only one row.

    var stmt = try db.prepare("SELECT data, author_id FROM article");
    defer stmt.deinit();

    var rows = try stmt.all(
        struct {
            data: []const u8,
            author_id: usize,
        },
        allocator,
        .{},
        .{},
    );
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(usize, 10), rows[0].author_id);
    try testing.expectEqualStrings("barbaz", rows[0].data);
}

test "sqlite: two nested savepoints with outer failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    blk: {
        var savepoint = try db.savepoint("outer3");
        defer savepoint.rollback();

        var i: usize = 100;
        while (i < 120) : (i += 1) {
            try db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?, ?)", .{}, .{ i, null, true });
        }

        // Explicitly fail
        db.exec("INSERT INTO article(author_id, data, is_published) VALUES(?, ?)", .{}, .{ 2, null }) catch {
            break :blk;
        };

        savepoint.commit();
    }

    // The outer transaction failed, expect to have no rows.

    var stmt = try db.prepare("SELECT 1 FROM article");
    defer stmt.deinit();

    var rows = try stmt.all(usize, allocator, .{}, .{});
    try testing.expectEqual(@as(usize, 0), rows.len);
}

const MyData = struct {
    data: [16]u8,

    const BaseType = []const u8;

    pub fn bindField(self: MyData, allocator: mem.Allocator) !BaseType {
        return try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&self.data)});
    }

    pub fn readField(alloc: mem.Allocator, value: BaseType) !MyData {
        _ = alloc;

        var result = [_]u8{0} ** 16;
        var i: usize = 0;
        while (i < result.len) : (i += 1) {
            const j = i * 2;
            result[i] = try std.fmt.parseUnsigned(u8, value[j..][0..2], 16);
        }
        return MyData{ .data = result };
    }
};

test "sqlite: bind custom type" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    {
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            var my_data: MyData = undefined;
            mem.set(u8, &my_data.data, @intCast(u8, i));

            var arena = heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();

            // insertion
            var stmt = try db.prepare("INSERT INTO article(data) VALUES(?)");
            try stmt.execAlloc(arena.allocator(), .{}, .{my_data});
        }
    }
    {
        // reading back
        var stmt = try db.prepare("SELECT * FROM article");
        defer stmt.deinit();

        const Article = struct {
            id: u32,
            author_id: u32,
            data: MyData,
            is_published: bool,
        };

        var arena = heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const rows = try stmt.all(Article, arena.allocator(), .{}, .{});
        try testing.expectEqual(@as(usize, 20), rows.len);

        for (rows) |row, i| {
            var exp_data: MyData = undefined;
            mem.set(u8, &exp_data.data, @intCast(u8, i));

            try testing.expectEqualSlices(u8, &exp_data.data, &row.data.data);
        }
    }
}

test "sqlite: bind runtime slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    // creating array list on heap so that it's deemed runtime size
    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();
    try list.append("this is some data");
    const args = try list.toOwnedSlice();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    {
        // insertion
        var stmt = try db.prepareDynamic("INSERT INTO article(data) VALUES(?)");
        defer stmt.deinit();
        try stmt.exec(.{}, args);
    }
}

test "sqlite: prepareDynamic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    var diags = Diagnostics{};
    var stmt = try db.prepareDynamicWithDiags("SELECT id FROM user WHERE age = ?", .{ .diags = &diags });
    defer stmt.deinit();

    {
        var iter = try stmt.iterator(usize, .{ .age = 33 });

        const id = try iter.next(.{});
        try testing.expect(id != null);
        try testing.expectEqual(@as(usize, 20), id.?);
    }

    stmt.reset();

    {
        var iter = try stmt.iteratorAlloc(usize, allocator, .{ .age = 33 });

        const id = try iter.next(.{});
        try testing.expect(id != null);
        try testing.expectEqual(@as(usize, 20), id.?);
    }

    stmt.reset();

    {
        var iter = try stmt.iteratorAlloc(usize, allocator, .{33});

        const id = try iter.next(.{});
        try testing.expect(id != null);
        try testing.expectEqual(@as(usize, 20), id.?);
    }
}

test "sqlite: oneDynamic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    var diags = Diagnostics{};

    {
        const id = try db.oneDynamic(
            usize,
            "SELECT id FROM user WHERE age = ?",
            .{ .diags = &diags },
            .{ .age = 33 },
        );
        try testing.expect(id != null);
        try testing.expectEqual(@as(usize, 20), id.?);
    }

    {
        // Mix bind marker prefix for good measure

        const id = try db.oneDynamic(
            usize,
            "SELECT id FROM user WHERE age = $age AND weight < :weight and id < @id",
            .{ .diags = &diags },
            .{ .id = 400, .age = 33, .weight = 200 },
        );
        try testing.expect(id != null);
        try testing.expectEqual(@as(usize, 20), id.?);
    }

    {
        const id = try db.oneDynamicAlloc(
            usize,
            allocator,
            "SELECT id FROM user WHERE age = ?",
            .{ .diags = &diags },
            .{ .age = 33 },
        );
        try testing.expect(id != null);
        try testing.expectEqual(@as(usize, 20), id.?);
    }

    {
        const id = try db.oneDynamicAlloc(
            usize,
            allocator,
            "SELECT id FROM user WHERE age = ?",
            .{ .diags = &diags },
            .{33},
        );
        try testing.expect(id != null);
        try testing.expectEqual(@as(usize, 20), id.?);
    }
}

test "sqlite: one with all named parameters" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    var diags = Diagnostics{};

    // Mix bind marker prefix for good measure

    const id = try db.one(
        usize,
        "SELECT id FROM user WHERE age = $age AND weight < :weight and id < @my_id",
        .{ .diags = &diags },
        .{ .my_id = 400, .age = 33, .weight = 200 },
    );
    try testing.expect(id != null);
    try testing.expectEqual(@as(usize, 20), id.?);
}

test "sqlite: create scalar function" {
    var db = try getTestDb();
    defer db.deinit();

    {
        try db.createScalarFunction(
            "myInteger",
            struct {
                fn run(input: u16) u16 {
                    return input * 2;
                }
            }.run,
            .{},
        );

        const result = try db.one(usize, "SELECT myInteger(20)", .{}, .{});

        try testing.expect(result != null);
        try testing.expectEqual(@as(usize, 40), result.?);
    }

    {
        try db.createScalarFunction(
            "myInteger64",
            struct {
                fn run(input: i64) i64 {
                    return @intCast(i64, input) * 2;
                }
            }.run,
            .{},
        );

        const result = try db.one(usize, "SELECT myInteger64(20)", .{}, .{});

        try testing.expect(result != null);
        try testing.expectEqual(@as(usize, 40), result.?);
    }

    {
        try db.createScalarFunction(
            "myMax",
            struct {
                fn run(a: f64, b: f64) f64 {
                    return std.math.max(a, b);
                }
            }.run,
            .{},
        );

        const result = try db.one(f64, "SELECT myMax(2.0, 23.4)", .{}, .{});

        try testing.expect(result != null);
        try testing.expectEqual(@as(f64, 23.4), result.?);
    }

    {
        try db.createScalarFunction(
            "myBool",
            struct {
                fn run() bool {
                    return true;
                }
            }.run,
            .{},
        );

        const result = try db.one(bool, "SELECT myBool()", .{}, .{});

        try testing.expect(result != null);
        try testing.expectEqual(true, result.?);
    }

    {
        try db.createScalarFunction(
            "mySlice",
            struct {
                fn run() []const u8 {
                    return "foobar";
                }
            }.run,
            .{},
        );

        const result = try db.oneAlloc([]const u8, testing.allocator, "SELECT mySlice()", .{}, .{});
        try testing.expect(result != null);
        try testing.expectEqualStrings("foobar", result.?);
        testing.allocator.free(result.?);
    }

    {
        const Blake3 = std.crypto.hash.Blake3;

        var expected_hash: [Blake3.digest_length]u8 = undefined;
        Blake3.hash("hello", &expected_hash, .{});

        try db.createScalarFunction(
            "blake3",
            struct {
                fn run(input: []const u8) [std.crypto.hash.Blake3.digest_length]u8 {
                    var hash: [Blake3.digest_length]u8 = undefined;
                    Blake3.hash(input, &hash, .{});
                    return hash;
                }
            }.run,
            .{},
        );

        const hash = try db.one([Blake3.digest_length]u8, "SELECT blake3('hello')", .{}, .{});

        try testing.expect(hash != null);
        try testing.expectEqual(expected_hash, hash.?);
    }

    {
        try db.createScalarFunction(
            "myText",
            struct {
                fn run() Text {
                    return Text{ .data = "foobar" };
                }
            }.run,
            .{},
        );

        const result = try db.oneAlloc(Text, testing.allocator, "SELECT myText()", .{}, .{});
        try testing.expect(result != null);
        try testing.expectEqualStrings("foobar", result.?.data);
        testing.allocator.free(result.?.data);
    }

    {
        try db.createScalarFunction(
            "myBlob",
            struct {
                fn run() Blob {
                    return Blob{ .data = "barbaz" };
                }
            }.run,
            .{},
        );

        const result = try db.oneAlloc(Blob, testing.allocator, "SELECT myBlob()", .{}, .{});
        try testing.expect(result != null);
        try testing.expectEqualStrings("barbaz", result.?.data);
        testing.allocator.free(result.?.data);
    }
}

test "sqlite: create aggregate function with no aggregate context" {
    var db = try getTestDb();
    defer db.deinit();

    var rand = std.rand.DefaultPrng.init(@intCast(u64, std.time.milliTimestamp()));

    // Create an aggregate function working with a MyContext

    const MyContext = struct {
        sum: u32,
    };
    var my_ctx = MyContext{ .sum = 0 };

    try db.createAggregateFunction(
        "mySum",
        &my_ctx,
        struct {
            fn step(fctx: FunctionContext, input: u32) void {
                var ctx = fctx.userContext(*MyContext) orelse return;
                ctx.sum += input;
            }
        }.step,
        struct {
            fn finalize(fctx: FunctionContext) u32 {
                var ctx = fctx.userContext(*MyContext) orelse return 0;
                return ctx.sum;
            }
        }.finalize,
        .{},
    );

    // Initialize some data

    try db.exec("DROP TABLE IF EXISTS view", .{}, .{});
    try db.exec("CREATE TABLE view(id integer PRIMARY KEY, nb integer)", .{}, .{});
    var i: usize = 0;
    var exp: usize = 0;
    while (i < 20) : (i += 1) {
        const val = rand.random().intRangeAtMost(u32, 0, 5205905);
        exp += val;

        try db.exec("INSERT INTO view(nb) VALUES(?{u32})", .{}, .{val});
    }

    // Get the sum and check the result

    var diags = Diagnostics{};
    const result = db.one(
        usize,
        "SELECT mySum(nb) FROM view",
        .{ .diags = &diags },
        .{},
    ) catch |err| {
        debug.print("err: {}\n", .{diags});
        return err;
    };

    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, exp), result.?);
}

test "sqlite: create aggregate function with an aggregate context" {
    var db = try getTestDb();
    defer db.deinit();

    var rand = std.rand.DefaultPrng.init(@intCast(u64, std.time.milliTimestamp()));

    try db.createAggregateFunction(
        "mySum",
        null,
        struct {
            fn step(fctx: FunctionContext, input: u32) void {
                var ctx = fctx.aggregateContext(*u32) orelse return;
                ctx.* += input;
            }
        }.step,
        struct {
            fn finalize(fctx: FunctionContext) u32 {
                var ctx = fctx.aggregateContext(*u32) orelse return 0;
                return ctx.*;
            }
        }.finalize,
        .{},
    );

    // Initialize some data

    try db.exec("DROP TABLE IF EXISTS view", .{}, .{});
    try db.exec("CREATE TABLE view(id integer PRIMARY KEY, a integer, b integer)", .{}, .{});
    var i: usize = 0;
    var exp_a: usize = 0;
    var exp_b: usize = 0;
    while (i < 20) : (i += 1) {
        const val1 = rand.random().intRangeAtMost(u32, 0, 5205905);
        exp_a += val1;

        const val2 = rand.random().intRangeAtMost(u32, 0, 310455);
        exp_b += val2;

        try db.exec("INSERT INTO view(a, b) VALUES(?{u32}, ?{u32})", .{}, .{ val1, val2 });
    }

    // Get the sum and check the result

    var diags = Diagnostics{};
    const result = db.one(
        struct {
            a_sum: usize,
            b_sum: usize,
        },
        "SELECT mySum(a), mySum(b) FROM view",
        .{ .diags = &diags },
        .{},
    ) catch |err| {
        debug.print("err: {}\n", .{diags});
        return err;
    };

    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, exp_a), result.?.a_sum);
    try testing.expectEqual(@as(usize, exp_b), result.?.b_sum);
}

test "sqlite: empty slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    var list = std.ArrayList(u8).init(arena.allocator());
    const ptr = try list.toOwnedSlice();

    try db.exec("INSERT INTO article(author_id, data) VALUES(?, ?)", .{}, .{ 1, ptr });

    // Read into an array
    {
        var stmt = try db.prepare("SELECT data FROM article");
        defer stmt.deinit();

        const row = try stmt.one(
            struct {
                data: [128:0]u8,
            },
            .{},
            .{},
        );

        try testing.expect(row != null);
        try testing.expectEqualSlices(u8, "", mem.sliceTo(&row.?.data, 0));
    }

    // Read into an allocated slice
    {
        var stmt = try db.prepare("SELECT data FROM article");
        defer stmt.deinit();

        const row = try stmt.oneAlloc(
            struct {
                data: []const u8,
            },
            arena.allocator(),
            .{},
            .{},
        );

        try testing.expect(row != null);
        try testing.expectEqualSlices(u8, "", row.?.data);
    }

    // Read into a Text
    {
        var stmt = try db.prepare("SELECT data FROM article");
        defer stmt.deinit();

        const row = try stmt.oneAlloc(
            struct {
                data: Text,
            },
            arena.allocator(),
            .{},
            .{},
        );

        try testing.expect(row != null);
        try testing.expectEqualSlices(u8, "", row.?.data.data);
    }
}

test "sqlite: fuzzer found crashes" {
    const test_cases = &[_]struct {
        input: []const u8,
        exp_error: anyerror,
    }{
        .{
            .input = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00CREATE TABLE \x80\x00\x00\x00ar(Wb)\x01",
            .exp_error = error.SQLiteError,
        },
        .{
            .input = "SELECT?",
            .exp_error = error.ExecReturnedData,
        },
    };

    inline for (test_cases) |tc| {
        var db = try getTestDb();
        defer db.deinit();

        try testing.expectError(tc.exp_error, db.execDynamic(tc.input, .{}, .{}));
    }
}

test "tagged union" {
    var db = try getTestDb();
    defer db.deinit();
    try addTestData(&db);

    const Foobar = union(enum) {
        name: []const u8,
        age: usize,
    };

    try db.exec("DROP TABLE IF EXISTS foobar", .{}, .{});
    try db.exec("CREATE TABLE foobar(key TEXT, value ANY)", .{}, .{});

    var foobar = Foobar{ .name = "hello" };

    {
        try db.exec("INSERT INTO foobar(key, value) VALUES($key, $value)", .{}, .{
            .key = std.meta.tagName(std.meta.activeTag(foobar)),
            .value = foobar,
        });

        var arena = heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const result = try db.oneAlloc(
            struct {
                key: []const u8,
                value: []const u8,
            },
            arena.allocator(),
            "SELECT key, value FROM foobar WHERE key = $key",
            .{},
            .{
                std.meta.tagName(std.meta.activeTag(foobar)),
            },
        );
        try testing.expect(result != null);
        try testing.expectEqualStrings("name", result.?.key);
        try testing.expectEqualStrings(foobar.name, result.?.value);
    }

    {
        foobar = Foobar{ .age = 204 };

        try db.exec("INSERT INTO foobar(key, value) VALUES($key, $value)", .{}, .{
            .key = std.meta.tagName(std.meta.activeTag(foobar)),
            .value = foobar,
        });

        var arena = heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const result = try db.oneAlloc(
            struct {
                key: []const u8,
                value: usize,
            },
            arena.allocator(),
            "SELECT key, value FROM foobar WHERE key = $key",
            .{},
            .{
                std.meta.tagName(std.meta.activeTag(foobar)),
            },
        );
        try testing.expect(result != null);
        try testing.expectEqualStrings("age", result.?.key);
        try testing.expectEqual(foobar.age, result.?.value);
    }
}
