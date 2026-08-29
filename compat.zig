//! Compatibility layer for Zig 0.16 (`std.builtin.Type`) and 0.17+ (`std.lang.Type`).
//!
//! Zig 0.17 renamed `std.builtin.Type` to `std.lang.Type` and reshaped its payloads:
//!   - `Fn.is_var_args`  -> `Fn.attrs.varargs`
//!   - `Fn.params`       -> `Fn.param_types`
//!   - `Struct.fields`   -> `Struct.field_names` + `Struct.field_types`
//!   - `Union.fields`    -> `Union.field_names` + `Union.field_types`
//!
//! The helpers below select the right representation at comptime so that call sites
//! work unmodified on both versions.

const std = @import("std");
const builtin = @import("builtin");

const is_zig_16 = builtin.zig_version.minor <= 16;

/// Returns the field names of a struct type.
pub fn structFieldNames(comptime T: type) []const [:0]const u8 {
    if (is_zig_16) {
        return comptime blk: {
            const fields = @typeInfo(T).@"struct".fields;
            var names: [fields.len][:0]const u8 = undefined;
            for (fields, 0..) |f, i| names[i] = f.name;
            const final = names;
            break :blk &final;
        };
    } else {
        return @typeInfo(T).@"struct".field_names;
    }
}

/// Returns the field types of a struct type, parallel to `structFieldNames`.
pub fn structFieldTypes(comptime T: type) []const type {
    if (is_zig_16) {
        return comptime blk: {
            const fields = @typeInfo(T).@"struct".fields;
            var types: [fields.len]type = undefined;
            for (fields, 0..) |f, i| types[i] = f.type;
            const final = types;
            break :blk &final;
        };
    } else {
        return @typeInfo(T).@"struct".field_types;
    }
}

/// Returns the field names of a tagged union type.
pub fn unionFieldNames(comptime T: type) []const [:0]const u8 {
    if (is_zig_16) {
        return comptime blk: {
            const fields = @typeInfo(T).@"union".fields;
            var names: [fields.len][:0]const u8 = undefined;
            for (fields, 0..) |f, i| names[i] = f.name;
            const final = names;
            break :blk &final;
        };
    } else {
        return @typeInfo(T).@"union".field_names;
    }
}

/// Returns the field types of a tagged union type, parallel to `unionFieldNames`.
pub fn unionFieldTypes(comptime T: type) []const type {
    if (is_zig_16) {
        return comptime blk: {
            const fields = @typeInfo(T).@"union".fields;
            var types: [fields.len]type = undefined;
            for (fields, 0..) |f, i| types[i] = f.type;
            const final = types;
            break :blk &final;
        };
    } else {
        return @typeInfo(T).@"union".field_types;
    }
}

/// Returns true if the function type info describes a variadic function.
pub fn fnIsVarArgs(comptime fn_info: anytype) bool {
    if (is_zig_16) {
        return fn_info.is_var_args;
    } else {
        return fn_info.attrs.varargs;
    }
}

/// Returns the parameter types of a function type info, as `?type` values
/// (null represents an `anytype` or otherwise generic parameter).
pub fn fnParamTypes(comptime fn_info: anytype) []const ?type {
    if (is_zig_16) {
        return comptime blk: {
            var types: [fn_info.params.len]?type = undefined;
            for (fn_info.params, 0..) |p, i| types[i] = p.type;
            const final = types;
            break :blk &final;
        };
    } else {
        return fn_info.param_types;
    }
}

/// Returns the parameter type at the given index of a function type info.
pub fn fnParamType(comptime fn_info: anytype, comptime index: usize) ?type {
    if (is_zig_16) {
        return fn_info.params[index].type;
    } else {
        return fn_info.param_types[index];
    }
}

/// Returns the number of parameters of a function type info.
pub fn fnParamCount(comptime fn_info: anytype) usize {
    if (is_zig_16) {
        return fn_info.params.len;
    } else {
        return fn_info.param_types.len;
    }
}

/// Duplicates a slice into newly allocated memory, with a zero sentinel.
///
/// Reimplements `std.mem.Allocator.dupeZ` which was removed in Zig 0.17.
pub fn dupeZ(allocator: std.mem.Allocator, comptime T: type, m: []const T) std.mem.Allocator.Error![:0]T {
    const result = try allocator.allocSentinel(T, m.len, 0);
    @memcpy(result, m);
    return result;
}

/// Returns true if the pointer type info is volatile.
pub fn ptrIsVolatile(comptime ptr: anytype) bool {
    if (is_zig_16) {
        return ptr.is_volatile;
    } else {
        return ptr.attrs.@"volatile";
    }
}

/// Returns true if the pointer type info allows zero.
pub fn ptrIsAllowzero(comptime ptr: anytype) bool {
    if (is_zig_16) {
        return ptr.is_allowzero;
    } else {
        return ptr.attrs.@"allowzero";
    }
}
