const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../compiler/ast.zig");
const Pattern = ast.Pattern;
const Node = ast.Node;
const automaton = @import("../matcher/automaton.zig");
const Matcher = automaton.Matcher;
const MatchOptions = automaton.MatchOptions;

/// Result of a successful match during filesystem traversal.
pub const Match = struct {
    /// The matched path (relative to starting directory).
    path: []const u8,
    /// The type of filesystem entry.
    kind: std.fs.File.Kind,

    pub fn deinit(self: *Match, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

/// Options for walker behavior.
pub const WalkerOptions = struct {
    /// Match dotfiles with wildcards.
    dot: bool = false,
    /// Case-insensitive matching.
    nocase: bool = false,
    /// Follow directory symlinks (enables cycle detection).
    follow_symlinks: bool = false,
    /// Maximum traversal depth (null = unlimited).
    max_depth: ?u32 = null,
};

/// Inode key for cycle detection when following symlinks.
const InodeKey = struct {
    dev: u64,
    ino: u64,
};

/// Work queue item representing a directory to process.
const WorkItem = struct {
    /// Handle to the open directory.
    dir: std.fs.Dir,
    /// Path prefix (allocated, must be freed).
    prefix: []const u8,
    /// Current segment index in pattern.
    segment_idx: usize,
    /// Current depth in traversal.
    depth: u32,
    /// Whether this item owns the directory handle.
    owns_dir: bool,

    fn deinit(self: *WorkItem, allocator: Allocator) void {
        allocator.free(self.prefix);
        if (self.owns_dir) {
            self.dir.close();
        }
    }
};

/// Iterator state for directory iteration.
const IterState = struct {
    /// Directory iterator.
    iter: std.fs.Dir.Iterator,
    /// The work item being iterated.
    work_item: WorkItem,
    /// Whether we're in globstar mode (matching zero or more directories).
    globstar_mode: bool,
    /// For globstar: have we already pushed the "skip globstar" case?
    globstar_skip_pushed: bool,
};

/// Filesystem walker with lazy iteration over glob matches.
pub const Walker = struct {
    allocator: Allocator,
    pattern: *const Pattern,
    options: WalkerOptions,

    /// Work queue for directories to process.
    work_queue: std.ArrayList(WorkItem),

    /// Current iteration state (if iterating a directory).
    current_iter: ?IterState,

    /// Visited inodes for cycle detection (only when following symlinks).
    visited: std.AutoHashMap(InodeKey, void),

    /// Pending matches to return (for cases where we find matches during queue processing).
    pending_matches: std.ArrayList(Match),

    /// The root directory handle.
    root_dir: std.fs.Dir,

    /// Whether walker owns the root directory.
    owns_root: bool,

    /// Initialize walker for a pattern starting from a directory.
    pub fn init(
        allocator: Allocator,
        pattern: *const Pattern,
        root_dir: std.fs.Dir,
        options: WalkerOptions,
    ) !Walker {
        var walker = Walker{
            .allocator = allocator,
            .pattern = pattern,
            .options = options,
            .work_queue = std.ArrayList(WorkItem).init(allocator),
            .current_iter = null,
            .visited = std.AutoHashMap(InodeKey, void).init(allocator),
            .pending_matches = std.ArrayList(Match).init(allocator),
            .root_dir = root_dir,
            .owns_root = false,
        };

        // Add initial work item at root
        const initial_prefix = try allocator.dupe(u8, "");
        try walker.work_queue.append(.{
            .dir = root_dir,
            .prefix = initial_prefix,
            .segment_idx = 0,
            .depth = 0,
            .owns_dir = false,
        });

        return walker;
    }

    /// Initialize walker with a path string.
    pub fn initFromPath(
        allocator: Allocator,
        pattern: *const Pattern,
        root_path: []const u8,
        options: WalkerOptions,
    ) !Walker {
        const dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
            return err;
        };

        var walker = try init(allocator, pattern, dir, options);
        walker.owns_root = true;
        return walker;
    }

    pub fn deinit(self: *Walker) void {
        // Clean up current iteration state
        if (self.current_iter) |*state| {
            state.work_item.deinit(self.allocator);
        }

        // Clean up work queue
        for (self.work_queue.items) |*item| {
            item.deinit(self.allocator);
        }
        self.work_queue.deinit();

        // Clean up pending matches
        for (self.pending_matches.items) |*m| {
            m.deinit(self.allocator);
        }
        self.pending_matches.deinit();

        // Clean up visited set
        self.visited.deinit();

        // Close root if we own it
        if (self.owns_root) {
            self.root_dir.close();
        }
    }

    /// Get the next match, or null if iteration is complete.
    pub fn next(self: *Walker) !?Match {
        while (true) {
            // First, return any pending matches
            if (self.pending_matches.items.len > 0) {
                return self.pending_matches.pop();
            }

            // If we have a current directory iteration, continue it
            if (self.current_iter) |*state| {
                if (try self.processIterEntry(state)) |match| {
                    return match;
                }
                // Iterator exhausted, clean up
                state.work_item.deinit(self.allocator);
                self.current_iter = null;
                continue;
            }

            // No current iteration, get next work item
            if (self.work_queue.items.len == 0) {
                return null; // Done
            }

            var work_item = self.work_queue.pop();

            // Check depth limit
            if (self.options.max_depth) |max| {
                if (work_item.depth > max) {
                    work_item.deinit(self.allocator);
                    continue;
                }
            }

            // Process the work item
            if (try self.processWorkItem(&work_item)) |match| {
                return match;
            }
        }
    }

    /// Process a work item, potentially setting up iteration or returning a match.
    fn processWorkItem(self: *Walker, work_item: *WorkItem) !?Match {
        const segments = self.pattern.segments;

        // Check if we've matched all segments
        if (work_item.segment_idx >= segments.len) {
            // We have a match at this prefix
            const match_path = try self.allocator.dupe(u8, work_item.prefix);
            const kind = self.getEntryKind(work_item.dir, ".") catch .directory;
            work_item.deinit(self.allocator);
            return Match{
                .path = match_path,
                .kind = kind,
            };
        }

        const current_segment = segments[work_item.segment_idx];

        // Check what type of segment this is
        if (self.isGlobstar(current_segment)) {
            // Globstar: set up special iteration
            try self.setupGlobstarIteration(work_item);
            return null;
        } else if (self.isLiteral(current_segment)) |literal| {
            // Literal: try to descend directly
            return try self.processLiteralSegment(work_item, literal);
        } else {
            // Pattern: set up directory iteration with matching
            try self.setupPatternIteration(work_item);
            return null;
        }
    }

    /// Check if a segment is a globstar (**).
    fn isGlobstar(self: *Walker, node: Node) bool {
        _ = self;
        return switch (node) {
            .globstar => true,
            .segment => |seg| {
                if (seg.len == 1) {
                    return seg[0] == .globstar;
                }
                return false;
            },
            else => false,
        };
    }

    /// Check if a segment is a pure literal and return it.
    fn isLiteral(self: *Walker, node: Node) ?[]const u8 {
        _ = self;
        return switch (node) {
            .literal => |lit| lit,
            .segment => |seg| {
                if (seg.len == 1) {
                    return switch (seg[0]) {
                        .literal => |lit| lit,
                        else => null,
                    };
                }
                return null;
            },
            else => null,
        };
    }

    /// Process a literal path segment (fast path using openDir).
    fn processLiteralSegment(self: *Walker, work_item: *WorkItem, literal: []const u8) !?Match {
        const is_last = work_item.segment_idx + 1 >= self.pattern.segments.len;

        // Build new prefix
        const new_prefix = try self.buildPath(work_item.prefix, literal);
        errdefer self.allocator.free(new_prefix);

        if (is_last) {
            // Last segment: check if entry exists and return match
            const stat = work_item.dir.statFile(literal) catch {
                // Entry doesn't exist
                self.allocator.free(new_prefix);
                work_item.deinit(self.allocator);
                return null;
            };

            work_item.deinit(self.allocator);
            return Match{
                .path = new_prefix,
                .kind = stat.kind,
            };
        } else {
            // Not last segment: try to open as directory
            const sub_dir = work_item.dir.openDir(literal, .{ .iterate = true }) catch {
                // Can't descend
                self.allocator.free(new_prefix);
                work_item.deinit(self.allocator);
                return null;
            };

            // Check for cycles if following symlinks
            if (self.options.follow_symlinks) {
                if (try self.checkCycle(sub_dir)) {
                    sub_dir.close();
                    self.allocator.free(new_prefix);
                    work_item.deinit(self.allocator);
                    return null;
                }
            }

            // Queue new work item
            try self.work_queue.append(.{
                .dir = sub_dir,
                .prefix = new_prefix,
                .segment_idx = work_item.segment_idx + 1,
                .depth = work_item.depth + 1,
                .owns_dir = true,
            });

            // Clean up old work item
            work_item.deinit(self.allocator);
            return null;
        }
    }

    /// Set up iteration for a pattern segment.
    fn setupPatternIteration(self: *Walker, work_item: *WorkItem) !void {
        self.current_iter = .{
            .iter = work_item.dir.iterate(),
            .work_item = work_item.*,
            .globstar_mode = false,
            .globstar_skip_pushed = false,
        };
        // Don't call deinit on work_item since we moved it
    }

    /// Set up iteration for a globstar segment.
    fn setupGlobstarIteration(self: *Walker, work_item: *WorkItem) !void {
        // First, push a work item that skips the globstar (matches zero directories)
        const skip_prefix = try self.allocator.dupe(u8, work_item.prefix);
        try self.work_queue.append(.{
            .dir = work_item.dir,
            .prefix = skip_prefix,
            .segment_idx = work_item.segment_idx + 1,
            .depth = work_item.depth,
            .owns_dir = false,
        });

        // Then set up iteration for matching one or more directories
        self.current_iter = .{
            .iter = work_item.dir.iterate(),
            .work_item = work_item.*,
            .globstar_mode = true,
            .globstar_skip_pushed = true,
        };
    }

    /// Process one entry from the current directory iteration.
    fn processIterEntry(self: *Walker, state: *IterState) !?Match {
        while (state.iter.next() catch null) |entry| {
            // Skip . and ..
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                continue;
            }

            // Apply dotfile rule
            if (!self.options.dot and entry.name[0] == '.') {
                // Check if pattern explicitly matches dotfiles
                if (!self.patternMatchesDotfile(state.work_item.segment_idx)) {
                    continue;
                }
            }

            if (state.globstar_mode) {
                // In globstar mode: descend into all directories
                if (entry.kind == .directory) {
                    try self.handleGlobstarEntry(state, entry);
                }
                // Also check if this entry matches the next segment
                try self.checkGlobstarMatch(state, entry);
            } else {
                // Pattern mode: check if entry matches current segment
                if (try self.checkPatternMatch(state, entry)) |match| {
                    return match;
                }
            }
        }
        return null;
    }

    /// Handle a directory entry in globstar mode.
    fn handleGlobstarEntry(self: *Walker, state: *IterState, entry: std.fs.Dir.Entry) !void {
        const new_prefix = try self.buildPath(state.work_item.prefix, entry.name);
        errdefer self.allocator.free(new_prefix);

        // Open the subdirectory
        const sub_dir = state.work_item.dir.openDir(entry.name, .{ .iterate = true }) catch {
            self.allocator.free(new_prefix);
            return;
        };
        errdefer sub_dir.close();

        // Check for cycles
        if (self.options.follow_symlinks) {
            if (try self.checkCycle(sub_dir)) {
                sub_dir.close();
                self.allocator.free(new_prefix);
                return;
            }
        }

        // Queue for continued globstar matching
        try self.work_queue.append(.{
            .dir = sub_dir,
            .prefix = new_prefix,
            .segment_idx = state.work_item.segment_idx, // Same index for recursive **
            .depth = state.work_item.depth + 1,
            .owns_dir = true,
        });
    }

    /// Check if an entry matches the pattern after globstar.
    fn checkGlobstarMatch(self: *Walker, state: *IterState, entry: std.fs.Dir.Entry) !void {
        const next_idx = state.work_item.segment_idx + 1;
        if (next_idx >= self.pattern.segments.len) {
            // Globstar is last segment: everything matches
            const match_path = try self.buildPath(state.work_item.prefix, entry.name);
            try self.pending_matches.append(.{
                .path = match_path,
                .kind = entry.kind,
            });
            return;
        }

        // Check if entry matches next segment
        const next_segment = self.pattern.segments[next_idx];
        if (self.matchesSegment(next_segment, entry.name)) {
            if (next_idx + 1 >= self.pattern.segments.len) {
                // Last segment matched
                const match_path = try self.buildPath(state.work_item.prefix, entry.name);
                try self.pending_matches.append(.{
                    .path = match_path,
                    .kind = entry.kind,
                });
            } else if (entry.kind == .directory) {
                // More segments to match, descend
                const new_prefix = try self.buildPath(state.work_item.prefix, entry.name);
                errdefer self.allocator.free(new_prefix);

                const sub_dir = state.work_item.dir.openDir(entry.name, .{ .iterate = true }) catch {
                    self.allocator.free(new_prefix);
                    return;
                };

                try self.work_queue.append(.{
                    .dir = sub_dir,
                    .prefix = new_prefix,
                    .segment_idx = next_idx + 1,
                    .depth = state.work_item.depth + 1,
                    .owns_dir = true,
                });
            }
        }
    }

    /// Check if an entry matches a pattern segment.
    fn checkPatternMatch(self: *Walker, state: *IterState, entry: std.fs.Dir.Entry) !?Match {
        const segment = self.pattern.segments[state.work_item.segment_idx];

        if (!self.matchesSegment(segment, entry.name)) {
            return null;
        }

        const new_prefix = try self.buildPath(state.work_item.prefix, entry.name);
        errdefer self.allocator.free(new_prefix);

        const is_last = state.work_item.segment_idx + 1 >= self.pattern.segments.len;

        if (is_last) {
            // Final segment: return match
            return Match{
                .path = new_prefix,
                .kind = entry.kind,
            };
        } else if (entry.kind == .directory) {
            // More segments: descend
            const sub_dir = state.work_item.dir.openDir(entry.name, .{ .iterate = true }) catch {
                self.allocator.free(new_prefix);
                return null;
            };

            if (self.options.follow_symlinks) {
                if (try self.checkCycle(sub_dir)) {
                    sub_dir.close();
                    self.allocator.free(new_prefix);
                    return null;
                }
            }

            try self.work_queue.append(.{
                .dir = sub_dir,
                .prefix = new_prefix,
                .segment_idx = state.work_item.segment_idx + 1,
                .depth = state.work_item.depth + 1,
                .owns_dir = true,
            });
        } else {
            // Not a directory and not last segment
            self.allocator.free(new_prefix);
        }

        return null;
    }

    /// Check if an entry name matches a pattern segment.
    fn matchesSegment(self: *Walker, segment: Node, name: []const u8) bool {
        // Create a temporary matcher for this check
        // TODO: Cache matchers for efficiency
        var temp_pattern = Pattern{
            .allocator = self.allocator,
            .segments = &[_]Node{segment},
            .is_absolute = false,
            .trailing_slash = false,
            .original = "",
        };

        var matcher = Matcher.init(self.allocator, &temp_pattern, .{
            .dot = self.options.dot,
            .nocase = self.options.nocase,
            .partial = false,
        });
        defer matcher.deinit();

        return matcher.matchNode(segment, name);
    }

    /// Check if the pattern at given index explicitly matches dotfiles.
    fn patternMatchesDotfile(self: *Walker, segment_idx: usize) bool {
        if (segment_idx >= self.pattern.segments.len) return false;

        const segment = self.pattern.segments[segment_idx];
        return switch (segment) {
            .literal => |lit| lit.len > 0 and lit[0] == '.',
            .segment => |seg| {
                if (seg.len > 0) {
                    return switch (seg[0]) {
                        .literal => |lit| lit.len > 0 and lit[0] == '.',
                        else => false,
                    };
                }
                return false;
            },
            else => false,
        };
    }

    /// Build a path by joining prefix and name.
    fn buildPath(self: *Walker, prefix: []const u8, name: []const u8) ![]const u8 {
        if (prefix.len == 0) {
            return try self.allocator.dupe(u8, name);
        }
        const result = try self.allocator.alloc(u8, prefix.len + 1 + name.len);
        @memcpy(result[0..prefix.len], prefix);
        result[prefix.len] = '/';
        @memcpy(result[prefix.len + 1 ..], name);
        return result;
    }

    /// Check if visiting a directory would create a cycle.
    fn checkCycle(self: *Walker, dir: std.fs.Dir) !bool {
        const stat = dir.stat() catch return false;
        const key = InodeKey{
            .dev = stat.dev,
            .ino = stat.ino,
        };

        if (self.visited.contains(key)) {
            return true;
        }

        try self.visited.put(key, {});
        return false;
    }

    /// Get the kind of a directory entry.
    fn getEntryKind(self: *Walker, dir: std.fs.Dir, name: []const u8) !std.fs.File.Kind {
        _ = self;
        const stat = try dir.statFile(name);
        return stat.kind;
    }

    /// Collect all remaining matches into a slice.
    pub fn collectAll(self: *Walker) ![]Match {
        var results = std.ArrayList(Match).init(self.allocator);
        errdefer {
            for (results.items) |*m| {
                m.deinit(self.allocator);
            }
            results.deinit();
        }

        while (try self.next()) |match| {
            try results.append(match);
        }

        return results.toOwnedSlice();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn createTestDir(allocator: Allocator) !struct { path: []const u8, dir: std.fs.Dir } {
    // Create a unique temp directory
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/zig-glob-test-{d}", .{std.time.milliTimestamp()});
    errdefer allocator.free(tmp_path);

    std.fs.makeDirAbsolute(tmp_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });

    return .{ .path = tmp_path, .dir = dir };
}

fn cleanupTestDir(allocator: Allocator, path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
    allocator.free(path);
}

fn createTestFile(dir: std.fs.Dir, path: []const u8) !void {
    // Create parent directories if needed
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
    const file = try dir.createFile(path, .{});
    file.close();
}

test "walker: literal path matching" {
    const allocator = testing.allocator;

    // Create test directory structure
    const test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create test files
    try createTestFile(test_info.dir, "foo.txt");
    try createTestFile(test_info.dir, "bar.txt");

    // Create a simple literal pattern
    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .{ .literal = "foo.txt" };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "foo.txt",
    };
    defer {
        // Don't free segments since we manually manage them here
    }

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    // Should find foo.txt
    const match = try walker.next();
    try testing.expect(match != null);
    try testing.expectEqualStrings("foo.txt", match.?.path);
    var m = match.?;
    m.deinit(allocator);

    // Should be done
    const no_more = try walker.next();
    try testing.expect(no_more == null);
}

test "walker: star pattern matching" {
    const allocator = testing.allocator;

    // Create test directory structure
    const test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create test files
    try createTestFile(test_info.dir, "file1.txt");
    try createTestFile(test_info.dir, "file2.txt");
    try createTestFile(test_info.dir, "other.md");

    // Create *.txt pattern
    const inner_nodes = try allocator.alloc(Node, 2);
    defer allocator.free(inner_nodes);
    inner_nodes[0] = .star;
    inner_nodes[1] = .{ .literal = ".txt" };

    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .{ .segment = inner_nodes };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "*.txt",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    var found_count: u32 = 0;
    var found_file1 = false;
    var found_file2 = false;

    while (try walker.next()) |match| {
        found_count += 1;
        if (std.mem.eql(u8, match.path, "file1.txt")) found_file1 = true;
        if (std.mem.eql(u8, match.path, "file2.txt")) found_file2 = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expectEqual(@as(u32, 2), found_count);
    try testing.expect(found_file1);
    try testing.expect(found_file2);
}

test "walker: subdirectory traversal" {
    const allocator = testing.allocator;

    // Create test directory structure
    const test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create nested structure: src/main.zig
    try createTestFile(test_info.dir, "src/main.zig");

    // Create pattern: src/main.zig
    const segments = try allocator.alloc(Node, 2);
    defer allocator.free(segments);
    segments[0] = .{ .literal = "src" };
    segments[1] = .{ .literal = "main.zig" };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "src/main.zig",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    const match = try walker.next();
    try testing.expect(match != null);
    try testing.expectEqualStrings("src/main.zig", match.?.path);
    var m = match.?;
    m.deinit(allocator);

    const no_more = try walker.next();
    try testing.expect(no_more == null);
}

test "walker: globstar basic" {
    const allocator = testing.allocator;

    // Create test directory structure
    const test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create nested structure
    try createTestFile(test_info.dir, "a.zig");
    try createTestFile(test_info.dir, "src/b.zig");
    try createTestFile(test_info.dir, "src/sub/c.zig");

    // Create pattern: **/*.zig (globstar followed by *.zig)
    const ext_nodes = try allocator.alloc(Node, 2);
    defer allocator.free(ext_nodes);
    ext_nodes[0] = .star;
    ext_nodes[1] = .{ .literal = ".zig" };

    const segments = try allocator.alloc(Node, 2);
    defer allocator.free(segments);
    segments[0] = .globstar;
    segments[1] = .{ .segment = ext_nodes };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "**/*.zig",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    var found_paths = std.StringHashMap(void).init(allocator);
    defer found_paths.deinit();

    while (try walker.next()) |match| {
        const path_copy = try allocator.dupe(u8, match.path);
        try found_paths.put(path_copy, {});
        var m = match;
        m.deinit(allocator);
    }

    // Clean up path copies
    defer {
        var key_iter = found_paths.keyIterator();
        while (key_iter.next()) |key| {
            allocator.free(key.*);
        }
    }

    try testing.expect(found_paths.contains("a.zig"));
    try testing.expect(found_paths.contains("src/b.zig"));
    try testing.expect(found_paths.contains("src/sub/c.zig"));
}

test "walker: dotfile handling" {
    const allocator = testing.allocator;

    // Create test directory structure
    const test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create files including dotfile
    try createTestFile(test_info.dir, "visible.txt");
    try createTestFile(test_info.dir, ".hidden");

    // Create *.txt pattern - should NOT match dotfiles by default
    const inner_nodes = try allocator.alloc(Node, 1);
    defer allocator.free(inner_nodes);
    inner_nodes[0] = .star;

    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .{ .segment = inner_nodes };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "*",
    };

    // Without dot option
    {
        var walker = try Walker.init(allocator, &pattern, test_info.dir, .{ .dot = false });
        defer walker.deinit();

        var found_hidden = false;
        while (try walker.next()) |match| {
            if (std.mem.eql(u8, match.path, ".hidden")) found_hidden = true;
            var m = match;
            m.deinit(allocator);
        }
        try testing.expect(!found_hidden);
    }

    // With dot option
    {
        var walker = try Walker.init(allocator, &pattern, test_info.dir, .{ .dot = true });
        defer walker.deinit();

        var found_hidden = false;
        while (try walker.next()) |match| {
            if (std.mem.eql(u8, match.path, ".hidden")) found_hidden = true;
            var m = match;
            m.deinit(allocator);
        }
        try testing.expect(found_hidden);
    }
}

test "walker: collectAll" {
    const allocator = testing.allocator;

    // Create test directory structure
    const test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create test files
    try createTestFile(test_info.dir, "a.txt");
    try createTestFile(test_info.dir, "b.txt");

    // Create * pattern
    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .star;

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "*",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    const matches = try walker.collectAll();
    defer {
        for (matches) |*m| {
            var match = m.*;
            match.deinit(allocator);
        }
        allocator.free(matches);
    }

    try testing.expectEqual(@as(usize, 2), matches.len);
}
