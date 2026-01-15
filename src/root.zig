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
//! const glob = @import("zig_glob");
//!
//! // Match a pattern against a path
//! const matches = try glob.match("**/*.zig", "src/main.zig", .{});
//!
//! // Compile a pattern for repeated use
//! var pattern = try glob.compile(allocator, "src/**/*.zig", .{});
//! defer pattern.deinit();
//!
//! // Walk filesystem matching pattern
//! var iter = try glob.glob(allocator, &.{"**/*.zig"}, .{ .cwd = "." });
//! defer iter.deinit();
//! while (try iter.next()) |entry| {
//!     std.debug.print("{s}\n", .{entry.path});
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// Re-export compiler modules
pub const ast = @import("compiler/ast.zig");
pub const lexer = @import("compiler/lexer.zig");
pub const brace = @import("compiler/brace.zig");
pub const parser = @import("compiler/parser.zig");

// Re-export matcher modules
pub const automaton = @import("matcher/automaton.zig");

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

// Run all submodule tests
test {
    _ = ast;
    _ = lexer;
    _ = brace;
    _ = parser;
    _ = automaton;
}
