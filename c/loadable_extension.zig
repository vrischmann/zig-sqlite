const c = @cImport({
    @cInclude("loadable-ext-sqlite3ext.h");
});

pub usingnamespace c;

pub var sqlite3_api: [*c]c.sqlite3_api_routines = null;

pub export fn sqlite3_libversion() [*c]const u8 {
    return sqlite3_api.*.libversion.?();
}

pub export fn sqlite3_create_module_v2(db: ?*c.sqlite3, zName: [*c]const u8, p: [*c]const c.sqlite3_module, pClientData: ?*anyopaque, xDestroy: ?fn (?*anyopaque) callconv(.C) void) c_int {
    return sqlite3_api.*.create_module_v2.?(db, zName, p, pClientData, xDestroy);
}

pub export fn sqlite3_declare_vtab(db: ?*c.sqlite3, zSQL: [*c]const u8) c_int {
    return sqlite3_api.*.declare_vtab.?(db, zSQL);
}

pub export fn sqlite3_malloc(n: c_int) ?*anyopaque {
    return sqlite3_api.*.malloc.?(n);
}

pub export fn sqlite3_result_text(pCtx: ?*c.sqlite3_context, z: [*c]const u8, n: c_int, xDel: ?fn (?*anyopaque) callconv(.C) void) void {
    return sqlite3_api.*.result_text.?(pCtx, z, n, xDel);
}

pub export fn sqlite3_result_int64(pCtx: ?*c.sqlite3_context, iVal: c.sqlite3_int64) void {
    return sqlite3_api.*.result_int64.?(pCtx, iVal);
}

pub export fn sqlite3_result_double(pCtx: ?*c.sqlite3_context, rVal: f64) void {
    return sqlite3_api.*.result_double.?(pCtx, rVal);
}

pub export fn sqlite3_value_bytes(pVal: ?*c.sqlite3_value) c_int {
    return sqlite3_api.*.value_bytes.?(pVal);
}
pub export fn sqlite3_value_text(pVal: ?*c.sqlite3_value) [*c]const u8 {
    return sqlite3_api.*.value_text.?(pVal);
}

pub export fn sqlite3_aggregate_context(p: ?*c.sqlite3_context, nBytes: c_int) ?*anyopaque {
    return sqlite3_api.*.aggregate_context.?(p, nBytes);
}
