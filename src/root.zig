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
                    .follow_symlinks = options.follow_dir_symlinks,
                    .include_broken_symlinks = options.include_broken_symlinks,
                    .max_depth = options.max_depth,
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
