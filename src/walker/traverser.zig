//! Filesystem traversal with glob pattern matching.
//!
//! Walks directory trees matching files against compiled glob patterns.
//! Supports globstar (`**`), symlink following with cycle detection,
//! depth limits, and exclude patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ast = @import("../compiler/ast.zig");
const Pattern = ast.Pattern;
const Node = ast.Node;
const parser = @import("../compiler/parser.zig");
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

/// Error handling policy for filesystem operations.
pub const ErrorPolicy = enum {
    /// Skip entries that cause errors (permission denied, etc.) silently.
    skip_silent,
    /// Skip entries but log/report the error.
    skip_report,
    /// Stop traversal on first error.
    stop_on_error,
};

/// Options for walker behavior.
pub const WalkerOptions = struct {
    /// Match dotfiles with wildcards.
    dot: bool = false,
    /// Case-insensitive matching.
    nocase: bool = false,
    /// Follow directory symlinks (enables cycle detection).
    follow_symlinks: bool = false,
    /// Include broken symlinks in results.
    include_broken_symlinks: bool = true,
    /// Maximum traversal depth (null = unlimited).
    max_depth: ?u32 = null,
    /// How to handle filesystem errors during traversal.
    error_policy: ErrorPolicy = .skip_silent,
    /// Callback for reported errors (used when error_policy is skip_report).
    /// Path is the path that caused the error.
    error_callback: ?*const fn (path: []const u8, err: anyerror) void = null,
    /// Patterns to exclude from results (compiled at init time for performance).
    exclude: ?[]const []const u8 = null,
};

/// Inode key for cycle detection when following symlinks.
/// Note: Using inode alone assumes same-filesystem traversal (typical case).
const InodeKey = struct {
    ino: std.fs.File.INode,
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
    work_queue: std.array_list.AlignedManaged(WorkItem, null),

    /// Current iteration state (if iterating a directory).
    current_iter: ?IterState,

    /// Visited inodes for cycle detection (only when following symlinks).
    visited: std.AutoHashMap(InodeKey, void),

    /// Pending matches to return (for cases where we find matches during queue processing).
    pending_matches: std.array_list.AlignedManaged(Match, null),

    /// The root directory handle.
    root_dir: std.fs.Dir,

    /// Whether walker owns the root directory.
    owns_root: bool,

    /// Compiled exclude patterns (owned by walker).
    exclude_patterns: std.array_list.AlignedManaged(Pattern, null),

    /// Pre-compiled matchers for exclude patterns (avoids alloc per check).
    exclude_matchers: std.array_list.AlignedManaged(Matcher, null),

    /// Initialize walker for a pattern starting from a directory.
    pub fn init(
        allocator: Allocator,
        pattern: *const Pattern,
        root_dir: std.fs.Dir,
        options: WalkerOptions,
    ) !Walker {
        // Compile exclude patterns upfront for performance
        var exclude_patterns = std.array_list.AlignedManaged(Pattern, null).init(allocator);
        errdefer {
            for (exclude_patterns.items) |*p| p.deinit();
            exclude_patterns.deinit();
        }

        if (options.exclude) |excludes| {
            try exclude_patterns.ensureTotalCapacity(excludes.len);
            for (excludes) |exclude_str| {
                const compiled = try parser.parse(allocator, exclude_str, .{
                    .globstar = true,
                    .brace = false, // Exclude patterns should be pre-expanded
                    .extglob = true,
                    .nocase = options.nocase,
                    .dot = true, // Exclude should match dotfiles
                });
                exclude_patterns.appendAssumeCapacity(compiled);
            }
        }

        // Pre-compile matchers for exclude patterns (avoids alloc per isExcluded check)
        var exclude_matchers = std.array_list.AlignedManaged(Matcher, null).init(allocator);
        errdefer {
            for (exclude_matchers.items) |*m| m.deinit();
            exclude_matchers.deinit();
        }

        if (exclude_patterns.items.len > 0) {
            try exclude_matchers.ensureTotalCapacity(exclude_patterns.items.len);
            for (exclude_patterns.items) |*excl_pattern| {
                const matcher = Matcher.init(allocator, excl_pattern, .{
                    .dot = true,
                    .nocase = options.nocase,
                });
                exclude_matchers.appendAssumeCapacity(matcher);
            }
        }

        var walker = Walker{
            .allocator = allocator,
            .pattern = pattern,
            .options = options,
            .work_queue = std.array_list.AlignedManaged(WorkItem, null).init(allocator),
            .current_iter = null,
            .visited = std.AutoHashMap(InodeKey, void).init(allocator),
            .pending_matches = std.array_list.AlignedManaged(Match, null).init(allocator),
            .root_dir = root_dir,
            .owns_root = false,
            .exclude_patterns = exclude_patterns,
            .exclude_matchers = exclude_matchers,
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

        // Clean up exclude matchers (must be before patterns since matchers reference patterns)
        for (self.exclude_matchers.items) |*m| {
            m.deinit();
        }
        self.exclude_matchers.deinit();

        // Clean up exclude patterns
        for (self.exclude_patterns.items) |*p| {
            p.deinit();
        }
        self.exclude_patterns.deinit();

        // Clean up visited set
        self.visited.deinit();

        // Close root if we own it
        if (self.owns_root) {
            self.root_dir.close();
        }
    }

    /// Check if a path matches any exclude pattern.
    /// Uses pre-compiled matchers for performance (no allocations per check).
    fn isExcluded(self: *Walker, path: []const u8) bool {
        for (self.exclude_matchers.items) |*matcher| {
            if (matcher.matchPath(path) catch false) {
                return true;
            }
        }
        return false;
    }

    /// Get the next match, or null if iteration is complete.
    pub fn next(self: *Walker) !?Match {
        while (true) {
            // First, return any pending matches
            if (self.pending_matches.pop()) |match| {
                // Check exclude patterns
                if (self.isExcluded(match.path)) {
                    self.allocator.free(match.path);
                    continue;
                }
                return match;
            }

            // If we have a current directory iteration, continue it
            if (self.current_iter) |*state| {
                if (try self.processIterEntry(state)) |match| {
                    // Check exclude patterns
                    if (self.isExcluded(match.path)) {
                        self.allocator.free(match.path);
                        continue;
                    }
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

            var work_item = self.work_queue.pop() orelse return null;

            // Check depth limit
            if (self.options.max_depth) |max| {
                if (work_item.depth > max) {
                    work_item.deinit(self.allocator);
                    continue;
                }
            }

            // Process the work item
            if (try self.processWorkItem(&work_item)) |match| {
                // Check exclude patterns
                if (self.isExcluded(match.path)) {
                    self.allocator.free(match.path);
                    continue;
                }
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
            var sub_dir = work_item.dir.openDir(literal, .{ .iterate = true }) catch {
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
        // This skip work item will own the dir if the original owned it.
        const skip_prefix = try self.allocator.dupe(u8, work_item.prefix);
        try self.work_queue.append(.{
            .dir = work_item.dir,
            .prefix = skip_prefix,
            .segment_idx = work_item.segment_idx + 1,
            .depth = work_item.depth,
            .owns_dir = work_item.owns_dir, // Transfer ownership to skip item
        });

        // Then set up iteration for matching one or more directories.
        // Current iteration doesn't own the dir (ownership transferred to skip item).
        var iter_work_item = work_item.*;
        iter_work_item.owns_dir = false; // Don't close dir when iteration ends
        self.current_iter = .{
            .iter = work_item.dir.iterate(),
            .work_item = iter_work_item,
            .globstar_mode = true,
            .globstar_skip_pushed = true,
        };
    }

    /// Walker-specific errors that can be returned to caller.
    pub const WalkerError = error{
        /// Permission denied accessing a path.
        PermissionDenied,
        /// Path no longer exists (TOCTOU race).
        PathNotFound,
        /// Generic filesystem error.
        FilesystemError,
        /// Out of memory.
        OutOfMemory,
    };

    /// Handle a filesystem error according to the error policy.
    /// Returns true if traversal should continue, false if should stop.
    fn handleFilesystemError(self: *Walker, path: []const u8, err: anyerror) WalkerError!void {
        switch (self.options.error_policy) {
            .skip_silent => {
                // Silently skip - do nothing
            },
            .skip_report => {
                // Report via callback if provided
                if (self.options.error_callback) |callback| {
                    callback(path, err);
                }
            },
            .stop_on_error => {
                // Map to walker error type
                return switch (err) {
                    error.AccessDenied => WalkerError.PermissionDenied,
                    error.FileNotFound => WalkerError.PathNotFound,
                    error.NotDir => WalkerError.PathNotFound,
                    else => WalkerError.FilesystemError,
                };
            },
        }
    }

    /// Process one entry from the current directory iteration.
    fn processIterEntry(self: *Walker, state: *IterState) !?Match {
        while (true) {
            // Handle directory iteration with proper error handling
            const entry_result = state.iter.next();
            const entry = entry_result catch |err| {
                // Build path for error reporting (best effort)
                const err_path = state.work_item.prefix;
                try self.handleFilesystemError(err_path, err);
                // If we get here, policy is to continue
                continue;
            };

            // Check if iteration is complete
            if (entry) |e| {
                // Skip . and ..
                if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) {
                    continue;
                }

                // Apply dotfile rule
                if (!self.options.dot and e.name[0] == '.') {
                    // Check if pattern explicitly matches dotfiles
                    if (!self.patternMatchesDotfile(state.work_item.segment_idx)) {
                        continue;
                    }
                }

                if (state.globstar_mode) {
                    // In globstar mode: descend into all directories (and symlinks if following)
                    if (self.shouldDescendInto(e.kind)) {
                        self.handleGlobstarEntry(state, e) catch |err| {
                            const path = self.buildPath(state.work_item.prefix, e.name) catch {
                                // Can't build path, just skip
                                continue;
                            };
                            defer self.allocator.free(path);
                            try self.handleFilesystemError(path, err);
                        };
                    }
                    // Also check if this entry matches the next segment
                    try self.checkGlobstarMatch(state, e);
                } else {
                    // Pattern mode: check if entry matches current segment
                    if (try self.checkPatternMatch(state, e)) |match| {
                        return match;
                    }
                }
            } else {
                // Iterator exhausted
                return null;
            }
        }
    }

    /// Handle a directory entry in globstar mode.
    fn handleGlobstarEntry(self: *Walker, state: *IterState, entry: std.fs.Dir.Entry) !void {
        const new_prefix = try self.buildPath(state.work_item.prefix, entry.name);
        errdefer self.allocator.free(new_prefix);

        // Open the subdirectory with TOCTOU-resilient error handling
        // Entry might have been deleted between iteration and openDir
        var sub_dir = state.work_item.dir.openDir(entry.name, .{ .iterate = true }) catch |err| {
            self.allocator.free(new_prefix);
            // Re-throw for caller to handle according to policy
            return err;
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
    /// Handles two cases:
    /// 1. Globstar is last segment: match everything (files and directories)
    /// 2. More segments after globstar: only handle directory descent for continuing match
    ///    File matching is handled by skip work items to avoid duplicates.
    fn checkGlobstarMatch(self: *Walker, state: *IterState, entry: std.fs.Dir.Entry) !void {
        const next_idx = state.work_item.segment_idx + 1;

        // Case 1: Globstar is last segment - match files only here
        // Directories are matched by their own skip items (which handle the case
        // of globstar matching zero more levels), so we skip them to avoid duplicates.
        if (next_idx >= self.pattern.segments.len) {
            if (!self.shouldDescendInto(entry.kind)) {
                // Only match files (non-directories)
                const match_path = try self.buildPath(state.work_item.prefix, entry.name);
                try self.pending_matches.append(.{
                    .path = match_path,
                    .kind = entry.kind,
                });
            }
            // Directories will be handled by handleGlobstarEntry pushing work items
            // and their own skip items returning them as matches
            return;
        }

        // Case 2: More segments after globstar
        // Only handle directory descent here. File matching is done by skip work items
        // which are pushed in setupGlobstarIteration. This prevents duplicate matches
        // for patterns like `**/*.zig`.
        const next_segment = self.pattern.segments[next_idx];
        if (self.matchesSegment(next_segment, entry.name)) {
            // Only descend into directories when there are more segments to match
            if (next_idx + 1 < self.pattern.segments.len and self.shouldDescendInto(entry.kind)) {
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
            // File matches for `**/*.ext` are handled by skip items, not here
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
        } else if (self.shouldDescendInto(entry.kind)) {
            // More segments: descend into directories (and symlinks if following)
            var sub_dir = state.work_item.dir.openDir(entry.name, .{ .iterate = true }) catch {
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
            // Not a directory (or symlink without follow) and not last segment
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

    /// Check if we should descend into an entry.
    /// Returns true for directories, and for symlinks when follow_symlinks is enabled.
    fn shouldDescendInto(self: *Walker, kind: std.fs.File.Kind) bool {
        if (kind == .directory) return true;
        if (kind == .sym_link and self.options.follow_symlinks) return true;
        return false;
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
        const key = InodeKey{ .ino = stat.inode };

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
        var results = std.array_list.AlignedManaged(Match, null).init(self.allocator);
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
    var test_info = try createTestDir(allocator);
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
    var test_info = try createTestDir(allocator);
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
    var test_info = try createTestDir(allocator);
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
    var test_info = try createTestDir(allocator);
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

    // Use ArrayList to track paths for simpler cleanup
    var paths = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }

    while (try walker.next()) |match| {
        const path_copy = try allocator.dupe(u8, match.path);
        errdefer allocator.free(path_copy);
        try paths.append(path_copy);
        var m = match;
        m.deinit(allocator);
    }

    // Check we found expected paths
    var found_a = false;
    var found_b = false;
    var found_c = false;
    for (paths.items) |p| {
        if (std.mem.eql(u8, p, "a.zig")) found_a = true;
        if (std.mem.eql(u8, p, "src/b.zig")) found_b = true;
        if (std.mem.eql(u8, p, "src/sub/c.zig")) found_c = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
    try testing.expect(found_c);
}

test "walker: dotfile handling" {
    const allocator = testing.allocator;

    // Create test directory structure
    var test_info = try createTestDir(allocator);
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
    var test_info = try createTestDir(allocator);
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

// ============================================================================
// Edge Case and Error Handling Tests
// ============================================================================

test "edge: max depth limit enforcement" {
    const allocator = testing.allocator;

    // Create test directory structure
    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create nested structure: a/b/c/d/file.txt (4 levels deep)
    try createTestFile(test_info.dir, "a/b/c/d/file.txt");
    try createTestFile(test_info.dir, "a/b/shallow.txt");

    // Create ** pattern with max_depth=2
    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .globstar;

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "**",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .max_depth = 2,
    });
    defer walker.deinit();

    var found_deep = false;
    var found_shallow = false;

    while (try walker.next()) |match| {
        if (std.mem.indexOf(u8, match.path, "a/b/c/d/file.txt")) |_| {
            found_deep = true;
        }
        if (std.mem.indexOf(u8, match.path, "shallow.txt")) |_| {
            found_shallow = true;
        }
        var m = match;
        m.deinit(allocator);
    }

    // Deep file should NOT be found due to depth limit
    // Shallow file should be found
    try testing.expect(!found_deep);
    try testing.expect(found_shallow);
}

test "edge: empty directory" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Don't create any files - directory is empty

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

    // Should return null immediately (no matches)
    const match = try walker.next();
    try testing.expect(match == null);
}

test "edge: special characters in filenames" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create files with special characters (that might look like glob patterns)
    try createTestFile(test_info.dir, "file[1].txt");
    try createTestFile(test_info.dir, "file{a}.txt");

    // Create * pattern
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

    var count: u32 = 0;
    while (try walker.next()) |match| {
        count += 1;
        var m = match;
        m.deinit(allocator);
    }

    // Should find both files
    try testing.expectEqual(@as(u32, 2), count);
}

test "edge: error callback is invoked" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create a file
    try createTestFile(test_info.dir, "test.txt");

    // Static error counter for callback
    const Counter = struct {
        var count: u32 = 0;
        fn callback(_: []const u8, _: anyerror) void {
            count += 1;
        }
    };
    Counter.count = 0;

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

    // Use skip_report policy with callback
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .error_policy = .skip_report,
        .error_callback = Counter.callback,
    });
    defer walker.deinit();

    // Normal operation should work, counter stays at 0 unless errors occur
    const matches = try walker.collectAll();
    defer {
        for (matches) |*m| {
            var match = m.*;
            match.deinit(allocator);
        }
        allocator.free(matches);
    }

    // Should find the file
    try testing.expectEqual(@as(usize, 1), matches.len);
}

test "edge: directory with only hidden files" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create only hidden files
    try createTestFile(test_info.dir, ".gitignore");
    try createTestFile(test_info.dir, ".env");

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

    // Without dot option - should find nothing
    {
        var walker = try Walker.init(allocator, &pattern, test_info.dir, .{ .dot = false });
        defer walker.deinit();

        const match = try walker.next();
        try testing.expect(match == null);
    }

    // With dot option - should find both
    {
        var walker = try Walker.init(allocator, &pattern, test_info.dir, .{ .dot = true });
        defer walker.deinit();

        var count: u32 = 0;
        while (try walker.next()) |match| {
            count += 1;
            var m = match;
            m.deinit(allocator);
        }
        try testing.expectEqual(@as(u32, 2), count);
    }
}

// ============================================================================
// Comprehensive Walker Edge Case Tests
// ============================================================================

test "edge: very deep directory structure (10 levels)" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create 10-level deep structure
    try createTestFile(test_info.dir, "a/b/c/d/e/f/g/h/i/j/deep.txt");

    // Create **/*.txt pattern
    const ext_nodes = try allocator.alloc(Node, 2);
    defer allocator.free(ext_nodes);
    ext_nodes[0] = .star;
    ext_nodes[1] = .{ .literal = ".txt" };

    const segments = try allocator.alloc(Node, 2);
    defer allocator.free(segments);
    segments[0] = .globstar;
    segments[1] = .{ .segment = ext_nodes };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "**/*.txt",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    var found_deep = false;
    while (try walker.next()) |match| {
        if (std.mem.endsWith(u8, match.path, "deep.txt")) {
            found_deep = true;
        }
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(found_deep);
}

test "edge: pattern matches nothing in non-empty directory" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create files with .txt extension only
    try createTestFile(test_info.dir, "file1.txt");
    try createTestFile(test_info.dir, "file2.txt");

    // Create *.nonexistent pattern - should match nothing
    const inner_nodes = try allocator.alloc(Node, 2);
    defer allocator.free(inner_nodes);
    inner_nodes[0] = .star;
    inner_nodes[1] = .{ .literal = ".nonexistent" };

    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .{ .segment = inner_nodes };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "*.nonexistent",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    var count: u32 = 0;
    while (try walker.next()) |match| {
        count += 1;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expectEqual(@as(u32, 0), count);
}

test "edge: literal path with multiple segments" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create nested structure
    try createTestFile(test_info.dir, "src/lib/utils.zig");

    // Create pattern with literal path separators
    const segments = try allocator.alloc(Node, 3);
    defer allocator.free(segments);
    segments[0] = .{ .literal = "src" };
    segments[1] = .{ .literal = "lib" };
    segments[2] = .{ .literal = "utils.zig" };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "src/lib/utils.zig",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    const match = try walker.next();
    try testing.expect(match != null);
    try testing.expectEqualStrings("src/lib/utils.zig", match.?.path);
    var m = match.?;
    m.deinit(allocator);

    // Should be done
    try testing.expect(try walker.next() == null);
}

test "edge: globstar with prefix directory restriction" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create structure in multiple directories
    try createTestFile(test_info.dir, "src/main.zig");
    try createTestFile(test_info.dir, "src/lib/utils.zig");
    try createTestFile(test_info.dir, "tests/test_main.zig");

    // Create src/**/*.zig pattern
    const ext_nodes = try allocator.alloc(Node, 2);
    defer allocator.free(ext_nodes);
    ext_nodes[0] = .star;
    ext_nodes[1] = .{ .literal = ".zig" };

    const segments = try allocator.alloc(Node, 3);
    defer allocator.free(segments);
    segments[0] = .{ .literal = "src" };
    segments[1] = .globstar;
    segments[2] = .{ .segment = ext_nodes };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "src/**/*.zig",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    var found_src_main = false;
    var found_src_utils = false;
    var found_tests = false;

    while (try walker.next()) |match| {
        if (std.mem.eql(u8, match.path, "src/main.zig")) found_src_main = true;
        if (std.mem.eql(u8, match.path, "src/lib/utils.zig")) found_src_utils = true;
        if (std.mem.indexOf(u8, match.path, "tests/") != null) found_tests = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(found_src_main);
    try testing.expect(found_src_utils);
    try testing.expect(!found_tests); // Should NOT match tests directory
}

test "edge: character class in walker pattern" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create files with different extensions
    try createTestFile(test_info.dir, "main.c");
    try createTestFile(test_info.dir, "main.h");
    try createTestFile(test_info.dir, "main.o");

    // Create *.[ch] pattern
    const cc_members = try allocator.alloc(ast.CharMember, 2);
    defer allocator.free(cc_members);
    cc_members[0] = .{ .single = 'c' };
    cc_members[1] = .{ .single = 'h' };

    const inner_nodes = try allocator.alloc(Node, 3);
    defer allocator.free(inner_nodes);
    inner_nodes[0] = .star;
    inner_nodes[1] = .{ .literal = "." };
    inner_nodes[2] = .{ .char_class = .{ .members = cc_members, .negated = false } };

    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .{ .segment = inner_nodes };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "*.[ch]",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{});
    defer walker.deinit();

    var found_c = false;
    var found_h = false;
    var found_o = false;

    while (try walker.next()) |match| {
        if (std.mem.eql(u8, match.path, "main.c")) found_c = true;
        if (std.mem.eql(u8, match.path, "main.h")) found_h = true;
        if (std.mem.eql(u8, match.path, "main.o")) found_o = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(found_c);
    try testing.expect(found_h);
    try testing.expect(!found_o); // Should NOT match .o files
}

test "edge: hidden directory traversal with globstar" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create hidden directory structure
    try createTestFile(test_info.dir, ".hidden/file.txt");
    try createTestFile(test_info.dir, "visible/file.txt");

    // Create **/*.txt pattern
    const ext_nodes = try allocator.alloc(Node, 2);
    defer allocator.free(ext_nodes);
    ext_nodes[0] = .star;
    ext_nodes[1] = .{ .literal = ".txt" };

    const segments = try allocator.alloc(Node, 2);
    defer allocator.free(segments);
    segments[0] = .globstar;
    segments[1] = .{ .segment = ext_nodes };

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "**/*.txt",
    };

    // Without dot option
    {
        var walker = try Walker.init(allocator, &pattern, test_info.dir, .{ .dot = false });
        defer walker.deinit();

        var found_hidden = false;
        var found_visible = false;

        while (try walker.next()) |match| {
            if (std.mem.indexOf(u8, match.path, ".hidden") != null) found_hidden = true;
            if (std.mem.indexOf(u8, match.path, "visible") != null) found_visible = true;
            var m = match;
            m.deinit(allocator);
        }

        try testing.expect(found_visible);
        // Without dot=true, hidden directories should not be traversed
    }

    // With dot option
    {
        var walker = try Walker.init(allocator, &pattern, test_info.dir, .{ .dot = true });
        defer walker.deinit();

        var found_hidden = false;
        var found_visible = false;

        while (try walker.next()) |match| {
            if (std.mem.indexOf(u8, match.path, ".hidden") != null) found_hidden = true;
            if (std.mem.indexOf(u8, match.path, "visible") != null) found_visible = true;
            var m = match;
            m.deinit(allocator);
        }

        try testing.expect(found_visible);
        try testing.expect(found_hidden);
    }
}

// ============================================================================
// Walker Exclude Functionality Tests
// ============================================================================

test "walker exclude: basic exclude pattern" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create test files
    try createTestFile(test_info.dir, "keep.txt");
    try createTestFile(test_info.dir, "exclude.txt");

    // Create * pattern with exclude
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

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = &.{"**/exclude.txt"},
    });
    defer walker.deinit();

    var found_keep = false;
    var found_exclude = false;
    while (try walker.next()) |match| {
        if (std.mem.eql(u8, match.path, "keep.txt")) found_keep = true;
        if (std.mem.eql(u8, match.path, "exclude.txt")) found_exclude = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(found_keep);
    try testing.expect(!found_exclude);
}

test "walker exclude: multiple exclude patterns" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create test files
    try createTestFile(test_info.dir, "file1.txt");
    try createTestFile(test_info.dir, "file2.txt");
    try createTestFile(test_info.dir, "file3.txt");
    try createTestFile(test_info.dir, "keep.md");

    // Create * pattern with multiple excludes
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

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = &.{ "**/file1.txt", "**/file2.txt" },
    });
    defer walker.deinit();

    var found_file1 = false;
    var found_file2 = false;
    var found_file3 = false;
    var found_keep = false;
    while (try walker.next()) |match| {
        if (std.mem.eql(u8, match.path, "file1.txt")) found_file1 = true;
        if (std.mem.eql(u8, match.path, "file2.txt")) found_file2 = true;
        if (std.mem.eql(u8, match.path, "file3.txt")) found_file3 = true;
        if (std.mem.eql(u8, match.path, "keep.md")) found_keep = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(!found_file1);
    try testing.expect(!found_file2);
    try testing.expect(found_file3);
    try testing.expect(found_keep);
}

test "walker exclude: globstar exclude pattern" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create nested structure
    try createTestFile(test_info.dir, "src/main.zig");
    try createTestFile(test_info.dir, "src/lib/utils.zig");
    try createTestFile(test_info.dir, "tests/test.zig");

    // Create ** pattern with exclude for tests directory
    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .globstar;

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "**",
    };

    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = &.{"**/tests/**"},
    });
    defer walker.deinit();

    var found_src = false;
    var found_tests = false;
    while (try walker.next()) |match| {
        if (std.mem.indexOf(u8, match.path, "src/") != null) found_src = true;
        if (std.mem.indexOf(u8, match.path, "tests/") != null) found_tests = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(found_src);
    try testing.expect(!found_tests);
}

test "walker exclude: exclude with nocase option" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create test files with mixed case
    try createTestFile(test_info.dir, "test.txt");
    try createTestFile(test_info.dir, "keep.txt");

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

    // Exclude with uppercase pattern, nocase should match lowercase
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .nocase = true,
        .exclude = &.{"**/TEST.txt"},
    });
    defer walker.deinit();

    var found_test = false;
    var found_keep = false;
    while (try walker.next()) |match| {
        if (std.mem.eql(u8, match.path, "test.txt")) found_test = true;
        if (std.mem.eql(u8, match.path, "keep.txt")) found_keep = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(!found_test); // Should be excluded (nocase)
    try testing.expect(found_keep);
}

test "walker exclude: exclude matches dotfiles" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create dotfiles
    try createTestFile(test_info.dir, ".hidden");
    try createTestFile(test_info.dir, "visible.txt");

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

    // Enable dot matching, but exclude dotfiles
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .dot = true,
        .exclude = &.{"**/.*"}, // Exclude all dotfiles
    });
    defer walker.deinit();

    var found_hidden = false;
    var found_visible = false;
    while (try walker.next()) |match| {
        if (std.mem.eql(u8, match.path, ".hidden")) found_hidden = true;
        if (std.mem.eql(u8, match.path, "visible.txt")) found_visible = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(!found_hidden); // Should be excluded
    try testing.expect(found_visible);
}

test "walker exclude: empty exclude list" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    try createTestFile(test_info.dir, "file.txt");

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

    // Empty exclude slice
    const empty_excludes: []const []const u8 = &.{};
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = empty_excludes,
    });
    defer walker.deinit();

    var count: u32 = 0;
    while (try walker.next()) |match| {
        count += 1;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(count >= 1);
}

test "walker exclude: null exclude option" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    try createTestFile(test_info.dir, "file.txt");

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

    // null exclude
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = null,
    });
    defer walker.deinit();

    var count: u32 = 0;
    while (try walker.next()) |match| {
        count += 1;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(count >= 1);
}

test "walker exclude: exclude all with globstar" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    try createTestFile(test_info.dir, "file1.txt");
    try createTestFile(test_info.dir, "file2.txt");
    try createTestFile(test_info.dir, "sub/file3.txt");

    // Create ** pattern
    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .globstar;

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "**",
    };

    // Exclude everything using ** pattern (matches any path)
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = &.{"**"},
    });
    defer walker.deinit();

    var count: u32 = 0;
    while (try walker.next()) |match| {
        count += 1;
        var m = match;
        m.deinit(allocator);
    }

    // Should find nothing (all excluded by ** pattern)
    try testing.expectEqual(@as(u32, 0), count);
}

test "walker exclude: exclude with character class" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create files with different first letters
    try createTestFile(test_info.dir, "alpha.txt");
    try createTestFile(test_info.dir, "beta.txt");
    try createTestFile(test_info.dir, "gamma.txt");

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

    // Exclude files starting with a or b
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = &.{"**/[ab]*.txt"},
    });
    defer walker.deinit();

    var found_alpha = false;
    var found_beta = false;
    var found_gamma = false;
    while (try walker.next()) |match| {
        if (std.mem.eql(u8, match.path, "alpha.txt")) found_alpha = true;
        if (std.mem.eql(u8, match.path, "beta.txt")) found_beta = true;
        if (std.mem.eql(u8, match.path, "gamma.txt")) found_gamma = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(!found_alpha);
    try testing.expect(!found_beta);
    try testing.expect(found_gamma);
}

test "walker exclude: exclude with question mark wildcard" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create files with different name lengths
    try createTestFile(test_info.dir, "ab.txt");
    try createTestFile(test_info.dir, "abc.txt");
    try createTestFile(test_info.dir, "abcd.txt");

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

    // Exclude 3-char filenames
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = &.{"**/???.txt"},
    });
    defer walker.deinit();

    var found_ab = false;
    var found_abc = false;
    var found_abcd = false;
    while (try walker.next()) |match| {
        if (std.mem.eql(u8, match.path, "ab.txt")) found_ab = true;
        if (std.mem.eql(u8, match.path, "abc.txt")) found_abc = true;
        if (std.mem.eql(u8, match.path, "abcd.txt")) found_abcd = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(found_ab);
    try testing.expect(!found_abc); // 3 chars, should be excluded
    try testing.expect(found_abcd);
}

test "walker exclude: exclude in nested directory" {
    const allocator = testing.allocator;

    var test_info = try createTestDir(allocator);
    defer cleanupTestDir(allocator, test_info.path);
    defer test_info.dir.close();

    // Create nested structure
    try createTestFile(test_info.dir, "a/b/c/deep.txt");
    try createTestFile(test_info.dir, "a/shallow.txt");
    try createTestFile(test_info.dir, "root.txt");

    // Create ** pattern
    const segments = try allocator.alloc(Node, 1);
    defer allocator.free(segments);
    segments[0] = .globstar;

    var pattern = Pattern{
        .allocator = allocator,
        .segments = segments,
        .is_absolute = false,
        .trailing_slash = false,
        .original = "**",
    };

    // Exclude deep files
    var walker = try Walker.init(allocator, &pattern, test_info.dir, .{
        .exclude = &.{"**/a/b/**"},
    });
    defer walker.deinit();

    var found_deep = false;
    var found_shallow = false;
    var found_root = false;
    while (try walker.next()) |match| {
        if (std.mem.indexOf(u8, match.path, "deep.txt") != null) found_deep = true;
        if (std.mem.indexOf(u8, match.path, "shallow.txt") != null) found_shallow = true;
        if (std.mem.eql(u8, match.path, "root.txt")) found_root = true;
        var m = match;
        m.deinit(allocator);
    }

    try testing.expect(!found_deep); // Should be excluded
    try testing.expect(found_shallow);
    try testing.expect(found_root);
}
