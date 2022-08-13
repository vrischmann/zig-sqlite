pub const c = @cImport({
    @cInclude("sqlite3.h");
});

// versionGreaterThanOrEqualTo returns true if the SQLite version is >= to the major.minor.patch provided.
pub fn versionGreaterThanOrEqualTo(major: u8, minor: u8, patch: u8) bool {
    return c.SQLITE_VERSION_NUMBER >= @as(u32, major) * 1000000 + @as(u32, minor) * 1000 + @as(u32, patch);
}

comptime {
    if (!versionGreaterThanOrEqualTo(3, 21, 0)) {
        @compileError("must use SQLite >= 3.21.0");
    }
}
