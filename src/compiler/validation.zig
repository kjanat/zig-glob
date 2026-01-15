//! Input validation and safety limits for glob patterns.
//!
//! Provides constants and validation functions to prevent:
//! - Denial of Service through excessive pattern complexity
//! - Buffer overflows through very long patterns
//! - Security issues through malformed input
//! - Resource exhaustion through unbounded expansion

const std = @import("std");

/// Maximum pattern length in bytes (64KB).
/// Prevents DoS through extremely long patterns consuming excessive memory.
pub const MAX_PATTERN_LENGTH: usize = 64 * 1024;

/// Maximum nesting depth for brace expressions.
/// Prevents stack overflow and exponential expansion.
pub const MAX_BRACE_NESTING_DEPTH: u32 = 10;

/// Maximum number of alternatives in a single brace expression.
/// Prevents excessive memory allocation from {a,b,c,...} patterns.
pub const MAX_BRACE_ALTERNATIVES: u32 = 100;

/// Maximum total expansion from brace expressions.
/// Prevents combinatorial explosion from nested braces.
pub const MAX_BRACE_EXPANSION: u32 = 10_000;

/// Maximum range span for numeric/alpha ranges in braces.
/// Prevents {0..999999} from generating excessive strings.
pub const MAX_RANGE_SPAN: u32 = 1000;

/// Maximum recursion depth for filesystem traversal.
/// Prevents infinite loops and excessive resource usage.
pub const MAX_TRAVERSAL_DEPTH: u32 = 100;

/// Maximum number of consecutive wildcards (after collapse).
/// Patterns like "***..." collapse but we limit for sanity.
pub const MAX_CONSECUTIVE_STARS: u32 = 2;

/// Maximum number of segments in a path pattern.
/// Prevents DoS through patterns like "a/b/c/d/e/.../z".
pub const MAX_PATH_SEGMENTS: u32 = 256;

/// Validation error type.
pub const ValidationError = error{
    /// Pattern exceeds maximum allowed length.
    PatternTooLong,
    /// Pattern contains null byte.
    NullByteInPattern,
    /// Pattern contains invalid UTF-8 sequence.
    InvalidUtf8,
    /// Brace nesting exceeds maximum depth.
    BraceNestingTooDeep,
    /// Too many alternatives in brace expression.
    TooManyBraceAlternatives,
    /// Range span exceeds maximum allowed.
    RangeSpanTooLarge,
    /// Pattern has too many path segments.
    TooManyPathSegments,
};

/// Result of pattern validation.
pub const ValidationResult = struct {
    /// Whether the pattern is valid.
    valid: bool,
    /// Error if invalid, null if valid.
    err: ?ValidationError,
    /// Warning flags (non-fatal issues).
    warnings: Warnings,

    pub const Warnings = packed struct {
        /// Pattern contains unusual consecutive wildcards.
        consecutive_wildcards: bool = false,
        /// Pattern has empty segments (a//b).
        empty_segments: bool = false,
        /// Pattern uses platform-specific path separators.
        platform_separators: bool = false,
        /// Pattern might be expensive to match.
        potentially_expensive: bool = false,
    };

    pub fn ok() ValidationResult {
        return .{ .valid = true, .err = null, .warnings = .{} };
    }

    pub fn fail(err: ValidationError) ValidationResult {
        return .{ .valid = false, .err = err, .warnings = .{} };
    }

    pub fn withWarnings(warnings: Warnings) ValidationResult {
        return .{ .valid = true, .err = null, .warnings = warnings };
    }
};

/// Validates a glob pattern for safety and correctness.
/// Returns validation result with error or warnings.
pub fn validatePattern(pattern: []const u8) ValidationResult {
    // Check length limit
    if (pattern.len > MAX_PATTERN_LENGTH) {
        return ValidationResult.fail(ValidationError.PatternTooLong);
    }

    var warnings: ValidationResult.Warnings = .{};

    // Check for null bytes
    if (std.mem.indexOfScalar(u8, pattern, 0)) |_| {
        return ValidationResult.fail(ValidationError.NullByteInPattern);
    }

    // Validate UTF-8 (Zig strings are bytes, but paths should be valid UTF-8)
    if (!std.unicode.utf8ValidateSlice(pattern)) {
        return ValidationResult.fail(ValidationError.InvalidUtf8);
    }

    // Check for consecutive wildcards
    var consecutive_stars: u32 = 0;
    var max_consecutive: u32 = 0;
    var empty_segment = false;
    var last_was_sep = true; // Start as true to detect leading empty segment
    var segment_count: u32 = 1;

    for (pattern) |c| {
        if (c == '*') {
            consecutive_stars += 1;
            if (consecutive_stars > max_consecutive) {
                max_consecutive = consecutive_stars;
            }
        } else {
            consecutive_stars = 0;
        }

        // Count path separators (both / and \ for cross-platform)
        if (c == '/' or c == '\\') {
            segment_count += 1;
            if (last_was_sep) {
                empty_segment = true;
            }
            last_was_sep = true;
            // Warn about backslashes on non-Windows (might be escape or path separator)
            if (c == '\\' and @import("builtin").os.tag != .windows) {
                warnings.platform_separators = true;
            }
        } else {
            last_was_sep = false;
        }
    }

    // Check segment count
    if (segment_count > MAX_PATH_SEGMENTS) {
        return ValidationResult.fail(ValidationError.TooManyPathSegments);
    }

    // Set warnings
    if (max_consecutive > MAX_CONSECUTIVE_STARS) {
        warnings.consecutive_wildcards = true;
    }
    if (empty_segment) {
        warnings.empty_segments = true;
    }

    // Check for potentially expensive patterns
    // Patterns with many wildcards or deeply nested braces can be expensive
    var brace_depth: u32 = 0;
    var max_brace_depth: u32 = 0;
    var wildcard_count: u32 = 0;

    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        // Skip escaped characters (e.g., \{ \} \* \?)
        if (c == '\\' and i + 1 < pattern.len) {
            i += 2; // Skip backslash and the escaped character
            continue;
        }
        switch (c) {
            '{' => {
                brace_depth += 1;
                if (brace_depth > max_brace_depth) {
                    max_brace_depth = brace_depth;
                }
            },
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '*', '?' => {
                wildcard_count += 1;
            },
            else => {},
        }
        i += 1;
    }

    if (max_brace_depth > MAX_BRACE_NESTING_DEPTH) {
        return ValidationResult.fail(ValidationError.BraceNestingTooDeep);
    }

    // Flag potentially expensive patterns
    if (wildcard_count > 10 or max_brace_depth > 3) {
        warnings.potentially_expensive = true;
    }

    if (warnings.consecutive_wildcards or warnings.empty_segments or
        warnings.platform_separators or warnings.potentially_expensive)
    {
        return ValidationResult.withWarnings(warnings);
    }

    return ValidationResult.ok();
}

/// Validates a numeric range for brace expansion.
pub fn validateRange(start: i64, end: i64) ValidationError!void {
    // Use i128 to avoid overflow when computing difference of extreme i64 values
    const start_wide: i128 = start;
    const end_wide: i128 = end;
    const diff = if (start_wide <= end_wide)
        end_wide - start_wide
    else
        start_wide - end_wide;

    // diff is always non-negative, safe to compare against MAX_RANGE_SPAN
    if (diff > @as(i128, MAX_RANGE_SPAN)) {
        return ValidationError.RangeSpanTooLarge;
    }
}

/// Check if a character is a path separator.
inline fn isPathSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Checks if a byte sequence looks like it might contain path traversal.
/// This is informational - the walker handles actual security.
pub fn detectPathTraversal(pattern: []const u8) bool {
    // Look for .. segments
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '.') {
            if (i + 1 < pattern.len and pattern[i + 1] == '.') {
                // Check if it's a standalone .. segment
                const before_ok = (i == 0) or isPathSep(pattern[i - 1]);
                const after_ok = (i + 2 >= pattern.len) or isPathSep(pattern[i + 2]);
                if (before_ok and after_ok) {
                    return true;
                }
            }
        }
        i += 1;
    }
    return false;
}

/// Normalizes path separators to forward slashes.
/// Always returns a newly allocated string that the caller must free.
pub fn normalizePathSeparators(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    // On Windows, convert backslashes to forward slashes
    // But preserve escape sequences (\* \? etc)
    if (@import("builtin").os.tag == .windows) {
        var needs_normalization = false;
        var i: usize = 0;
        while (i < pattern.len) {
            if (pattern[i] == '\\') {
                // Check if this is an escape or path separator
                if (i + 1 < pattern.len) {
                    const next = pattern[i + 1];
                    // These are escape sequences, not path separators
                    if (next == '*' or next == '?' or next == '[' or
                        next == ']' or next == '{' or next == '}' or
                        next == '\\')
                    {
                        i += 2;
                        continue;
                    }
                }
                needs_normalization = true;
                break;
            }
            i += 1;
        }

        if (needs_normalization) {
            const result = try allocator.alloc(u8, pattern.len);
            var j: usize = 0;
            i = 0;
            while (i < pattern.len) {
                if (pattern[i] == '\\') {
                    if (i + 1 < pattern.len) {
                        const next = pattern[i + 1];
                        if (next == '*' or next == '?' or next == '[' or
                            next == ']' or next == '{' or next == '}' or
                            next == '\\')
                        {
                            result[j] = pattern[i];
                            result[j + 1] = pattern[i + 1];
                            i += 2;
                            j += 2;
                            continue;
                        }
                    }
                    result[j] = '/';
                } else {
                    result[j] = pattern[i];
                }
                i += 1;
                j += 1;
            }
            return result[0..j];
        }
    }

    // No normalization needed, return a duplicate for consistent ownership
    return allocator.dupe(u8, pattern);
}

// Tests
test "validatePattern: empty pattern is valid" {
    const result = validatePattern("");
    try std.testing.expect(result.valid);
}

test "validatePattern: normal pattern is valid" {
    const result = validatePattern("src/**/*.zig");
    try std.testing.expect(result.valid);
}

test "validatePattern: pattern with null byte is invalid" {
    const result = validatePattern("foo\x00bar");
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(ValidationError.NullByteInPattern, result.err.?);
}

test "validatePattern: very long pattern is invalid" {
    const long_pattern = "a" ** (MAX_PATTERN_LENGTH + 1);
    const result = validatePattern(long_pattern);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(ValidationError.PatternTooLong, result.err.?);
}

test "validatePattern: deeply nested braces rejected" {
    // Create pattern with 11 levels of nesting
    const pattern = "{" ** 11 ++ "a" ++ "}" ** 11;
    const result = validatePattern(pattern);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(ValidationError.BraceNestingTooDeep, result.err.?);
}

test "validatePattern: empty segments trigger warning" {
    const result = validatePattern("a//b");
    try std.testing.expect(result.valid);
    try std.testing.expect(result.warnings.empty_segments);
}

test "validatePattern: many wildcards trigger warning" {
    const result = validatePattern("*/*/*/*/*/*/*/*/*/*/*/*");
    try std.testing.expect(result.valid);
    try std.testing.expect(result.warnings.potentially_expensive);
}

test "validatePattern: consecutive stars trigger warning" {
    const result = validatePattern("***");
    try std.testing.expect(result.valid);
    try std.testing.expect(result.warnings.consecutive_wildcards);
}

test "validateRange: normal range is valid" {
    try validateRange(0, 100);
    try validateRange(-50, 50);
}

test "validateRange: large range is rejected" {
    try std.testing.expectError(ValidationError.RangeSpanTooLarge, validateRange(0, 2000));
}

test "detectPathTraversal: detects .. segments" {
    try std.testing.expect(detectPathTraversal("../etc/passwd"));
    try std.testing.expect(detectPathTraversal("foo/../bar"));
    try std.testing.expect(detectPathTraversal("foo/.."));
}

test "detectPathTraversal: ignores .. in names" {
    try std.testing.expect(!detectPathTraversal("foo..bar"));
    try std.testing.expect(!detectPathTraversal("..."));
    try std.testing.expect(!detectPathTraversal("..hidden"));
}
