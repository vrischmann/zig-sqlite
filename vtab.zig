const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;

const c = @import("c.zig").c;
const versionGreaterThanOrEqualTo = @import("c.zig").versionGreaterThanOrEqualTo;
const getTestDb = @import("test.zig").getTestDb;
const Diagnostics = @import("sqlite.zig").Diagnostics;
const Blob = @import("sqlite.zig").Blob;
const Text = @import("sqlite.zig").Text;
const helpers = @import("helpers.zig");

const logger = std.log.scoped(.vtab);

/// ModuleContext contains state that is needed by all implementations of virtual tables.
///
/// Currently there's only an allocator.
pub const ModuleContext = struct {
    allocator: mem.Allocator,
};

fn dupeToSQLiteString(s: []const u8) [*c]const u8 {
    var buffer = @ptrCast([*c]u8, c.sqlite3_malloc(@intCast(c_int, s.len) + 1));

    mem.copy(u8, buffer[0..s.len], s);
    buffer[s.len] = 0;

    return buffer;
}

/// VTabDiagnostics is used by the user to report error diagnostics to the virtual table.
pub const VTabDiagnostics = struct {
    const Self = @This();

    allocator: mem.Allocator,

    error_message: []const u8 = "unknown error",

    pub fn setErrorMessage(self: *Self, comptime format_string: []const u8, values: anytype) void {
        self.error_message = fmt.allocPrint(self.allocator, format_string, values) catch |err| switch (err) {
            error.OutOfMemory => "can't set diagnostic message, out of memory",
        };
    }
};

pub const BestIndexBuilder = struct {
    const Self = @This();

    /// Constraint operator codes.
    /// See https://sqlite.org/c3ref/c_index_constraint_eq.html
    pub const ConstraintOp = if (versionGreaterThanOrEqualTo(3, 38, 0))
        enum {
            eq,
            gt,
            le,
            lt,
            ge,
            match,
            like,
            glob,
            regexp,
            ne,
            is_not,
            is_not_null,
            is_null,
            is,
            limit,
            offset,
        }
    else
        enum {
            eq,
            gt,
            le,
            lt,
            ge,
            match,
            like,
            glob,
            regexp,
            ne,
            is_not,
            is_not_null,
            is_null,
            is,
        };

    const ConstraintOpFromCodeError = error{
        InvalidCode,
    };

    fn constraintOpFromCode(code: u8) ConstraintOpFromCodeError!ConstraintOp {
        if (comptime versionGreaterThanOrEqualTo(3, 38, 0)) {
            switch (code) {
                c.SQLITE_INDEX_CONSTRAINT_LIMIT => return .limit,
                c.SQLITE_INDEX_CONSTRAINT_OFFSET => return .offset,
                else => {},
            }
        }

        switch (code) {
            c.SQLITE_INDEX_CONSTRAINT_EQ => return .eq,
            c.SQLITE_INDEX_CONSTRAINT_GT => return .gt,
            c.SQLITE_INDEX_CONSTRAINT_LE => return .le,
            c.SQLITE_INDEX_CONSTRAINT_LT => return .lt,
            c.SQLITE_INDEX_CONSTRAINT_GE => return .ge,
            c.SQLITE_INDEX_CONSTRAINT_MATCH => return .match,
            c.SQLITE_INDEX_CONSTRAINT_LIKE => return .like,
            c.SQLITE_INDEX_CONSTRAINT_GLOB => return .glob,
            c.SQLITE_INDEX_CONSTRAINT_REGEXP => return .regexp,
            c.SQLITE_INDEX_CONSTRAINT_NE => return .ne,
            c.SQLITE_INDEX_CONSTRAINT_ISNOT => return .is_not,
            c.SQLITE_INDEX_CONSTRAINT_ISNOTNULL => return .is_not_null,
            c.SQLITE_INDEX_CONSTRAINT_ISNULL => return .is_null,
            c.SQLITE_INDEX_CONSTRAINT_IS => return .is,
            else => return error.InvalidCode,
        }
    }

    // WHERE clause constraint
    pub const Constraint = struct {
        // Column constrained. -1 for ROWID
        column: isize,
        op: ConstraintOp,
        usable: bool,

        usage: struct {
            // If >0, constraint is part of argv to xFilter
            argv_index: i32 = 0,
            // Id >0, do not code a test for this constraint
            omit: bool = false,
        },
    };

    // ORDER BY clause
    pub const OrderBy = struct {
        column: usize,
        order: enum {
            desc,
            asc,
        },
    };

    /// Internal state
    allocator: mem.Allocator,
    id_str_buffer: std.ArrayList(u8),
    index_info: *c.sqlite3_index_info,

    /// List of WHERE clause constraints
    ///
    /// Similar to `aConstraint` in the Inputs section of sqlite3_index_info except we embed the constraint usage in there too.
    /// This makes it nicer to use for the user.
    constraints: []Constraint,

    /// Indicate which columns of the virtual table are actually used by the statement.
    /// If the lowest bit of colUsed is set, that means that the first column is used.
    /// The second lowest bit corresponds to the second column. And so forth.
    ///
    /// Maps to the `colUsed` field.
    columns_used: u64,

    /// Index identifier.
    /// This is passed to the filtering function to identify which index to use.
    ///
    /// Maps to the `idxNum` and `idxStr` field in sqlite3_index_info.
    /// Id id.id_str is non empty the string will be copied to a SQLite-allocated buffer and `needToFreeIdxStr` will be 1.
    id: IndexIdentifier,

    /// If the virtual table will output its rows already in the order specified by the ORDER BY clause then this can be set to true.
    /// This will indicate to SQLite that it doesn't need to do a sorting pass.
    ///
    /// Maps to the `orderByConsumed` field.
    already_ordered: bool = false,

    /// Estimated number of "disk access operations" required to execute this query.
    ///
    /// Maps to the `estimatedCost` field.
    estimated_cost: ?f64 = null,

    /// Estimated number of rows returned by this query.
    ///
    /// Maps to the `estimatedRows` field.
    ///
    /// ODO(vincent): implement this
    estimated_rows: ?i64 = null,

    /// Additiounal flags for this index.
    ///
    /// Maps to the `idxFlags` field.
    flags: struct {
        unique: bool = false,
    } = .{},

    const InitError = error{} || mem.Allocator.Error || ConstraintOpFromCodeError;

    fn init(allocator: mem.Allocator, index_info: *c.sqlite3_index_info) InitError!Self {
        var res = Self{
            .allocator = allocator,
            .index_info = index_info,
            .id_str_buffer = std.ArrayList(u8).init(allocator),
            .constraints = try allocator.alloc(Constraint, @intCast(usize, index_info.nConstraint)),
            .columns_used = @intCast(u64, index_info.colUsed),
            .id = .{},
        };

        for (res.constraints) |*constraint, i| {
            const raw_constraint = index_info.aConstraint[i];

            constraint.column = @intCast(isize, raw_constraint.iColumn);
            constraint.op = try constraintOpFromCode(raw_constraint.op);
            constraint.usable = if (raw_constraint.usable == 1) true else false;
            constraint.usage = .{};
        }

        return res;
    }

    /// Returns true if the column is used, false otherwise.
    pub fn isColumnUsed(self: *Self, column: u6) bool {
        const mask = @as(u64, 1) << column - 1;
        return self.columns_used & mask == mask;
    }

    /// Builds the final index data.
    ///
    /// Internally it populates the sqlite3_index_info "Outputs" fields using the information set by the user.
    pub fn build(self: *Self) void {
        var index_info = self.index_info;

        // Populate the constraint usage
        var constraint_usage: []c.sqlite3_index_constraint_usage = index_info.aConstraintUsage[0..self.constraints.len];
        for (self.constraints) |constraint, i| {
            constraint_usage[i].argvIndex = constraint.usage.argv_index;
            constraint_usage[i].omit = if (constraint.usage.omit) 1 else 0;
        }

        // Identifiers
        index_info.idxNum = @intCast(c_int, self.id.num);
        if (self.id.str.len > 0) {
            // Must always be NULL-terminated so add 1
            const tmp = @ptrCast([*c]u8, c.sqlite3_malloc(@intCast(c_int, self.id.str.len + 1)));

            mem.copy(u8, tmp[0..self.id.str.len], self.id.str);
            tmp[self.id.str.len] = 0;

            index_info.idxStr = tmp;
            index_info.needToFreeIdxStr = 1;
        }

        index_info.orderByConsumed = if (self.already_ordered) 1 else 0;
        if (self.estimated_cost) |estimated_cost| {
            index_info.estimatedCost = estimated_cost;
        }
        if (self.estimated_rows) |estimated_rows| {
            index_info.estimatedRows = estimated_rows;
        }

        // Flags
        index_info.idxFlags = 0;
        if (self.flags.unique) {
            index_info.idxFlags |= c.SQLITE_INDEX_SCAN_UNIQUE;
        }
    }
};

/// Identifies an index for a virtual table.
///
/// The user-provided buildBestIndex functions sets the index identifier.
/// These fields are meaningless for SQLite so they can be whatever you want as long as
/// both buildBestIndex and filter functions agree on what they mean.
pub const IndexIdentifier = struct {
    num: i32 = 0,
    str: []const u8 = "",

    fn fromC(idx_num: c_int, idx_str: [*c]const u8) IndexIdentifier {
        return IndexIdentifier{
            .num = @intCast(i32, idx_num),
            .str = if (idx_str != null) mem.sliceTo(idx_str, 0) else "",
        };
    }
};

pub const FilterArg = struct {
    value: ?*c.sqlite3_value,

    pub fn as(self: FilterArg, comptime Type: type) Type {
        var result: Type = undefined;
        helpers.setTypeFromValue(Type, &result, self.value.?);

        return result;
    }
};

/// Validates that a type implements everything required to be a cursor for a virtual table.
fn validateCursorType(comptime Table: type) void {
    const Cursor = Table.Cursor;

    // Validate the `init` function
    {
        if (!meta.trait.hasDecls(Cursor, .{"InitError"})) {
            @compileError("the Cursor type must declare a InitError error set for the init function");
        }

        const error_message =
            \\the Cursor.init function must have the signature `fn init(allocator: std.mem.Allocator, parent: *Table) InitError!*Cursor`
        ;

        if (!meta.trait.hasFn("init")(Cursor)) {
            @compileError("the Cursor type must have an init function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.init)).Fn;

        if (info.args.len != 2) @compileError(error_message);
        if (info.args[0].arg_type.? != mem.Allocator) @compileError(error_message);
        if (info.args[1].arg_type.? != *Table) @compileError(error_message);
        if (info.return_type.? != Cursor.InitError!*Cursor) @compileError(error_message);
    }

    // Validate the `deinit` function
    {
        const error_message =
            \\the Cursor.deinit function must have the signature `fn deinit(cursor: *Cursor) void`
        ;

        if (!meta.trait.hasFn("deinit")(Cursor)) {
            @compileError("the Cursor type must have a deinit function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.deinit)).Fn;

        if (info.args.len != 1) @compileError(error_message);
        if (info.args[0].arg_type.? != *Cursor) @compileError(error_message);
        if (info.return_type.? != void) @compileError(error_message);
    }

    // Validate the `next` function
    {
        if (!meta.trait.hasDecls(Cursor, .{"NextError"})) {
            @compileError("the Cursor type must declare a NextError error set for the next function");
        }

        const error_message =
            \\the Cursor.next function must have the signature `fn next(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics) NextError!void`
        ;

        if (!meta.trait.hasFn("next")(Cursor)) {
            @compileError("the Cursor type must have a next function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.next)).Fn;

        if (info.args.len != 2) @compileError(error_message);
        if (info.args[0].arg_type.? != *Cursor) @compileError(error_message);
        if (info.args[1].arg_type.? != *VTabDiagnostics) @compileError(error_message);
        if (info.return_type.? != Cursor.NextError!void) @compileError(error_message);
    }

    // Validate the `hasNext` function
    {
        if (!meta.trait.hasDecls(Cursor, .{"HasNextError"})) {
            @compileError("the Cursor type must declare a HasNextError error set for the hasNext function");
        }

        const error_message =
            \\the Cursor.hasNext function must have the signature `fn hasNext(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics) HasNextError!bool`
        ;

        if (!meta.trait.hasFn("hasNext")(Cursor)) {
            @compileError("the Cursor type must have a hasNext function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.hasNext)).Fn;

        if (info.args.len != 2) @compileError(error_message);
        if (info.args[0].arg_type.? != *Cursor) @compileError(error_message);
        if (info.args[1].arg_type.? != *VTabDiagnostics) @compileError(error_message);
        if (info.return_type.? != Cursor.HasNextError!bool) @compileError(error_message);
    }

    // Validate the `filter` function
    {
        if (!meta.trait.hasDecls(Cursor, .{"FilterError"})) {
            @compileError("the Cursor type must declare a FilterError error set for the filter function");
        }

        const error_message =
            \\the Cursor.filter function must have the signature `fn filter(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics, index: sqlite.vtab.IndexIdentifier, args: []FilterArg) FilterError!bool`
        ;

        if (!meta.trait.hasFn("filter")(Cursor)) {
            @compileError("the Cursor type must have a filter function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.filter)).Fn;

        if (info.args.len != 4) @compileError(error_message);
        if (info.args[0].arg_type.? != *Cursor) @compileError(error_message);
        if (info.args[1].arg_type.? != *VTabDiagnostics) @compileError(error_message);
        if (info.args[2].arg_type.? != IndexIdentifier) @compileError(error_message);
        if (info.args[3].arg_type.? != []FilterArg) @compileError(error_message);
        if (info.return_type.? != Cursor.FilterError!void) @compileError(error_message);
    }

    // Validate the `column` function
    {
        if (!meta.trait.hasDecls(Cursor, .{"ColumnError"})) {
            @compileError("the Cursor type must declare a ColumnError error set for the column function");
        }
        if (!meta.trait.hasDecls(Cursor, .{"Column"})) {
            @compileError("the Cursor type must declare a Column type for the return type of the column function");
        }

        const error_message =
            \\the Cursor.column function must have the signature `fn column(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics, column_number: i32) ColumnError!Column`
        ;

        if (!meta.trait.hasFn("column")(Cursor)) {
            @compileError("the Cursor type must have a column function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.column)).Fn;

        if (info.args.len != 3) @compileError(error_message);
        if (info.args[0].arg_type.? != *Cursor) @compileError(error_message);
        if (info.args[1].arg_type.? != *VTabDiagnostics) @compileError(error_message);
        if (info.args[2].arg_type.? != i32) @compileError(error_message);
        if (info.return_type.? != Cursor.ColumnError!Cursor.Column) @compileError(error_message);
    }

    // Validate the `rowId` function
    {
        if (!meta.trait.hasDecls(Cursor, .{"RowIDError"})) {
            @compileError("the Cursor type must declare a RowIDError error set for the rowId function");
        }

        const error_message =
            \\the Cursor.rowId function must have the signature `fn rowId(cursor: *Cursor, diags: *sqlite.vtab.VTabDiagnostics) RowIDError!i64`
        ;

        if (!meta.trait.hasFn("rowId")(Cursor)) {
            @compileError("the Cursor type must have a rowId function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Cursor.rowId)).Fn;

        if (info.args.len != 2) @compileError(error_message);
        if (info.args[0].arg_type.? != *Cursor) @compileError(error_message);
        if (info.args[1].arg_type.? != *VTabDiagnostics) @compileError(error_message);
        if (info.return_type.? != Cursor.RowIDError!i64) @compileError(error_message);
    }
}

/// Validates that a type implements everything required to be a virtual table.
fn validateTableType(comptime Table: type) void {
    // Validate the `init` function
    {
        if (!meta.trait.hasDecls(Table, .{"InitError"})) {
            @compileError("the Table type must declare a InitError error set for the init function");
        }

        const error_message =
            \\the Table.init function must have the signature `fn init(allocator: std.mem.Allocator, diags: *sqlite.vtab.VTabDiagnostics, args: []const ModuleArgument) InitError!*Table`
        ;

        if (!meta.trait.hasFn("init")(Table)) {
            @compileError("the Table type must have a init function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Table.init)).Fn;

        if (info.args.len != 3) @compileError(error_message);
        if (info.args[0].arg_type.? != mem.Allocator) @compileError(error_message);
        if (info.args[1].arg_type.? != *VTabDiagnostics) @compileError(error_message);
        // TODO(vincent): maybe allow a signature without the args since a table can do withoout them
        if (info.args[2].arg_type.? != []const ModuleArgument) @compileError(error_message);
        if (info.return_type.? != Table.InitError!*Table) @compileError(error_message);
    }

    // Validate the `deinit` function
    {
        const error_message =
            \\the Table.deinit function must have the signature `fn deinit(table: *Table, allocator: std.mem.Allocator) void`
        ;

        if (!meta.trait.hasFn("deinit")(Table)) {
            @compileError("the Table type must have a deinit function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Table.deinit)).Fn;

        if (info.args.len != 2) @compileError(error_message);
        if (info.args[0].arg_type.? != *Table) @compileError(error_message);
        if (info.args[1].arg_type.? != mem.Allocator) @compileError(error_message);
        if (info.return_type.? != void) @compileError(error_message);
    }

    // Validate the `buildBestIndex` function
    {
        if (!meta.trait.hasDecls(Table, .{"BuildBestIndexError"})) {
            @compileError("the Cursor type must declare a BuildBestIndexError error set for the buildBestIndex function");
        }

        const error_message =
            \\the Table.buildBestIndex function must have the signature `fn buildBestIndex(table: *Table, diags: *sqlite.vtab.VTabDiagnostics, builder: *sqlite.vtab.BestIndexBuilder) BuildBestIndexError!void`
        ;

        if (!meta.trait.hasFn("buildBestIndex")(Table)) {
            @compileError("the Table type must have a buildBestIndex function, " ++ error_message);
        }

        const info = @typeInfo(@TypeOf(Table.buildBestIndex)).Fn;

        if (info.args.len != 3) @compileError(error_message);
        if (info.args[0].arg_type.? != *Table) @compileError(error_message);
        if (info.args[1].arg_type.? != *VTabDiagnostics) @compileError(error_message);
        if (info.args[2].arg_type.? != *BestIndexBuilder) @compileError(error_message);
        if (info.return_type.? != Table.BuildBestIndexError!void) @compileError(error_message);
    }

    if (!meta.trait.hasDecls(Table, .{"Cursor"})) {
        @compileError("the Table type must declare a Cursor type");
    }
}

pub const ModuleArgument = union(enum) {
    kv: struct {
        key: []const u8,
        value: []const u8,
    },
    plain: []const u8,
};

const ParseModuleArgumentsError = error{} || mem.Allocator.Error;

fn parseModuleArguments(allocator: mem.Allocator, argc: c_int, argv: [*c]const [*c]const u8) ParseModuleArgumentsError![]ModuleArgument {
    var res = try allocator.alloc(ModuleArgument, @intCast(usize, argc));
    errdefer allocator.free(res);

    for (res) |*marg, i| {
        // The documentation of sqlite says each string in argv is null-terminated
        const arg = mem.sliceTo(argv[i], 0);

        if (mem.indexOfScalar(u8, arg, '=')) |pos| {
            marg.* = ModuleArgument{
                .kv = .{
                    .key = arg[0..pos],
                    .value = arg[pos + 1 ..],
                },
            };
        } else {
            marg.* = ModuleArgument{ .plain = arg };
        }
    }

    return res;
}

pub fn VirtualTable(
    comptime table_name: [:0]const u8,
    comptime Table: type,
) type {
    // Validate the Table type

    comptime {
        validateTableType(Table);
        validateCursorType(Table);
    }

    const State = struct {
        const Self = @This();

        /// vtab must come first !
        /// The different functions receive a pointer to a vtab so we have to use @fieldParentPtr to get our state.
        vtab: c.sqlite3_vtab,
        /// The module context contains state that's the same for _all_ implementations of virtual tables.
        module_context: *ModuleContext,
        /// The table is the actual virtual table implementation.
        table: *Table,

        const InitError = error{} || mem.Allocator.Error || Table.InitError;

        fn init(module_context: *ModuleContext, table: *Table) InitError!*Self {
            var res = try module_context.allocator.create(Self);
            res.* = .{
                .vtab = mem.zeroes(c.sqlite3_vtab),
                .module_context = module_context,
                .table = table,
            };
            return res;
        }

        fn deinit(self: *Self) void {
            self.table.deinit(self.module_context.allocator);
            self.module_context.allocator.destroy(self);
        }
    };

    const CursorState = struct {
        const Self = @This();

        /// vtab_cursor must come first !
        /// The different functions receive a pointer to a vtab_cursor so we have to use @fieldParentPtr to get our state.
        vtab_cursor: c.sqlite3_vtab_cursor,
        /// The module context contains state that's the same for _all_ implementations of virtual tables.
        module_context: *ModuleContext,
        /// The table is the actual virtual table implementation.
        table: *Table,
        cursor: *Table.Cursor,

        const InitError = error{} || mem.Allocator.Error || Table.Cursor.InitError;

        fn init(module_context: *ModuleContext, table: *Table) InitError!*Self {
            var res = try module_context.allocator.create(Self);
            errdefer module_context.allocator.destroy(res);

            res.* = .{
                .vtab_cursor = mem.zeroes(c.sqlite3_vtab_cursor),
                .module_context = module_context,
                .table = table,
                .cursor = try Table.Cursor.init(module_context.allocator, table),
            };

            return res;
        }

        fn deinit(self: *Self) void {
            self.cursor.deinit();
            self.module_context.allocator.destroy(self);
        }
    };

    return struct {
        const Self = @This();

        pub const name = table_name;
        pub const module = if (versionGreaterThanOrEqualTo(3, 26, 0))
            c.sqlite3_module{
                .iVersion = 0,
                .xCreate = xConnect, // TODO(vincent): implement xCreate and use it
                .xConnect = xConnect,
                .xBestIndex = xBestIndex,
                .xDisconnect = xDisconnect,
                .xDestroy = xDisconnect, // TODO(vincent): implement xDestroy and use it
                .xOpen = xOpen,
                .xClose = xClose,
                .xFilter = xFilter,
                .xNext = xNext,
                .xEof = xEof,
                .xColumn = xColumn,
                .xRowid = xRowid,
                .xUpdate = null,
                .xBegin = null,
                .xSync = null,
                .xCommit = null,
                .xRollback = null,
                .xFindFunction = null,
                .xRename = null,
                .xSavepoint = null,
                .xRelease = null,
                .xRollbackTo = null,
                .xShadowName = null,
            }
        else
            c.sqlite3_module{
                .iVersion = 0,
                .xCreate = xConnect, // TODO(vincent): implement xCreate and use it
                .xConnect = xConnect,
                .xBestIndex = xBestIndex,
                .xDisconnect = xDisconnect,
                .xDestroy = xDisconnect, // TODO(vincent): implement xDestroy and use it
                .xOpen = xOpen,
                .xClose = xClose,
                .xFilter = xFilter,
                .xNext = xNext,
                .xEof = xEof,
                .xColumn = xColumn,
                .xRowid = xRowid,
                .xUpdate = null,
                .xBegin = null,
                .xSync = null,
                .xCommit = null,
                .xRollback = null,
                .xFindFunction = null,
                .xRename = null,
                .xSavepoint = null,
                .xRelease = null,
                .xRollbackTo = null,
            };

        table: Table,

        fn getModuleContext(ptr: ?*anyopaque) *ModuleContext {
            return @ptrCast(*ModuleContext, @alignCast(@alignOf(ModuleContext), ptr.?));
        }

        fn createState(allocator: mem.Allocator, diags: *VTabDiagnostics, module_context: *ModuleContext, args: []const ModuleArgument) !*State {
            // The Context holds the complete of the virtual table and lives for its entire lifetime.
            // Context.deinit() will be called when xDestroy is called.

            var table = try Table.init(allocator, diags, args);
            errdefer table.deinit(allocator);

            return try State.init(module_context, table);
        }

        fn xCreate(db: ?*c.sqlite3, module_context_ptr: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, vtab: [*c][*c]c.sqlite3_vtab, err_str: [*c][*c]const u8) callconv(.C) c_int {
            _ = db;
            _ = module_context_ptr;
            _ = argc;
            _ = argv;
            _ = vtab;
            _ = err_str;

            debug.print("xCreate\n", .{});

            return c.SQLITE_ERROR;
        }

        fn xConnect(db: ?*c.sqlite3, module_context_ptr: ?*anyopaque, argc: c_int, argv: [*c]const [*c]const u8, vtab: [*c][*c]c.sqlite3_vtab, err_str: [*c][*c]const u8) callconv(.C) c_int {
            const module_context = getModuleContext(module_context_ptr);

            var arena = heap.ArenaAllocator.init(module_context.allocator);
            defer arena.deinit();

            // Convert the C-like args to more idiomatic types.
            const args = parseModuleArguments(arena.allocator(), argc, argv) catch {
                err_str.* = dupeToSQLiteString("out of memory");
                return c.SQLITE_ERROR;
            };

            //
            // Create the context and state, assign it to the vtab and declare the vtab.
            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const state = createState(module_context.allocator, &diags, module_context, args) catch {
                err_str.* = dupeToSQLiteString(diags.error_message);
                return c.SQLITE_ERROR;
            };
            vtab.* = @ptrCast(*c.sqlite3_vtab, state);

            const res = c.sqlite3_declare_vtab(db, @ptrCast([*c]const u8, state.table.schema));
            if (res != c.SQLITE_OK) {
                return c.SQLITE_ERROR;
            }

            return c.SQLITE_OK;
        }

        fn xBestIndex(vtab: [*c]c.sqlite3_vtab, index_info_ptr: [*c]c.sqlite3_index_info) callconv(.C) c_int {
            const index_info: *c.sqlite3_index_info = index_info_ptr orelse unreachable;

            //

            const state = @fieldParentPtr(State, "vtab", vtab);

            var arena = heap.ArenaAllocator.init(state.module_context.allocator);
            defer arena.deinit();

            // Create an index builder and let the user build the index.

            var builder = BestIndexBuilder.init(arena.allocator(), index_info) catch |err| {
                logger.err("unable to create best index builder, err: {!}", .{err});
                return c.SQLITE_ERROR;
            };

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            state.table.buildBestIndex(&diags, &builder) catch |err| {
                logger.err("unable to build best index, err: {!}", .{err});
                return c.SQLITE_ERROR;
            };

            return c.SQLITE_OK;
        }

        fn xDisconnect(vtab: [*c]c.sqlite3_vtab) callconv(.C) c_int {
            const state = @fieldParentPtr(State, "vtab", vtab);
            state.deinit();

            return c.SQLITE_OK;
        }

        fn xDestroy(vtab: [*c]c.sqlite3_vtab) callconv(.C) c_int {
            _ = vtab;

            debug.print("xDestroy\n", .{});

            return c.SQLITE_ERROR;
        }

        fn xOpen(vtab: [*c]c.sqlite3_vtab, vtab_cursor: [*c][*c]c.sqlite3_vtab_cursor) callconv(.C) c_int {
            const state = @fieldParentPtr(State, "vtab", vtab);

            const cursor_state = CursorState.init(state.module_context, state.table) catch |err| {
                logger.err("unable to create cursor state, err: {!}", .{err});
                return c.SQLITE_ERROR;
            };
            vtab_cursor.* = @ptrCast(*c.sqlite3_vtab_cursor, cursor_state);

            return c.SQLITE_OK;
        }

        fn xClose(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.C) c_int {
            const cursor_state = @fieldParentPtr(CursorState, "vtab_cursor", vtab_cursor);
            cursor_state.deinit();

            return c.SQLITE_OK;
        }

        fn xEof(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.C) c_int {
            const cursor_state = @fieldParentPtr(CursorState, "vtab_cursor", vtab_cursor);
            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const has_next = cursor.hasNext(&diags) catch {
                logger.err("unable to call Table.Cursor.hasNext: {s}", .{diags.error_message});
                return 1;
            };

            if (has_next) {
                return 0;
            } else {
                return 1;
            }
        }

        const FilterArgsFromCPointerError = error{} || mem.Allocator.Error;

        fn filterArgsFromCPointer(allocator: mem.Allocator, argc: c_int, argv: [*c]?*c.sqlite3_value) FilterArgsFromCPointerError![]FilterArg {
            const size = @intCast(usize, argc);

            var res = try allocator.alloc(FilterArg, size);
            for (res) |*item, i| {
                item.* = .{
                    .value = argv[i],
                };
            }

            return res;
        }

        fn xFilter(vtab_cursor: [*c]c.sqlite3_vtab_cursor, idx_num: c_int, idx_str: [*c]const u8, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.C) c_int {
            const cursor_state = @fieldParentPtr(CursorState, "vtab_cursor", vtab_cursor);
            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            const id = IndexIdentifier.fromC(idx_num, idx_str);

            var args = filterArgsFromCPointer(arena.allocator(), argc, argv) catch |err| {
                logger.err("unable to create filter args, err: {!}", .{err});
                return c.SQLITE_ERROR;
            };

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            cursor.filter(&diags, id, args) catch {
                logger.err("unable to call Table.Cursor.filter: {s}", .{diags.error_message});
                return c.SQLITE_ERROR;
            };

            return c.SQLITE_OK;
        }

        fn xNext(vtab_cursor: [*c]c.sqlite3_vtab_cursor) callconv(.C) c_int {
            const cursor_state = @fieldParentPtr(CursorState, "vtab_cursor", vtab_cursor);
            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            cursor.next(&diags) catch {
                logger.err("unable to call Table.Cursor.next: {s}", .{diags.error_message});
                return c.SQLITE_ERROR;
            };

            return c.SQLITE_OK;
        }

        fn xColumn(vtab_cursor: [*c]c.sqlite3_vtab_cursor, ctx: ?*c.sqlite3_context, n: c_int) callconv(.C) c_int {
            const cursor_state = @fieldParentPtr(CursorState, "vtab_cursor", vtab_cursor);
            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const column = cursor.column(&diags, @intCast(i32, n)) catch {
                logger.err("unable to call Table.Cursor.column: {s}", .{diags.error_message});
                return c.SQLITE_ERROR;
            };

            // TODO(vincent): does it make sense to put this in setResult ? Functions could also return a union.
            const ColumnType = @TypeOf(column);
            switch (@typeInfo(ColumnType)) {
                .Union => |info| {
                    if (info.tag_type) |UnionTagType| {
                        inline for (info.fields) |u_field| {

                            // This wasn't entirely obvious when I saw code like this elsewhere, it works because of type coercion.
                            // See https://ziglang.org/documentation/master/#Type-Coercion-unions-and-enums
                            const column_tag: std.meta.Tag(ColumnType) = column;
                            const this_tag: std.meta.Tag(ColumnType) = @field(UnionTagType, u_field.name);

                            if (column_tag == this_tag) {
                                const column_value = @field(column, u_field.name);

                                helpers.setResult(ctx, column_value);
                            }
                        }
                    } else {
                        @compileError("cannot use bare unions as a column");
                    }
                },
                else => helpers.setResult(ctx, column),
            }

            return c.SQLITE_OK;
        }

        fn xRowid(vtab_cursor: [*c]c.sqlite3_vtab_cursor, row_id_ptr: [*c]c.sqlite3_int64) callconv(.C) c_int {
            const cursor_state = @fieldParentPtr(CursorState, "vtab_cursor", vtab_cursor);
            const cursor = cursor_state.cursor;

            var arena = heap.ArenaAllocator.init(cursor_state.module_context.allocator);
            defer arena.deinit();

            //

            var diags = VTabDiagnostics{ .allocator = arena.allocator() };
            const row_id = cursor.rowId(&diags) catch {
                logger.err("unable to call Table.Cursor.rowId: {s}", .{diags.error_message});
                return c.SQLITE_ERROR;
            };

            row_id_ptr.* = row_id;

            return c.SQLITE_OK;
        }
    };
}

const TestVirtualTable = struct {
    pub const Cursor = TestVirtualTableCursor;

    const Row = struct {
        foo: []const u8,
        bar: []const u8,
        baz: isize,
    };

    arena_state: heap.ArenaAllocator.State,

    rows: []Row,
    schema: [:0]const u8,

    pub const InitError = error{} || mem.Allocator.Error || fmt.ParseIntError;

    pub fn init(gpa: mem.Allocator, diags: *VTabDiagnostics, args: []const ModuleArgument) InitError!*TestVirtualTable {
        var arena = heap.ArenaAllocator.init(gpa);
        const allocator = arena.allocator();

        var res = try allocator.create(TestVirtualTable);
        errdefer res.deinit(gpa);

        // Generate test data
        const rows = blk: {
            var n: usize = 0;
            for (args) |arg| {
                switch (arg) {
                    .plain => {},
                    .kv => |kv| {
                        if (mem.eql(u8, kv.key, "n")) {
                            n = fmt.parseInt(usize, kv.value, 10) catch |err| {
                                switch (err) {
                                    error.InvalidCharacter => diags.setErrorMessage("not a number: {s}", .{kv.value}),
                                    else => diags.setErrorMessage("got error while parsing value {s}: {!}", .{ kv.value, err }),
                                }
                                return err;
                            };
                        }
                    },
                }
            }

            //

            const data = &[_][]const u8{
                "Vincent", "José", "Michel",
            };

            var rand = std.rand.DefaultPrng.init(204882485);

            var tmp = try allocator.alloc(Row, n);
            for (tmp) |*s| {
                const foo_value = data[rand.random().intRangeLessThan(usize, 0, data.len)];
                const bar_value = data[rand.random().intRangeLessThan(usize, 0, data.len)];
                const baz_value = rand.random().intRangeAtMost(isize, 0, 200);

                s.* = .{
                    .foo = foo_value,
                    .bar = bar_value,
                    .baz = baz_value,
                };
            }

            break :blk tmp;
        };
        res.rows = rows;

        // Build the schema
        res.schema = try allocator.dupeZ(u8,
            \\CREATE TABLE foobar(foo TEXT, bar TEXT, baz INTEGER)
        );

        res.arena_state = arena.state;

        return res;
    }

    pub fn deinit(self: *TestVirtualTable, gpa: mem.Allocator) void {
        self.arena_state.promote(gpa).deinit();
    }

    fn connect(self: *TestVirtualTable) anyerror!void {
        _ = self;
        debug.print("connect\n", .{});
    }

    pub const BuildBestIndexError = error{} || mem.Allocator.Error;

    pub fn buildBestIndex(self: *TestVirtualTable, diags: *VTabDiagnostics, builder: *BestIndexBuilder) BuildBestIndexError!void {
        _ = self;
        _ = diags;

        var id_str_writer = builder.id_str_buffer.writer();

        var argv_index: i32 = 0;
        for (builder.constraints) |*constraint| {
            if (constraint.op == .eq) {
                argv_index += 1;
                constraint.usage.argv_index = argv_index;

                try id_str_writer.print("={d:<6}", .{constraint.column});
            }
        }

        //

        builder.id.str = try builder.id_str_buffer.toOwnedSlice();
        builder.estimated_cost = 200;
        builder.estimated_rows = 200;

        builder.build();
    }

    /// An iterator over the rows of this table capable of applying filters.
    /// The filters are used when the index asks for it.
    const Iterator = struct {
        rows: []Row,
        pos: usize,

        filters: struct {
            foo: ?[]const u8 = null,
            bar: ?[]const u8 = null,
        } = .{},

        fn init(rows: []Row) Iterator {
            return Iterator{
                .rows = rows,
                .pos = 0,
            };
        }

        fn currentRow(it: *Iterator) Row {
            return it.rows[it.pos];
        }

        fn hasNext(it: *Iterator) bool {
            return it.pos < it.rows.len;
        }

        fn next(it: *Iterator) void {
            const foo = it.filters.foo orelse "";
            const bar = it.filters.bar orelse "";

            it.pos += 1;

            while (it.pos < it.rows.len) : (it.pos += 1) {
                const row = it.rows[it.pos];

                if (foo.len > 0 and bar.len > 0 and mem.eql(u8, foo, row.foo) and mem.eql(u8, bar, row.bar)) break;
                if (foo.len > 0 and mem.eql(u8, foo, row.foo)) break;
                if (bar.len > 0 and mem.eql(u8, bar, row.bar)) break;
            }
        }
    };
};

const TestVirtualTableCursor = struct {
    allocator: mem.Allocator,
    parent: *TestVirtualTable,
    iterator: TestVirtualTable.Iterator,

    pub const InitError = error{} || mem.Allocator.Error;

    pub fn init(allocator: mem.Allocator, parent: *TestVirtualTable) InitError!*TestVirtualTableCursor {
        var res = try allocator.create(TestVirtualTableCursor);
        res.* = .{
            .allocator = allocator,
            .parent = parent,
            .iterator = TestVirtualTable.Iterator.init(parent.rows),
        };
        return res;
    }

    pub fn deinit(cursor: *TestVirtualTableCursor) void {
        cursor.allocator.destroy(cursor);
    }

    pub const FilterError = error{InvalidColumn} || fmt.ParseIntError;

    pub fn filter(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics, index: IndexIdentifier, args: []FilterArg) FilterError!void {
        _ = diags;

        var id = index.str;

        // NOTE(vincent): this is an ugly ass parser for the index string, don't judge me.

        var i: usize = 0;
        while (true) {
            const pos = mem.indexOfScalar(u8, id, '=') orelse break;

            const arg = args[i];
            i += 1;

            // 3 chars for the '=' marker
            // 6 chars because we format all columns in a 6 char wide string
            const col_str = id[pos + 1 .. pos + 1 + 6];
            const col = try fmt.parseInt(i32, mem.trimRight(u8, col_str, " "), 10);

            id = id[pos + 1 + 6 ..];

            //

            if (col == 0) {
                cursor.iterator.filters.foo = arg.as([]const u8);
            } else if (col == 1) {
                cursor.iterator.filters.bar = arg.as([]const u8);
            } else if (col == 2) {
                _ = arg.as(isize);
            } else {
                return error.InvalidColumn;
            }
        }
    }

    pub const NextError = error{};

    pub fn next(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics) NextError!void {
        _ = diags;

        cursor.iterator.next();
    }

    pub const HasNextError = error{};

    pub fn hasNext(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics) HasNextError!bool {
        _ = diags;

        return cursor.iterator.hasNext();
    }

    pub const Column = union(enum) {
        foo: []const u8,
        bar: []const u8,
        baz: isize,
    };

    pub const ColumnError = error{InvalidColumn};

    pub fn column(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics, column_number: i32) ColumnError!Column {
        _ = diags;

        const row = cursor.iterator.currentRow();

        switch (column_number) {
            0 => return Column{ .foo = row.foo },
            1 => return Column{ .bar = row.bar },
            2 => return Column{ .baz = row.baz },
            else => return error.InvalidColumn,
        }
    }

    pub const RowIDError = error{};

    pub fn rowId(cursor: *TestVirtualTableCursor, diags: *VTabDiagnostics) RowIDError!i64 {
        _ = diags;

        return @intCast(i64, cursor.iterator.pos);
    }
};

test "virtual table" {
    var db = try getTestDb();
    defer db.deinit();

    var myvtab_module_context = ModuleContext{
        .allocator = testing.allocator,
    };

    try db.createVirtualTable(
        "myvtab",
        &myvtab_module_context,
        TestVirtualTable,
    );

    var diags = Diagnostics{};
    try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS vtab_foobar USING myvtab(n=200)", .{ .diags = &diags }, .{});

    // Filter with both `foo` and `bar`

    var stmt = try db.prepareWithDiags(
        "SELECT rowid, foo, bar, baz FROM vtab_foobar WHERE foo = ?{[]const u8} AND bar = ?{[]const u8} AND baz > ?{usize}",
        .{ .diags = &diags },
    );
    defer stmt.deinit();

    var rows_arena = heap.ArenaAllocator.init(testing.allocator);
    defer rows_arena.deinit();

    const rows = try stmt.all(
        struct {
            id: i64,
            foo: []const u8,
            bar: []const u8,
            baz: usize,
        },
        rows_arena.allocator(),
        .{ .diags = &diags },
        .{
            .foo = @as([]const u8, "Vincent"),
            .bar = @as([]const u8, "Michel"),
            .baz = @as(usize, 2),
        },
    );
    try testing.expect(rows.len > 0);

    for (rows) |row| {
        try testing.expectEqualStrings("Vincent", row.foo);
        try testing.expectEqualStrings("Michel", row.bar);
        try testing.expect(row.baz > 2);
    }
}

test "parse module arguments" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try allocator.alloc([*c]const u8, 20);
    for (args) |*arg, i| {
        const tmp = try fmt.allocPrintZ(allocator, "arg={d}", .{i});
        arg.* = @ptrCast([*c]const u8, tmp);
    }

    const res = try parseModuleArguments(
        allocator,
        @intCast(c_int, args.len),
        @ptrCast([*c]const [*c]const u8, args),
    );
    try testing.expectEqual(@as(usize, 20), res.len);

    for (res) |arg, i| {
        try testing.expectEqualStrings("arg", arg.kv.key);
        try testing.expectEqual(i, try fmt.parseInt(usize, arg.kv.value, 10));
    }
}
