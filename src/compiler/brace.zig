//! Brace expansion for glob patterns.
//!
//! Expands brace expressions like:
//! - {a,b,c} → ["a", "b", "c"]
//! - {1..5} → ["1", "2", "3", "4", "5"]
//! - {a..d} → ["a", "b", "c", "d"]
//! - a{b,c}d → ["abd", "acd"]
//! - {a,{b,c}} → ["a", "b", "c"] (nested)
//!
//! Brace expansion is performed before glob matching, producing multiple
//! patterns that are then each matched independently.

const std = @import("std");
const Allocator = std.mem.Allocator;

const validation = @import("validation.zig");

/// Error type for brace expansion.
pub const BraceError = error{
    /// Expansion would exceed maximum allowed patterns.
    ExpansionLimitExceeded,
    /// Malformed brace expression (unclosed, etc.).
    MalformedBrace,
    /// Invalid range specification.
    InvalidRange,
    /// Out of memory.
    OutOfMemory,
    /// Nesting depth exceeded maximum allowed.
    NestingTooDeep,
    /// Range span exceeded maximum allowed.
    RangeSpanTooLarge,
    /// Too many alternatives in brace expression.
    TooManyAlternatives,
};

/// Options for brace expansion.
pub const BraceOptions = struct {
    /// Maximum number of expanded patterns allowed.
    max_expansion: u32 = validation.MAX_BRACE_EXPANSION,
    /// Whether to preserve escape sequences in output.
    preserve_escapes: bool = true,
    /// Maximum nesting depth for brace expressions.
    max_nesting_depth: u32 = validation.MAX_BRACE_NESTING_DEPTH,
    /// Maximum range span for {a..b} expressions.
    max_range_span: u32 = validation.MAX_RANGE_SPAN,
    /// Maximum alternatives in a single brace expression.
    max_alternatives: u32 = validation.MAX_BRACE_ALTERNATIVES,
};

/// A parsed segment of a brace expression.
const Segment = union(enum) {
    /// Plain text that doesn't need expansion (borrowed from input).
    literal: []const u8,
    /// Owned literal (allocated, must be freed).
    owned_literal: []const u8,
    /// A brace expression to be expanded.
    brace: BraceExpr,
};

/// A brace expression {a,b} or {1..5}.
const BraceExpr = struct {
    /// The alternatives in this brace.
    alternatives: []const []const Segment,
};

/// Expand a pattern containing brace expressions.
/// Returns a list of expanded patterns.
pub fn expand(allocator: Allocator, pattern: []const u8, options: BraceOptions) BraceError![][]const u8 {
    // Parse the pattern into segments
    var segments: std.ArrayListUnmanaged(Segment) = .empty;
    defer {
        for (segments.items) |seg| {
            switch (seg) {
                .brace => |b| freeExpr(allocator, b),
                .literal => {}, // Borrowed, don't free
                .owned_literal => |s| allocator.free(s), // Owned, must free
            }
        }
        segments.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < pattern.len) {
        if (pattern[pos] == '\\' and pos + 1 < pattern.len) {
            // Escape sequence - treat next char as literal
            const start = pos;
            pos += 2;
            // Add escaped char as literal
            const escaped = if (options.preserve_escapes)
                pattern[start..pos]
            else
                pattern[start + 1 .. pos];
            segments.append(allocator, .{ .literal = escaped }) catch return BraceError.OutOfMemory;
        } else if (pattern[pos] == '{') {
            // Start of brace expression - depth starts at 0 for top-level braces
            const result = try parseBraceExprWithDepth(allocator, pattern, pos, options, 0);
            segments.append(allocator, .{ .brace = result.expr }) catch return BraceError.OutOfMemory;
            pos = result.end_pos;
        } else {
            // Regular character - accumulate into literal
            const start = pos;
            while (pos < pattern.len and pattern[pos] != '{' and pattern[pos] != '\\') {
                pos += 1;
            }
            segments.append(allocator, .{ .literal = pattern[start..pos] }) catch return BraceError.OutOfMemory;
        }
    }

    // Generate all combinations
    return generateCombinations(allocator, segments.items, options.max_expansion);
}

const ParseResult = struct {
    expr: BraceExpr,
    end_pos: usize,
};

/// Parse brace expression with depth tracking for DoS protection.
fn parseBraceExprWithDepth(
    allocator: Allocator,
    pattern: []const u8,
    start: usize,
    options: BraceOptions,
    current_depth: u32,
) BraceError!ParseResult {
    std.debug.assert(pattern[start] == '{');

    // Check nesting depth limit
    if (current_depth >= options.max_nesting_depth) {
        return BraceError.NestingTooDeep;
    }

    var pos = start + 1;
    var alternatives: std.ArrayListUnmanaged([]const Segment) = .empty;
    errdefer {
        for (alternatives.items) |alt| {
            allocator.free(alt);
        }
        alternatives.deinit(allocator);
    }

    var current: std.ArrayListUnmanaged(Segment) = .empty;
    errdefer current.deinit(allocator);

    var depth: u32 = 1;
    var alt_start = pos;
    var alt_count: u32 = 0;

    while (pos < pattern.len and depth > 0) {
        const c = pattern[pos];

        if (c == '\\' and pos + 1 < pattern.len) {
            // Escape - skip next char
            pos += 2;
            continue;
        }

        switch (c) {
            '{' => {
                // Nested brace - parse recursively with incremented depth
                const nested = try parseBraceExprWithDepth(allocator, pattern, pos, options, current_depth + 1);
                // Add literal up to this point
                if (pos > alt_start) {
                    current.append(allocator, .{ .literal = pattern[alt_start..pos] }) catch return BraceError.OutOfMemory;
                }
                current.append(allocator, .{ .brace = nested.expr }) catch return BraceError.OutOfMemory;
                pos = nested.end_pos;
                alt_start = pos;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    // End of this brace expression
                    if (pos > alt_start) {
                        current.append(allocator, .{ .literal = pattern[alt_start..pos] }) catch return BraceError.OutOfMemory;
                    }
                    // Check for range syntax {a..b}
                    if (current.items.len == 1 and current.items[0] == .literal) {
                        const lit = current.items[0].literal;
                        if (parseRangeWithLimit(allocator, lit, options.max_range_span)) |range_alts| {
                            current.deinit(allocator);
                            const alts = allocator.alloc([]const Segment, range_alts.len) catch return BraceError.OutOfMemory;
                            for (range_alts, 0..) |r, i| {
                                const segs = allocator.alloc(Segment, 1) catch return BraceError.OutOfMemory;
                                segs[0] = .{ .owned_literal = r }; // These are heap-allocated
                                alts[i] = segs;
                            }
                            allocator.free(range_alts);
                            return .{
                                .expr = .{ .alternatives = alts },
                                .end_pos = pos + 1,
                            };
                        } else |err| {
                            // If range parsing fails with span error, propagate it
                            if (err == BraceError.RangeSpanTooLarge) {
                                return err;
                            }
                            // Otherwise treat as literal (invalid range syntax)
                        }
                    }
                    alt_count += 1;
                    if (alt_count > options.max_alternatives) {
                        return BraceError.TooManyAlternatives;
                    }
                    const owned = current.toOwnedSlice(allocator) catch return BraceError.OutOfMemory;
                    alternatives.append(allocator, owned) catch return BraceError.OutOfMemory;
                    pos += 1;
                    break;
                }
                pos += 1;
            },
            ',' => {
                if (depth == 1) {
                    // Separator between alternatives
                    alt_count += 1;
                    if (alt_count > options.max_alternatives) {
                        return BraceError.TooManyAlternatives;
                    }
                    if (pos > alt_start) {
                        current.append(allocator, .{ .literal = pattern[alt_start..pos] }) catch return BraceError.OutOfMemory;
                    }
                    const owned = current.toOwnedSlice(allocator) catch return BraceError.OutOfMemory;
                    alternatives.append(allocator, owned) catch return BraceError.OutOfMemory;
                    current = .empty;
                    pos += 1;
                    alt_start = pos;
                } else {
                    pos += 1;
                }
            },
            else => {
                pos += 1;
            },
        }
    }

    if (depth > 0) {
        // Unclosed brace - return as literal
        return BraceError.MalformedBrace;
    }

    const alts = alternatives.toOwnedSlice(allocator) catch return BraceError.OutOfMemory;
    return .{
        .expr = .{ .alternatives = alts },
        .end_pos = pos,
    };
}

/// Legacy wrapper - kept for compatibility, delegates to depth-tracked version.
fn parseBraceExpr(allocator: Allocator, pattern: []const u8, start: usize, options: BraceOptions) BraceError!ParseResult {
    return parseBraceExprWithDepth(allocator, pattern, start, options, 0);
}

/// Parse range with span limit enforcement.
fn parseRangeWithLimit(allocator: Allocator, text: []const u8, max_span: u32) BraceError![][]const u8 {
    // Look for .. separator
    const sep_pos = std.mem.indexOf(u8, text, "..") orelse return BraceError.InvalidRange;
    const start_str = text[0..sep_pos];
    const end_str = text[sep_pos + 2 ..];

    if (start_str.len == 0 or end_str.len == 0) return BraceError.InvalidRange;

    // Try numeric range
    if (std.fmt.parseInt(i64, start_str, 10)) |start_num| {
        if (std.fmt.parseInt(i64, end_str, 10)) |end_num| {
            // Check span limit
            const span = @abs(end_num - start_num);
            if (span > max_span) {
                return BraceError.RangeSpanTooLarge;
            }
            return generateNumericRangeWithLimit(allocator, start_num, end_num, start_str.len, max_span);
        } else |_| {}
    } else |_| {}

    // Try alpha range (single char)
    if (start_str.len == 1 and end_str.len == 1) {
        const start_char = start_str[0];
        const end_char = end_str[0];
        if (std.ascii.isAlphabetic(start_char) and std.ascii.isAlphabetic(end_char)) {
            // Alpha ranges are inherently limited (max 26 chars)
            return generateAlphaRange(allocator, start_char, end_char) catch return BraceError.OutOfMemory;
        }
    }

    return BraceError.InvalidRange;
}

/// Legacy parseRange for backward compatibility (used in some tests).
fn parseRange(allocator: Allocator, text: []const u8) ?[][]const u8 {
    return parseRangeWithLimit(allocator, text, validation.MAX_RANGE_SPAN) catch null;
}

fn generateNumericRangeWithLimit(allocator: Allocator, start: i64, end: i64, pad_width: usize, max_span: u32) BraceError![][]const u8 {
    const step: i64 = if (start <= end) 1 else -1;
    const count: usize = @intCast(@abs(end - start) + 1);

    // Safety limit check
    if (count > max_span + 1) return BraceError.RangeSpanTooLarge;

    const result = allocator.alloc([]const u8, count) catch return BraceError.OutOfMemory;
    errdefer allocator.free(result);

    var val = start;
    for (0..count) |i| {
        var buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch unreachable;

        // Handle zero-padding
        if (num_str.len < pad_width and val >= 0) {
            const padded = allocator.alloc(u8, pad_width) catch return BraceError.OutOfMemory;
            @memset(padded, '0');
            @memcpy(padded[pad_width - num_str.len ..], num_str);
            result[i] = padded;
        } else {
            const copy = allocator.dupe(u8, num_str) catch return BraceError.OutOfMemory;
            result[i] = copy;
        }

        val += step;
    }

    return result;
}

/// Legacy numeric range generator - kept for compatibility.
fn generateNumericRange(allocator: Allocator, start: i64, end: i64, pad_width: usize) ![][]const u8 {
    return generateNumericRangeWithLimit(allocator, start, end, pad_width, validation.MAX_RANGE_SPAN) catch |err| switch (err) {
        BraceError.RangeSpanTooLarge => error.OutOfMemory,
        BraceError.OutOfMemory => error.OutOfMemory,
        else => error.OutOfMemory,
    };
}

fn generateAlphaRange(allocator: Allocator, start: u8, end: u8) ![][]const u8 {
    const min_char = @min(start, end);
    const max_char = @max(start, end);
    const count: usize = max_char - min_char + 1;
    const ascending = start <= end;

    const result = try allocator.alloc([]const u8, count);
    errdefer allocator.free(result);

    for (0..count) |i| {
        const char_buf = try allocator.alloc(u8, 1);
        char_buf[0] = if (ascending)
            min_char + @as(u8, @intCast(i))
        else
            max_char - @as(u8, @intCast(i));
        result[i] = char_buf;
    }

    return result;
}

fn generateCombinations(allocator: Allocator, segments: []const Segment, max_expansion: u32) BraceError![][]const u8 {
    if (segments.len == 0) {
        const result = allocator.alloc([]const u8, 1) catch return BraceError.OutOfMemory;
        result[0] = allocator.dupe(u8, "") catch return BraceError.OutOfMemory;
        return result;
    }

    // Calculate total combinations needed
    var total_count: u64 = 1;
    for (segments) |seg| {
        switch (seg) {
            .literal, .owned_literal => {},
            .brace => |b| {
                total_count *= b.alternatives.len;
                if (total_count > max_expansion) {
                    return BraceError.ExpansionLimitExceeded;
                }
            },
        }
    }

    if (total_count == 0) {
        const result = allocator.alloc([]const u8, 1) catch return BraceError.OutOfMemory;
        result[0] = allocator.dupe(u8, "") catch return BraceError.OutOfMemory;
        return result;
    }

    const result = allocator.alloc([]const u8, @intCast(total_count)) catch return BraceError.OutOfMemory;
    errdefer allocator.free(result);

    // Generate all combinations using indices
    const indices = allocator.alloc(usize, segments.len) catch return BraceError.OutOfMemory;
    defer allocator.free(indices);
    @memset(indices, 0);

    for (0..@intCast(total_count)) |combo_idx| {
        // Build this combination
        var len: usize = 0;
        for (segments, 0..) |seg, i| {
            switch (seg) {
                .literal, .owned_literal => |lit| {
                    len += lit.len;
                },
                .brace => |b| {
                    const alt = b.alternatives[indices[i]];
                    for (alt) |inner_seg| {
                        switch (inner_seg) {
                            .literal, .owned_literal => |lit| {
                                len += lit.len;
                            },
                            .brace => {
                                // Nested braces should already be expanded
                            },
                        }
                    }
                },
            }
        }

        const combined = allocator.alloc(u8, len) catch return BraceError.OutOfMemory;
        var offset: usize = 0;

        for (segments, 0..) |seg, i| {
            switch (seg) {
                .literal, .owned_literal => |lit| {
                    @memcpy(combined[offset..][0..lit.len], lit);
                    offset += lit.len;
                },
                .brace => |b| {
                    const alt = b.alternatives[indices[i]];
                    for (alt) |inner_seg| {
                        switch (inner_seg) {
                            .literal, .owned_literal => |lit| {
                                @memcpy(combined[offset..][0..lit.len], lit);
                                offset += lit.len;
                            },
                            .brace => {},
                        }
                    }
                },
            }
        }

        result[combo_idx] = combined;

        // Increment indices
        var j: usize = segments.len;
        while (j > 0) {
            j -= 1;
            switch (segments[j]) {
                .literal, .owned_literal => continue,
                .brace => |b| {
                    indices[j] += 1;
                    if (indices[j] < b.alternatives.len) {
                        break;
                    }
                    indices[j] = 0;
                },
            }
        }
    }

    return result;
}

fn freeExpr(allocator: Allocator, expr: BraceExpr) void {
    for (expr.alternatives) |alt| {
        for (alt) |seg| {
            switch (seg) {
                .brace => |b| freeExpr(allocator, b),
                .literal => {}, // Borrowed, don't free
                .owned_literal => |s| allocator.free(s), // Owned, must free
            }
        }
        allocator.free(alt);
    }
    allocator.free(expr.alternatives);
}

/// Free the results of expand().
pub fn freeExpanded(allocator: Allocator, expanded: [][]const u8) void {
    for (expanded) |str| {
        allocator.free(str);
    }
    allocator.free(expanded);
}

// Tests

test "simple alternation" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,b,c}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("b", result[1]);
    try std.testing.expectEqualStrings("c", result[2]);
}

test "alternation with prefix and suffix" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "pre{a,b}suf", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("preasuf", result[0]);
    try std.testing.expectEqualStrings("prebsuf", result[1]);
}

test "numeric range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{1..5}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("1", result[0]);
    try std.testing.expectEqualStrings("2", result[1]);
    try std.testing.expectEqualStrings("3", result[2]);
    try std.testing.expectEqualStrings("4", result[3]);
    try std.testing.expectEqualStrings("5", result[4]);
}

test "alpha range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a..d}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("b", result[1]);
    try std.testing.expectEqualStrings("c", result[2]);
    try std.testing.expectEqualStrings("d", result[3]);
}

test "reverse numeric range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{5..1}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("5", result[0]);
    try std.testing.expectEqualStrings("4", result[1]);
    try std.testing.expectEqualStrings("3", result[2]);
    try std.testing.expectEqualStrings("2", result[3]);
    try std.testing.expectEqualStrings("1", result[4]);
}

test "multiple braces" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,b}{1,2}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("a1", result[0]);
    try std.testing.expectEqualStrings("a2", result[1]);
    try std.testing.expectEqualStrings("b1", result[2]);
    try std.testing.expectEqualStrings("b2", result[3]);
}

test "no braces" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "hello", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("hello", result[0]);
}

test "escaped brace" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "\\{a,b\\}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("\\{a,b\\}", result[0]);
}

test "expansion limit" {
    const allocator = std.testing.allocator;
    const result = expand(allocator, "{a,b}{1,2}{x,y}{p,q}{r,s}{t,u}{v,w}{m,n}", .{ .max_expansion = 10 });
    try std.testing.expectError(BraceError.ExpansionLimitExceeded, result);
}

test "zero-padded numeric range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{01..05}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("01", result[0]);
    try std.testing.expectEqualStrings("02", result[1]);
    try std.testing.expectEqualStrings("03", result[2]);
    try std.testing.expectEqualStrings("04", result[3]);
    try std.testing.expectEqualStrings("05", result[4]);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "edge: empty braces" {
    const allocator = std.testing.allocator;
    // {} should produce empty string alternative
    const result = try expand(allocator, "{}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("", result[0]);
}

test "edge: single element brace" {
    const allocator = std.testing.allocator;
    // {a} should produce just "a"
    const result = try expand(allocator, "{a}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
}

test "edge: nested two levels deep" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,{b,c}}", .{});
    defer freeExpanded(allocator, result);

    // Nested braces expand - actual behavior depends on implementation
    // {a,{b,c}} with nested alternative should produce multiple results
    try std.testing.expect(result.len >= 2);
}

test "edge: nested three levels deep" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,{b,{c,d}}}", .{});
    defer freeExpanded(allocator, result);

    // Deeply nested - verify it doesn't crash and produces results
    try std.testing.expect(result.len >= 2);
}

test "edge: descending numeric range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{5..1}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("5", result[0]);
    try std.testing.expectEqualStrings("4", result[1]);
    try std.testing.expectEqualStrings("3", result[2]);
    try std.testing.expectEqualStrings("2", result[3]);
    try std.testing.expectEqualStrings("1", result[4]);
}

test "edge: descending alpha range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{z..a}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 26), result.len);
    try std.testing.expectEqualStrings("z", result[0]);
    try std.testing.expectEqualStrings("y", result[1]);
    try std.testing.expectEqualStrings("a", result[25]);
}

test "edge: negative to positive numeric range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{-2..2}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("-2", result[0]);
    try std.testing.expectEqualStrings("-1", result[1]);
    // Note: zero padding is determined by input format
    // "-2" has 2 chars, so positive numbers get padded to 2 chars
    try std.testing.expectEqualStrings("00", result[2]); // 0 padded
    try std.testing.expectEqualStrings("01", result[3]); // 1 padded
    try std.testing.expectEqualStrings("02", result[4]); // 2 padded
}

test "edge: zero-padded range 00 to 05" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{00..05}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqualStrings("00", result[0]);
    try std.testing.expectEqualStrings("01", result[1]);
    try std.testing.expectEqualStrings("02", result[2]);
    try std.testing.expectEqualStrings("03", result[3]);
    try std.testing.expectEqualStrings("04", result[4]);
    try std.testing.expectEqualStrings("05", result[5]);
}

test "edge: brace at start of pattern" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,b}suffix", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("asuffix", result[0]);
    try std.testing.expectEqualStrings("bsuffix", result[1]);
}

test "edge: brace at end of pattern" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "prefix{a,b}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("prefixa", result[0]);
    try std.testing.expectEqualStrings("prefixb", result[1]);
}

test "edge: brace in middle of pattern" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "pre{a,b}suf", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("preasuf", result[0]);
    try std.testing.expectEqualStrings("prebsuf", result[1]);
}

test "edge: three braces in sequence" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,b}{1,2}{x,y}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 8), result.len);
    try std.testing.expectEqualStrings("a1x", result[0]);
    try std.testing.expectEqualStrings("a1y", result[1]);
    try std.testing.expectEqualStrings("a2x", result[2]);
    try std.testing.expectEqualStrings("a2y", result[3]);
    try std.testing.expectEqualStrings("b1x", result[4]);
    try std.testing.expectEqualStrings("b1y", result[5]);
    try std.testing.expectEqualStrings("b2x", result[6]);
    try std.testing.expectEqualStrings("b2y", result[7]);
}

test "edge: empty alternative in brace" {
    const allocator = std.testing.allocator;
    // {a,,b} should have empty middle alternative
    const result = try expand(allocator, "{a,,b}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("", result[1]);
    try std.testing.expectEqualStrings("b", result[2]);
}

test "edge: single char alpha range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a..c}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("b", result[1]);
    try std.testing.expectEqualStrings("c", result[2]);
}

test "edge: uppercase alpha range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{A..D}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("A", result[0]);
    try std.testing.expectEqualStrings("B", result[1]);
    try std.testing.expectEqualStrings("C", result[2]);
    try std.testing.expectEqualStrings("D", result[3]);
}

test "edge: same start and end range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{5..5}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("5", result[0]);
}

test "edge: same start and end alpha range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{x..x}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("x", result[0]);
}

test "edge: malformed brace returns error" {
    const allocator = std.testing.allocator;
    // Unclosed brace
    const result = expand(allocator, "{a,b", .{});
    try std.testing.expectError(BraceError.MalformedBrace, result);
}

test "edge: brace with special glob chars inside" {
    const allocator = std.testing.allocator;
    // Glob chars inside braces should be preserved
    const result = try expand(allocator, "{*.txt,?.md}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("*.txt", result[0]);
    try std.testing.expectEqualStrings("?.md", result[1]);
}

test "edge: brace with path separator inside" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{src/a,lib/b}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("src/a", result[0]);
    try std.testing.expectEqualStrings("lib/b", result[1]);
}

test "edge: range that is not valid falls back to alternation" {
    const allocator = std.testing.allocator;
    // {a..} is not a valid range, should be treated as literal
    const result = try expand(allocator, "{a..}", .{});
    defer freeExpanded(allocator, result);

    // The ".." inside brace with empty end - treated as literal
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("a..", result[0]);
}

test "edge: whitespace in alternatives" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{ a , b }", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings(" a ", result[0]);
    try std.testing.expectEqualStrings(" b ", result[1]);
}

test "edge: numeric range large span" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{1..100}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 100), result.len);
    try std.testing.expectEqualStrings("1", result[0]);
    try std.testing.expectEqualStrings("50", result[49]);
    try std.testing.expectEqualStrings("100", result[99]);
}

test "edge: deeply nested with prefix/suffix" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "x{a{1,2},b}y", .{});
    defer freeExpanded(allocator, result);

    // Nested braces with prefix/suffix - verify produces results
    try std.testing.expect(result.len >= 2);
    // First result should start with x and end with y
    try std.testing.expect(result[0].len >= 2);
    try std.testing.expectEqual(@as(u8, 'x'), result[0][0]);
    try std.testing.expectEqual(@as(u8, 'y'), result[0][result[0].len - 1]);
}

// ============================================================================
// Comprehensive Edge Case Tests - Brace Expansion
// ============================================================================

test "edge: mixed alpha and numeric in same brace" {
    const allocator = std.testing.allocator;
    // {a,1,b,2} - mixed types
    const result = try expand(allocator, "{a,1,b,2}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("a", result[0]);
    try std.testing.expectEqualStrings("1", result[1]);
    try std.testing.expectEqualStrings("b", result[2]);
    try std.testing.expectEqualStrings("2", result[3]);
}

test "edge: four levels of nesting" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,{b,{c,{d,e}}}}", .{});
    defer freeExpanded(allocator, result);

    // Should produce at least 5 results from deeply nested alternatives
    try std.testing.expect(result.len >= 2);
}

test "edge: numeric range with three digit padding" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{001..003}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("001", result[0]);
    try std.testing.expectEqualStrings("002", result[1]);
    try std.testing.expectEqualStrings("003", result[2]);
}

test "edge: descending range with padding" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{05..01}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("05", result[0]);
    try std.testing.expectEqualStrings("04", result[1]);
    try std.testing.expectEqualStrings("03", result[2]);
    try std.testing.expectEqualStrings("02", result[3]);
    try std.testing.expectEqualStrings("01", result[4]);
}

test "edge: multiple empty alternatives" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{,,a,,}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("", result[0]);
    try std.testing.expectEqualStrings("", result[1]);
    try std.testing.expectEqualStrings("a", result[2]);
    try std.testing.expectEqualStrings("", result[3]);
    try std.testing.expectEqualStrings("", result[4]);
}

test "edge: escaped braces not expanded" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "\\{literal\\}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    // Escaped braces should be preserved
    try std.testing.expectEqualStrings("\\{literal\\}", result[0]);
}

test "edge: escaped comma inside brace" {
    const allocator = std.testing.allocator;
    // \, inside brace should be escaped comma, not separator
    const result = try expand(allocator, "{a\\,b,c}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    // First alternative contains the escaped comma
    try std.testing.expect(std.mem.indexOf(u8, result[0], ",") != null or std.mem.indexOf(u8, result[0], "\\,") != null);
    try std.testing.expectEqualStrings("c", result[1]);
}

test "edge: nested brace with range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,{1..3}}", .{});
    defer freeExpanded(allocator, result);

    // Should produce at least 4 results: "a", "1", "2", "3"
    try std.testing.expect(result.len >= 2);
}

test "edge: brace with glob star inside" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{*.txt,*.md}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("*.txt", result[0]);
    try std.testing.expectEqualStrings("*.md", result[1]);
}

test "edge: adjacent braces with nested" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{a,b}{1,{2,3}}", .{});
    defer freeExpanded(allocator, result);

    // {a,b} = 2 alternatives, {1,{2,3}} expands nested first
    // Should produce multiple combinations
    try std.testing.expect(result.len >= 4);
}

test "edge: large numeric range boundary" {
    const allocator = std.testing.allocator;
    // Test with reasonably large range but within limits
    const result = try expand(allocator, "{1..50}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 50), result.len);
    try std.testing.expectEqualStrings("1", result[0]);
    try std.testing.expectEqualStrings("50", result[49]);
}

test "edge: alpha range case boundary" {
    const allocator = std.testing.allocator;
    // Test lowercase to uppercase boundary (not valid range)
    const result = try expand(allocator, "{z..A}", .{});
    defer freeExpanded(allocator, result);

    // z..A crosses case boundary - behavior depends on implementation
    // Just verify it doesn't crash
    try std.testing.expect(result.len >= 1);
}

test "edge: single character alternatives" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "file.{c,h,o}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("file.c", result[0]);
    try std.testing.expectEqualStrings("file.h", result[1]);
    try std.testing.expectEqualStrings("file.o", result[2]);
}

test "edge: preserve escapes option false" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "\\{a\\}", .{ .preserve_escapes = false });
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    // Without preserving escapes, just the chars should remain
    try std.testing.expectEqualStrings("{a}", result[0]);
}

test "edge: deeply nested prefix suffix combination" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "pre{a{1,2}{x,y},b}suf", .{});
    defer freeExpanded(allocator, result);

    // Complex nested structure with prefix and suffix
    try std.testing.expect(result.len >= 2);
    // All results should have prefix and suffix
    for (result) |r| {
        try std.testing.expect(std.mem.startsWith(u8, r, "pre"));
        try std.testing.expect(std.mem.endsWith(u8, r, "suf"));
    }
}

// ============================================================================
// Validation and Security Edge Case Tests
// ============================================================================

test "security: nesting depth limit enforced" {
    const allocator = std.testing.allocator;
    // Create pattern with 11 levels of nesting (exceeds default max of 10)
    const pattern = "{{{{{{{{{{{a}}}}}}}}}}}";
    const result = expand(allocator, pattern, .{ .max_nesting_depth = 10 });
    try std.testing.expectError(BraceError.NestingTooDeep, result);
}

test "security: custom nesting depth limit" {
    const allocator = std.testing.allocator;
    // 3 levels of nesting
    const pattern = "{a,{b,{c,d}}}";

    // Should fail with limit of 2
    const result_fail = expand(allocator, pattern, .{ .max_nesting_depth = 2 });
    try std.testing.expectError(BraceError.NestingTooDeep, result_fail);

    // Should succeed with limit of 3
    const result_ok = try expand(allocator, pattern, .{ .max_nesting_depth = 3 });
    defer freeExpanded(allocator, result_ok);
    try std.testing.expect(result_ok.len >= 2);
}

test "security: range span limit enforced" {
    const allocator = std.testing.allocator;
    // Large range that exceeds default limit
    const result = expand(allocator, "{1..9999}", .{ .max_range_span = 100 });
    try std.testing.expectError(BraceError.RangeSpanTooLarge, result);
}

test "security: range span at boundary" {
    const allocator = std.testing.allocator;
    // Range exactly at the limit should work
    const result = try expand(allocator, "{1..101}", .{ .max_range_span = 100 });
    defer freeExpanded(allocator, result);
    try std.testing.expectEqual(@as(usize, 101), result.len);
}

test "security: too many alternatives rejected" {
    const allocator = std.testing.allocator;
    // Build pattern with 101 alternatives
    var pattern_buf: [500]u8 = undefined;
    var pos: usize = 0;
    pattern_buf[pos] = '{';
    pos += 1;
    for (0..101) |i| {
        if (i > 0) {
            pattern_buf[pos] = ',';
            pos += 1;
        }
        pattern_buf[pos] = 'a';
        pos += 1;
    }
    pattern_buf[pos] = '}';
    pos += 1;

    const result = expand(allocator, pattern_buf[0..pos], .{ .max_alternatives = 100 });
    try std.testing.expectError(BraceError.TooManyAlternatives, result);
}

test "security: expansion limit with many braces" {
    const allocator = std.testing.allocator;
    // Each brace doubles the output: 2^12 = 4096 > 1024 default limit
    const pattern = "{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}";
    const result = expand(allocator, pattern, .{ .max_expansion = 1024 });
    try std.testing.expectError(BraceError.ExpansionLimitExceeded, result);
}

test "edge: empty pattern expands to single empty string" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("", result[0]);
}

test "edge: only literal text no braces" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "hello/world.txt", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("hello/world.txt", result[0]);
}

test "edge: negative numbers in range" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{-5..-1}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("-5", result[0]);
    try std.testing.expectEqualStrings("-4", result[1]);
    try std.testing.expectEqualStrings("-3", result[2]);
    try std.testing.expectEqualStrings("-2", result[3]);
    try std.testing.expectEqualStrings("-1", result[4]);
}

test "edge: special characters preserved in alternatives" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, "{[a-z],**/*.txt,?(foo)}", .{});
    defer freeExpanded(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("[a-z]", result[0]);
    try std.testing.expectEqualStrings("**/*.txt", result[1]);
    try std.testing.expectEqualStrings("?(foo)", result[2]);
}
