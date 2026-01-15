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
};

/// Options for brace expansion.
pub const BraceOptions = struct {
    /// Maximum number of expanded patterns allowed.
    max_expansion: u32 = 1024,
    /// Whether to preserve escape sequences in output.
    preserve_escapes: bool = true,
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
            // Start of brace expression
            const result = try parseBraceExpr(allocator, pattern, pos, options);
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

fn parseBraceExpr(allocator: Allocator, pattern: []const u8, start: usize, options: BraceOptions) BraceError!ParseResult {
    std.debug.assert(pattern[start] == '{');

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

    while (pos < pattern.len and depth > 0) {
        const c = pattern[pos];

        if (c == '\\' and pos + 1 < pattern.len) {
            // Escape - skip next char
            pos += 2;
            continue;
        }

        switch (c) {
            '{' => {
                // Nested brace - parse recursively
                const nested = try parseBraceExpr(allocator, pattern, pos, options);
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
                        if (parseRange(allocator, lit)) |range_alts| {
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
                        }
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

fn parseRange(allocator: Allocator, text: []const u8) ?[][]const u8 {
    // Look for .. separator
    const sep_pos = std.mem.indexOf(u8, text, "..") orelse return null;
    const start_str = text[0..sep_pos];
    const end_str = text[sep_pos + 2 ..];

    if (start_str.len == 0 or end_str.len == 0) return null;

    // Try numeric range
    if (std.fmt.parseInt(i64, start_str, 10)) |start_num| {
        if (std.fmt.parseInt(i64, end_str, 10)) |end_num| {
            return generateNumericRange(allocator, start_num, end_num, start_str.len) catch null;
        } else |_| {}
    } else |_| {}

    // Try alpha range (single char)
    if (start_str.len == 1 and end_str.len == 1) {
        const start_char = start_str[0];
        const end_char = end_str[0];
        if (std.ascii.isAlphabetic(start_char) and std.ascii.isAlphabetic(end_char)) {
            return generateAlphaRange(allocator, start_char, end_char) catch null;
        }
    }

    return null;
}

fn generateNumericRange(allocator: Allocator, start: i64, end: i64, pad_width: usize) ![][]const u8 {
    const step: i64 = if (start <= end) 1 else -1;
    const count: usize = @intCast(@abs(end - start) + 1);

    if (count > 10000) return error.OutOfMemory; // Safety limit

    const result = try allocator.alloc([]const u8, count);
    errdefer allocator.free(result);

    var val = start;
    for (0..count) |i| {
        var buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "{d}", .{val}) catch unreachable;

        // Handle zero-padding
        if (num_str.len < pad_width and val >= 0) {
            const padded = try allocator.alloc(u8, pad_width);
            @memset(padded, '0');
            @memcpy(padded[pad_width - num_str.len ..], num_str);
            result[i] = padded;
        } else {
            const copy = try allocator.dupe(u8, num_str);
            result[i] = copy;
        }

        val += step;
    }

    return result;
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
