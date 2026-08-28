# Zig Version Compatibility Lessons

## Overview
This document summarizes key breaking changes and compatibility patterns discovered while updating zig-sqlite for Zig 0.16 and 0.17 support.

---

## 1. @typeInfo API Changes

### Zig 0.16 (and earlier)
```zig
// Old API - still works in 0.16
inline for (std.meta.fields(EnableOptions)) |field| { ... }

// Or using @typeInfo with string key
inline for (@typeInfo(EnableOptions).@"struct".fields) |field| { ... }
```

### Zig 0.17+
```zig
// New API - Struct.decls with kind filtering
inline for (@typeInfo(EnableOptions).Struct.decls) |decl| {
    if (decl.kind == .field) |field| {
        // use field.name, field.type, etc.
    }
}
```

### Version-gated Compatibility Pattern
```zig
const fields = if (builtin.zig_version.minor <= 16)
    @typeInfo(EnableOptions).@"struct".fields
else
    @typeInfo(EnableOptions).Struct.decls; // Filter by decl.kind == .field
```

---

## 2. Power Operator `**` Removed in Zig 0.17

### Zig 0.16
```zig
const result = x ** 2;  // Works
```

### Zig 0.17+
```zig
// Use multiplication or std.math.powi
const result = x * x;           // For integers
const result = std.math.powi(x, 2); // For floats/integers
```

---

## 3. @fromBackingInt / @backingInt Removed in Zig 0.17

### Zig 0.16
```zig
@fromBackingInt(value)   // Convert integer to enum
@backingInt(enum_value)  // Convert enum to integer
```

### Zig 0.17+
```zig
@enumFromInt(value)      // Convert integer to enum (replaces @fromBackingInt)
@intFromEnum(enum_value) // Convert enum to integer (replaces @backingInt)
```

### Version-gated Pattern
```zig
const fromInt = if (builtin.zig_version.minor <= 16) @fromBackingInt else @enumFromInt;
const toInt = if (builtin.zig_version.minor <= 16) @backingInt else @intFromEnum;
```

---

## 4. std.mem.copy → std.mem.copyForwards

### Zig 0.16
```zig
std.mem.copy(u8, dest, src);  // Works
```

### Zig 0.17+
```zig
std.mem.copyForwards(u8, dest, src);  // Required in 0.17+
```

**Note**: `copyForwards` exists in 0.16 but was preferred; in 0.17 it's required.

---

## 5. @cImport Changes in Zig 0.17

### Cross-compilation Limitation
In Zig 0.17, `@cImport` fails during cross-compilation (e.g., targeting different OS/arch).

```zig
// This fails in 0.17 when cross-compiling:
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
```

### Workaround
For loadable extensions or cross-compilation, use pre-processed headers or conditional compilation:

```zig
pub const c = if (@hasDecl(root, "loadable_extension"))
    @import("c/loadable_extension.zig")
else
    @cImport({
        @cInclude("sqlite3.h");
        @cInclude("workaround.h");
    });
```

---

## 6. Array Repeat Syntax `**` Spacing

### Zig 0.16
```zig
var arr = [_]u8{0} ** 16;  // OK
```

### Zig 0.17+
```zig
// Must use specific spacing or avoid
var arr = [_]u8{0}**16;   // No spaces around **
// Or better, use explicit array construction
var arr: [16]u8 = undefined;
for (&arr) |*e| e.* = 0;
```

---

## 7. Module Name Uniqueness in Zig 0.17

Zig 0.17 enforces unique module names per package. If `b.addModule("name")` is called twice, it panics.

### Fix
```zig
fn makeSQLiteLib(b: *std.Build, ..., module_suffix: []const u8) !*std.Build.Step.Compile {
    const mod_name = try std.fmt.allocPrint(b.allocator, "lib-sqlite-{s}", .{module_suffix});
    const mod = b.addModule(mod_name, ...);
    ...
}
```

---

## 8. Custom Build Step API Changes

### Zig 0.16
```zig
.step = std.Build.Step.init(.{
    .id = std.Build.Step.Id.custom,
    .name = "preprocess",
    .owner = owner,
    .makeFn = make,
});
```

### Zig 0.17+
Custom step API removed. Use built-in step types or `b.step()` for top-level steps.

### Pattern
```zig
if (builtin.zig_version.minor <= 16) {
    addPreprocessStep(b, io, sqlite_dep);
}
```

---

## 9. Error-Union Return Types

Zig 0.17 enforces explicit error unions for functions that can fail:

```zig
// 0.16: implicit
fn makeLib(...) *std.Build.Step.Compile { ... }

// 0.17+: explicit error union
fn makeLib(...) !*std.Build.Step.Compile { ... }
```

---

## 10. Zig Version Detection

```zig
const is_zig_17_plus = builtin.zig_version.minor >= 17;
const is_zig_16_or_earlier = builtin.zig_version.minor <= 16;

// For precise version checks
if (builtin.zig_version.minor == 16 and builtin.zig_version.patch >= 0) {
    // 0.16.x specific code
}
```

---

## CI Strategy for Multi-Version Support

### Branch Strategy
- `main` branch → Zig 0.16 compatible
- `zig-0.17` branch → Zig 0.17 compatible

### build.zig.zon Dependencies
```zig
// For 0.16 CI job
.sqlite = .{ .url = "git+https://github.com/samooth/zig-sqlite#main", ... }

// For 0.17 CI job  
.sqlite = .{ .url = "git+https://github.com/samooth/zig-sqlite#zig-0.17", ... }
```

### GitHub Actions Matrix
```yaml
jobs:
  test:
    strategy:
      matrix:
        zig: ["0.16.0", "master"]  # or "0.17.0"
```

---

## Summary of Changes Made to zig-sqlite

| File | Changes |
|------|---------|
| `build.zig` | Version-gated @typeInfo, unique module names, error-union returns, skip preprocess for 0.17+ |
| `sqlite.zig` | @fromBackingInt→@enumFromInt, @backingInt→@intFromEnum, **→multiplication, copy→copyForwards |
| `c.zig` | @cImport kept with loadable_extension fallback |
| `.github/workflows/main.yml` | Matrix for 0.16.0 and 0.17.0 |

---

## Key Takeaways

1. **Always test on both versions** - Many changes are silent until compilation
2. **Use version checks** - `builtin.zig_version` is the standard way to gate code
3. **Cross-compilation is fragile in 0.17** - @cImport and loadable extensions have known issues
4. **Standard library evolves** - Check `std.meta`, `std.mem`, `std.math` for moved/renamed functions
5. **Custom build steps are unstable** - Prefer built-in step types when possible