const std = @import("std");
const debug = std.debug;

const c = @import("c.zig").c;

const Blob = @import("sqlite.zig").Blob;
const Text = @import("sqlite.zig").Text;

/// Sets the result of a function call in the context `ctx`.
///
/// Determines at compile time which sqlite3_result_XYZ function to use based on the type of `result`.
pub fn setResult(ctx: ?*c.sqlite3_context, result: anytype) void {
    const ResultType = @TypeOf(result);

    switch (ResultType) {
        Text => c.sqlite3_result_text(ctx, result.data.ptr, @intCast(c_int, result.data.len), c.SQLITE_TRANSIENT),
        Blob => c.sqlite3_result_blob(ctx, result.data.ptr, @intCast(c_int, result.data.len), c.SQLITE_TRANSIENT),
        else => switch (@typeInfo(ResultType)) {
            .Int => |info| if ((info.bits + if (info.signedness == .unsigned) 1 else 0) <= 32) {
                c.sqlite3_result_int(ctx, result);
            } else if ((info.bits + if (info.signedness == .unsigned) 1 else 0) <= 64) {
                c.sqlite3_result_int64(ctx, result);
            } else {
                @compileError("integer " ++ @typeName(ResultType) ++ " is not representable in sqlite");
            },
            .Float => c.sqlite3_result_double(ctx, result),
            .Bool => c.sqlite3_result_int(ctx, if (result) 1 else 0),
            .Array => |arr| switch (arr.child) {
                u8 => c.sqlite3_result_blob(ctx, &result, arr.len, c.SQLITE_TRANSIENT),
                else => @compileError("cannot use a result of type " ++ @typeName(ResultType)),
            },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => switch (ptr.child) {
                    u8 => c.sqlite3_result_text(ctx, result.ptr, @intCast(c_int, result.len), c.SQLITE_TRANSIENT),
                    else => @compileError("cannot use a result of type " ++ @typeName(ResultType)),
                },
                else => @compileError("cannot use a result of type " ++ @typeName(ResultType)),
            },
            else => @compileError("cannot use a result of type " ++ @typeName(ResultType)),
        },
    }
}

/// Sets a type using the provided value.
///
/// Determines at compile time which sqlite3_value_XYZ function to use based on the type `ArgType`.
pub fn setTypeFromValue(comptime ArgType: type, arg: *ArgType, sqlite_value: *c.sqlite3_value) void {
    switch (ArgType) {
        Text => arg.*.data = sliceFromValue(sqlite_value),
        Blob => arg.*.data = sliceFromValue(sqlite_value),
        else => switch (@typeInfo(ArgType)) {
            .Int => |info| if ((info.bits + if (info.signedness == .unsigned) 1 else 0) <= 32) {
                const value = c.sqlite3_value_int(sqlite_value);
                arg.* = @intCast(ArgType, value);
            } else if ((info.bits + if (info.signedness == .unsigned) 1 else 0) <= 64) {
                const value = c.sqlite3_value_int64(sqlite_value);
                arg.* = @intCast(ArgType, value);
            } else {
                @compileError("integer " ++ @typeName(ArgType) ++ " is not representable in sqlite");
            },
            .Float => {
                const value = c.sqlite3_value_double(sqlite_value);
                arg.* = @floatCast(ArgType, value);
            },
            .Bool => {
                const value = c.sqlite3_value_int(sqlite_value);
                arg.* = value > 0;
            },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => switch (ptr.child) {
                    u8 => arg.* = sliceFromValue(sqlite_value),
                    else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
                },
                else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
            },
            else => @compileError("cannot use an argument of type " ++ @typeName(ArgType)),
        },
    }
}

fn sliceFromValue(sqlite_value: *c.sqlite3_value) []const u8 {
    const size = @intCast(usize, c.sqlite3_value_bytes(sqlite_value));

    const value = c.sqlite3_value_text(sqlite_value);
    debug.assert(value != null); // TODO(vincent): how do we handle this properly ?

    return value.?[0..size];
}
