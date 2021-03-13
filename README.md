# zig-sqlite

This package is a thin wrapper around [sqlite](https://sqlite.org/index.html)'s C API.

# Status

While the core functionality works right now, the API is still subject to changes.

If you use this library, expect to have to make changes when you update the code.

# Requirements

[Zig master](https://ziglang.org/download/) is the only required dependency.

For sqlite, you have options depending on your target:
* On Windows the only supported way at the moment to build `zig-sqlite` is with the bundled sqlite source code file.
* On Linux we have two options:
  * use the system and development package for sqlite (`libsqlite3-dev` for Debian and derivatives, `sqlite3-devel` for Fedora)
  * use the bundled sqlite source code file.

# Features

* Preparing, executing statements
* comptime checked bind parameters

# Installation

Since there's no package manager for Zig yet, the recommended way is to use a git submodule:

```bash
$ git submodule add https://github.com/vrischmann/zig-sqlite.git third_party/zig-sqlite
```

## Using the system sqlite library

If you want to use the system sqlite library, add the following to your `build.zig` target(s):

```zig
exe.linkLibC();
exe.linkSystemLibrary("sqlite3");
exe.addPackage(.{ .name = "sqlite", .path = "third_party/zig-sqlite/sqlite.zig" });
```

## Using the bundled sqlite source code file

If you want to use the bundled sqlite source code file, first you need to add it as a static library in your `build.zig` file:

```zig
const sqlite = b.addStaticLibrary("sqlite", null);
sqlite.addCSourceFile("third_party/zig-sqlite/sqlite3.c", &[_][]const u8{"-std=c99"});
sqlite.linkLibC();
```

Now it's just a matter of linking your `build.zig` target(s) to this library instead of the system one:

```zig
exe.linkLibC();
exe.linkLibrary(sqlite);
exe.addPackage(.{ .name = "sqlite", .path = "third_party/zig-sqlite/sqlite.zig" });
```

If you're building with glibc you must make sure that the version used is at least 2.28.

You can do that in your `build.zig` file:
```zig
var target = b.standardTargetOptions(.{});
target.setGnuLibCVersion(2, 28, 0);
exe.setTarget(target);
```

Or with `-Dtarget`:
```
$ zig build -Dtarget=native-linux-gnu.2.28
```

# Usage

Import `zig-sqlite` like this:

```zig
const sqlite = @import("sqlite");
```

## Initialization

You must create and initialize an instance of `sqlite.Db`:

```zig
var db: sqlite.Db = undefined;
try db.init(.{
    .mode = sqlite.Db.Mode{ .File = "/home/vincent/mydata.db" },
    .open_flags = .{
        .write = true,
        .create = true,
    },
    .threading_mode = .MultiThread,
});
```

The `init` method takes a `InitOptions` struct which will be used to configure sqlite.

Only the `mode` field is mandatory, the other fields have sane default values.

## Preparing a statement

### Common use

sqlite works exclusively by using prepared statements. The wrapper type is `sqlite.Statement`. Here is how you get one:

```zig
const query =
    \\SELECT id, name, age, salary FROM employees WHERE age > ? AND age < ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();
```

The `Db.prepare` method takes a `comptime` query string.

### Diagnostics

If you want failure diagnostics you can use `prepareWithDiags` like this:

```zig
var diags = sqlite.Diagnostics{};
var stmt = db.prepareWithDiags(query, .{ .diags = &diags }) catch |err| {
    std.log.err("unable to prepare statement, got error {s}. diagnostics: {s}", .{ err, diags });
    return err;
};
defer stmt.deinit();
```

## Executing a statement

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

## Reuse a statement

You can reuse a statement by resetting it like this:
```zig
const query =
    \\UPDATE foo SET salary = ? WHERE id = ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

var id: usize = 0;
while (id < 20) : (id += 1) {
    stmt.reset();
    try stmt.exec(.{
        .salary = 2000,
        .id = id,
    });
}
```

## Reading data

For queries which return data you have multiple options:
* `Statement.all` which takes an allocator and can allocate memory.
* `Statement.one` which does not take an allocator and cannot allocate memory (aside from what sqlite allocates itself).
* `Statement.oneAlloc` which takes an allocator and can allocate memory.

### Type parameter

All these methods take a type as first parameter.

The type represents a "row", it can be:
* a struct where each field maps to the corresponding column in the resultset (so field 0 must map to column 1 and so on).
* a single type, in that case the resultset must only return one column.

The type can be a pointer but only when using the methods taking an allocator.

Not all types are allowed, see the section "Bind parameters and resultset rows" for more information on the types mapping rules.

### Non allocating

Using `one`:

```zig
const query =
    \\SELECT name, age FROM employees WHERE id = ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

const row = try stmt.one(
    struct {
        name: [128:0]u8,
        age: usize,
    },
    .{},
    .{ .id = 20 },
);
if (row) |row| {
    std.log.debug("name: {}, age: {}", .{std.mem.spanZ(&row.name), row.age});
}
```
Notice that to read text we need to use a 0-terminated array; if the `name` column is bigger than 127 bytes the call to `one` will fail.

The sentinel is mandatory: without one there would be no way to know where the data ends in the array.

The convenience function `sqlite.Db.one` works exactly the same way:

```zig
const query =
    \\SELECT age FROM employees WHERE id = ?
;

const row = try db.one(usize, query, .{}, .{ .id = 20 });
if (row) |age| {
    std.log.debug("age: {}", .{age});
}
```

### Allocating

Using `all`:

```zig
const query =
    \\SELECT name FROM employees WHERE age > ? AND age < ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

const names = try stmt.all([]const u8, allocator, .{}, .{
    .age1 = 20,
    .age2 = 40,
});
for (names) |name| {
    std.log.debug("name: {}", .{ row.name });
}
```

Using `oneAlloc`:

```zig
const query =
    \\SELECT name FROM employees WHERE id = ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

const row = try stmt.oneAlloc([]const u8, allocator, .{}, .{
    .id = 200,
});
if (row) |name| {
    std.log.debug("name: {}", .{name});
}
```

## Iterating

Another way to get the data returned by a query is to use the `sqlite.Iterator` type.

You can only get one by calling the `iterator` method on a statement.

The `iterator` method takes a type which is the same as with `all`, `one` or `oneAlloc`: every row retrieved by calling `next` or `nextAlloc` will have this type.

Iterating is done by calling the `next` or `nextAlloc` method on an iterator. Just like before, `next` cannot allocate memory while `nextAlloc` can allocate memory.

`next` or `nextAlloc` will either return an optional value or an error; you should keep iterating until `null` is returned.

### Non allocating

```zig
var stmt = try db.prepare("SELECT age FROM user WHERE age < ?");
defer stmt.deinit();

var iter = try stmt.iterator(usize, .{
    .age = 20,
});

while (try iter.next(.{})) |age| {
    std.debug.print("age: {}\n", .{age});
}
```

### Allocating

```zig
var stmt = try db.prepare("SELECT name FROM user WHERE age < ?");
defer stmt.deinit();

var iter = try stmt.iterator([]const u8, .{
    .age = 20,
});

while (true) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const name = (try iter.nextAlloc(&arena.allocator, .{})) orelse break;
    std.debug.print("name: {}\n", .{name});
}
```

## Bind parameters and resultset rows

Since sqlite doesn't have many [types](https://www.sqlite.org/datatype3.html) only a small number of Zig types are allowed in binding parameters and in resultset mapping types.

Here are the rules for bind parameters:
* any Zig `Int` or `ComptimeInt` is treated as a `INTEGER`.
* any Zig `Float` or `ComptimeFloat` is treated as a `REAL`.
* `[]const u8`, `[]u8` is treated as a `TEXT`.
* the custom `sqlite.Blob` type is treated as a `BLOB`.
* the custom `sqlite.Text` type is treated as a `TEXT`.
* the `null` value is treated as a `NULL`.
* non-null optionals are treated like a regular value, null optionals are treated as a `NULL`.

Here are the rules for resultset rows:
* `INTEGER` can be read into any Zig `Int` provided the data fits.
* `REAL` can be read into any Zig `Float` provided the data fits.
* `TEXT` can be read into a `[]const u8` or `[]u8`.
* `TEXT` can be read into any array of `u8` with a sentinel provided the data fits.
* `BLOB` follows the same rules as `TEXT`.
* `NULL` can be read into any optional.

Note that arrays must have a sentinel because we need a way to communicate where the data actually stops in the array, so for example use `[200:0]u8` for a `TEXT` field.

# Comptime checks

Prepared statements contain _comptime_ metadata which is used to validate every call to `exec`, `one` and `all` _at compile time_.

## Check the number of bind parameters.

The first check makes sure you provide the same number of bind parameters as there are bind markers in the query string.

Take the following code:
```zig
var stmt = try db.prepare("SELECT id FROM user WHERE age > ? AND age < ? AND weight > ?");
defer stmt.deinit();

const rows = try stmt.all(usize, .{}, .{
    .age_1 = 10,
    .age_2 = 20,
});
_ = rows;
```
It fails with this compilation error:
```
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:738:17: error: number of bind markers not equal to number of fields
                @compileError("number of bind markers not equal to number of fields");
                ^
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:817:22: note: called from here
            self.bind(values);
                     ^
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:905:41: note: called from here
            var iter = try self.iterator(Type, values);
                                        ^
./src/main.zig:19:30: note: called from here
    const rows = try stmt.all(usize, allocator, .{}, .{
                             ^
./src/main.zig:5:29: note: called from here
pub fn main() anyerror!void {
```

## Assign types to bind markers and check them.

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
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:745:25: error: value type bool is not the bind marker type usize
                        @compileError("value type " ++ @typeName(struct_field.field_type) ++ " is not the bind marker type " ++ @typeName(typ));
                        ^
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:817:22: note: called from here
            self.bind(values);
                     ^
/home/vincent/dev/perso/libs/zig-sqlite/sqlite.zig:905:41: note: called from here
            var iter = try self.iterator(Type, values);
                                        ^
./src/main.zig:19:30: note: called from here
    const rows = try stmt.all(usize, allocator, .{}, .{
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

const rows = try stmt.all(usize, .{}, .{
    .age_1 = 10,
    .age_2 = 20,
    .weight = @as(usize, 200),
});
_ = rows;
```
