//! Symlink handling and cycle detection for filesystem traversal.
//!
//! This module provides policies for handling symbolic links during glob
//! pattern matching, including cycle detection to prevent infinite loops
//! when following directory symlinks.
//!
//! Platform-specific behavior:
//! - Linux/macOS: Full symlink support with device ID from dev_major/dev_minor
//! - Windows: Symlink support with device ID from volume serial number
//!   - Cycle detection works across different drives (C:, D:, etc.)
//!   - Creating symlinks requires Administrator privileges or Developer Mode
//!   - Tests are skipped on Windows due to privilege requirements

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;
const builtin = @import("builtin");

/// Mode for stat operations - determines whether symlinks are followed.
pub const StatMode = enum {
    /// Use lstat - don't follow symlinks (returns info about the link itself)
    lstat,
    /// Use stat - follow symlinks (returns info about the target)
    stat,
};

/// Policy for handling symbolic links during directory traversal.
pub const SymlinkPolicy = struct {
    /// Whether to follow directory symlinks during traversal.
    /// When false (default, matches Node.js behavior), symlinks to directories
    /// are not descended into. When true, symlinks are followed, requiring
    /// cycle detection to prevent infinite loops.
    follow_dir_symlinks: bool = false,

    /// Whether to include broken symlinks in results.
    /// When true (default), broken symlinks are included as matches.
    /// When false, broken symlinks are silently skipped.
    include_broken_symlinks: bool = true,

    /// Stat mode for file type determination.
    /// lstat (default): Returns info about the symlink itself
    /// stat: Follows symlinks and returns info about the target
    stat_mode: StatMode = .lstat,

    /// Create a policy that follows symlinks (requires cycle detection).
    pub fn followSymlinks() SymlinkPolicy {
        return .{
            .follow_dir_symlinks = true,
            .include_broken_symlinks = true,
            .stat_mode = .stat,
        };
    }

    /// Create a policy that never follows symlinks (safe, no cycles possible).
    pub fn noFollow() SymlinkPolicy {
        return .{
            .follow_dir_symlinks = false,
            .include_broken_symlinks = true,
            .stat_mode = .lstat,
        };
    }
};

/// Platform-independent key for identifying unique filesystem locations.
/// Used for cycle detection when following symlinks.
pub const InodeKey = struct {
    /// Device ID (filesystem identifier) - may be 0 on some platforms
    dev: u64,
    /// Inode number (unique within device)
    inode: u64,

    pub fn eql(a: InodeKey, b: InodeKey) bool {
        return a.dev == b.dev and a.inode == b.inode;
    }

    pub fn hash(key: InodeKey) u64 {
        // Combine dev and inode into a single hash
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.dev));
        hasher.update(std.mem.asBytes(&key.inode));
        return hasher.final();
    }
};

/// Hash context for InodeKey in hash maps.
const InodeKeyContext = struct {
    pub fn hash(_: InodeKeyContext, key: InodeKey) u64 {
        return InodeKey.hash(key);
    }

    pub fn eql(_: InodeKeyContext, a: InodeKey, b: InodeKey) bool {
        return InodeKey.eql(a, b);
    }
};

/// Set of visited directories for cycle detection.
/// Tracks (dev, inode) pairs to detect when we've visited a directory before.
pub const VisitedSet = struct {
    map: std.HashMap(InodeKey, void, InodeKeyContext, 80),
    allocator: Allocator,

    /// Initialize a new visited set.
    pub fn init(allocator: Allocator) VisitedSet {
        return .{
            .map = std.HashMap(InodeKey, void, InodeKeyContext, 80).init(allocator),
            .allocator = allocator,
        };
    }

    /// Free all resources.
    pub fn deinit(self: *VisitedSet) void {
        self.map.deinit();
    }

    /// Check if a (dev, inode) pair has been visited.
    pub fn contains(self: *const VisitedSet, dev: u64, inode: u64) bool {
        return self.map.contains(.{ .dev = dev, .inode = inode });
    }

    /// Mark a (dev, inode) pair as visited.
    pub fn put(self: *VisitedSet, dev: u64, inode: u64) !void {
        try self.map.put(.{ .dev = dev, .inode = inode }, {});
    }

    /// Remove a (dev, inode) pair from the visited set.
    /// Useful when backtracking in traversal.
    pub fn remove(self: *VisitedSet, dev: u64, inode: u64) void {
        _ = self.map.remove(.{ .dev = dev, .inode = inode });
    }

    /// Clear all visited entries.
    pub fn clear(self: *VisitedSet) void {
        self.map.clearRetainingCapacity();
    }

    /// Get the number of visited entries.
    pub fn count(self: *const VisitedSet) usize {
        return self.map.count();
    }
};

/// Error type for symlink operations.
pub const SymlinkError = error{
    /// The path forms a cycle (already visited)
    CycleDetected,
    /// The symlink target does not exist
    BrokenSymlink,
    /// Platform does not support this operation
    PlatformNotSupported,
    /// Access denied
    AccessDenied,
    /// File not found
    FileNotFound,
    /// Other filesystem error
    Unexpected,
} || std.fs.File.OpenError || std.fs.File.StatError || Allocator.Error;

/// Result of shouldDescend check.
pub const DescendResult = union(enum) {
    /// Safe to descend into this directory
    descend: InodeKey,
    /// Don't descend (symlink not followed or not a directory)
    skip,
    /// Cycle detected - this directory was already visited
    cycle,
    /// Broken symlink (target doesn't exist)
    broken,
    /// Error accessing the entry
    err: anyerror,
};

/// Information from a stat operation on a path.
const StatInfo = struct {
    dev: u64,
    inode: u64,
    kind: std.fs.File.Kind,
};

/// Get Windows volume serial number from a file path (Windows only).
/// This provides proper device identification for cycle detection across drives.
fn getWindowsVolumeSerial(dir: std.fs.Dir, name: []const u8) ?u64 {
    if (comptime builtin.os.tag != .windows) return null;

    const windows = std.os.windows;

    // Open the file to get its handle
    const file = dir.openFile(name, .{}) catch return null;
    defer file.close();

    return getWindowsVolumeSerialFromHandle(file.handle);
}

/// Get Windows volume serial number from a directory handle (Windows only).
fn getWindowsVolumeSerialFromDir(dir: std.fs.Dir) ?u64 {
    if (comptime builtin.os.tag != .windows) return null;

    const windows = std.os.windows;
    return getWindowsVolumeSerialFromHandle(dir.fd);
}

/// Get Windows volume serial number from a file handle (Windows only).
fn getWindowsVolumeSerialFromHandle(handle: std.os.windows.HANDLE) ?u64 {
    if (comptime builtin.os.tag != .windows) return null;

    const windows = std.os.windows;

    // Get file information which includes volume serial number
    var info: windows.BY_HANDLE_FILE_INFORMATION = undefined;
    if (windows.kernel32.GetFileInformationByHandle(handle, &info) == 0) {
        return null;
    }

    // The dwVolumeSerialNumber field uniquely identifies the volume
    return @as(u64, info.dwVolumeSerialNumber);
}

/// Stat a path without following symlinks (lstat behavior).
fn lstatPath(dir: std.fs.Dir, name: []const u8) ?StatInfo {
    if (comptime builtin.os.tag == .linux) {
        const path_c = posix.toPosixPath(name) catch return null;
        var stx = std.mem.zeroes(linux.Statx);

        const rc = linux.statx(
            dir.fd,
            &path_c,
            linux.AT.NO_AUTOMOUNT | linux.AT.SYMLINK_NOFOLLOW,
            linux.STATX_TYPE | linux.STATX_INO,
            &stx,
        );

        if (linux.E.init(rc) != .SUCCESS) {
            return null;
        }

        const dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
        const kind = kindFromMode(stx.mode);
        return .{ .dev = dev, .inode = stx.ino, .kind = kind };
    } else if (comptime builtin.os.tag == .windows) {
        const stat = dir.statFile(name) catch return null;
        // For lstat behavior, use the directory's volume serial since
        // the symlink itself is on the same volume as its parent
        const dev = getWindowsVolumeSerialFromDir(dir) orelse 0;
        return .{ .dev = dev, .inode = stat.inode, .kind = stat.kind };
    } else {
        const st = posix.fstatat(dir.fd, name, posix.AT.SYMLINK_NOFOLLOW) catch return null;
        const kind = kindFromPosixMode(st.mode);
        return .{ .dev = st.dev, .inode = st.ino, .kind = kind };
    }
}

/// Convert Linux statx mode to file kind.
fn kindFromMode(mode: u16) std.fs.File.Kind {
    const S_IFMT: u16 = 0o170000;
    const S_IFSOCK: u16 = 0o140000;
    const S_IFLNK: u16 = 0o120000;
    const S_IFREG: u16 = 0o100000;
    const S_IFBLK: u16 = 0o060000;
    const S_IFDIR: u16 = 0o040000;
    const S_IFCHR: u16 = 0o020000;
    const S_IFIFO: u16 = 0o010000;

    return switch (mode & S_IFMT) {
        S_IFSOCK => .unix_domain_socket,
        S_IFLNK => .sym_link,
        S_IFREG => .file,
        S_IFBLK => .block_device,
        S_IFDIR => .directory,
        S_IFCHR => .character_device,
        S_IFIFO => .named_pipe,
        else => .unknown,
    };
}

/// Convert POSIX stat mode to file kind.
fn kindFromPosixMode(mode: posix.mode_t) std.fs.File.Kind {
    const S = posix.S;
    if (S.ISSOCK(mode)) return .unix_domain_socket;
    if (S.ISLNK(mode)) return .sym_link;
    if (S.ISREG(mode)) return .file;
    if (S.ISBLK(mode)) return .block_device;
    if (S.ISDIR(mode)) return .directory;
    if (S.ISCHR(mode)) return .character_device;
    if (S.ISFIFO(mode)) return .named_pipe;
    return .unknown;
}

/// Get inode key from a directory's stat info.
/// On Linux, uses statx to get dev_major/dev_minor.
/// On other POSIX systems, uses standard stat.
/// On Windows, uses file index with volume serial as device ID.
fn getInodeKeyFromDir(dir: std.fs.Dir) ?InodeKey {
    if (comptime builtin.os.tag == .linux) {
        // Use fstat on the directory handle
        var stx = std.mem.zeroes(linux.Statx);
        const rc = linux.statx(
            dir.fd,
            "",
            linux.AT.EMPTY_PATH,
            linux.STATX_INO,
            &stx,
        );
        if (linux.E.init(rc) != .SUCCESS) {
            return null;
        }
        const dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
        return .{ .dev = dev, .inode = stx.ino };
    } else if (comptime builtin.os.tag == .windows) {
        const stat = dir.stat() catch return null;
        // Try to get volume serial number for proper device tracking
        const dev = getWindowsVolumeSerialFromDir(dir) orelse 0;
        return .{ .dev = dev, .inode = stat.inode };
    } else {
        const st = posix.fstat(dir.fd) catch return null;
        return .{ .dev = st.dev, .inode = st.ino };
    }
}

/// Get inode key for a path relative to a directory.
fn getInodeKeyForPath(dir: std.fs.Dir, name: []const u8, follow_symlinks: bool) ?InodeKey {
    if (comptime builtin.os.tag == .linux) {
        return getInodeKeyLinux(dir, name, follow_symlinks);
    } else if (comptime builtin.os.tag == .windows) {
        return getInodeKeyWindows(dir, name);
    } else {
        return getInodeKeyPosix(dir, name, follow_symlinks);
    }
}

/// Linux-specific implementation using statx for dev info.
fn getInodeKeyLinux(dir: std.fs.Dir, name: []const u8, follow_symlinks: bool) ?InodeKey {
    const path_c = posix.toPosixPath(name) catch return null;
    var stx = std.mem.zeroes(linux.Statx);

    const flags: u32 = if (follow_symlinks)
        linux.AT.NO_AUTOMOUNT
    else
        linux.AT.NO_AUTOMOUNT | linux.AT.SYMLINK_NOFOLLOW;

    const rc = linux.statx(
        dir.fd,
        &path_c,
        flags,
        linux.STATX_TYPE | linux.STATX_INO,
        &stx,
    );

    if (linux.E.init(rc) != .SUCCESS) {
        return null;
    }

    // Combine dev_major and dev_minor into a single u64
    const dev = (@as(u64, stx.dev_major) << 32) | @as(u64, stx.dev_minor);
    return .{ .dev = dev, .inode = stx.ino };
}

/// Generic POSIX implementation.
fn getInodeKeyPosix(dir: std.fs.Dir, name: []const u8, follow_symlinks: bool) ?InodeKey {
    const flags: u32 = if (follow_symlinks) 0 else posix.AT.SYMLINK_NOFOLLOW;
    const st = posix.fstatat(dir.fd, name, flags) catch return null;
    return .{ .dev = st.dev, .inode = st.ino };
}

/// Windows implementation using file index and volume serial.
fn getInodeKeyWindows(dir: std.fs.Dir, name: []const u8) ?InodeKey {
    const stat = dir.statFile(name) catch return null;
    // Get volume serial number from the file if possible, otherwise from the directory
    const dev = getWindowsVolumeSerial(dir, name) orelse
        getWindowsVolumeSerialFromDir(dir) orelse 0;
    return .{ .dev = dev, .inode = stat.inode };
}

/// Check whether the walker should descend into a directory entry.
///
/// This function handles:
/// - Symlink following based on policy
/// - Cycle detection using the visited set
/// - Broken symlink detection
///
/// Parameters:
/// - dir: The parent directory
/// - name: The entry name to check
/// - policy: Symlink handling policy
/// - visited: Set of already-visited directories (for cycle detection)
///
/// Returns a DescendResult indicating whether to descend and any relevant metadata.
pub fn shouldDescend(
    dir: std.fs.Dir,
    name: []const u8,
    policy: SymlinkPolicy,
    visited: *VisitedSet,
) DescendResult {
    // First, get info without following symlinks to detect symlink type
    const stat_info = lstatPath(dir, name) orelse {
        return .{ .err = error.FileNotFound };
    };

    const is_symlink = stat_info.kind == .sym_link;

    // If not following symlinks, only descend into real directories
    if (!policy.follow_dir_symlinks) {
        if (is_symlink) {
            return .skip;
        }
        if (stat_info.kind != .directory) {
            return .skip;
        }
        // Real directory - use the stat info we already have
        const key = InodeKey{ .dev = stat_info.dev, .inode = stat_info.inode };
        if (visited.contains(key.dev, key.inode)) {
            return .cycle;
        }
        return .{ .descend = key };
    }

    // Following symlinks
    if (is_symlink) {
        // Try to open the symlink target as a directory
        var sub_dir = dir.openDir(name, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound, error.NotDir => if (policy.include_broken_symlinks) .broken else .skip,
                else => .{ .err = err },
            };
        };
        defer sub_dir.close();

        // Get the target's inode key
        const key = getInodeKeyFromDir(sub_dir) orelse {
            return .broken;
        };

        if (visited.contains(key.dev, key.inode)) {
            return .cycle;
        }

        return .{ .descend = key };
    }

    // Not a symlink - check if it's a directory
    if (stat_info.kind != .directory) {
        return .skip;
    }

    // Real directory - use the stat info we already have
    const key = InodeKey{ .dev = stat_info.dev, .inode = stat_info.inode };

    if (visited.contains(key.dev, key.inode)) {
        return .cycle;
    }

    return .{ .descend = key };
}

/// Check if a symlink is broken (target doesn't exist).
pub fn isBrokenSymlink(dir: std.fs.Dir, name: []const u8) bool {
    // First check if it's a symlink using lstat
    const stat_info = lstatPath(dir, name) orelse return false;
    if (stat_info.kind != .sym_link) {
        return false;
    }

    // Try to open the target as directory - if it works, not broken
    if (dir.openDir(name, .{})) |sub_result| {
        var sub = sub_result;
        sub.close();
        return false;
    } else |err| {
        if (err == error.NotDir) {
            // Target exists but is a file, not broken
            if (dir.openFile(name, .{})) |file_result| {
                var file = file_result;
                file.close();
                return false;
            } else |_| {}
        }
    }

    // Could not open target - symlink is broken
    return true;
}

/// Get the effective file kind for an entry based on the policy.
/// Returns the kind after following symlinks if policy requires it.
pub fn getEffectiveKind(
    dir: std.fs.Dir,
    name: []const u8,
    policy: SymlinkPolicy,
) ?std.fs.File.Kind {
    // Use lstat to get info without following symlinks first
    const stat_info = lstatPath(dir, name) orelse return null;

    if (policy.stat_mode == .lstat) {
        return stat_info.kind;
    }

    // stat mode - follow symlinks if it's a symlink
    if (stat_info.kind != .sym_link) {
        return stat_info.kind;
    }

    // It's a symlink - try to determine target kind
    if (dir.openDir(name, .{})) |sub_result| {
        var sub = sub_result;
        sub.close();
        return .directory;
    } else |_| {}

    if (dir.openFile(name, .{})) |file_result| {
        var file = file_result;
        file.close();
        return .file;
    } else |_| {}

    return null; // Broken symlink
}

// ============================================================================
// Tests
// ============================================================================

test "VisitedSet basic operations" {
    const allocator = std.testing.allocator;
    var visited = VisitedSet.init(allocator);
    defer visited.deinit();

    // Empty set shouldn't contain anything
    try std.testing.expect(!visited.contains(1, 100));
    try std.testing.expect(!visited.contains(1, 200));
    try std.testing.expectEqual(@as(usize, 0), visited.count());

    // Add entries
    try visited.put(1, 100);
    try visited.put(1, 200);
    try visited.put(2, 100);

    try std.testing.expect(visited.contains(1, 100));
    try std.testing.expect(visited.contains(1, 200));
    try std.testing.expect(visited.contains(2, 100));
    try std.testing.expect(!visited.contains(2, 200));
    try std.testing.expectEqual(@as(usize, 3), visited.count());

    // Remove entry
    visited.remove(1, 200);
    try std.testing.expect(!visited.contains(1, 200));
    try std.testing.expect(visited.contains(1, 100));
    try std.testing.expectEqual(@as(usize, 2), visited.count());

    // Clear all
    visited.clear();
    try std.testing.expect(!visited.contains(1, 100));
    try std.testing.expectEqual(@as(usize, 0), visited.count());
}

test "VisitedSet duplicate insertions" {
    const allocator = std.testing.allocator;
    var visited = VisitedSet.init(allocator);
    defer visited.deinit();

    // Insert same entry twice - should not increase count
    try visited.put(1, 100);
    try visited.put(1, 100);
    try std.testing.expectEqual(@as(usize, 1), visited.count());
}

test "InodeKey equality and hashing" {
    const k1 = InodeKey{ .dev = 1, .inode = 100 };
    const k2 = InodeKey{ .dev = 1, .inode = 100 };
    const k3 = InodeKey{ .dev = 1, .inode = 200 };
    const k4 = InodeKey{ .dev = 2, .inode = 100 };

    // Equality
    try std.testing.expect(InodeKey.eql(k1, k2));
    try std.testing.expect(!InodeKey.eql(k1, k3));
    try std.testing.expect(!InodeKey.eql(k1, k4));

    // Hash consistency
    try std.testing.expectEqual(InodeKey.hash(k1), InodeKey.hash(k2));
    // Different keys should (likely) have different hashes
    try std.testing.expect(InodeKey.hash(k1) != InodeKey.hash(k3) or InodeKey.hash(k1) != InodeKey.hash(k4));
}

test "SymlinkPolicy defaults" {
    const default_policy = SymlinkPolicy{};
    try std.testing.expect(!default_policy.follow_dir_symlinks);
    try std.testing.expect(default_policy.include_broken_symlinks);
    try std.testing.expectEqual(StatMode.lstat, default_policy.stat_mode);
}

test "SymlinkPolicy presets" {
    const follow = SymlinkPolicy.followSymlinks();
    try std.testing.expect(follow.follow_dir_symlinks);
    try std.testing.expectEqual(StatMode.stat, follow.stat_mode);

    const no_follow = SymlinkPolicy.noFollow();
    try std.testing.expect(!no_follow.follow_dir_symlinks);
    try std.testing.expectEqual(StatMode.lstat, no_follow.stat_mode);
}

test "shouldDescend with real filesystem" {
    // Skip on Windows: Creating symlinks requires elevated privileges (Administrator)
    // or Developer Mode enabled. The functionality works on Windows when symlinks
    // exist, but we cannot reliably test it without special permissions.
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;

    // Create a temporary directory structure for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test structure:
    // tmp/
    //   real_dir/
    //   real_file.txt
    //   link_to_dir -> real_dir (symlink)
    //   link_to_file -> real_file.txt (symlink)
    //   broken_link -> nonexistent (broken symlink)

    // Create real directory
    try tmp_dir.dir.makeDir("real_dir");

    // Create real file
    const file = try tmp_dir.dir.createFile("real_file.txt", .{});
    file.close();

    // Create symlinks (need flags argument in Zig 0.15+)
    try tmp_dir.dir.symLink("real_dir", "link_to_dir", .{ .is_directory = true });
    try tmp_dir.dir.symLink("real_file.txt", "link_to_file", .{});
    try tmp_dir.dir.symLink("nonexistent", "broken_link", .{});

    // Test 1: Real directory with no-follow policy
    {
        var visited = VisitedSet.init(allocator);
        defer visited.deinit();

        const result = shouldDescend(tmp_dir.dir, "real_dir", SymlinkPolicy.noFollow(), &visited);
        switch (result) {
            .descend => |key| {
                try std.testing.expect(key.inode != 0);
            },
            else => return error.UnexpectedResult,
        }
    }

    // Test 2: Symlink to directory with no-follow policy (should skip)
    {
        var visited = VisitedSet.init(allocator);
        defer visited.deinit();

        const result = shouldDescend(tmp_dir.dir, "link_to_dir", SymlinkPolicy.noFollow(), &visited);
        try std.testing.expectEqual(DescendResult.skip, result);
    }

    // Test 3: Symlink to directory with follow policy (should descend)
    {
        var visited = VisitedSet.init(allocator);
        defer visited.deinit();

        const result = shouldDescend(tmp_dir.dir, "link_to_dir", SymlinkPolicy.followSymlinks(), &visited);
        switch (result) {
            .descend => |key| {
                try std.testing.expect(key.inode != 0);
            },
            else => return error.UnexpectedResult,
        }
    }

    // Test 4: Real file (should skip - not a directory)
    {
        var visited = VisitedSet.init(allocator);
        defer visited.deinit();

        const result = shouldDescend(tmp_dir.dir, "real_file.txt", SymlinkPolicy.noFollow(), &visited);
        try std.testing.expectEqual(DescendResult.skip, result);
    }

    // Test 5: Broken symlink with include_broken policy
    {
        var visited = VisitedSet.init(allocator);
        defer visited.deinit();

        const policy = SymlinkPolicy{
            .follow_dir_symlinks = true,
            .include_broken_symlinks = true,
            .stat_mode = .stat,
        };
        const result = shouldDescend(tmp_dir.dir, "broken_link", policy, &visited);
        try std.testing.expectEqual(DescendResult.broken, result);
    }

    // Test 6: Broken symlink with exclude_broken policy
    {
        var visited = VisitedSet.init(allocator);
        defer visited.deinit();

        const policy = SymlinkPolicy{
            .follow_dir_symlinks = true,
            .include_broken_symlinks = false,
            .stat_mode = .stat,
        };
        const result = shouldDescend(tmp_dir.dir, "broken_link", policy, &visited);
        try std.testing.expectEqual(DescendResult.skip, result);
    }
}

test "cycle detection" {
    // Skip on Windows: Requires symlink creation privileges
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;

    // Create a temporary directory with a cyclic symlink
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a directory
    try tmp_dir.dir.makeDir("dir_a");

    // Get the inode of dir_a
    var visited = VisitedSet.init(allocator);
    defer visited.deinit();

    const result1 = shouldDescend(tmp_dir.dir, "dir_a", SymlinkPolicy.followSymlinks(), &visited);
    const key = switch (result1) {
        .descend => |k| k,
        else => return error.UnexpectedResult,
    };

    // Mark as visited
    try visited.put(key.dev, key.inode);

    // Now trying to descend into the same directory should detect a cycle
    const result2 = shouldDescend(tmp_dir.dir, "dir_a", SymlinkPolicy.followSymlinks(), &visited);
    try std.testing.expectEqual(DescendResult.cycle, result2);
}

test "cycle detection with symlink loop" {
    // Skip on Windows: Requires symlink creation privileges
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a directory structure with a symlink cycle:
    // dir_a/
    //   link_to_parent -> ../ (symlink pointing to parent)
    try tmp_dir.dir.makeDir("dir_a");

    // Open dir_a to create the symlink inside it
    var dir_a = try tmp_dir.dir.openDir("dir_a", .{});
    defer dir_a.close();

    try dir_a.symLink("..", "link_to_parent", .{ .is_directory = true });

    var visited = VisitedSet.init(allocator);
    defer visited.deinit();

    // First, mark the tmp_dir as visited (we're traversing from there)
    const tmp_key = getInodeKeyFromDir(tmp_dir.dir) orelse return error.UnexpectedResult;
    try visited.put(tmp_key.dev, tmp_key.inode);

    // Visit dir_a
    const result1 = shouldDescend(tmp_dir.dir, "dir_a", SymlinkPolicy.followSymlinks(), &visited);
    switch (result1) {
        .descend => |key| {
            try visited.put(key.dev, key.inode);
        },
        else => return error.UnexpectedResult,
    }

    // Now following link_to_parent should detect the cycle
    const result2 = shouldDescend(dir_a, "link_to_parent", SymlinkPolicy.followSymlinks(), &visited);
    try std.testing.expectEqual(DescendResult.cycle, result2);
}

test "isBrokenSymlink" {
    // Skip on Windows: Requires symlink creation privileges
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file = try tmp_dir.dir.createFile("real_file.txt", .{});
    file.close();

    try tmp_dir.dir.symLink("real_file.txt", "valid_link", .{});
    try tmp_dir.dir.symLink("nonexistent", "broken_link", .{});

    // Regular file is not a broken symlink
    try std.testing.expect(!isBrokenSymlink(tmp_dir.dir, "real_file.txt"));

    // Valid symlink is not broken
    try std.testing.expect(!isBrokenSymlink(tmp_dir.dir, "valid_link"));

    // Broken symlink should be detected
    try std.testing.expect(isBrokenSymlink(tmp_dir.dir, "broken_link"));

    // Non-existent entry
    try std.testing.expect(!isBrokenSymlink(tmp_dir.dir, "nonexistent"));
}

test "getEffectiveKind" {
    // Skip on Windows: Requires symlink creation privileges
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test structure
    const file = try tmp_dir.dir.createFile("real_file.txt", .{});
    file.close();
    try tmp_dir.dir.makeDir("real_dir");
    try tmp_dir.dir.symLink("real_file.txt", "link_to_file", .{});
    try tmp_dir.dir.symLink("real_dir", "link_to_dir", .{ .is_directory = true });

    // With lstat - should see symlinks as symlinks
    const lstat_policy = SymlinkPolicy{ .stat_mode = .lstat };

    try std.testing.expectEqual(std.fs.File.Kind.file, getEffectiveKind(tmp_dir.dir, "real_file.txt", lstat_policy).?);
    try std.testing.expectEqual(std.fs.File.Kind.directory, getEffectiveKind(tmp_dir.dir, "real_dir", lstat_policy).?);
    try std.testing.expectEqual(std.fs.File.Kind.sym_link, getEffectiveKind(tmp_dir.dir, "link_to_file", lstat_policy).?);
    try std.testing.expectEqual(std.fs.File.Kind.sym_link, getEffectiveKind(tmp_dir.dir, "link_to_dir", lstat_policy).?);

    // With stat - should see symlink targets
    const stat_policy = SymlinkPolicy{ .stat_mode = .stat };

    try std.testing.expectEqual(std.fs.File.Kind.file, getEffectiveKind(tmp_dir.dir, "real_file.txt", stat_policy).?);
    try std.testing.expectEqual(std.fs.File.Kind.directory, getEffectiveKind(tmp_dir.dir, "real_dir", stat_policy).?);
    try std.testing.expectEqual(std.fs.File.Kind.file, getEffectiveKind(tmp_dir.dir, "link_to_file", stat_policy).?);
    try std.testing.expectEqual(std.fs.File.Kind.directory, getEffectiveKind(tmp_dir.dir, "link_to_dir", stat_policy).?);
}
