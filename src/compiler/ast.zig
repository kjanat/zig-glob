//! AST node definitions for glob patterns.
//!
//! The AST represents a compiled glob pattern as a tree structure that can be
//! traversed by the matcher. Patterns are split into path segments separated by `/`,
//! where each segment contains a sequence of atoms (literals, wildcards, etc.).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// POSIX character classes supported in bracket expressions.
pub const PosixClass = enum {
    alpha, // [:alpha:] - alphabetic characters
    digit, // [:digit:] - decimal digits
    alnum, // [:alnum:] - alphanumeric characters
    space, // [:space:] - whitespace characters
    upper, // [:upper:] - uppercase letters
    lower, // [:lower:] - lowercase letters
    xdigit, // [:xdigit:] - hexadecimal digits
    cntrl, // [:cntrl:] - control characters
    graph, // [:graph:] - visible characters (no space)
    print, // [:print:] - printable characters (with space)
    punct, // [:punct:] - punctuation characters
    blank, // [:blank:] - space and tab
    ascii, // [:ascii:] - ASCII characters (extension)
    word, // [:word:] - word characters (extension, \w equivalent)

    /// Test if a byte matches this POSIX class.
    pub fn matches(self: PosixClass, byte: u8) bool {
        return switch (self) {
            .alpha => std.ascii.isAlphabetic(byte),
            .digit => std.ascii.isDigit(byte),
            .alnum => std.ascii.isAlphanumeric(byte),
            .space => std.ascii.isWhitespace(byte),
            .upper => std.ascii.isUpper(byte),
            .lower => std.ascii.isLower(byte),
            .xdigit => std.ascii.isHex(byte),
            .cntrl => std.ascii.isControl(byte),
            .graph => byte > 0x20 and byte < 0x7F,
            .print => byte >= 0x20 and byte < 0x7F,
            .punct => (byte >= '!' and byte <= '/') or
                (byte >= ':' and byte <= '@') or
                (byte >= '[' and byte <= '`') or
                (byte >= '{' and byte <= '~'),
            .blank => byte == ' ' or byte == '\t',
            .ascii => byte < 128,
            .word => std.ascii.isAlphanumeric(byte) or byte == '_',
        };
    }

    /// Parse a POSIX class name from a string like "alpha", "digit", etc.
    pub fn fromString(name: []const u8) ?PosixClass {
        const map = std.StaticStringMap(PosixClass).initComptime(.{
            .{ "alpha", .alpha },
            .{ "digit", .digit },
            .{ "alnum", .alnum },
            .{ "space", .space },
            .{ "upper", .upper },
            .{ "lower", .lower },
            .{ "xdigit", .xdigit },
            .{ "cntrl", .cntrl },
            .{ "graph", .graph },
            .{ "print", .print },
            .{ "punct", .punct },
            .{ "blank", .blank },
            .{ "ascii", .ascii },
            .{ "word", .word },
        });
        return map.get(name);
    }
};

/// A member of a character class (bracket expression).
pub const CharMember = union(enum) {
    /// Single character: [a]
    single: u8,

    /// Character range: [a-z]
    range: struct {
        start: u8,
        end: u8,
    },

    /// POSIX class: [[:alpha:]]
    posix: PosixClass,

    /// Test if a byte matches this member.
    pub fn matches(self: CharMember, byte: u8) bool {
        return switch (self) {
            .single => |c| byte == c,
            .range => |r| byte >= r.start and byte <= r.end,
            .posix => |p| p.matches(byte),
        };
    }
};

/// A character class (bracket expression) like [abc], [a-z], [[:alpha:]].
pub const CharClass = struct {
    /// If true, the class is negated: [^abc] or [!abc]
    negated: bool,

    /// The members of the character class.
    members: []const CharMember,

    /// Test if a byte matches this character class.
    pub fn matches(self: CharClass, byte: u8) bool {
        var any_match = false;
        for (self.members) |member| {
            if (member.matches(byte)) {
                any_match = true;
                break;
            }
        }
        return if (self.negated) !any_match else any_match;
    }
};

/// Extended glob operator type.
pub const ExtGlobOp = enum {
    /// ?(pattern) - match zero or one occurrence
    optional,

    /// *(pattern) - match zero or more occurrences
    zero_or_more,

    /// +(pattern) - match one or more occurrences
    one_or_more,

    /// @(pattern) - match exactly one occurrence
    exactly_one,

    /// !(pattern) - match anything except pattern
    negated,

    /// Get the prefix character for this operator.
    pub fn prefix(self: ExtGlobOp) u8 {
        return switch (self) {
            .optional => '?',
            .zero_or_more => '*',
            .one_or_more => '+',
            .exactly_one => '@',
            .negated => '!',
        };
    }

    /// Parse operator from prefix character.
    pub fn fromPrefix(char: u8) ?ExtGlobOp {
        return switch (char) {
            '?' => .optional,
            '*' => .zero_or_more,
            '+' => .one_or_more,
            '@' => .exactly_one,
            '!' => .negated,
            else => null,
        };
    }
};

/// An extended glob expression like ?(a|b), *(foo), !(bar).
pub const ExtGlob = struct {
    /// The operator type.
    op: ExtGlobOp,

    /// Alternative patterns separated by |.
    alternatives: []const Node,
};

/// AST node representing a glob pattern element.
pub const Node = union(enum) {
    /// Literal string that must match exactly.
    literal: []const u8,

    /// Single character wildcard: ? (matches any single non-/ character)
    any_char,

    /// Star wildcard: * (matches zero or more non-/ characters)
    star,

    /// Globstar: ** (matches zero or more path components including /)
    globstar,

    /// Character class: [abc], [a-z], [[:alpha:]]
    char_class: CharClass,

    /// Extended glob: ?(a|b), *(foo), +(bar), @(baz), !(qux)
    extglob: ExtGlob,

    /// Sequence of nodes that must match consecutively.
    sequence: []const Node,

    /// A single path segment (between / separators).
    /// Contains the pattern elements for one directory/file name.
    segment: []const Node,
};

/// A compiled glob pattern ready for matching.
pub const Pattern = struct {
    allocator: Allocator,

    /// The segments of the pattern, split by path separators.
    /// For "src/**/*.zig", this would be ["src", "**", "*.zig"].
    segments: []const Node,

    /// Whether the pattern is absolute (starts with /).
    is_absolute: bool,

    /// Whether the pattern ends with a trailing slash.
    trailing_slash: bool,

    /// Original pattern string (for debugging/error messages).
    original: []const u8,

    pub fn deinit(self: *Pattern) void {
        self.freeNodes(self.segments);
        self.allocator.free(self.original);
    }

    fn freeNodes(self: *Pattern, nodes: []const Node) void {
        for (nodes) |node| {
            switch (node) {
                .literal => |s| self.allocator.free(s),
                .char_class => |cc| self.allocator.free(cc.members),
                .extglob => |eg| self.freeNodes(eg.alternatives),
                .sequence => |seq| self.freeNodes(seq),
                .segment => |seg| self.freeNodes(seg),
                else => {},
            }
        }
        self.allocator.free(nodes);
    }

    /// Check if this pattern has any globstar (**) segments.
    pub fn hasGlobstar(self: *const Pattern) bool {
        for (self.segments) |seg| {
            if (self.segmentHasGlobstar(seg)) return true;
        }
        return false;
    }

    fn segmentHasGlobstar(self: *const Pattern, node: Node) bool {
        return switch (node) {
            .globstar => true,
            .sequence => |seq| {
                for (seq) |n| {
                    if (self.segmentHasGlobstar(n)) return true;
                }
                return false;
            },
            .segment => |seg| {
                for (seg) |n| {
                    if (self.segmentHasGlobstar(n)) return true;
                }
                return false;
            },
            else => false,
        };
    }

    /// Check if this pattern starts with a literal prefix.
    /// Returns the literal prefix if it exists, null otherwise.
    pub fn literalPrefix(self: *const Pattern) ?[]const u8 {
        if (self.segments.len == 0) return null;
        const first = self.segments[0];
        return switch (first) {
            .literal => |s| s,
            .segment => |seg| {
                if (seg.len == 0) return null;
                return switch (seg[0]) {
                    .literal => |s| s,
                    else => null,
                };
            },
            else => null,
        };
    }
};

/// Options for pattern compilation.
pub const CompileOptions = struct {
    /// Enable globstar (**) support.
    globstar: bool = true,

    /// Enable brace expansion ({a,b}).
    brace: bool = true,

    /// Enable extended glob operators (?(), *(), etc.).
    extglob: bool = true,

    /// Enable case-insensitive matching.
    nocase: bool = false,

    /// Match dotfiles with wildcards (bash: dotglob).
    dot: bool = false,
};

test "PosixClass.matches" {
    const alpha = PosixClass.alpha;
    try std.testing.expect(alpha.matches('a'));
    try std.testing.expect(alpha.matches('Z'));
    try std.testing.expect(!alpha.matches('0'));
    try std.testing.expect(!alpha.matches(' '));

    const digit = PosixClass.digit;
    try std.testing.expect(digit.matches('0'));
    try std.testing.expect(digit.matches('9'));
    try std.testing.expect(!digit.matches('a'));

    const xdigit = PosixClass.xdigit;
    try std.testing.expect(xdigit.matches('0'));
    try std.testing.expect(xdigit.matches('a'));
    try std.testing.expect(xdigit.matches('F'));
    try std.testing.expect(!xdigit.matches('g'));
}

test "CharMember.matches" {
    const single = CharMember{ .single = 'x' };
    try std.testing.expect(single.matches('x'));
    try std.testing.expect(!single.matches('y'));

    const range = CharMember{ .range = .{ .start = 'a', .end = 'z' } };
    try std.testing.expect(range.matches('a'));
    try std.testing.expect(range.matches('m'));
    try std.testing.expect(range.matches('z'));
    try std.testing.expect(!range.matches('A'));
    try std.testing.expect(!range.matches('0'));
}

test "CharClass.matches" {
    const members = [_]CharMember{
        .{ .single = 'a' },
        .{ .range = .{ .start = 'x', .end = 'z' } },
    };

    const cc = CharClass{ .negated = false, .members = &members };
    try std.testing.expect(cc.matches('a'));
    try std.testing.expect(cc.matches('x'));
    try std.testing.expect(cc.matches('y'));
    try std.testing.expect(!cc.matches('b'));

    const negated = CharClass{ .negated = true, .members = &members };
    try std.testing.expect(!negated.matches('a'));
    try std.testing.expect(!negated.matches('x'));
    try std.testing.expect(negated.matches('b'));
    try std.testing.expect(negated.matches('0'));
}

test "PosixClass.fromString" {
    try std.testing.expectEqual(PosixClass.alpha, PosixClass.fromString("alpha").?);
    try std.testing.expectEqual(PosixClass.digit, PosixClass.fromString("digit").?);
    try std.testing.expectEqual(PosixClass.alnum, PosixClass.fromString("alnum").?);
    try std.testing.expect(PosixClass.fromString("invalid") == null);
}
