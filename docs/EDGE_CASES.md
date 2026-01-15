# zig-glob Edge Cases and Limitations

This document describes edge case handling, security considerations, and known limitations of the zig-glob library.

## Input Validation

### Pattern Validation (`src/compiler/validation.zig`)

The library provides a `validatePattern()` function that checks patterns before processing:

| Check                 | Default Limit                   | Error/Warning                         |
| --------------------- | ------------------------------- | ------------------------------------- |
| Pattern length        | 64KB                            | `ValidationError.PatternTooLong`      |
| Null bytes            | None allowed                    | `ValidationError.NullByteInPattern`   |
| UTF-8 validity        | Required                        | `ValidationError.InvalidUtf8`         |
| Brace nesting depth   | 10 levels                       | `ValidationError.BraceNestingTooDeep` |
| Path segment count    | 256                             | `ValidationError.TooManyPathSegments` |
| Consecutive wildcards | >2                              | Warning only                          |
| Empty segments (a//b) | Allowed                         | Warning only                          |
| Expensive patterns    | 10+ wildcards or 3+ brace depth | Warning only                          |

#### Usage

```zig
const result = validatePattern("**/*.zig");
if (!result.valid) {
    // Handle error: result.err
}
if (result.warnings.potentially_expensive) {
    // Log warning about expensive pattern
}
```

## Brace Expansion Limits

### Configurable Limits (`BraceOptions`)

| Option              | Default | Description                             |
| ------------------- | ------- | --------------------------------------- |
| `max_expansion`     | 10,000  | Maximum total expanded patterns         |
| `max_nesting_depth` | 10      | Maximum brace nesting `{a,{b,{c,...}}}` |
| `max_range_span`    | 1,000   | Maximum range size `{1..1000}`          |
| `max_alternatives`  | 100     | Maximum alternatives in single brace    |

### Error Types

- `BraceError.ExpansionLimitExceeded` - Too many total patterns
- `BraceError.NestingTooDeep` - Too many nested braces
- `BraceError.RangeSpanTooLarge` - Range like `{1..99999}` too large
- `BraceError.TooManyAlternatives` - Single brace has too many options

## Filesystem Traversal

### Error Handling Policy (`WalkerOptions.error_policy`)

| Policy                   | Behavior                         |
| ------------------------ | -------------------------------- |
| `.skip_silent` (default) | Silently skip inaccessible paths |
| `.skip_report`           | Skip but call error callback     |
| `.stop_on_error`         | Return error to caller           |

### TOCTOU Handling

The walker handles Time-of-Check-Time-of-Use race conditions:

- Files may be deleted between directory iteration and access
- Permission denied errors are handled gracefully
- Disappearing files don't crash the iteration

#### Error Callback Example

```zig
fn onError(path: []const u8, err: anyerror) void {
    std.debug.print("Error accessing {s}: {any}\n", .{ path, err });
}

const options = WalkerOptions{
    .error_policy = .skip_report,
    .error_callback = onError,
};
```

### Depth Limits

- `max_depth: ?u32` - Limits traversal depth (null = unlimited)
- Default is unlimited but can be set for DoS protection

### Symlink Handling

| Option                                    | Behavior                    |
| ----------------------------------------- | --------------------------- |
| `follow_symlinks: false` (default)        | Don't follow symlinks       |
| `follow_symlinks: true`                   | Follow with cycle detection |
| `include_broken_symlinks: true` (default) | Include broken links        |

Cycle detection uses inode tracking to prevent infinite loops.

## Known Limitations

### 1. Character Class Edge Cases

Some character class patterns have edge case handling issues:

- `[\]]` (escaped bracket inside class) - May not parse correctly
- `[!]]` (negated with bracket) - Parser may misinterpret

**Workaround**: Use POSIX classes or simpler patterns where possible.

### 2. Unicode in Patterns

- Patterns are treated as byte sequences
- UTF-8 validation is performed but matching is byte-level
- Case-insensitive matching (`nocase`) only works for ASCII

### 3. Path Separator Normalization

- The library uses `/` as the canonical separator
- On Windows, backslashes in patterns should be escaped or normalized
- Use `validation.normalizePathSeparators()` for cross-platform patterns

**Cross-Platform Recommendations**:
- Always use forward slashes (`/`) in patterns for maximum portability
- On Windows, call `normalizePathSeparators()` if accepting user input that may contain backslashes
- Escape special glob characters in literal path segments:
  - Escape `*`, `?`, `[`, `]`, `{`, `}` with backslash if they should be treated literally
  - Example: `foo\\*.txt` to match the literal filename `foo*.txt`

### 4. Memory Allocation

All operations that allocate memory can return `OutOfMemory`:

- Pattern parsing
- Brace expansion
- Path building during traversal

Use `errdefer` patterns for proper cleanup.

### 5. Large Directory Handling

Very large directories (millions of files) may:

- Use significant memory for work queues
- Take time to iterate

Consider using `max_depth` limits for protection.

## Cross-Platform Improvements

### Windows Device Tracking (v0.1.1+)

Previous versions had a limitation where Windows device IDs were always set to 0, which prevented proper cycle detection across different drives. This has been fixed:

**Before**:
```zig
// Old implementation - no cross-drive cycle detection
return .{ .dev = 0, .inode = stat.inode };
```

**After**:
```zig
// New implementation - uses volume serial number
const dev = getWindowsVolumeSerialFromDir(dir) orelse 0;
return .{ .dev = dev, .inode = stat.inode };
```

**Benefits**:
- Cycle detection now works correctly across different Windows drives (C:, D:, E:, etc.)
- Prevents infinite loops when following symlinks across volumes
- Matches behavior of POSIX systems with proper device ID tracking

**Technical Details**:
- Uses Windows `GetFileInformationByHandle` API to retrieve volume serial number
- Volume serial number uniquely identifies each filesystem/drive
- Falls back to 0 if volume information cannot be retrieved (rare, maintains backward compatibility)

## Security Considerations

### DoS Protection

1. **Pattern Length**: 64KB maximum prevents memory exhaustion
2. **Brace Expansion**: Limits prevent combinatorial explosion
3. **Traversal Depth**: Configurable to prevent deep recursion
4. **Segment Count**: 256 maximum path segments

### Path Traversal Detection

```zig
if (validation.detectPathTraversal(pattern)) {
    // Pattern contains ".." segments - may need review
}
```

Note: The walker itself prevents escaping the root directory.

### Null Byte Injection

Patterns with null bytes are rejected to prevent path manipulation attacks.

## Platform-Specific Behavior

### Linux/macOS

- Case-sensitive matching by default
- Full symlink support with cycle detection using device ID (dev_major/dev_minor) and inode numbers
- Permission errors silently skip entries (default)
- All filesystem features fully supported

### Windows

- **Case Sensitivity**: Use `nocase: true` for case-insensitive filesystem matching
- **Path Separators**: Both `/` and `\` are treated as path separators
  - Backslash handling requires escaping or normalization
  - Use `validation.normalizePathSeparators()` for cross-platform patterns
  - Ambiguity between escape sequences (e.g., `\*`) and path separators (e.g., `foo\bar`)
- **Symlink Support**:
  - Symlink following and cycle detection are fully implemented
  - Cycle detection uses volume serial number for device ID (supports cross-drive detection)
  - **Limitation**: Creating symlinks requires Administrator privileges or Developer Mode
  - Tests are skipped on Windows due to privilege requirements for symlink creation
- **Device Tracking**: Uses volume serial number to distinguish different drives (C:, D:, etc.)
- **POSIX Character Classes**: May not work as expected for non-ASCII characters
- **Unicode**: Pattern matching is byte-level; case-insensitive matching only works for ASCII

## Testing Edge Cases

Run the test suite to verify edge case handling:

```bash
zig build test
```

Key test categories:

- `test "security: *"` - DoS and limit tests
- `test "edge: *"` - Boundary condition tests
- `test "walker: *"` - Filesystem traversal tests

## API Quick Reference

### Validation

```zig
const validation = @import("zig-glob").validation;

// Validate pattern before use
const result = validation.validatePattern(pattern);

// Normalize path separators (Windows)
const normalized = try validation.normalizePathSeparators(allocator, pattern);

// Check for path traversal
const has_traversal = validation.detectPathTraversal(pattern);
```

### Safe Brace Expansion

```zig
const expanded = try brace.expand(allocator, pattern, .{
    .max_expansion = 1000,      // Limit total patterns
    .max_nesting_depth = 5,     // Limit nesting
    .max_range_span = 100,      // Limit range sizes
    .max_alternatives = 50,     // Limit alternatives per brace
});
defer brace.freeExpanded(allocator, expanded);
```

### Safe Walker Configuration

```zig
var walker = try Walker.init(allocator, &pattern, root_dir, .{
    .max_depth = 20,                      // Limit depth
    .error_policy = .skip_report,         // Report errors
    .error_callback = myErrorHandler,     // Handle errors
    .follow_symlinks = false,             // Don't follow symlinks
});
defer walker.deinit();
```
