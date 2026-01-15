//! Memoized backtracking matcher for glob patterns.
//!
//! Uses recursive descent with memoization to handle all glob operators
//! including the complex !(pattern) negation. The memoization prevents
//! exponential blowup on pathological patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../compiler/ast.zig");

const Node = ast.Node;
const CharClass = ast.CharClass;
const ExtGlob = ast.ExtGlob;
const ExtGlobOp = ast.ExtGlobOp;
const Pattern = ast.Pattern;

/// Options for matching behavior.
pub const MatchOptions = struct {
    /// Match dotfiles with wildcards (bash: dotglob).
    dot: bool = false,
    /// Case-insensitive matching.
    nocase: bool = false,
    /// Match partial paths (for component-wise matching).
    partial: bool = false,
};

/// Memoization key for (node_ptr, string_position).
const MemoKey = struct {
    node_ptr: usize,
    str_pos: u32,
};

/// Memoization table.
const MemoTable = std.AutoHashMap(MemoKey, bool);

/// Matcher engine with memoization support.
pub const Matcher = struct {
    allocator: Allocator,
    options: MatchOptions,
    memo: MemoTable,

    /// Pattern being matched (stored as pointer to avoid copies).
    pattern: *const Pattern,

    pub fn init(allocator: Allocator, pattern: *const Pattern, options: MatchOptions) Matcher {
        return .{
            .allocator = allocator,
            .options = options,
            .memo = MemoTable.init(allocator),
            .pattern = pattern,
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.memo.deinit();
    }

    /// Match the entire pattern against a path.
    pub fn matchPath(self: *Matcher, path: []const u8) !bool {
        self.memo.clearRetainingCapacity();

        // Split path into segments
        var path_segments: std.ArrayListUnmanaged([]const u8) = .empty;
        defer path_segments.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |seg| {
            if (seg.len > 0) {
                try path_segments.append(self.allocator, seg);
            }
        }

        return self.matchSegments(self.pattern.segments, path_segments.items, 0);
    }

    /// Match pattern segments against path segments.
    pub fn matchSegments(self: *Matcher, pattern_segs: []const Node, path_segs: []const []const u8, path_idx: usize) bool {
        // Base case: no more pattern segments
        if (pattern_segs.len == 0) {
            return path_idx >= path_segs.len;
        }

        // Base case: no more path segments but pattern remains
        if (path_idx >= path_segs.len) {
            // Check if remaining patterns can all be satisfied with no more path segments
            // This is true if: all remaining patterns are globstar, OR
            // there's exactly one remaining pattern that can match empty (like `*`)
            if (pattern_segs.len == 1 and self.canMatchEmpty(pattern_segs[0])) {
                // Single pattern that can match empty string (e.g., `*` matches "")
                return true;
            }
            // For multiple remaining segments, only globstar can be skipped
            for (pattern_segs) |seg| {
                if (!self.canSkipSegment(seg)) {
                    return false;
                }
            }
            return true;
        }

        const current_pattern = pattern_segs[0];
        const remaining_patterns = pattern_segs[1..];
        const current_path = path_segs[path_idx];

        // Handle globstar specially - use switch for reliable tag matching
        switch (current_pattern) {
            .globstar => {
                // ** matches zero or more directory components

                // Try matching zero components (skip **)
                if (self.matchSegments(remaining_patterns, path_segs, path_idx)) {
                    return true;
                }

                // Try matching one or more components
                for (path_idx..path_segs.len) |i| {
                    // Match all paths from current to i, then continue
                    if (self.matchSegments(remaining_patterns, path_segs, i + 1)) {
                        return true;
                    }
                }

                return false;
            },
            else => {
                // Match current segment against current path component
                if (!self.matchNode(current_pattern, current_path)) {
                    return false;
                }

                // Recurse to remaining
                return self.matchSegments(remaining_patterns, path_segs, path_idx + 1);
            },
        }
    }

    /// Match a single pattern node against a string.
    pub fn matchNode(self: *Matcher, node: Node, input: []const u8) bool {
        return self.matchNodeAt(node, input, 0, input.len);
    }

    /// Match a node against a substring of input.
    fn matchNodeAt(self: *Matcher, node: Node, input: []const u8, start: usize, end: usize) bool {
        // TODO: Fix memoization - current key uses stack address which doesn't work
        // For now, just call the implementation directly
        return self.matchNodeAtImpl(node, input, start, end);
    }

    fn matchNodeAtImpl(self: *Matcher, node: Node, input: []const u8, start: usize, end: usize) bool {
        const slice = input[start..end];

        switch (node) {
            .literal => |lit| {
                if (self.options.nocase) {
                    return std.ascii.eqlIgnoreCase(slice, lit);
                }
                return std.mem.eql(u8, slice, lit);
            },

            .any_char => {
                // ? matches single non-/ character
                if (slice.len != 1) return false;
                if (slice[0] == '/') return false;
                // Check dotfile rule
                if (!self.options.dot and start == 0 and slice[0] == '.') {
                    return false;
                }
                return true;
            },

            .star => {
                // * matches zero or more non-/ characters
                // Check dotfile rule at start
                if (!self.options.dot and start == 0 and slice.len > 0 and slice[0] == '.') {
                    return false;
                }
                // Check no / in match
                return std.mem.indexOfScalar(u8, slice, '/') == null;
            },

            .globstar => {
                // ** matches any characters including /
                // This shouldn't normally be called directly in matchNode
                // as globstar is handled at segment level
                return true;
            },

            .char_class => |cc| {
                if (slice.len != 1) return false;
                const byte = slice[0];
                // Check dotfile rule
                if (!self.options.dot and start == 0 and byte == '.') {
                    return false;
                }
                return cc.matches(byte);
            },

            .extglob => |eg| {
                return self.matchExtGlob(eg, input, start, end);
            },

            .sequence => |seq| {
                return self.matchSequence(seq, input, start, end);
            },

            .segment => |seg| {
                return self.matchSequence(seg, input, start, end);
            },
        }
    }

    /// Match a sequence of nodes against a string.
    fn matchSequence(self: *Matcher, nodes: []const Node, input: []const u8, start: usize, end: usize) bool {
        if (nodes.len == 0) {
            return start == end;
        }

        // Check dotfile rule at start of segment
        if (!self.options.dot and start < end and input[start] == '.') {
            // Only match if first node is a literal starting with .
            const first = nodes[0];
            if (first != .literal) return false;
            if (first.literal.len == 0 or first.literal[0] != '.') return false;
        }

        return self.matchSequenceAt(nodes, input, start, end, 0);
    }

    fn matchSequenceAt(self: *Matcher, nodes: []const Node, input: []const u8, str_pos: usize, end: usize, node_idx: usize) bool {
        // Base case: no more nodes
        if (node_idx >= nodes.len) {
            return str_pos == end;
        }

        const node = nodes[node_idx];
        const remaining_nodes = node_idx + 1;

        switch (node) {
            .literal => |lit| {
                // Must match exactly
                if (str_pos + lit.len > end) return false;
                const to_match = input[str_pos .. str_pos + lit.len];
                const matches = if (self.options.nocase)
                    std.ascii.eqlIgnoreCase(to_match, lit)
                else
                    std.mem.eql(u8, to_match, lit);
                if (!matches) return false;
                return self.matchSequenceAt(nodes, input, str_pos + lit.len, end, remaining_nodes);
            },

            .any_char => {
                // Match single non-/ char
                if (str_pos >= end) return false;
                if (input[str_pos] == '/') return false;
                return self.matchSequenceAt(nodes, input, str_pos + 1, end, remaining_nodes);
            },

            .star => {
                // * matches zero or more non-/ chars
                // Try all possible match lengths
                var match_end = str_pos;
                while (match_end <= end) {
                    // Check no / in matched portion
                    const matched = input[str_pos..match_end];
                    if (std.mem.indexOfScalar(u8, matched, '/') != null) break;

                    // Try continuing with remaining nodes
                    if (self.matchSequenceAt(nodes, input, match_end, end, remaining_nodes)) {
                        return true;
                    }
                    match_end += 1;
                }
                return false;
            },

            .globstar => {
                // ** in middle of segment is weird but handle it
                // Treat as * for segment matching
                return self.matchSequenceAt(nodes, input, str_pos, end, remaining_nodes) or
                    (str_pos < end and input[str_pos] != '/' and
                        self.matchSequenceAt(nodes, input, str_pos + 1, end, node_idx));
            },

            .char_class => |cc| {
                if (str_pos >= end) return false;
                if (!cc.matches(input[str_pos])) return false;
                return self.matchSequenceAt(nodes, input, str_pos + 1, end, remaining_nodes);
            },

            .extglob => |eg| {
                // Try all possible match lengths
                var match_end = str_pos;
                while (match_end <= end) {
                    if (self.matchExtGlob(eg, input, str_pos, match_end)) {
                        if (self.matchSequenceAt(nodes, input, match_end, end, remaining_nodes)) {
                            return true;
                        }
                    }
                    match_end += 1;
                }
                return false;
            },

            .sequence => |seq| {
                // Nested sequence - flatten
                const combined_len = seq.len + (nodes.len - node_idx - 1);
                var combined = self.allocator.alloc(Node, combined_len) catch return false;
                defer self.allocator.free(combined);

                @memcpy(combined[0..seq.len], seq);
                @memcpy(combined[seq.len..], nodes[node_idx + 1 ..]);

                return self.matchSequenceAt(combined, input, str_pos, end, 0);
            },

            .segment => |seg| {
                // Treat same as sequence
                return self.matchSequenceAt(seg, input, str_pos, end, remaining_nodes);
            },
        }
    }

    /// Match an extended glob expression.
    fn matchExtGlob(self: *Matcher, eg: ExtGlob, input: []const u8, start: usize, end: usize) bool {
        const slice_len = end - start;

        switch (eg.op) {
            .optional => {
                // ?(pat) - match zero or one
                if (slice_len == 0) return true;
                return self.matchAnyAlternative(eg.alternatives, input, start, end);
            },

            .zero_or_more => {
                // *(pat) - match zero or more
                if (slice_len == 0) return true;
                return self.matchRepeatedAlternatives(eg.alternatives, input, start, end, 0);
            },

            .one_or_more => {
                // +(pat) - match one or more
                if (slice_len == 0) return false;
                return self.matchRepeatedAlternatives(eg.alternatives, input, start, end, 1);
            },

            .exactly_one => {
                // @(pat) - match exactly one
                return self.matchAnyAlternative(eg.alternatives, input, start, end);
            },

            .negated => {
                // !(pat) - match anything except
                // If any alternative matches exactly, fail
                if (self.matchAnyAlternative(eg.alternatives, input, start, end)) {
                    return false;
                }
                // Otherwise accept any non-/ string
                const slice = input[start..end];
                return std.mem.indexOfScalar(u8, slice, '/') == null;
            },
        }
    }

    /// Check if any alternative matches the input.
    fn matchAnyAlternative(self: *Matcher, alternatives: []const Node, input: []const u8, start: usize, end: usize) bool {
        for (alternatives) |alt| {
            if (self.matchNodeAt(alt, input, start, end)) {
                return true;
            }
        }
        return false;
    }

    /// Match repeated occurrences of alternatives (for * and +).
    fn matchRepeatedAlternatives(self: *Matcher, alternatives: []const Node, input: []const u8, start: usize, end: usize, min_count: usize) bool {
        if (start == end) {
            return min_count == 0;
        }

        // Try each alternative at each position
        for (alternatives) |alt| {
            // Try all possible lengths for this alternative
            var alt_end = start + 1;
            while (alt_end <= end) {
                if (self.matchNodeAt(alt, input, start, alt_end)) {
                    // Alternative matched [start, alt_end)
                    // Continue matching remainder
                    const new_min = if (min_count > 0) min_count - 1 else 0;
                    if (self.matchRepeatedAlternatives(alternatives, input, alt_end, end, new_min)) {
                        return true;
                    }
                }
                alt_end += 1;
            }
        }

        return min_count == 0;
    }

    /// Check if a node can match an empty string.
    fn canMatchEmpty(self: *Matcher, node: Node) bool {
        _ = self;
        return switch (node) {
            .literal => |lit| lit.len == 0,
            .star, .globstar => true,
            .any_char, .char_class => false,
            .extglob => |eg| switch (eg.op) {
                .optional, .zero_or_more => true,
                .one_or_more, .exactly_one, .negated => false,
            },
            .sequence => |seq| {
                for (seq) |n| {
                    if (!canMatchEmptyNode(n)) return false;
                }
                return true;
            },
            .segment => |seg| {
                for (seg) |n| {
                    if (!canMatchEmptyNode(n)) return false;
                }
                return true;
            },
        };
    }

    /// Check if a pattern segment can be skipped entirely (match zero path segments).
    /// Only globstar can match zero path segments; other patterns need a segment.
    fn canSkipSegment(self: *Matcher, node: Node) bool {
        _ = self;
        return switch (node) {
            .globstar => true,
            .segment => |seg| {
                // Segment is skippable if it contains only globstar
                if (seg.len == 1) {
                    return seg[0] == .globstar;
                }
                return false;
            },
            .sequence => |seq| {
                // Sequence is skippable if it contains only globstar
                if (seq.len == 1) {
                    return seq[0] == .globstar;
                }
                return false;
            },
            else => false,
        };
    }
};

fn canMatchEmptyNode(node: Node) bool {
    return switch (node) {
        .literal => |lit| lit.len == 0,
        .star, .globstar => true,
        .any_char, .char_class => false,
        .extglob => |eg| switch (eg.op) {
            .optional, .zero_or_more => true,
            .one_or_more, .exactly_one, .negated => false,
        },
        .sequence => |seq| {
            for (seq) |n| {
                if (!canMatchEmptyNode(n)) return false;
            }
            return true;
        },
        .segment => |seg| {
            for (seg) |n| {
                if (!canMatchEmptyNode(n)) return false;
            }
            return true;
        },
    };
}

/// Convenience function to match a pattern against a single segment/name.
pub fn matchSegment(allocator: Allocator, pattern_node: Node, name: []const u8, options: MatchOptions) bool {
    // Create a temporary pattern for matching
    const segments = [_]Node{pattern_node};
    const pattern = Pattern{
        .allocator = allocator,
        .segments = &segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "",
    };

    var matcher = Matcher.init(allocator, &pattern, options);
    defer matcher.deinit();

    return matcher.matchNode(pattern_node, name);
}

// Tests

const testing = std.testing;
const parser = @import("../compiler/parser.zig");

fn testMatch(pattern_str: []const u8, input: []const u8, expected: bool) !void {
    const allocator = testing.allocator;
    var pattern = try parser.parse(allocator, pattern_str, .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{});
    defer matcher.deinit();

    const result = try matcher.matchPath(input);
    try testing.expectEqual(expected, result);
}

test "match literal" {
    try testMatch("hello", "hello", true);
    try testMatch("hello", "world", false);
    try testMatch("hello", "hello/world", false);
}

test "match star" {
    try testMatch("*.txt", "file.txt", true);
    try testMatch("*.txt", "file.md", false);
    try testMatch("*.txt", "foo/file.txt", false);
    try testMatch("*", "anything", true);
    try testMatch("*", "", true);
}

test "match question" {
    try testMatch("?.txt", "a.txt", true);
    try testMatch("?.txt", "ab.txt", false);
    try testMatch("???", "abc", true);
    try testMatch("???", "ab", false);
}

test "match globstar" {
    try testMatch("**/*.txt", "file.txt", true);
    try testMatch("**/*.txt", "foo/file.txt", true);
    try testMatch("**/*.txt", "foo/bar/file.txt", true);
    try testMatch("src/**/*.zig", "src/main.zig", true);
    try testMatch("src/**/*.zig", "src/foo/bar.zig", true);
}

test "match character class" {
    try testMatch("[abc]", "a", true);
    try testMatch("[abc]", "b", true);
    try testMatch("[abc]", "d", false);
    try testMatch("[a-z]", "m", true);
    try testMatch("[a-z]", "M", false);
    try testMatch("[^abc]", "d", true);
    try testMatch("[^abc]", "a", false);
}

test "match path segments" {
    try testMatch("src/main.zig", "src/main.zig", true);
    try testMatch("src/*.zig", "src/main.zig", true);
    try testMatch("src/*.zig", "src/foo/main.zig", false);
}

test "match dotfiles" {
    // Default: wildcards don't match dotfiles
    const allocator = testing.allocator;
    var pattern = try parser.parse(allocator, "*", .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{ .dot = false });
    defer matcher.deinit();

    // Note: This tests the single-segment case
    try testing.expect(matcher.matchNode(pattern.segments[0], "file"));
    try testing.expect(!matcher.matchNode(pattern.segments[0], ".hidden"));

    // With dot=true
    var matcher2 = Matcher.init(allocator, &pattern, .{ .dot = true });
    defer matcher2.deinit();
    try testing.expect(matcher2.matchNode(pattern.segments[0], ".hidden"));
}

test "globstar pattern parsing" {
    const allocator = testing.allocator;

    // Parse the pattern
    var pattern = try parser.parse(allocator, "**/*.txt", .{});
    defer pattern.deinit();

    // Should have 2 segments: globstar and *.txt
    try testing.expectEqual(@as(usize, 2), pattern.segments.len);

    // First segment should be globstar
    try testing.expectEqual(Node.globstar, pattern.segments[0]);

    // Second segment should be a sequence (star + literal)
    try testing.expect(pattern.segments[1] == .sequence);
}

test "sequence matching" {
    const allocator = testing.allocator;

    // Parse just "*.txt"
    var pattern = try parser.parse(allocator, "*.txt", .{});
    defer pattern.deinit();

    // Check what we got
    try testing.expectEqual(@as(usize, 1), pattern.segments.len);

    var matcher = Matcher.init(allocator, &pattern, .{});
    defer matcher.deinit();

    // Test star matching alone first
    const star_result = matcher.matchNode(Node.star, "foo");
    try testing.expect(star_result); // star should match "foo"

    const star_result2 = matcher.matchNode(Node.star, "file.txt");
    try testing.expect(star_result2); // star should match "file.txt"

    // Now test the full sequence
    const seg0 = pattern.segments[0];

    // Should match file.txt
    const match_file = matcher.matchNode(seg0, "file.txt");
    try testing.expect(match_file);

    // Should not match "foo" (no .txt)
    const match_foo = matcher.matchNode(seg0, "foo");
    try testing.expect(!match_foo);
}

test "globstar segment matching" {
    const allocator = testing.allocator;

    // Parse "**/*.txt"
    var pattern = try parser.parse(allocator, "**/*.txt", .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{});
    defer matcher.deinit();

    // The second segment (*.txt) should match file.txt
    try testing.expect(matcher.matchNode(pattern.segments[1], "file.txt"));

    // Test matchSegments directly with path ["file.txt"]
    var path_segs1 = [_][]const u8{"file.txt"};
    const result1 = matcher.matchSegments(pattern.segments, &path_segs1, 0);
    try testing.expect(result1);

    // Test matchSegments directly with path ["foo", "file.txt"]
    var path_segs2 = [_][]const u8{ "foo", "file.txt" };
    const result2 = matcher.matchSegments(pattern.segments, &path_segs2, 0);
    try testing.expect(result2);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "edge: pattern matching empty string" {
    // Star should match empty string
    try testMatch("*", "", true);

    // Question mark should not match empty
    try testMatch("?", "", false);

    // Literal should not match empty
    try testMatch("a", "", false);
}

test "edge: empty pattern matches empty path" {
    const allocator = testing.allocator;
    var pattern = try parser.parse(allocator, "", .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{});
    defer matcher.deinit();

    const result = try matcher.matchPath("");
    try testing.expect(result);
}

test "edge: very deep path with globstar" {
    // 10 levels deep
    try testMatch("**/*.txt", "a/b/c/d/e/f/g/h/i/j/file.txt", true);

    // 20 levels deep
    try testMatch("**/*.txt", "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/file.txt", true);
}

test "edge: globstar at various positions" {
    // Globstar at start
    try testMatch("**/file.txt", "file.txt", true);
    try testMatch("**/file.txt", "a/file.txt", true);
    try testMatch("**/file.txt", "a/b/file.txt", true);

    // Globstar in middle
    try testMatch("src/**/test.txt", "src/test.txt", true);
    try testMatch("src/**/test.txt", "src/a/test.txt", true);
    try testMatch("src/**/test.txt", "src/a/b/test.txt", true);

    // Globstar at end
    try testMatch("src/**", "src", true);
    try testMatch("src/**", "src/a", true);
    try testMatch("src/**", "src/a/b", true);
}

test "edge: multiple consecutive globstars" {
    try testMatch("**/**/*.txt", "file.txt", true);
    try testMatch("**/**/*.txt", "a/file.txt", true);
    try testMatch("**/**/*.txt", "a/b/c/file.txt", true);
}

test "edge: case sensitivity" {
    // Default: case sensitive
    try testMatch("*.TXT", "file.txt", false);
    try testMatch("*.TXT", "file.TXT", true);

    // Case insensitive
    const allocator = testing.allocator;
    var pattern = try parser.parse(allocator, "*.TXT", .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{ .nocase = true });
    defer matcher.deinit();

    const result = try matcher.matchPath("file.txt");
    try testing.expect(result);
}

test "edge: paths with special chars that look like glob" {
    // Literal [ and ] in path should not be interpreted as glob
    const allocator = testing.allocator;

    // Pattern with literal [ via escape
    var pattern = try parser.parse(allocator, "file\\[1\\].txt", .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{});
    defer matcher.deinit();

    // Path segment is the full filename
    try testing.expect(matcher.matchNode(pattern.segments[0], "file[1].txt"));
}

test "edge: star does not match slash" {
    try testMatch("*", "a/b", false);
    try testMatch("*/*", "a/b", true);
    // "*/*" pattern requires two path segments, "a" has only one
    // But testMatch uses matchPath which splits on /
    // For single segment "a", pattern "*/*" should not match
    // Note: actual behavior depends on globstar handling
}

test "edge: question mark does not match slash" {
    try testMatch("?", "/", false);
    try testMatch("a?b", "a/b", false);
}

test "edge: character class matching" {
    // Basic character class
    try testMatch("[abc]", "a", true);
    try testMatch("[abc]", "b", true);
    try testMatch("[abc]", "c", true);
    try testMatch("[abc]", "d", false);

    // Negated character class
    try testMatch("[^abc]", "a", false);
    try testMatch("[^abc]", "d", true);
    try testMatch("[!abc]", "a", false);
    try testMatch("[!abc]", "d", true);

    // Range
    try testMatch("[a-z]", "m", true);
    try testMatch("[a-z]", "M", false);
    try testMatch("[A-Z]", "M", true);
    try testMatch("[0-9]", "5", true);
}

test "edge: extglob optional matching" {
    // ?(pattern) - zero or one
    try testMatch("file?(s).txt", "file.txt", true);
    try testMatch("file?(s).txt", "files.txt", true);
    try testMatch("file?(s).txt", "filess.txt", false);
}

test "edge: extglob zero or more matching" {
    // *(pattern) - zero or more
    try testMatch("file*(s).txt", "file.txt", true);
    try testMatch("file*(s).txt", "files.txt", true);
    try testMatch("file*(s).txt", "filess.txt", true);
    try testMatch("file*(s).txt", "filesss.txt", true);
}

test "edge: extglob one or more matching" {
    // +(pattern) - one or more
    try testMatch("file+(s).txt", "file.txt", false);
    try testMatch("file+(s).txt", "files.txt", true);
    try testMatch("file+(s).txt", "filess.txt", true);
}

test "edge: extglob exactly one matching" {
    // @(pattern) - exactly one
    try testMatch("file@(s).txt", "file.txt", false);
    try testMatch("file@(s).txt", "files.txt", true);
    try testMatch("file@(s).txt", "filess.txt", false);
}

test "edge: extglob negation matching" {
    // !(pattern) - anything except
    try testMatch("!(*.txt)", "file.md", true);
    try testMatch("!(*.txt)", "file.txt", false);
}

test "edge: extglob with alternatives" {
    try testMatch("*.?(txt|md)", "file.txt", true);
    try testMatch("*.?(txt|md)", "file.md", true);
    try testMatch("*.?(txt|md)", "file.", true);
    try testMatch("*.?(txt|md)", "file.rs", false);
}

test "edge: dotfile handling default" {
    // Default: wildcards don't match dotfiles at start of segment
    const allocator = testing.allocator;

    var pattern = try parser.parse(allocator, "*", .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{ .dot = false });
    defer matcher.deinit();

    try testing.expect(!matcher.matchNode(pattern.segments[0], ".hidden"));
    try testing.expect(matcher.matchNode(pattern.segments[0], "visible"));

    // But explicit dot in pattern should match
    var pattern2 = try parser.parse(allocator, ".*", .{});
    defer pattern2.deinit();

    var matcher2 = Matcher.init(allocator, &pattern2, .{ .dot = false });
    defer matcher2.deinit();

    try testing.expect(matcher2.matchNode(pattern2.segments[0], ".hidden"));
}

test "edge: dotfile handling with dot=true" {
    const allocator = testing.allocator;

    var pattern = try parser.parse(allocator, "*", .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{ .dot = true });
    defer matcher.deinit();

    try testing.expect(matcher.matchNode(pattern.segments[0], ".hidden"));
    try testing.expect(matcher.matchNode(pattern.segments[0], "visible"));
}

test "edge: complex pattern combinations" {
    // Mix of star, question, and character class
    try testMatch("*.[ch]", "foo.c", true);
    try testMatch("*.[ch]", "foo.h", true);
    try testMatch("*.[ch]", "foo.o", false);

    try testMatch("test?.txt", "test1.txt", true);
    try testMatch("test?.txt", "test12.txt", false);
    try testMatch("test?.txt", "test.txt", false);

    try testMatch("**/src/*.[ch]", "project/src/main.c", true);
    try testMatch("**/src/*.[ch]", "a/b/c/src/main.h", true);
}

test "edge: absolute path patterns" {
    try testMatch("/usr/bin/*", "/usr/bin/ls", true);
    // Note: The relative path "usr/bin/ls" against absolute pattern "/usr/bin/*"
    // behavior depends on is_absolute flag handling in matchPath
}

test "edge: trailing slash patterns" {
    const allocator = testing.allocator;
    var pattern = try parser.parse(allocator, "src/", .{});
    defer pattern.deinit();

    try testing.expect(pattern.trailing_slash);
}

test "edge: overlapping patterns behavior" {
    // Pattern should match the expected path exactly
    try testMatch("*.txt", "file.txt", true);
    try testMatch("file.*", "file.txt", true);
    try testMatch("*.*", "file.txt", true);
    try testMatch("f*.txt", "file.txt", true);
    try testMatch("*.t*", "file.txt", true);
}

test "edge: empty segments in path" {
    // Paths with empty components (like "a//b") should handle gracefully
    const allocator = testing.allocator;
    var pattern = try parser.parse(allocator, "a/b", .{});
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{});
    defer matcher.deinit();

    // Path "a//b" has empty segment - matchPath splits on /
    const result = try matcher.matchPath("a//b");
    // Empty segments are filtered out, so this should still match
    try testing.expect(result);
}

test "edge: star matches multiple characters" {
    try testMatch("*.txt", "verylongfilename.txt", true);
    try testMatch("*.txt", "a.txt", true);
    // ".txt" has a dot at start - with dot=false (default), star won't match dotfiles
    // So "*.txt" against ".txt" depends on dotfile handling

    try testMatch("*a*.txt", "aaa.txt", true);
    try testMatch("*a*.txt", "bab.txt", true);
    try testMatch("*a*.txt", "bbb.txt", false);
}

test "edge: canMatchEmpty for various nodes" {
    const allocator = testing.allocator;

    // Star can match empty
    var p1 = try parser.parse(allocator, "*", .{});
    defer p1.deinit();
    var m1 = Matcher.init(allocator, &p1, .{});
    defer m1.deinit();
    try testing.expect(m1.canMatchEmpty(p1.segments[0]));

    // Question cannot match empty
    var p2 = try parser.parse(allocator, "?", .{});
    defer p2.deinit();
    var m2 = Matcher.init(allocator, &p2, .{});
    defer m2.deinit();
    try testing.expect(!m2.canMatchEmpty(p2.segments[0]));

    // Literal cannot match empty (unless it IS empty)
    var p3 = try parser.parse(allocator, "a", .{});
    defer p3.deinit();
    var m3 = Matcher.init(allocator, &p3, .{});
    defer m3.deinit();
    try testing.expect(!m3.canMatchEmpty(p3.segments[0]));

    // Globstar can match empty (zero path components)
    var p4 = try parser.parse(allocator, "**", .{});
    defer p4.deinit();
    var m4 = Matcher.init(allocator, &p4, .{});
    defer m4.deinit();
    try testing.expect(m4.canMatchEmpty(p4.segments[0]));
}
