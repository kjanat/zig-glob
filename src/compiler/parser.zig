//! Parser for glob patterns.
//!
//! Converts a token stream from the lexer into an AST representation.
//! Handles:
//! - Path segments separated by /
//! - Character classes [abc], [a-z], [[:alpha:]]
//! - Extended globs ?(foo|bar), *(x), +(y), @(z), !(w)
//! - Wildcards *, ?, **

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

const Node = ast.Node;
const CharClass = ast.CharClass;
const CharMember = ast.CharMember;
const ExtGlob = ast.ExtGlob;
const ExtGlobOp = ast.ExtGlobOp;
const PosixClass = ast.PosixClass;
const Pattern = ast.Pattern;
const CompileOptions = ast.CompileOptions;

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Lexer = lexer.Lexer;

/// Parser error type.
pub const ParseError = error{
    /// Unclosed character class.
    UnclosedCharClass,
    /// Unclosed extended glob.
    UnclosedExtGlob,
    /// Invalid character class syntax.
    InvalidCharClass,
    /// Unknown POSIX class.
    UnknownPosixClass,
    /// Out of memory.
    OutOfMemory,
    /// Empty pattern.
    EmptyPattern,
};

/// Parser state machine.
pub const Parser = struct {
    allocator: Allocator,
    lex: Lexer,
    options: CompileOptions,
    current: Token,

    pub fn init(allocator: Allocator, pattern: []const u8, options: CompileOptions) Parser {
        var lex = Lexer.init(pattern);
        const current = lex.next();
        return .{
            .allocator = allocator,
            .lex = lex,
            .options = options,
            .current = current,
        };
    }

    /// Parse the entire pattern into a Pattern struct.
    pub fn parse(self: *Parser) ParseError!Pattern {
        var segments: std.ArrayListUnmanaged(Node) = .empty;
        errdefer {
            for (segments.items) |seg| {
                self.freeNode(seg);
            }
            segments.deinit(self.allocator);
        }

        var is_absolute = false;
        var trailing_slash = false;

        // Check for leading /
        if (self.current.kind == .path_sep) {
            is_absolute = true;
            self.advance();
        }

        // Parse segments
        while (self.current.kind != .eof) {
            // Skip consecutive slashes
            while (self.current.kind == .path_sep) {
                self.advance();
            }

            if (self.current.kind == .eof) {
                trailing_slash = true;
                break;
            }

            const segment = try self.parseSegment();
            segments.append(self.allocator, segment) catch return ParseError.OutOfMemory;
        }

        const owned_segments = segments.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
        return Pattern{
            .allocator = self.allocator,
            .segments = owned_segments,
            .is_absolute = is_absolute,
            .trailing_slash = trailing_slash,
            .original = self.allocator.dupe(u8, self.lex.input) catch return ParseError.OutOfMemory,
        };
    }

    /// Parse a single path segment (between / separators).
    fn parseSegment(self: *Parser) ParseError!Node {
        var atoms: std.ArrayListUnmanaged(Node) = .empty;
        errdefer {
            for (atoms.items) |atom| {
                self.freeNode(atom);
            }
            atoms.deinit(self.allocator);
        }

        while (self.current.kind != .path_sep and self.current.kind != .eof) {
            const atom = try self.parseAtom();
            atoms.append(self.allocator, atom) catch return ParseError.OutOfMemory;
        }

        // Don't consume trailing separator here - let parse() handle it for trailing_slash detection

        if (atoms.items.len == 0) {
            return Node{ .literal = "" };
        }

        if (atoms.items.len == 1) {
            const single = atoms.items[0];
            atoms.deinit(self.allocator);
            return single;
        }

        return Node{ .sequence = atoms.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory };
    }

    /// Parse a single atom (literal, wildcard, char class, extglob).
    fn parseAtom(self: *Parser) ParseError!Node {
        switch (self.current.kind) {
            .literal => {
                const text = self.allocator.dupe(u8, self.current.text) catch return ParseError.OutOfMemory;
                self.advance();
                return Node{ .literal = text };
            },

            .star => {
                self.advance();
                return Node.star;
            },

            .globstar => {
                self.advance();
                if (self.options.globstar) {
                    return Node.globstar;
                }
                // If globstar disabled, treat ** as two stars
                // But since we're in a segment, just return star
                return Node.star;
            },

            .question => {
                self.advance();
                return Node.any_char;
            },

            .bracket_open => {
                return self.parseCharClass();
            },

            .extglob_prefix => {
                if (self.options.extglob) {
                    return self.parseExtGlob();
                }
                // If extglob disabled, treat prefix as literal
                const text = self.allocator.dupe(u8, self.current.text) catch return ParseError.OutOfMemory;
                self.advance();
                return Node{ .literal = text };
            },

            .brace_open => {
                // Brace expansion should be handled before parsing
                // If we see braces here, treat as literal
                const text = self.allocator.dupe(u8, self.current.text) catch return ParseError.OutOfMemory;
                self.advance();
                return Node{ .literal = text };
            },

            .brace_close, .comma, .dot_dot => {
                // Should not appear outside brace context
                const text = self.allocator.dupe(u8, self.current.text) catch return ParseError.OutOfMemory;
                self.advance();
                return Node{ .literal = text };
            },

            .paren_open, .paren_close, .pipe => {
                // Should not appear outside extglob context
                const text = self.allocator.dupe(u8, self.current.text) catch return ParseError.OutOfMemory;
                self.advance();
                return Node{ .literal = text };
            },

            else => {
                // Anything else becomes literal
                const text = self.allocator.dupe(u8, self.current.text) catch return ParseError.OutOfMemory;
                self.advance();
                return Node{ .literal = text };
            },
        }
    }

    /// Parse a character class [abc], [a-z], [^abc], [[:alpha:]].
    fn parseCharClass(self: *Parser) ParseError!Node {
        std.debug.assert(self.current.kind == .bracket_open);
        self.advance();

        var negated = false;
        var members: std.ArrayListUnmanaged(CharMember) = .empty;
        errdefer members.deinit(self.allocator);

        // Check for negation
        if (self.current.kind == .caret) {
            negated = true;
            self.advance();
        }

        // Parse members until ]
        while (self.current.kind != .bracket_close and self.current.kind != .eof) {
            const member = try self.parseCharMember();
            if (member) |m| {
                members.append(self.allocator, m) catch return ParseError.OutOfMemory;
            }
        }

        if (self.current.kind != .bracket_close) {
            return ParseError.UnclosedCharClass;
        }
        self.advance();

        return Node{
            .char_class = CharClass{
                .negated = negated,
                .members = members.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            },
        };
    }

    /// Parse a single character class member.
    fn parseCharMember(self: *Parser) ParseError!?CharMember {
        switch (self.current.kind) {
            .posix_class => {
                const name = self.current.text;
                self.advance();
                const posix = PosixClass.fromString(name) orelse {
                    return ParseError.UnknownPosixClass;
                };
                return CharMember{ .posix = posix };
            },

            .literal => {
                const start_char = self.current.text[0];
                self.advance();

                // Check for range (a-z)
                if (self.current.kind == .dash) {
                    self.advance();
                    if (self.current.kind == .literal and self.current.text.len > 0) {
                        const end_char = self.current.text[0];
                        self.advance();
                        return CharMember{ .range = .{ .start = start_char, .end = end_char } };
                    } else if (self.current.kind == .bracket_close) {
                        // Trailing dash: "a-" means 'a' and '-'
                        return CharMember{ .single = start_char };
                    }
                    // Malformed range, treat start as single
                    return CharMember{ .single = start_char };
                }

                return CharMember{ .single = start_char };
            },

            .dash => {
                // Dash at start or end is literal
                self.advance();
                return CharMember{ .single = '-' };
            },

            else => {
                // Skip unknown tokens in bracket
                self.advance();
                return null;
            },
        }
    }

    /// Parse an extended glob ?(foo|bar), *(x), etc.
    fn parseExtGlob(self: *Parser) ParseError!Node {
        std.debug.assert(self.current.kind == .extglob_prefix);

        const op_char = self.current.text[0];
        const op = ExtGlobOp.fromPrefix(op_char) orelse unreachable;
        self.advance();

        // Expect (
        if (self.current.kind != .paren_open) {
            // Malformed extglob, return prefix as literal
            const text = self.allocator.alloc(u8, 1) catch return ParseError.OutOfMemory;
            text[0] = op_char;
            return Node{ .literal = text };
        }
        self.advance();

        // Parse alternatives separated by |
        var alternatives: std.ArrayListUnmanaged(Node) = .empty;
        errdefer {
            for (alternatives.items) |alt| {
                self.freeNode(alt);
            }
            alternatives.deinit(self.allocator);
        }

        var current_alt: std.ArrayListUnmanaged(Node) = .empty;
        errdefer {
            for (current_alt.items) |atom| {
                self.freeNode(atom);
            }
            current_alt.deinit(self.allocator);
        }

        var depth: u32 = 1;

        while (depth > 0 and self.current.kind != .eof) {
            switch (self.current.kind) {
                .paren_open => {
                    depth += 1;
                    const text = self.allocator.dupe(u8, "(") catch return ParseError.OutOfMemory;
                    self.advance();
                    current_alt.append(self.allocator, Node{ .literal = text }) catch return ParseError.OutOfMemory;
                },

                .paren_close => {
                    depth -= 1;
                    if (depth == 0) {
                        // End of extglob
                        self.advance();
                        const alt = try self.finishAlternative(&current_alt);
                        alternatives.append(self.allocator, alt) catch return ParseError.OutOfMemory;
                    } else {
                        const text = self.allocator.dupe(u8, ")") catch return ParseError.OutOfMemory;
                        self.advance();
                        current_alt.append(self.allocator, Node{ .literal = text }) catch return ParseError.OutOfMemory;
                    }
                },

                .pipe => {
                    if (depth == 1) {
                        // Alternative separator
                        self.advance();
                        const alt = try self.finishAlternative(&current_alt);
                        alternatives.append(self.allocator, alt) catch return ParseError.OutOfMemory;
                        current_alt = .empty;
                    } else {
                        const text = self.allocator.dupe(u8, "|") catch return ParseError.OutOfMemory;
                        self.advance();
                        current_alt.append(self.allocator, Node{ .literal = text }) catch return ParseError.OutOfMemory;
                    }
                },

                .path_sep => {
                    // Path separator inside extglob - this is valid for patterns like !(foo/bar)
                    const text = self.allocator.dupe(u8, "/") catch return ParseError.OutOfMemory;
                    self.advance();
                    current_alt.append(self.allocator, Node{ .literal = text }) catch return ParseError.OutOfMemory;
                },

                else => {
                    // Parse as atom
                    const atom = try self.parseAtom();
                    current_alt.append(self.allocator, atom) catch return ParseError.OutOfMemory;
                },
            }
        }

        if (depth > 0) {
            return ParseError.UnclosedExtGlob;
        }

        return Node{
            .extglob = ExtGlob{
                .op = op,
                .alternatives = alternatives.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            },
        };
    }

    fn finishAlternative(self: *Parser, alt_list: *std.ArrayListUnmanaged(Node)) ParseError!Node {
        if (alt_list.items.len == 0) {
            return Node{ .literal = "" };
        }
        if (alt_list.items.len == 1) {
            const single = alt_list.items[0];
            alt_list.clearAndFree(self.allocator);
            return single;
        }
        return Node{ .sequence = alt_list.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory };
    }

    fn advance(self: *Parser) void {
        self.current = self.lex.next();
    }

    fn freeNode(self: *Parser, node: Node) void {
        switch (node) {
            .literal => |s| if (s.len > 0) self.allocator.free(s),
            .char_class => |cc| self.allocator.free(cc.members),
            .extglob => |eg| {
                for (eg.alternatives) |alt| {
                    self.freeNode(alt);
                }
                self.allocator.free(eg.alternatives);
            },
            .sequence => |seq| {
                for (seq) |n| {
                    self.freeNode(n);
                }
                self.allocator.free(seq);
            },
            .segment => |seg| {
                for (seg) |n| {
                    self.freeNode(n);
                }
                self.allocator.free(seg);
            },
            else => {},
        }
    }
};

/// Convenience function to parse a pattern.
pub fn parse(allocator: Allocator, pattern: []const u8, options: CompileOptions) ParseError!Pattern {
    var p = Parser.init(allocator, pattern, options);
    return p.parse();
}

// Tests

test "parse literal" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "hello", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
    try std.testing.expectEqualStrings("hello", pattern.segments[0].literal);
}

test "parse star" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "*.txt", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
    const seq = pattern.segments[0].sequence;
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expect(seq[0] == .star);
    try std.testing.expectEqualStrings(".txt", seq[1].literal);
}

test "parse globstar" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "**/*.zig", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 2), pattern.segments.len);
    try std.testing.expect(pattern.segments[0] == .globstar);

    const seq = pattern.segments[1].sequence;
    try std.testing.expect(seq[0] == .star);
    try std.testing.expectEqualStrings(".zig", seq[1].literal);
}

test "parse question mark" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "?.txt", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
    const seq = pattern.segments[0].sequence;
    try std.testing.expect(seq[0] == .any_char);
}

test "parse character class" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "[abc]", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
    const cc = pattern.segments[0].char_class;
    try std.testing.expect(!cc.negated);
    try std.testing.expectEqual(@as(usize, 3), cc.members.len);
}

test "parse negated character class" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "[^abc]", .{});
    defer pattern.deinit();

    const cc = pattern.segments[0].char_class;
    try std.testing.expect(cc.negated);
}

test "parse character range" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "[a-z]", .{});
    defer pattern.deinit();

    const cc = pattern.segments[0].char_class;
    try std.testing.expectEqual(@as(usize, 1), cc.members.len);
    try std.testing.expectEqual(@as(u8, 'a'), cc.members[0].range.start);
    try std.testing.expectEqual(@as(u8, 'z'), cc.members[0].range.end);
}

test "parse posix class" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "[[:alpha:]]", .{});
    defer pattern.deinit();

    const cc = pattern.segments[0].char_class;
    try std.testing.expectEqual(@as(usize, 1), cc.members.len);
    try std.testing.expectEqual(PosixClass.alpha, cc.members[0].posix);
}

test "parse extglob optional" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "?(foo|bar)", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
    const eg = pattern.segments[0].extglob;
    try std.testing.expectEqual(ExtGlobOp.optional, eg.op);
    try std.testing.expectEqual(@as(usize, 2), eg.alternatives.len);
}

test "parse path segments" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "src/main.zig", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 2), pattern.segments.len);
    try std.testing.expectEqualStrings("src", pattern.segments[0].literal);
    try std.testing.expectEqualStrings("main.zig", pattern.segments[1].literal);
}

test "parse absolute path" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "/usr/bin/*", .{});
    defer pattern.deinit();

    try std.testing.expect(pattern.is_absolute);
    try std.testing.expectEqual(@as(usize, 3), pattern.segments.len);
}

test "parse trailing slash" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "src/", .{});
    defer pattern.deinit();

    try std.testing.expect(pattern.trailing_slash);
    try std.testing.expectEqual(@as(usize, 1), pattern.segments.len);
}

test "parse complex pattern" {
    const allocator = std.testing.allocator;
    var pattern = try parse(allocator, "src/**/*.[ch]", .{});
    defer pattern.deinit();

    try std.testing.expectEqual(@as(usize, 3), pattern.segments.len);
    try std.testing.expectEqualStrings("src", pattern.segments[0].literal);
    try std.testing.expect(pattern.segments[1] == .globstar);

    const seg3 = pattern.segments[2].sequence;
    try std.testing.expect(seg3[0] == .star);
    try std.testing.expectEqualStrings(".", seg3[1].literal);
    try std.testing.expect(seg3[2] == .char_class);
}
