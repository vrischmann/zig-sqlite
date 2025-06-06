# zig-sqlite

This package is a thin wrapper around [sqlite](https://sqlite.org/index.html)'s C API.

_Maintainer note_: I'm currently on a break working with Zig and don't intend to work on new features for zig-sqlite.
I will keep it updated for the latest Zig versions because that doesn't take too much of my time.

# Status

While the core functionality works right now, the API is still subject to changes.

If you use this library, expect to have to make changes when you update the code.

# Zig release support

`zig-sqlite` only tracks Zig master (as can be found [here](https://ziglang.org/download/)). The plan is to support releases once Zig 1.0 is released but this can still change.

So your mileage may vary if you try to use `zig-sqlite`.

# Table of contents

<!--toc:start-->
- [zig-sqlite](#zig-sqlite)
- [Status](#status)
- [Zig release support](#zig-release-support)
- [Table of contents](#table-of-contents)
- [Requirements](#requirements)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
  - [Demo](#demo)
  - [Initialization](#initialization)
  - [Preparing a statement](#preparing-a-statement)
    - [Common use](#common-use)
    - [Diagnostics](#diagnostics)
  - [Executing a statement](#executing-a-statement)
  - [Reuse a statement](#reuse-a-statement)
  - [Reading data in one go](#reading-data-in-one-go)
    - [Type parameter](#type-parameter)
    - [`Statement.one`](#statementone)
    - [`Statement.all` and `Statement.oneAlloc`](#statementall-and-statementonealloc)
  - [Iterating](#iterating)
    - [`Iterator.next`](#iteratornext)
    - [`Iterator.nextAlloc`](#iteratornextalloc)
  - [Bind parameters and resultset rows](#bind-parameters-and-resultset-rows)
  - [Custom type binding and reading](#custom-type-binding-and-reading)
  - [Note about complex allocations](#note-about-complex-allocations)
- [Comptime checks](#comptime-checks)
  - [Check the number of bind parameters.](#check-the-number-of-bind-parameters)
  - [Assign types to bind markers and check them.](#assign-types-to-bind-markers-and-check-them)
- [User defined SQL functions](#user-defined-sql-functions)
  - [Scalar functions](#scalar-functions)
  - [Aggregate functions](#aggregate-functions)
<!--toc:end-->

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
* user defined SQL functions

# Installation

Use the following `zig fetch` command:

```
zig fetch --save git+https://github.com/vrischmann/zig-sqlite
```

Now in your `build.zig` you can access the module like this:
```zig
const sqlite = b.dependency("sqlite", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
```

# Usage

## Demo

See https://github.com/vrischmann/zig-sqlite-demo for a quick demo.

## Initialization

Import `zig-sqlite` like this:

```zig
const sqlite = @import("sqlite");
```

You must create and initialize an instance of `sqlite.Db`:

```zig
var db = try sqlite.Db.init(.{
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
try db.exec("CREATE TABLE IF NOT EXISTS employees(id integer primary key, name text, age integer, salary integer)", .{}, .{});

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
    std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
    return err;
};
defer stmt.deinit();
```

## Executing a statement

For queries which do not return data (`INSERT`, `UPDATE`) you can use the `exec` method:

```zig
const query =
    \\INSERT INTO employees(name, age, salary) VALUES(?, ?, ?)
;

var stmt = try db.prepare(query);
defer stmt.deinit();

try stmt.exec(.{}, .{
    .name = "José",
    .age = 40,
    .salary = 20000,
});
```

See the section "Bind parameters and resultset rows" for more information on the types mapping rules.

## Reuse a statement

You can reuse a statement by resetting it like this:
```zig
const query =
    \\UPDATE employees SET salary = ? WHERE id = ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

var id: usize = 0;
while (id < 20) : (id += 1) {
    stmt.reset();
    try stmt.exec(.{}, .{
        .salary = 2000,
        .id = id,
    });
}
```

## Reading data in one go

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

### `Statement.one`

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
if (row) |r| {
    const name_ptr: [*:0]const u8 = &r.name;
    std.log.debug("name: {s}, age: {}", .{ std.mem.span(name_ptr), r.age });
}
}
```
Notice that to read text we need to use a 0-terminated array; if the `name` column is bigger than 127 bytes the call to `one` will fail.

If the length of the data is variable then the sentinel is mandatory: without one there would be no way to know where the data ends in the array.

However if the length is fixed, you can read into a non 0-terminated array, for example:

```zig
const query =
    \\SELECT id FROM employees WHERE name = ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

const row = try stmt.one(
    [16]u8,
    .{},
    .{ .name = "Vincent" },
);
if (row) |id| {
    std.log.debug("id: {s}", .{std.fmt.fmtSliceHexLower(&id)});
}
```

If the column data doesn't have the correct length a `error.ArraySizeMismatch` will be returned.

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

### `Statement.all` and `Statement.oneAlloc`

Using `all`:

```zig
const query =
    \\SELECT name FROM employees WHERE age > ? AND age < ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

const allocator = std.heap.page_allocator; // Use a suitable allocator

const names = try stmt.all([]const u8, allocator, .{}, .{
    .age1 = 20,
    .age2 = 40,
});
for (names) |name| {
    std.log.debug("name: {s}", .{ name });
}
```

Using `oneAlloc`:

```zig
const query =
    \\SELECT name FROM employees WHERE id = ?
;

var stmt = try db.prepare(query);
defer stmt.deinit();

const allocator = std.heap.page_allocator; // Use a suitable allocator

const row = try stmt.oneAlloc([]const u8, allocator, .{}, .{
    .id = 200,
});
if (row) |name| {
    std.log.debug("name: {s}", .{name});
}
```

## Iterating

Another way to get the data returned by a query is to use the `sqlite.Iterator` type.

You can only get one by calling the `iterator` method on a statement.

The `iterator` method takes a type which is the same as with `all`, `one` or `oneAlloc`: every row retrieved by calling `next` or `nextAlloc` will have this type.

Iterating is done by calling the `next` or `nextAlloc` method on an iterator. Just like before, `next` cannot allocate memory while `nextAlloc` can allocate memory.

`next` or `nextAlloc` will either return an optional value or an error; you should keep iterating until `null` is returned.

### `Iterator.next`

```zig
var stmt = try db.prepare("SELECT age FROM employees WHERE age < ?");
defer stmt.deinit();

var iter = try stmt.iterator(usize, .{
    .age = 20,
});

while (try iter.next(.{})) |age| {
    std.debug.print("age: {}\n", .{age});
}
```

### `Iterator.nextAlloc`

```zig
var stmt = try db.prepare("SELECT name FROM employees WHERE age < ?");
defer stmt.deinit();

var iter = try stmt.iterator([]const u8, .{
    .age = 20,
});

const allocator = std.heap.page_allocator; // Use a suitable allocator

while (true) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const name = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;
    std.debug.print("name: {s}\n", .{name});
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

## Custom type binding and reading

Sometimes the default field binding or reading logic is not what you want, for example if you want to store an enum using its tag name instead of its integer value or
if you want to store a byte slice as an hex string.

To accomplish this you must first define a wrapper struct for your type. For example if your type is a `[4]u8` and you want to treat it as an integer:
```zig
pub const MyArray = struct {
    data: [4]u8,

    pub const BaseType = u32;

    pub fn bindField(self: MyArray, _: std.mem.Allocator) !BaseType {
        return std.mem.readIntNative(BaseType, &self.data);
    }

    pub fn readField(_: std.mem.Allocator, value: BaseType) !MyArray {
        var arr: MyArray = undefined;
        std.mem.writeIntNative(BaseType, &arr.data, value);
        return arr;
    }
};
```

Now when you bind a value of type `MyArray` the value returned by `bindField` will be used for binding instead.

Same for reading, when you select _into_ a `MyArray` row or field the value returned by `readField` will be used instead.

_NOTE_: when you _do_ allocate in `bindField` or `readField` make sure to pass a `std.heap.ArenaAllocator`-based allocator.

The binding or reading code does not keep tracking of allocations made in custom types so it can't free the allocated data itself; it's therefore required
to use an arena to prevent memory leaks.

## Note about complex allocations

Depending on your queries and types there can be a lot of allocations required. Take the following example:
```zig
const User = struct {
    id: usize,
    first_name: []const u8,
    last_name: []const u8,
    data: []const u8,
};

fn fetchUsers(allocator: std.mem.Allocator, db: *sqlite.Db) ![]User {
    var stmt = try db.prepare("SELECT id FROM user WHERE id > $id");
    defer stmt.deinit();

    return stmt.all(User, allocator, .{}, .{ .id = 20 });
}
```

This will do multiple allocations:
* one for each id field in the `User` type
* one for the resulting slice

To facilitate memory handling, consider using an arena allocator like this:
```zig
const allocator = std.heap.page_allocator; // Use a suitable allocator

var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const users = try fetchUsers(arena.allocator(), db);
_ = users;
```

This is especially recommended if you use custom types that allocate memory since, as noted above, it's necessary to prevent memory leaks.

# Comptime checks

Prepared statements contain _comptime_ metadata which is used to validate every call to `exec`, `one` and `all` _at compile time_.

## Check the number of bind parameters.

The first check makes sure you provide the same number of bind parameters as there are bind markers in the query string.

Take the following code:
```zig
var stmt = try db.prepare("SELECT id FROM user WHERE age > ? AND age < ? AND weight > ?");
defer stmt.deinit();

const allocator = std.heap.page_allocator; // Use a suitable allocator

const rows = try stmt.all(usize, allocator, .{}, .{
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

const allocator = std.heap.page_allocator; // Use a suitable allocator

const rows = try stmt.all(usize, allocator, .{}, .{
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

const allocator = std.heap.page_allocator; // Use a suitable allocator

const rows = try stmt.all(usize, allocator, .{}, .{
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

It is probably possible to support arbitrary types if they can be marshaled to an SQLite type. This is something to investigate.

**NOTE**: this is done at compile time and is quite CPU intensive, therefore it's possible you'll have to play with [@setEvalBranchQuota](https://ziglang.org/documentation/master/#setEvalBranchQuota) to make it compile.

To finish our example, passing the proper type allows it compile:
```zig
var stmt = try db.prepare("SELECT id FROM user WHERE age > ? AND age < ? AND weight > ?{usize}");
defer stmt.deinit();

const allocator = std.heap.page_allocator; // Use a suitable allocator

const rows = try stmt.all(usize, allocator, .{}, .{
    .age_1 = 10,
    .age_2 = 20,
    .weight = @as(usize, 200),
});
_ = rows;
```

# User defined SQL functions

sqlite supports [user-defined SQL functions](https://www.sqlite.org/c3ref/create_function.html) which come in two types:
* scalar functions
* aggregate functions

In both cases the arguments are [sqlite3\_values](https://www.sqlite.org/c3ref/value_blob.html) and are converted to Zig values using the following rules:
* `TEXT` values can be either `sqlite.Text` or `[]const u8`
* `BLOB` values can be either `sqlite.Blob` or `[]const u8`
* `INTEGER` values can be any Zig integer
* `REAL` values can be any Zig float

## Scalar functions

You can define a scalar function using `db.createScalarFunction`:
```zig
try db.createScalarFunction(
    "blake3",
    struct {
        fn run(input: []const u8) [std.crypto.hash.Blake3.digest_length]u8 {
            var hash: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
            std.crypto.hash.Blake3.hash(input, &hash, .{});
            return hash;
        }
    }.run,
    .{},
);

const hash = try db.one([std.crypto.hash.Blake3.digest_length]u8, "SELECT blake3('hello')", .{}, .{});
```

Each input arguments in the function call in the statement is passed on to the registered `run` function.

## Aggregate functions

You can define an aggregate function using `db.createAggregateFunction`:
```zig
const MyContext = struct {
    sum: u32,
};
var my_ctx = MyContext{ .sum = 0 };

try db.createAggregateFunction(
    "mySum",
    &my_ctx,
    struct {
        fn step(fctx: sqlite.FunctionContext, input: u32) void {
            var ctx = fctx.userContext(*MyContext) orelse return;
            ctx.sum += input;
        }
    }.step,
    struct {
        fn finalize(fctx: sqlite.FunctionContext) u32 {
            const ctx = fctx.userContext(*MyContext) orelse return 0;
            return ctx.sum;
        }
    }.finalize,
    .{},
);

const result = try db.one(usize, "SELECT mySum(nb) FROM foobar", .{}, .{});
```

Each input arguments in the function call in the statement is passed on to the registered `step` function.
The `finalize` function is called once at the end.

The context (2nd argument of `createAggregateFunction`) can be whatever you want; both the `step` and `finalize` functions must
have their first argument of the same type as the context.
