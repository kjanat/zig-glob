# zig-glob

A production-grade glob pattern matching library for Zig.

## Features

- **Full bash glob compatibility**: `*`, `?`, `**`, `[...]`, `{...}`
- **Extended glob operators**: `?()`, `*()`, `+()`, `@()`, `!()`
- **POSIX character classes**: `[:alpha:]`, `[:digit:]`, `[:alnum:]`, etc.
- **Brace expansion**: `{a,b,c}`, `{1..10}`, `{a..z}`
- **Filesystem traversal**: Iterator-based with configurable symlink handling
- **Cross-platform**: Works on Linux, macOS, and Windows
- **DoS protection**: Limits on pattern complexity, brace expansion, and traversal depth
- **Zero allocations** in hot paths (memoized matching)

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_glob = .{
        .url = "https://github.com/kjanat/zig-glob/archive/refs/heads/master.tar.gz",
        // .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const zig_glob = b.dependency("zig_glob", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zig_glob", zig_glob.module("zig_glob"));
```

## Quick Start

```zig
const std = @import("std");
const glob = @import("zig_glob");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Match a pattern against a path (no filesystem access)
    const matches = try glob.match(allocator, "**/*.zig", "src/main.zig", .{});
    std.debug.print("Matches: {}\n", .{matches}); // true

    // Walk filesystem matching pattern
    var iter = try glob.glob(allocator, &.{"src/**/*.zig"}, .{});
    defer iter.deinit();

    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        std.debug.print("{s}\n", .{entry.path});
    }
}
```

## CLI Usage

```bash
# Build the CLI tool
zig build

# Find all Zig files
./zig-out/bin/zig-glob '**/*.zig'

# Find files in specific directory
./zig-out/bin/zig-glob '*.md' docs/
```

## API Reference

### Pattern Matching

```zig
// One-shot match
const matches = try glob.match(allocator, pattern, path, .{});

// Compile for repeated use
var pattern = try glob.compile(allocator, "**/*.zig", .{});
defer pattern.deinit();
```

### Filesystem Traversal

```zig
// Iterator-based (memory efficient)
var iter = try glob.glob(allocator, &.{"**/*.zig"}, .{ .cwd = "src" });
defer iter.deinit();
while (try iter.next()) |entry| {
    defer allocator.free(entry.path);
    // use entry.path, entry.kind
}

// Collect all results
const results = try glob.globSync(allocator, &.{"**/*.zig"}, .{});
defer glob.freeGlobResults(allocator, results);
```

### Brace Expansion

```zig
const expanded = try glob.expandBraces(allocator, "{a,b,c}.txt", .{});
defer glob.freeBraces(allocator, expanded);
// ["a.txt", "b.txt", "c.txt"]
```

### Options

```zig
const options = glob.GlobOptions{
    .cwd = ".",                      // Base directory
    .dot = false,                    // Match dotfiles with wildcards
    .globstar = true,                // Enable ** support
    .brace_expansion = true,         // Enable {a,b} expansion
    .extglob = true,                 // Enable ?(), *(), etc.
    .nocase = false,                 // Case-insensitive matching
    .follow_dir_symlinks = false,    // Follow symlinks during traversal
    .max_depth = null,               // Recursion limit (null = unlimited)
    .types = .all,                   // .all, .files_only, .directories_only
};
```

## Pattern Syntax

| Pattern  | Description                       | Example                              |
| -------- | --------------------------------- | ------------------------------------ |
| `*`      | Match any characters except `/`   | `*.zig` matches `main.zig`           |
| `?`      | Match single character except `/` | `?.zig` matches `a.zig`              |
| `**`     | Match any path segments           | `**/test.zig` matches `a/b/test.zig` |
| `[abc]`  | Character class                   | `[abc].txt` matches `a.txt`          |
| `[a-z]`  | Character range                   | `[a-z].txt` matches `x.txt`          |
| `[!abc]` | Negated class                     | `[!0-9].txt` matches `a.txt`         |
| `{a,b}`  | Brace expansion                   | `{src,lib}/*.zig`                    |
| `{1..5}` | Numeric range                     | `file{1..5}.txt`                     |
| `?(...)` | Match zero or one                 | `file?(.bak).txt`                    |
| `*(...)` | Match zero or more                | `file*(.bak).txt`                    |
| `+(...)` | Match one or more                 | `file+([0-9]).txt`                   |
| `@(...)` | Match exactly one                 | `@(foo\|bar).txt`                    |
| `!(...)` | Match none                        | `!(test).zig`                        |

### POSIX Character Classes

Use within `[...]`: `[[:alpha:]]`, `[[:digit:]]`, `[[:alnum:]]`, `[[:space:]]`, `[[:upper:]]`, `[[:lower:]]`, `[[:punct:]]`, `[[:xdigit:]]`

## Safety Limits

Built-in DoS protection:

| Limit           | Default   | Purpose                         |
| --------------- | --------- | ------------------------------- |
| Pattern length  | 64KB      | Prevent memory exhaustion       |
| Brace nesting   | 10 levels | Prevent stack overflow          |
| Brace expansion | 10,000    | Prevent combinatorial explosion |
| Range span      | 1,000     | Prevent `{0..999999}`           |
| Traversal depth | 100       | Prevent infinite recursion      |
| Path segments   | 256       | Prevent excessive nesting       |

## Testing

```bash
zig build test
```

## License

[MIT]

<!--link-definitions-start-->

[MIT]: https://github.com/kjanat/zig-glob/blob/master/LICENSE

<!--link-definitions-end-->
