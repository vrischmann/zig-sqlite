# zig-sqlite

This package is a thin wrapper around [sqlite](https://sqlite.org/index.html)'s C API.

## Status

While the core functionality works right now, the API is still subject to changes.

If you use this library, expect to have to make changes when you update the code.

## Requirements

* [Zig master](https://ziglang.org/download/)
* Linux
* the system and development package for sqlite
  * `libsqlite3-dev` for Debian and derivatives
  * `sqlite3-devel` for Fedora

## Features

* Preparing, executing statements
* comptime checked bind parameters

## Installation

Since there's no package manager for Zig yet, the recommended way is to use a git submodule:

```bash
$ git submodule add https://git.sr.ht/~vrischmann/zig-sqlite src/sqlite
```

Then add the following to your `build.zig` target(s):

```zig
exe.linkLibC();
exe.linkSystemLibrary("sqlite3");
exe.addPackage(.{ .name = "sqlite", .path = "src/sqlite/sqlite.zig" });
```

Now you should be able to import sqlite like this:

```zig
const sqlite = @import("sqlite");
```

## Usage

### Initialization

You must create and initialize an instance of `sqlite.Db`:

```zig
var db: sqlite.Db = undefined;
try db.init(allocator, .{ .mode = sqlite.Db.Mode{ .File = "/home/vincent/mydata.db" } });
```

The `init` method takes an allocator and an optional tuple which will be used to configure sqlite.

Right now the only member used in that tuple is `mode` which defines if the sqlite database is in memory or uses a file.

### Preparing a statement

sqlite works exclusively by using prepared statements. The wrapper type is `sqlite.Statement`. Here is how you get one:

```zig
const query =
    \\SELECT id, name, age, salary FROM employees WHERE age > ? AND age < ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();
```

The `Db.prepare` method takes a `comptime` query string.

### Executing a statement

For queries which do not return data (`INSERT`, `UPDATE`) you can use the `exec` method:

```zig
const query =
    \\UPDATE foo SET salary = ? WHERE id = ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

try stmt.exec({
    .salary = 20000,
    .id = 40,
});
```

See the section "Bind parameters and resultset rows" for more information on the types mapping rules.

### Reading data

For queries which do return data you can use the `all` method:

```zig
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
```

The `all` method takes a type and an options tuple.

The type represents a "row", it can be:
* a struct where each field maps to the corresponding column in the resultset (so field 0 must map to field 1 and so on).
* a single type, in that case the resultset must only return one column.

Not all types are allowed, see the section "Bind parameters and resultset rows" for more information on the types mapping rules.

The options tuple is used to pass additional state required for some queries, usually it will be an allocator.
Not all queries require an allocator, hence why it's not required for every call.

The `one` method on a statement works the same way except it returns the first row of the result set:

```zig
const query =
    \\SELECT age FROM employees WHERE id = ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

const row = try stmt.one(usize, .{}, .{ .id = 20 });
if (row) |age| {
    std.log.debug("age: {}", .{age});
}
```

The convienence function `sqlite.Db.one` works exactly the same way:

```zig
const query =
    \\SELECT age FROM employees WHERE id = ?
;

const row = try db.one(usize, query, .{}, .{ .id = 20 });
if (row) |age| {
    std.log.debug("age: {}", .{age});
}
```

### Iterating

Another way to get the data returned by a query is to use the `sqlite.Iterator` type.

You can only get one by calling the `iterator` method on a statement:

```zig
var stmt = try db.prepare("SELECT name FROM user WHERE age < ?");
defer stmt.deinit();

var iter = try stmt.iterator([]const u8, .{
    .age = 20,
});

var names = std.ArrayList([]const u8).init(allocator);
while (true) {
    const row = (try iter.next(.{ .allocator = allocator })) orelse break;
    try rows.append(row);
}
```

The `iterator` method takes a type which is the same as with `all` or `one`: every row retrieved by calling `next` will have this type.

Using the iterator is straightforward: call `next` on it in a loop; it can either fail with an error or return an optional value: if that optional is null, iterating is done.

The `next` method takes an options tuple which serves the same function as the one in `all` or `one`.

The code example above uses the iterator but it's no different than just calling `all` used like this; the real benefit of the iterator is to be able to process each row
sequentially without needing to store all the resultset in memory at the same time.

Here's an example:
```zig
var stmt = try db.prepare("SELECT name FROM user WHERE age < ?");
defer stmt.deinit();

var iter = try stmt.iterator([]const u8, .{
    .age = 20,
});

while (true) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const name = (try iter.next(.{ .allocator = &arena.allocator })) orelse break;

    // do stuff with name here
}
```

Used like this the memory required for the row is only used for one iteration. You can imagine this is especially useful if your resultset contains millions of rows.

### Bind parameters and resultset rows

Since sqlite doesn't have many [types](https://www.sqlite.org/datatype3.html) only a small number of Zig types are allowed in binding parameters and in resultset mapping types.

Here are the rules for bind parameters:
* any Zig `Int` or `ComptimeInt` is tread as a `INTEGER`.
* any Zig `Float` or `ComptimeFloat` is treated as a `REAL`.
* `[]const u8`, `[]u8` or any array of `u8` is treated as a `TEXT`.
* The custom `sqlite.Blob` type is treated as a `BLOB`.
* The custom `sqlite.Text` type is treated as a `TEXT`.

Here are the rules for resultset rows:
* `INTEGER` can be read into any Zig `Int` provided the data fits.
* `REAL` can be read into any Zig `Float` provided the data fits.
* `TEXT` can be read into a `[]const u8` or `[]u8`.
* `TEXT` can be read into any array of `u8` provided the data fits.
* `BLOB` follows the same rules as `TEXT`.

Note that arrays must have a sentinel because we need a way to communicate where the data actually stops in the array, so for example use `[200:0]u8` for a `TEXT` field.

## Comptime checks

Prepared statements contain _comptime_ metadata which is used to validate every call to `exec`, `one` and `all` _at compile time_.

### Check the number of bind parameters.

The first check makes sure you provide the same number of bind parameters as there are bind markers in the query string.

Take the following code:
```zig
var stmt = try db.prepare("SELECT id FROM user WHERE age > ? AND age < ? AND weight > ?");
defer stmt.deinit();

const rows = try stmt.all(usize, .{ .allocator = allocator }, .{
    .age_1 = 10,
    .age_2 = 20,
});
_ = rows;
```
It fails with this compilation error:
```
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:465:17: error: number of bind markers not equal to number of fields
                @compileError("number of bind markers not equal to number of fields");
                ^
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:543:22: note: called from here
            self.bind(values);
                     ^
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:619:41: note: called from here
            var iter = try self.iterator(Type, values);
                                        ^
./src/main.zig:16:30: note: called from here
    const rows = try stmt.all(usize, .{ .allocator = allocator }, .{
                             ^
./src/main.zig:5:29: note: called from here
pub fn main() anyerror!void {
```

### Assign types to bind markers and check them.

The second (and more interesting) check makes sure you provide appropriately typed values as bind parameters.

This check is not automatic since with a standard SQL query we have no way to know the types of the bind parameters, to use it you must provide theses types in the SQL query with a custom syntax.

For example, take the same code as above but now we also bind the last parameter:
```zig
var stmt = try db.prepare("SELECT id FROM user WHERE age > ? AND age < ? AND weight > ?");
defer stmt.deinit();

const rows = try stmt.all(usize, .{ .allocator = allocator }, .{
    .age_1 = 10,
    .age_2 = 20,
    .weight = false,
});
_ = rows;
```

This compiles correctly even if the `weight` field in our `user` table is of the type `INTEGER`.

We can make sure the bind parameters have the right type if we rewrite the query like this:
```zig
var stmt = try db.prepare("SELECT id FROM user WHERE age > ? AND age < ? AND weight > ?{usize}");
defer stmt.deinit();

const rows = try stmt.all(usize, .{ .allocator = allocator }, .{
    .age_1 = 10,
    .age_2 = 20,
    .weight = false,
});
_ = rows;

```
Now this fails to compile:
```
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:485:25: error: value type bool is not the bind marker type usize
                        @compileError("value type " ++ @typeName(struct_field.field_type) ++ " is not the bind marker type " ++ @typeName(typ));
                        ^
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:557:22: note: called from here
            self.bind(values);
                     ^
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:633:41: note: called from here
            var iter = try self.iterator(Type, values);
                                        ^
./src/main.zig:16:30: note: called from here
    const rows = try stmt.all(usize, .{ .allocator = allocator }, .{
                             ^
./src/main.zig:5:29: note: called from here
pub fn main() anyerror!void {
```
The syntax is straightforward: a bind marker `?` followed by `{`, a Zig type name and finally `}`.

There are a limited number of types allowed currently:
 * all [integer](https://ziglang.org/documentation/master/#Primitive-Types) types.
 * all [arbitrary bit-width integer](https://ziglang.org/documentation/master/#Primitive-Types) types.
 * all [float](https://ziglang.org/documentation/master/#Primitive-Types) types.
 * bool.
 * strings with `[]const u8` or `[]u8`.
 * strings with `sqlite.Text`.
 * blobs with `sqlite.Blob`.

It's probably possible to support arbitrary types if they can be marshaled to a sqlite type. This is something to investigate.

**NOTE**: this is done at compile time and is quite CPU intensive, therefore it's possible you'll have to play with [@setEvalBranchQuota](https://ziglang.org/documentation/master/#setEvalBranchQuota) to make it compile.

To finish our example, passing the proper type allows it compile:
```zig
var stmt = try db.prepare("SELECT id FROM user WHERE age > ? AND age < ? AND weight > ?{usize}");
defer stmt.deinit();

const rows = try stmt.all(usize, .{ .allocator = allocator }, .{
    .age_1 = 10,
    .age_2 = 20,
    .weight = @as(usize, 200),
});
_ = rows;
```
