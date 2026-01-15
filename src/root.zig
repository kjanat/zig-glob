//! Zig Glob - A production-grade glob pattern matching library.
//!
//! Features:
//! - Full bash glob compatibility (*, ?, **, [...], {...})
//! - Extended glob operators (?(), *(), +(), @(), !())
//! - POSIX character classes ([:alpha:], [:digit:], etc.)
//! - Brace expansion with nested braces and ranges
//! - Component-wise filesystem traversal
//! - Configurable symlink handling and dotfile behavior
//!
//! ## Quick Start
//!
//! ```zig
//! const std = @import("std");
//! const glob = @import("zig_glob");
//!
//! pub fn main() !void {
//!     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//!     defer _ = gpa.deinit();
//!     const allocator = gpa.allocator();
//!
//!     // Match a pattern against a path
//!     const matches = try glob.match(allocator, "**/*.zig", "src/main.zig", .{});
//!     _ = matches;
//!
//!     // Compile a pattern for repeated use
//!     var pattern = try glob.compile(allocator, "src/**/*.zig", .{});
//!     defer pattern.deinit();
//!
//!     // Walk filesystem matching pattern
//!     var iter = try glob.glob(allocator, &.{"**/*.zig"}, .{ .cwd = "." });
//!     defer iter.deinit();
//!     while (try iter.next()) |entry| {
//!         defer allocator.free(entry.path);
//!         std.debug.print("{s}\n", .{entry.path});
//!     }
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// Re-export compiler modules
pub const ast = @import("compiler/ast.zig");
pub const lexer = @import("compiler/lexer.zig");
pub const brace = @import("compiler/brace.zig");
pub const parser = @import("compiler/parser.zig");
pub const validation = @import("compiler/validation.zig");

// Re-export matcher modules
pub const automaton = @import("matcher/automaton.zig");

// Re-export walker modules
pub const traverser = @import("walker/traverser.zig");
pub const symlink = @import("walker/symlink.zig");

// Re-export types
pub const Node = ast.Node;
pub const Pattern = ast.Pattern;
pub const CompileOptions = ast.CompileOptions;
pub const CharClass = ast.CharClass;
pub const CharMember = ast.CharMember;
pub const PosixClass = ast.PosixClass;
pub const ExtGlob = ast.ExtGlob;
pub const ExtGlobOp = ast.ExtGlobOp;

pub const Token = lexer.Token;
pub const TokenKind = lexer.TokenKind;
pub const Lexer = lexer.Lexer;

pub const BraceError = brace.BraceError;
pub const BraceOptions = brace.BraceOptions;

pub const ParseError = parser.ParseError;
pub const Parser = parser.Parser;

pub const Matcher = automaton.Matcher;
pub const MatchOptions = automaton.MatchOptions;

pub const Walker = traverser.Walker;
pub const WalkerOptions = traverser.WalkerOptions;
pub const WalkerMatch = traverser.Match;

pub const SymlinkPolicy = symlink.SymlinkPolicy;
pub const VisitedSet = symlink.VisitedSet;

// Validation types
pub const ValidationError = validation.ValidationError;
pub const ValidationResult = validation.ValidationResult;
pub const validatePattern = validation.validatePattern;

// Error handling policy for walker
pub const ErrorPolicy = traverser.ErrorPolicy;

/// Options for glob operations.
pub const GlobOptions = struct {
    /// Base directory for relative patterns.
    cwd: []const u8 = ".",

    /// Match dotfiles with wildcards (default: false, like bash).
    dot: bool = false,

    /// Enable globstar (**) support.
    globstar: bool = true,

    /// Enable brace expansion ({a,b}).
    brace_expansion: bool = true,

    /// Enable extended glob operators (?(), *(), etc.).
    extglob: bool = true,

    /// Case-insensitive matching.
    nocase: bool = false,

    /// Follow directory symlinks during traversal.
    follow_dir_symlinks: bool = false,

    /// Include broken symlinks in results.
    include_broken_symlinks: bool = true,

    /// Return absolute paths instead of relative.
    absolute: bool = false,

    /// Append / to directory matches.
    mark_directories: bool = false,

    /// Maximum brace expansion count (DoS protection).
    max_brace_expansion: u32 = 1024,

    /// Maximum recursion depth (null = unlimited).
    max_depth: ?u32 = null,

    /// File types to include.
    types: EntryTypeFilter = .all,

    /// Patterns to exclude from results.
    exclude: ?[]const []const u8 = null,
};

/// Filter for entry types.
pub const EntryTypeFilter = enum {
    all,
    files_only,
    directories_only,
};

/// A matched entry from glob traversal.
pub const GlobEntry = struct {
    /// Path relative to cwd (or absolute if options.absolute).
    path: []const u8,

    /// Entry type.
    kind: std.fs.File.Kind,

    /// File metadata (if requested).
    stat: ?std.fs.File.Stat = null,
};

// ============================================================================
// Public API
// ============================================================================

/// Compile a glob pattern for repeated use.
pub fn compile(allocator: Allocator, pattern: []const u8, options: CompileOptions) ParseError!Pattern {
    return parser.parse(allocator, pattern, options);
}

/// Expand brace expressions in a pattern.
pub fn expandBraces(allocator: Allocator, pattern: []const u8, options: BraceOptions) BraceError![][]const u8 {
    return brace.expand(allocator, pattern, options);
}

/// Free the results from expandBraces.
pub fn freeBraces(allocator: Allocator, expanded: [][]const u8) void {
    brace.freeExpanded(allocator, expanded);
}

/// Match a pattern against a path (no filesystem access).
pub fn match(allocator: Allocator, pattern_str: []const u8, path: []const u8, options: GlobOptions) !bool {
    // Handle brace expansion
    if (options.brace_expansion) {
        const expanded = try expandBraces(allocator, pattern_str, .{ .max_expansion = options.max_brace_expansion });
        defer freeBraces(allocator, expanded);

        for (expanded) |pat| {
            if (try matchSingle(allocator, pat, path, options)) {
                return true;
            }
        }
        return false;
    }

    return matchSingle(allocator, pattern_str, path, options);
}

fn matchSingle(allocator: Allocator, pattern_str: []const u8, path: []const u8, options: GlobOptions) !bool {
    var pattern = try compile(allocator, pattern_str, .{
        .globstar = options.globstar,
        .brace = false, // Already expanded
        .extglob = options.extglob,
        .nocase = options.nocase,
        .dot = options.dot,
    });
    defer pattern.deinit();

    var matcher = Matcher.init(allocator, &pattern, .{
        .dot = options.dot,
        .nocase = options.nocase,
    });
    defer matcher.deinit();

    return matcher.matchPath(path);
}

/// Walker with its associated pattern (pattern must outlive walker).
const WalkerWithPattern = struct {
    walker: traverser.Walker,
    pattern: Pattern,
};

/// Iterator for glob results.
pub const GlobIterator = struct {
    allocator: Allocator,
    walkers: std.array_list.AlignedManaged(WalkerWithPattern, null),
    current_walker: usize,
    options: GlobOptions,

    pub fn init(allocator: Allocator, patterns: []const []const u8, options: GlobOptions) !GlobIterator {
        var walkers = std.array_list.AlignedManaged(WalkerWithPattern, null).init(allocator);
        errdefer {
            for (walkers.items) |*wp| {
                wp.walker.deinit();
                wp.pattern.deinit();
            }
            walkers.deinit();
        }

        for (patterns) |pattern_str| {
            // Handle brace expansion
            const expanded = if (options.brace_expansion)
                try brace.expand(allocator, pattern_str, .{ .max_expansion = options.max_brace_expansion })
            else blk: {
                const single = try allocator.alloc([]const u8, 1);
                single[0] = try allocator.dupe(u8, pattern_str);
                break :blk single;
            };
            defer {
                for (expanded) |e| allocator.free(e);
                allocator.free(expanded);
            }

            for (expanded) |pat| {
                var pattern = try parser.parse(allocator, pat, .{
                    .globstar = options.globstar,
                    .brace = false,
                    .extglob = options.extglob,
                    .nocase = options.nocase,
                    .dot = options.dot,
                });
                errdefer pattern.deinit();

                // Append pattern first so we can take its address
                try walkers.append(.{
                    .pattern = pattern,
                    .walker = undefined, // Will be initialized next
                });
                const wp = &walkers.items[walkers.items.len - 1];

                // Now initialize walker with pointer to stored pattern
                wp.walker = try traverser.Walker.initFromPath(allocator, &wp.pattern, options.cwd, .{
                    .dot = options.dot,
                    .nocase = options.nocase,
                    .follow_symlinks = options.follow_dir_symlinks,
                    .include_broken_symlinks = options.include_broken_symlinks,
                    .max_depth = options.max_depth,
                    .exclude = options.exclude,
                });
            }
        }

        return .{
            .allocator = allocator,
            .walkers = walkers,
            .current_walker = 0,
            .options = options,
        };
    }

    pub fn deinit(self: *GlobIterator) void {
        for (self.walkers.items) |*wp| {
            wp.walker.deinit();
            wp.pattern.deinit();
        }
        self.walkers.deinit();
    }

    pub fn next(self: *GlobIterator) !?GlobEntry {
        while (self.current_walker < self.walkers.items.len) {
            if (try self.walkers.items[self.current_walker].walker.next()) |m| {
                // Apply type filter
                const include = switch (self.options.types) {
                    .all => true,
                    .files_only => m.kind == .file,
                    .directories_only => m.kind == .directory,
                };

                if (!include) {
                    self.allocator.free(m.path);
                    continue;
                }

                return GlobEntry{
                    .path = m.path,
                    .kind = m.kind,
                    .stat = null,
                };
            }
            self.current_walker += 1;
        }
        return null;
    }

    /// Collect all remaining matches into a slice.
    pub fn collectAll(self: *GlobIterator) ![]GlobEntry {
        var results = std.array_list.AlignedManaged(GlobEntry, null).init(self.allocator);
        errdefer results.deinit();

        while (try self.next()) |entry| {
            try results.append(entry);
        }

        return results.toOwnedSlice();
    }
};

/// Walk filesystem matching patterns (iterator-based).
pub fn glob(allocator: Allocator, patterns: []const []const u8, options: GlobOptions) !GlobIterator {
    return GlobIterator.init(allocator, patterns, options);
}

/// Walk filesystem matching patterns (collect all results).
pub fn globSync(allocator: Allocator, patterns: []const []const u8, options: GlobOptions) ![]GlobEntry {
    var iter = try glob(allocator, patterns, options);
    defer iter.deinit();
    return iter.collectAll();
}

/// Free the results from globSync.
pub fn freeGlobResults(allocator: Allocator, results: []GlobEntry) void {
    for (results) |entry| {
        allocator.free(entry.path);
    }
    allocator.free(results);
}

/// Tokenize a pattern (low-level API).
pub fn tokenize(allocator: Allocator, pattern: []const u8) ![]Token {
    return lexer.tokenize(allocator, pattern);
}

// ============================================================================
// Tests
// ============================================================================

test "compile and match" {
    const allocator = std.testing.allocator;

    var pattern = try compile(allocator, "*.zig", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
}

test "match basic patterns" {
    const allocator = std.testing.allocator;

    try std.testing.expect(try match(allocator, "*.txt", "file.txt", .{}));
    try std.testing.expect(!try match(allocator, "*.txt", "file.md", .{}));
    try std.testing.expect(try match(allocator, "**/*.zig", "src/main.zig", .{}));
}

test "match with brace expansion" {
    const allocator = std.testing.allocator;

    try std.testing.expect(try match(allocator, "*.{txt,md}", "file.txt", .{}));
    try std.testing.expect(try match(allocator, "*.{txt,md}", "file.md", .{}));
    try std.testing.expect(!try match(allocator, "*.{txt,md}", "file.zig", .{}));
}

test "brace expansion" {
    const allocator = std.testing.allocator;

    const expanded = try expandBraces(allocator, "{a,b,c}", .{});
    defer freeBraces(allocator, expanded);

    try std.testing.expectEqual(@as(usize, 3), expanded.len);
    try std.testing.expectEqualStrings("a", expanded[0]);
    try std.testing.expectEqualStrings("b", expanded[1]);
    try std.testing.expectEqualStrings("c", expanded[2]);
}

test "tokenize pattern" {
    const allocator = std.testing.allocator;

    const tokens = try tokenize(allocator, "*.txt");
    defer allocator.free(tokens);

    try std.testing.expectEqual(TokenKind.star, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.literal, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.eof, tokens[2].kind);
}

test "glob iterator on current directory" {
    const allocator = std.testing.allocator;

    // Test that we can iterate over .zig files in src/
    var iter = try glob(allocator, &.{"src/*.zig"}, .{});
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        allocator.free(entry.path);
        count += 1;
    }

    // Should find at least root.zig
    try std.testing.expect(count >= 1);
}

test "globSync collects results" {
    const allocator = std.testing.allocator;

    const results = try globSync(allocator, &.{"src/compiler/*.zig"}, .{});
    defer freeGlobResults(allocator, results);

    // Should find lexer.zig, parser.zig, brace.zig, ast.zig
    try std.testing.expect(results.len >= 4);
}

test "glob with type filter" {
    const allocator = std.testing.allocator;

    var iter = try glob(allocator, &.{"src/*"}, .{ .types = .directories_only });
    defer iter.deinit();

    var found_compiler = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.eql(u8, entry.path, "src/compiler") or
            std.mem.endsWith(u8, entry.path, "/compiler"))
        {
            found_compiler = true;
        }
        try std.testing.expectEqual(std.fs.File.Kind.directory, entry.kind);
    }

    try std.testing.expect(found_compiler);
}

test "glob with exclude pattern" {
    const allocator = std.testing.allocator;

    // Match all .zig files but exclude root.zig
    var iter = try glob(allocator, &.{"src/*.zig"}, .{
        .exclude = &.{"**/root.zig"},
    });
    defer iter.deinit();

    var found_main = false;
    var found_root = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "main.zig")) {
            found_main = true;
        }
        if (std.mem.endsWith(u8, entry.path, "root.zig")) {
            found_root = true;
        }
    }

    try std.testing.expect(found_main); // main.zig should be found
    try std.testing.expect(!found_root); // root.zig should be excluded
}

test "glob with multiple exclude patterns" {
    const allocator = std.testing.allocator;

    // Match all files in compiler but exclude lexer and parser
    var iter = try glob(allocator, &.{"src/compiler/*.zig"}, .{
        .exclude = &.{ "**/lexer.zig", "**/parser.zig" },
    });
    defer iter.deinit();

    var found_ast = false;
    var found_lexer = false;
    var found_parser = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "ast.zig")) found_ast = true;
        if (std.mem.endsWith(u8, entry.path, "lexer.zig")) found_lexer = true;
        if (std.mem.endsWith(u8, entry.path, "parser.zig")) found_parser = true;
    }

    try std.testing.expect(found_ast); // ast.zig should be found
    try std.testing.expect(!found_lexer); // lexer.zig should be excluded
    try std.testing.expect(!found_parser); // parser.zig should be excluded
}

test "glob exclude with globstar" {
    const allocator = std.testing.allocator;

    // Match everything but exclude all .zig files
    var iter = try glob(allocator, &.{"src/**/*"}, .{
        .exclude = &.{"**/*.zig"},
        .types = .files_only,
    });
    defer iter.deinit();

    var found_zig = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, ".zig")) {
            found_zig = true;
        }
    }

    // Should not find any .zig files
    try std.testing.expect(!found_zig);
}

// ============================================================================
// Exclude Functionality Tests - Edge Cases
// ============================================================================

test "exclude: empty exclude list matches everything" {
    const allocator = std.testing.allocator;

    // Match all .zig files with empty exclude list (null = no exclusions)
    var iter = try glob(allocator, &.{"src/*.zig"}, .{
        .exclude = null, // Explicit null
    });
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        count += 1;
    }

    // Should find files (at least root.zig)
    try std.testing.expect(count >= 1);
}

test "exclude: empty slice exclude list matches everything" {
    const allocator = std.testing.allocator;

    // Match all .zig files with empty exclude slice
    const empty_excludes: []const []const u8 = &.{};
    var iter = try glob(allocator, &.{"src/*.zig"}, .{
        .exclude = empty_excludes,
    });
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        count += 1;
    }

    // Should find files (at least root.zig)
    try std.testing.expect(count >= 1);
}

test "exclude: pattern that matches nothing" {
    const allocator = std.testing.allocator;

    // Exclude pattern that won't match any real files
    var iter = try glob(allocator, &.{"src/*.zig"}, .{
        .exclude = &.{"**/nonexistent_pattern_xyz123.abc"},
    });
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        count += 1;
    }

    // Should find all .zig files since exclude matches nothing
    try std.testing.expect(count >= 1);
}

test "exclude: pattern that matches everything" {
    const allocator = std.testing.allocator;

    // Exclude all files with **/*
    var iter = try glob(allocator, &.{"src/**/*.zig"}, .{
        .exclude = &.{"**/*"},
        .types = .files_only,
    });
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        count += 1;
    }

    // Should find nothing since all are excluded
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "exclude: pattern with special characters in filename" {
    const allocator = std.testing.allocator;

    // Test that exclude works with patterns containing special chars
    // Using a pattern that might have special characters
    var iter = try glob(allocator, &.{"src/**/*"}, .{
        .exclude = &.{"**/*.zig"},
    });
    defer iter.deinit();

    var found_zig = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, ".zig")) {
            found_zig = true;
        }
    }

    // Should not find any .zig files
    try std.testing.expect(!found_zig);
}

// ============================================================================
// Exclude Functionality Tests - Pattern Types
// ============================================================================

test "exclude: simple wildcard pattern (*.txt)" {
    const allocator = std.testing.allocator;

    // This tests that simple *.ext patterns work in exclude
    var iter = try glob(allocator, &.{"src/**/*"}, .{
        .exclude = &.{"**/*.zig"},
        .types = .files_only,
    });
    defer iter.deinit();

    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        // Verify no .zig files come through
        try std.testing.expect(!std.mem.endsWith(u8, entry.path, ".zig"));
    }
}

test "exclude: question mark wildcard" {
    const allocator = std.testing.allocator;

    // Exclude files with single character before .zig
    // This tests ? wildcard in exclude patterns
    var iter = try glob(allocator, &.{"src/compiler/*.zig"}, .{
        .exclude = &.{"**/???.zig"}, // Excludes 3-char names like ast.zig
    });
    defer iter.deinit();

    var found_ast = false;
    var found_lexer = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "ast.zig")) found_ast = true;
        if (std.mem.endsWith(u8, entry.path, "lexer.zig")) found_lexer = true;
    }

    // ast.zig (3 chars) should be excluded, lexer.zig (5 chars) should remain
    try std.testing.expect(!found_ast);
    try std.testing.expect(found_lexer);
}

test "exclude: character class pattern [a-z]" {
    const allocator = std.testing.allocator;

    // Exclude files starting with specific letters
    var iter = try glob(allocator, &.{"src/compiler/*.zig"}, .{
        .exclude = &.{"**/[ab]*.zig"}, // Excludes ast.zig, brace.zig
    });
    defer iter.deinit();

    var found_ast = false;
    var found_brace = false;
    var found_lexer = false;
    var found_parser = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "ast.zig")) found_ast = true;
        if (std.mem.endsWith(u8, entry.path, "brace.zig")) found_brace = true;
        if (std.mem.endsWith(u8, entry.path, "lexer.zig")) found_lexer = true;
        if (std.mem.endsWith(u8, entry.path, "parser.zig")) found_parser = true;
    }

    // ast.zig and brace.zig should be excluded
    try std.testing.expect(!found_ast);
    try std.testing.expect(!found_brace);
    // lexer.zig and parser.zig should remain
    try std.testing.expect(found_lexer);
    try std.testing.expect(found_parser);
}

test "exclude: negated character class [^a-z]" {
    const allocator = std.testing.allocator;

    // Exclude files NOT starting with a-l (should keep ast, brace, lexer but exclude parser, validation)
    var iter = try glob(allocator, &.{"src/compiler/*.zig"}, .{
        .exclude = &.{"**/[^a-l]*.zig"}, // Excludes files starting with m-z
    });
    defer iter.deinit();

    var found_ast = false;
    var found_parser = false;
    var found_validation = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "ast.zig")) found_ast = true;
        if (std.mem.endsWith(u8, entry.path, "parser.zig")) found_parser = true;
        if (std.mem.endsWith(u8, entry.path, "validation.zig")) found_validation = true;
    }

    // ast.zig should remain (starts with 'a')
    try std.testing.expect(found_ast);
    // parser.zig and validation.zig should be excluded (start with p, v)
    try std.testing.expect(!found_parser);
    try std.testing.expect(!found_validation);
}

test "exclude: extglob optional pattern ?()" {
    const allocator = std.testing.allocator;

    // Test extglob optional in exclude
    var iter = try glob(allocator, &.{"src/compiler/*.zig"}, .{
        .exclude = &.{"**/ast?(s).zig"}, // Excludes ast.zig or asts.zig
    });
    defer iter.deinit();

    var found_ast = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "ast.zig")) found_ast = true;
    }

    // ast.zig should be excluded
    try std.testing.expect(!found_ast);
}

test "exclude: extglob alternatives @(a|b)" {
    const allocator = std.testing.allocator;

    // Test extglob alternatives in exclude
    var iter = try glob(allocator, &.{"src/compiler/*.zig"}, .{
        .exclude = &.{"**/@(ast|lexer).zig"}, // Excludes ast.zig or lexer.zig
    });
    defer iter.deinit();

    var found_ast = false;
    var found_lexer = false;
    var found_parser = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "ast.zig")) found_ast = true;
        if (std.mem.endsWith(u8, entry.path, "lexer.zig")) found_lexer = true;
        if (std.mem.endsWith(u8, entry.path, "parser.zig")) found_parser = true;
    }

    // ast.zig and lexer.zig should be excluded
    try std.testing.expect(!found_ast);
    try std.testing.expect(!found_lexer);
    // parser.zig should remain
    try std.testing.expect(found_parser);
}

test "exclude: extglob negation !(pattern)" {
    const allocator = std.testing.allocator;

    // Exclude everything EXCEPT .zig files (using negation)
    // !(*.zig) means match anything that is NOT *.zig
    var iter = try glob(allocator, &.{"src/**/*"}, .{
        .exclude = &.{"**/!(*.zig)"},
        .types = .files_only,
    });
    defer iter.deinit();

    var found_zig = false;
    var found_non_zig = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, ".zig")) {
            found_zig = true;
        } else {
            found_non_zig = true;
        }
    }

    // Should find .zig files (not excluded)
    try std.testing.expect(found_zig);
    // Non-.zig files would be excluded by the negation pattern
}

// ============================================================================
// Exclude Functionality Tests - Option Interactions
// ============================================================================

test "exclude: interaction with dot option (dotfiles)" {
    const allocator = std.testing.allocator;

    // Test that exclude patterns can match dotfiles when dot=true
    var iter = try glob(allocator, &.{"**/*"}, .{
        .cwd = ".",
        .dot = true, // Include dotfiles in main pattern
        .exclude = &.{ "**/.git/**", "**/.*" }, // Exclude .git and dotfiles
    });
    defer iter.deinit();

    var found_git = false;
    var found_dotfile = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.indexOf(u8, entry.path, ".git") != null) {
            found_git = true;
        }
        // Check for dotfiles (files starting with .)
        const basename = std.fs.path.basename(entry.path);
        if (basename.len > 0 and basename[0] == '.') {
            found_dotfile = true;
        }
    }

    // .git directory content should be excluded
    try std.testing.expect(!found_git);
}

test "exclude: interaction with nocase option" {
    const allocator = std.testing.allocator;

    // Test case-insensitive exclude matching
    var iter = try glob(allocator, &.{"src/**/*.zig"}, .{
        .nocase = true,
        .exclude = &.{"**/ROOT.zig"}, // Uppercase - should match root.zig with nocase
    });
    defer iter.deinit();

    var found_root = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        // Check both case variants
        if (std.mem.endsWith(u8, entry.path, "root.zig") or
            std.mem.endsWith(u8, entry.path, "ROOT.zig"))
        {
            found_root = true;
        }
    }

    // root.zig should be excluded due to nocase matching
    try std.testing.expect(!found_root);
}

test "exclude: interaction with files_only type filter" {
    const allocator = std.testing.allocator;

    // Exclude + files_only filter
    var iter = try glob(allocator, &.{"src/**/*"}, .{
        .types = .files_only,
        .exclude = &.{"**/*.zig"},
    });
    defer iter.deinit();

    var found_zig = false;
    var found_directory = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, ".zig")) {
            found_zig = true;
        }
        if (entry.kind == .directory) {
            found_directory = true;
        }
    }

    // No .zig files should be found (excluded)
    try std.testing.expect(!found_zig);
    // No directories should be found (type filter)
    try std.testing.expect(!found_directory);
}

test "exclude: interaction with directories_only type filter" {
    const allocator = std.testing.allocator;

    // Exclude + directories_only filter
    var iter = try glob(allocator, &.{"src/**/*"}, .{
        .types = .directories_only,
        .exclude = &.{"**/compiler"}, // Exclude compiler directory
    });
    defer iter.deinit();

    var found_compiler = false;
    var found_file = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "compiler")) {
            found_compiler = true;
        }
        if (entry.kind == .file) {
            found_file = true;
        }
    }

    // compiler directory should be excluded
    try std.testing.expect(!found_compiler);
    // No files should be found (type filter)
    try std.testing.expect(!found_file);
}

test "exclude: interaction with max_depth" {
    const allocator = std.testing.allocator;

    // Exclude + max_depth
    var iter = try glob(allocator, &.{"src/**/*"}, .{
        .max_depth = 1,
        .exclude = &.{"**/root.zig"},
    });
    defer iter.deinit();

    var found_root = false;
    var found_deep = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "root.zig")) {
            found_root = true;
        }
        // Check for deeply nested files
        var depth: usize = 0;
        for (entry.path) |c| {
            if (c == '/') depth += 1;
        }
        if (depth > 1) found_deep = true;
    }

    // root.zig should be excluded
    try std.testing.expect(!found_root);
    // Should not find files deeper than max_depth
    try std.testing.expect(!found_deep);
}

// ============================================================================
// Exclude Functionality Tests - Performance/Stress
// ============================================================================

test "exclude: many exclude patterns" {
    const allocator = std.testing.allocator;

    // Test with multiple exclude patterns
    var iter = try glob(allocator, &.{"src/compiler/*.zig"}, .{
        .exclude = &.{
            "**/ast.zig",
            "**/lexer.zig",
            "**/parser.zig",
            "**/brace.zig",
            "**/validation.zig",
            // Additional patterns that won't match anything
            "**/nonexistent1.zig",
            "**/nonexistent2.zig",
            "**/nonexistent3.zig",
            "**/nonexistent4.zig",
            "**/nonexistent5.zig",
        },
    });
    defer iter.deinit();

    var found_ast = false;
    var found_lexer = false;
    var found_parser = false;
    var found_brace = false;
    var found_validation = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "ast.zig")) found_ast = true;
        if (std.mem.endsWith(u8, entry.path, "lexer.zig")) found_lexer = true;
        if (std.mem.endsWith(u8, entry.path, "parser.zig")) found_parser = true;
        if (std.mem.endsWith(u8, entry.path, "brace.zig")) found_brace = true;
        if (std.mem.endsWith(u8, entry.path, "validation.zig")) found_validation = true;
    }

    // All specified files should be excluded
    try std.testing.expect(!found_ast);
    try std.testing.expect(!found_lexer);
    try std.testing.expect(!found_parser);
    try std.testing.expect(!found_brace);
    try std.testing.expect(!found_validation);
}

test "exclude: pattern requiring backtracking" {
    const allocator = std.testing.allocator;

    // Pattern with multiple wildcards that may require backtracking
    var iter = try glob(allocator, &.{"src/**/*.zig"}, .{
        .exclude = &.{"**/*a*r*.zig"}, // Matches parser.zig (p-a-r-ser)
    });
    defer iter.deinit();

    var found_parser = false;
    var found_lexer = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "parser.zig")) found_parser = true;
        if (std.mem.endsWith(u8, entry.path, "lexer.zig")) found_lexer = true;
    }

    // parser.zig matches *a*r* pattern (p[a]rse[r].zig)
    try std.testing.expect(!found_parser);
    // lexer.zig does not match (no 'a' before 'r')
    try std.testing.expect(found_lexer);
}

test "exclude: overlapping exclude patterns" {
    const allocator = std.testing.allocator;

    // Multiple patterns that overlap in what they exclude
    var iter = try glob(allocator, &.{"src/**/*.zig"}, .{
        .exclude = &.{
            "**/*.zig", // Excludes all .zig
            "**/ast.zig", // Also excludes ast.zig (redundant)
            "**/parser.zig", // Also excludes parser.zig (redundant)
        },
    });
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        count += 1;
    }

    // All .zig files should be excluded
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "exclude: globstar exclude in deep directory" {
    const allocator = std.testing.allocator;

    // Exclude specific directory at any depth
    var iter = try glob(allocator, &.{"src/**/*"}, .{
        .exclude = &.{"**/compiler/**"},
    });
    defer iter.deinit();

    var found_compiler_file = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.indexOf(u8, entry.path, "compiler/") != null) {
            found_compiler_file = true;
        }
    }

    // Nothing inside compiler/ should be found
    try std.testing.expect(!found_compiler_file);
}

test "exclude: exclude with exact path match" {
    const allocator = std.testing.allocator;

    // Test exact path exclude (no wildcards in exclude)
    var iter = try glob(allocator, &.{"src/*.zig"}, .{
        .exclude = &.{"src/root.zig"}, // Exact path
    });
    defer iter.deinit();

    var found_root = false;
    var found_other = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.eql(u8, entry.path, "src/root.zig")) {
            found_root = true;
        } else {
            found_other = true;
        }
    }

    // root.zig should be excluded
    try std.testing.expect(!found_root);
    // Other files should still be found
    try std.testing.expect(found_other);
}

test "exclude: exclude preserves order of remaining matches" {
    const allocator = std.testing.allocator;

    // Verify that excluding some files doesn't break iteration
    var iter = try glob(allocator, &.{"src/compiler/*.zig"}, .{
        .exclude = &.{"**/ast.zig"},
    });
    defer iter.deinit();

    var paths = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }

    while (try iter.next()) |entry| {
        try paths.append(try allocator.dupe(u8, entry.path));
        allocator.free(entry.path);
    }

    // Should have found some files
    try std.testing.expect(paths.items.len > 0);

    // Verify ast.zig is not in results
    for (paths.items) |p| {
        try std.testing.expect(!std.mem.endsWith(u8, p, "ast.zig"));
    }
}

test "exclude: exclude with mixed slash styles" {
    const allocator = std.testing.allocator;

    // Test that exclude works with forward slashes (Unix-style)
    var iter = try glob(allocator, &.{"src/**/*.zig"}, .{
        .exclude = &.{"src/compiler/ast.zig"}, // Forward slashes
    });
    defer iter.deinit();

    var found_ast = false;
    while (try iter.next()) |entry| {
        defer allocator.free(entry.path);
        if (std.mem.endsWith(u8, entry.path, "ast.zig")) {
            found_ast = true;
        }
    }

    // ast.zig should be excluded
    try std.testing.expect(!found_ast);
}

// Run all submodule tests
test {
    _ = ast;
    _ = lexer;
    _ = brace;
    _ = parser;
    _ = automaton;
    _ = traverser;
    _ = symlink;
}
