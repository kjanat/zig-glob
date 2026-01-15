//! Lexer for glob patterns.
//!
//! Tokenizes glob pattern strings into a stream of tokens, handling:
//! - Escape sequences (\ escapes the next character)
//! - Special glob characters (*, ?, [, ], {, }, etc.)
//! - Extended glob prefixes (?, *, +, @, ! followed by ()
//! - Path separators (/)
//! - Character class contents

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Token types produced by the lexer.
pub const TokenKind = enum {
    /// Regular literal character(s).
    literal,

    /// * wildcard (single star, not globstar).
    star,

    /// ** globstar (matches across path separators).
    globstar,

    /// ? wildcard (matches single character).
    question,

    /// [ opening bracket for character class.
    bracket_open,

    /// ] closing bracket for character class.
    bracket_close,

    /// { opening brace for brace expansion.
    brace_open,

    /// } closing brace for brace expansion.
    brace_close,

    /// , comma inside brace expansion.
    comma,

    /// .. range separator inside brace expansion (e.g., {1..5}).
    dot_dot,

    /// ( opening paren for extended glob.
    paren_open,

    /// ) closing paren for extended glob.
    paren_close,

    /// | pipe separator inside extended glob.
    pipe,

    /// Extended glob operator prefix: ?, *, +, @, !
    /// The actual operator character is stored in the token data.
    extglob_prefix,

    /// ^ or ! at start of character class (negation).
    caret,

    /// - range separator inside character class.
    dash,

    /// [:name:] POSIX class inside character class.
    posix_class,

    /// / path separator.
    path_sep,

    /// End of input.
    eof,
};

/// A token produced by the lexer.
pub const Token = struct {
    kind: TokenKind,
    /// The raw text of the token (slice into original input).
    text: []const u8,
    /// Position in the original input.
    pos: usize,
};

/// Lexer state machine for tokenizing glob patterns.
pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    /// Context for bracket expression parsing.
    in_bracket: bool,
    bracket_start: bool, // True if at start of bracket (for ^ handling)

    /// Context for brace expansion parsing.
    brace_depth: u32,

    /// Context for extglob parsing.
    paren_depth: u32,

    pub fn init(input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
            .in_bracket = false,
            .bracket_start = false,
            .brace_depth = 0,
            .paren_depth = 0,
        };
    }

    /// Get the next token from the input.
    pub fn next(self: *Lexer) Token {
        if (self.pos >= self.input.len) {
            return .{ .kind = .eof, .text = "", .pos = self.pos };
        }

        const start = self.pos;
        const c = self.input[self.pos];

        // Handle escape sequences
        if (c == '\\' and self.pos + 1 < self.input.len) {
            self.pos += 2; // Skip \ and the escaped char
            return .{ .kind = .literal, .text = self.input[start + 1 .. self.pos], .pos = start };
        }

        // Context-sensitive tokenization
        if (self.in_bracket) {
            return self.nextInBracket(start, c);
        }

        return self.nextNormal(start, c);
    }

    fn nextNormal(self: *Lexer, start: usize, c: u8) Token {
        switch (c) {
            '*' => {
                self.pos += 1;
                // Check for ** (globstar)
                if (self.pos < self.input.len and self.input[self.pos] == '*') {
                    self.pos += 1;
                    return .{ .kind = .globstar, .text = "**", .pos = start };
                }
                return .{ .kind = .star, .text = "*", .pos = start };
            },

            '?' => {
                // Check for extglob prefix: ?( means optional pattern
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '(') {
                    self.pos += 1;
                    return .{ .kind = .extglob_prefix, .text = "?", .pos = start };
                }
                self.pos += 1;
                return .{ .kind = .question, .text = "?", .pos = start };
            },

            '+', '@', '!' => {
                // Check for extglob prefix: +( @( !(
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '(') {
                    self.pos += 1;
                    return .{ .kind = .extglob_prefix, .text = self.input[start..self.pos], .pos = start };
                }
                // Not extglob, treat as literal
                return self.readLiteral(start);
            },

            '[' => {
                self.pos += 1;
                self.in_bracket = true;
                self.bracket_start = true;
                return .{ .kind = .bracket_open, .text = "[", .pos = start };
            },

            '{' => {
                self.pos += 1;
                self.brace_depth += 1;
                return .{ .kind = .brace_open, .text = "{", .pos = start };
            },

            '}' => {
                self.pos += 1;
                if (self.brace_depth > 0) self.brace_depth -= 1;
                return .{ .kind = .brace_close, .text = "}", .pos = start };
            },

            ',' => {
                self.pos += 1;
                if (self.brace_depth > 0) {
                    return .{ .kind = .comma, .text = ",", .pos = start };
                }
                // Outside braces, comma is literal
                return .{ .kind = .literal, .text = ",", .pos = start };
            },

            '.' => {
                // Check for .. (range in brace expansion)
                if (self.brace_depth > 0 and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '.') {
                    self.pos += 2;
                    return .{ .kind = .dot_dot, .text = "..", .pos = start };
                }
                return self.readLiteral(start);
            },

            '(' => {
                self.pos += 1;
                self.paren_depth += 1;
                return .{ .kind = .paren_open, .text = "(", .pos = start };
            },

            ')' => {
                self.pos += 1;
                if (self.paren_depth > 0) self.paren_depth -= 1;
                return .{ .kind = .paren_close, .text = ")", .pos = start };
            },

            '|' => {
                self.pos += 1;
                if (self.paren_depth > 0) {
                    return .{ .kind = .pipe, .text = "|", .pos = start };
                }
                // Outside parens, pipe is literal
                return .{ .kind = .literal, .text = "|", .pos = start };
            },

            '/' => {
                self.pos += 1;
                return .{ .kind = .path_sep, .text = "/", .pos = start };
            },

            else => return self.readLiteral(start),
        }
    }

    fn nextInBracket(self: *Lexer, start: usize, c: u8) Token {
        switch (c) {
            ']' => {
                // ] at the very start of bracket is literal
                if (self.bracket_start) {
                    self.bracket_start = false;
                    self.pos += 1;
                    return .{ .kind = .literal, .text = "]", .pos = start };
                }
                self.pos += 1;
                self.in_bracket = false;
                return .{ .kind = .bracket_close, .text = "]", .pos = start };
            },

            '^', '!' => {
                // Negation only at start of bracket
                if (self.bracket_start) {
                    self.bracket_start = false;
                    self.pos += 1;
                    return .{ .kind = .caret, .text = self.input[start..self.pos], .pos = start };
                }
                self.pos += 1;
                return .{ .kind = .literal, .text = self.input[start..self.pos], .pos = start };
            },

            '-' => {
                self.bracket_start = false;
                self.pos += 1;
                return .{ .kind = .dash, .text = "-", .pos = start };
            },

            '[' => {
                // Check for POSIX class [:name:]
                if (self.pos + 2 < self.input.len and self.input[self.pos + 1] == ':') {
                    if (self.readPosixClass(start)) |token| {
                        self.bracket_start = false;
                        return token;
                    }
                }
                // Not a POSIX class, literal [
                self.bracket_start = false;
                self.pos += 1;
                return .{ .kind = .literal, .text = "[", .pos = start };
            },

            '\\' => {
                // Escape in bracket
                if (self.pos + 1 < self.input.len) {
                    self.pos += 2;
                    self.bracket_start = false;
                    return .{ .kind = .literal, .text = self.input[start + 1 .. self.pos], .pos = start };
                }
                self.pos += 1;
                return .{ .kind = .literal, .text = "\\", .pos = start };
            },

            else => {
                self.bracket_start = false;
                self.pos += 1;
                return .{ .kind = .literal, .text = self.input[start..self.pos], .pos = start };
            },
        }
    }

    fn readPosixClass(self: *Lexer, start: usize) ?Token {
        // Look for [:name:]
        var end = self.pos + 2; // Skip [:
        while (end < self.input.len and self.input[end] != ':') {
            end += 1;
        }
        if (end + 1 < self.input.len and self.input[end] == ':' and self.input[end + 1] == ']') {
            const name = self.input[self.pos + 2 .. end];
            self.pos = end + 2;
            return .{ .kind = .posix_class, .text = name, .pos = start };
        }
        return null;
    }

    fn readLiteral(self: *Lexer, start: usize) Token {
        const specials = "*?[{},/\\()|";
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\\') break; // Escape starts new token
            if (std.mem.indexOfScalar(u8, specials, c) != null) break;

            // Check for extglob prefix
            if ((c == '+' or c == '@' or c == '!') and
                self.pos + 1 < self.input.len and self.input[self.pos + 1] == '(')
            {
                break;
            }

            // Check for .. in brace
            if (c == '.' and self.brace_depth > 0 and
                self.pos + 1 < self.input.len and self.input[self.pos + 1] == '.')
            {
                break;
            }

            self.pos += 1;
        }

        const text = self.input[start..self.pos];
        if (text.len == 0) {
            // Shouldn't happen, but handle edge case
            self.pos += 1;
            return .{ .kind = .literal, .text = self.input[start..self.pos], .pos = start };
        }
        return .{ .kind = .literal, .text = text, .pos = start };
    }

    /// Peek at the next token without consuming it.
    pub fn peek(self: *Lexer) Token {
        const saved_pos = self.pos;
        const saved_bracket = self.in_bracket;
        const saved_bracket_start = self.bracket_start;
        const saved_brace = self.brace_depth;
        const saved_paren = self.paren_depth;

        const token = self.next();

        self.pos = saved_pos;
        self.in_bracket = saved_bracket;
        self.bracket_start = saved_bracket_start;
        self.brace_depth = saved_brace;
        self.paren_depth = saved_paren;

        return token;
    }

    /// Check if there are more tokens.
    pub fn hasMore(self: *const Lexer) bool {
        return self.pos < self.input.len;
    }

    /// Reset the lexer to the beginning.
    pub fn reset(self: *Lexer) void {
        self.pos = 0;
        self.in_bracket = false;
        self.bracket_start = false;
        self.brace_depth = 0;
        self.paren_depth = 0;
    }
};

/// Tokenize an entire pattern into a list of tokens.
pub fn tokenize(allocator: Allocator, pattern: []const u8) ![]Token {
    var lex = Lexer.init(pattern);
    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = lex.next();
        try tokens.append(allocator, token);
        if (token.kind == .eof) break;
    }

    return tokens.toOwnedSlice(allocator);
}

// Tests

test "basic wildcards" {
    var lexer = Lexer.init("*.txt");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.star, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings(".txt", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.eof, tok.kind);
}

test "globstar" {
    var lexer = Lexer.init("**/*.zig");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.globstar, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.path_sep, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.star, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings(".zig", tok.text);
}

test "escape sequences" {
    var lexer = Lexer.init("\\*.txt");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("*", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings(".txt", tok.text);
}

test "bracket expression" {
    var lexer = Lexer.init("[abc]");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_open, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("a", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("b", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("c", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_close, tok.kind);
}

test "negated bracket" {
    var lexer = Lexer.init("[^abc]");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_open, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.caret, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("a", tok.text);
}

test "bracket with range" {
    var lexer = Lexer.init("[a-z]");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_open, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("a", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.dash, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("z", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_close, tok.kind);
}

test "posix class" {
    var lexer = Lexer.init("[[:alpha:]]");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_open, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.posix_class, tok.kind);
    try std.testing.expectEqualStrings("alpha", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_close, tok.kind);
}

test "brace expansion" {
    var lexer = Lexer.init("{a,b,c}");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.brace_open, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("a", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.comma, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("b", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.comma, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("c", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.brace_close, tok.kind);
}

test "brace range" {
    var lexer = Lexer.init("{1..5}");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.brace_open, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("1", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.dot_dot, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("5", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.brace_close, tok.kind);
}

test "extglob prefix" {
    var lexer = Lexer.init("?(foo|bar)");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.extglob_prefix, tok.kind);
    try std.testing.expectEqualStrings("?", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.paren_open, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("foo", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.pipe, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("bar", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.paren_close, tok.kind);
}

test "question mark not extglob" {
    // ? not followed by ( is a wildcard
    var lexer = Lexer.init("?.txt");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.question, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings(".txt", tok.text);
}

test "path separators" {
    var lexer = Lexer.init("src/main.zig");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("src", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.path_sep, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("main.zig", tok.text);
}

test "literal bracket at start of class" {
    // ] at start of bracket is literal, not closing
    var lexer = Lexer.init("[]a]");

    var tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_open, tok.kind);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("]", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.literal, tok.kind);
    try std.testing.expectEqualStrings("a", tok.text);

    tok = lexer.next();
    try std.testing.expectEqual(TokenKind.bracket_close, tok.kind);
}
