# zig-sqlite

This package is a thin wrapper around [sqlite](https://sqlite.org/index.html)'s C API.

## Requirements

* Linux
* the system and development package for sqlite
 * `libsqlite3-dev` for Debian and derivatives
 * `sqlite3-devel` for Fedora

## Installation

Since there's no package manager for Zig yet, the recommended way is to use a git submodule:

    $ git submodule add https://git.sr.ht/~vrischmann/zig-sqlite src/sqlite

Then add the following to your `build.zig` target(s):

    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");
    exe.addPackage(.{ .name = "sqlite", .path = "src/sqlite/sqlite.zig" });

Now you should be able to import sqlite like this:

    const sqlite = @import("sqlite");

## Usage

### Initialization

You must create and initialize an instance of `sqlite.Db`:

    var db: sqlite.Db = undefined;
    try db.init(allocator, .{ .mode = sqlite.Db.Mode{ .File = "/home/vincent/mydata.db" } });

The `init` method takes an allocator and an optional tuple which will used to configure sqlite.

Right now the only member used in that tuple is `mode` which defines if the sqlite database is in memory or uses a file.

### Preparing a statement

sqlite works exclusively by using prepared statements. The wrapper type is `sqlite.Statement`. Here is how you get one:

    const query =
        \\SELECT id, name, age, salary FROM employees WHERE age > ? AND age < ?
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

The `Db.prepare` method takes a `comptime` query string.

### Executing a statement

For queries which do not return data (`INSERT`, `UPDATE`) you can use the `exec` method:

    const query =
        \\UPDATE foo SET salary = ? WHERE id = ?
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    try stmt.exec({
        .salary = 20000,
        .id = 40,
    });

See the section "Bind parameters and resultset rows" for more information on the types mapping rules.

### Reading data

For queries which do return data you can use the `all` method:

    const query =
        \\SELECT id, name, age, salary FROM employees WHERE age > ? AND age < ?
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const rows = try stmt.all(
        struct {
            id: usize,
            name: []const u8,
            age: u16,
            salary: u32,
        },
        .{ .allocator = allocator },
        .{ .age1 = 20, .age2 = 40 },
    );
    for (rows) |row| {
        std.log.debug("id: {} ; name: {}; age: {}; salary: {}", .{ row.id, row.name, row.age, row.salary });
    }

The `all` method takes a type and an optional tuple.

The type represents a "row", it can be:
* a struct where each field maps to the corresponding column in the resultset (so field 0 must map to field 1 and so on).
* a single type, in that case the resultset must only return one column.

Not all types are allowed, see the section "Bind parameters and resultset rows" for more information on the types mapping rules.

### Bind parameters and resultset rows

Since sqlite doesn't have many [types](https://www.sqlite.org/datatype3.html) only a small number of Zig types are allowed in binding parameters and in resultset mapping types.

Here are the rules for bind parameters:
* any Zig `Int` or `ComptimeInt` is tread as a `INTEGER`.
* any Zig `Float` or `ComptimeFloat` is treated as a `REAL`.
* `[]const u8`, `[]u8` or any array of `u8` is treated as a `TEXT`.
* The custom `sqlite.Bytes` type is treated as a `TEXT` or `BLOB`.

Here are the resules for resultset rows:
* `INTEGER` can be read into any Zig `Int` provided the data fits.
* `REAL` can be read into any Zig `Float` provided the data fits.
* `TEXT` can be read into a `[]const u8` or `[]u8`.
* `TEXT` can be read into any array of `u8` provided the data fits.
* `BLOB` follows the same rules as `TEXT`.
