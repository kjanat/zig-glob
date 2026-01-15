const std = @import("std");
const zig_glob = @import("zig_glob");
const build_options = @import("build_options");

const version = build_options.version;

const usage =
    \\Usage: zig-glob [OPTIONS] <PATTERN>... [--] [PATH...]
    \\
    \\Find files matching glob patterns.
    \\
    \\Arguments:
    \\  <PATTERN>...  Glob patterns to match (e.g., '**/*.zig', 'src/*.txt')
    \\  [PATH...]     Base directories to search (default: current directory)
    \\
    \\Options:
    \\  -d, --dot             Match dotfiles with wildcards
    \\  -i, --ignore-case     Case-insensitive matching
    \\  -L, --follow          Follow directory symlinks
    \\  -a, --absolute        Output absolute paths
    \\  -D, --mark-dirs       Append / to directory matches
    \\  -x, --exclude PAT     Exclude files matching PAT (can be repeated)
    \\      --max-depth N     Maximum directory depth (default: unlimited)
    \\
    \\  -t, --type TYPE       Filter by type: f=files, d=directories, a=all (default)
    \\
    \\  -0, --null            Null-terminated output (for xargs -0)
    \\  -c, --count           Only print match count
    \\  -q, --quiet           Quiet mode: exit 0 if matches found, 1 otherwise
    \\
    \\  -h, --help            Show this help message
    \\  -V, --version         Show version
    \\
    \\Examples:
    \\  zig-glob '**/*.zig'                    Find all Zig files
    \\  zig-glob '*.txt' -d                    Find .txt files including dotfiles
    \\  zig-glob -t f '**/*' -x '**/node_modules/**'
    \\                                         Find all files, excluding node_modules
    \\  zig-glob '*.{c,h}' src/                Find C source/header files in src/
    \\  zig-glob -0 '**/*.log' | xargs -0 rm   Delete all log files
    \\
;

const CliOptions = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayListUnmanaged([]const u8) = .empty,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,
    exclude: std.ArrayListUnmanaged([]const u8) = .empty,
    dot: bool = false,
    nocase: bool = false,
    follow: bool = false,
    absolute: bool = false,
    mark_dirs: bool = false,
    max_depth: ?u32 = null,
    type_filter: zig_glob.EntryTypeFilter = .all,
    null_sep: bool = false,
    count_only: bool = false,
    quiet: bool = false,
    show_help: bool = false,
    show_version: bool = false,

    fn deinit(self: *CliOptions) void {
        self.patterns.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.exclude.deinit(self.allocator);
    }
};

const ParseError = error{
    MissingArgument,
    InvalidArgument,
    UnknownOption,
};

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !CliOptions {
    var opts = CliOptions{ .allocator = allocator };
    errdefer opts.deinit();

    var i: usize = 1; // Skip program name
    var after_separator = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // After --, everything is a path
        if (after_separator) {
            try opts.paths.append(allocator, arg);
            continue;
        }

        // Separator
        if (std.mem.eql(u8, arg, "--")) {
            after_separator = true;
            continue;
        }

        // Long options
        if (std.mem.startsWith(u8, arg, "--")) {
            const opt = arg[2..];

            if (std.mem.eql(u8, opt, "help")) {
                opts.show_help = true;
            } else if (std.mem.eql(u8, opt, "version")) {
                opts.show_version = true;
            } else if (std.mem.eql(u8, opt, "dot")) {
                opts.dot = true;
            } else if (std.mem.eql(u8, opt, "ignore-case")) {
                opts.nocase = true;
            } else if (std.mem.eql(u8, opt, "follow")) {
                opts.follow = true;
            } else if (std.mem.eql(u8, opt, "absolute")) {
                opts.absolute = true;
            } else if (std.mem.eql(u8, opt, "mark-dirs")) {
                opts.mark_dirs = true;
            } else if (std.mem.eql(u8, opt, "null")) {
                opts.null_sep = true;
            } else if (std.mem.eql(u8, opt, "count")) {
                opts.count_only = true;
            } else if (std.mem.eql(u8, opt, "quiet")) {
                opts.quiet = true;
            } else if (std.mem.eql(u8, opt, "exclude")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                try opts.exclude.append(allocator, args[i]);
            } else if (std.mem.eql(u8, opt, "max-depth")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                opts.max_depth = std.fmt.parseInt(u32, args[i], 10) catch return ParseError.InvalidArgument;
            } else if (std.mem.eql(u8, opt, "type")) {
                i += 1;
                if (i >= args.len) return ParseError.MissingArgument;
                opts.type_filter = parseTypeFilter(args[i]) orelse return ParseError.InvalidArgument;
            } else {
                return ParseError.UnknownOption;
            }
            continue;
        }

        // Short options
        if (arg.len > 1 and arg[0] == '-') {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];
                switch (c) {
                    'h' => opts.show_help = true,
                    'V' => opts.show_version = true,
                    'd' => opts.dot = true,
                    'i' => opts.nocase = true,
                    'L' => opts.follow = true,
                    'a' => opts.absolute = true,
                    'D' => opts.mark_dirs = true,
                    '0' => opts.null_sep = true,
                    'c' => opts.count_only = true,
                    'q' => opts.quiet = true,
                    'x' => {
                        // -x requires argument
                        if (j + 1 < arg.len) {
                            // Rest of arg is the value: -xPATTERN
                            try opts.exclude.append(allocator, arg[j + 1 ..]);
                            break;
                        } else {
                            // Next arg is the value: -x PATTERN
                            i += 1;
                            if (i >= args.len) return ParseError.MissingArgument;
                            try opts.exclude.append(allocator, args[i]);
                        }
                    },
                    't' => {
                        // -t requires argument
                        if (j + 1 < arg.len) {
                            opts.type_filter = parseTypeFilter(arg[j + 1 ..]) orelse return ParseError.InvalidArgument;
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) return ParseError.MissingArgument;
                            opts.type_filter = parseTypeFilter(args[i]) orelse return ParseError.InvalidArgument;
                        }
                    },
                    else => return ParseError.UnknownOption,
                }
            }
            continue;
        }

        // Positional argument - pattern or path
        // First positional args are patterns, until we see something that looks like a path
        // Heuristic: if it contains no glob chars and exists as a directory, treat as path
        if (opts.patterns.items.len == 0 or hasGlobChars(arg)) {
            try opts.patterns.append(allocator, arg);
        } else {
            // Could be a pattern or a path - check if it's a directory
            var dir = std.fs.cwd().openDir(arg, .{}) catch {
                // Not a directory, treat as pattern
                try opts.patterns.append(allocator, arg);
                continue;
            };
            dir.close();
            try opts.paths.append(allocator, arg);
        }
    }

    return opts;
}

fn parseTypeFilter(s: []const u8) ?zig_glob.EntryTypeFilter {
    if (s.len == 0) return null;
    return switch (s[0]) {
        'f' => .files_only,
        'd' => .directories_only,
        'a' => .all,
        else => null,
    };
}

fn hasGlobChars(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '*', '?', '[', '{' => return true,
            else => {},
        }
    }
    return false;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stderr = std.fs.File.stderr();
    const stdout = std.fs.File.stdout();

    var opts = parseArgs(allocator, args) catch |err| {
        switch (err) {
            ParseError.MissingArgument => stderr.writeAll("Error: Missing argument for option\n") catch {},
            ParseError.InvalidArgument => stderr.writeAll("Error: Invalid argument\n") catch {},
            ParseError.UnknownOption => stderr.writeAll("Error: Unknown option\n") catch {},
            else => stderr.writeAll("Error: Failed to parse arguments\n") catch {},
        }
        stderr.writeAll("Try 'zig-glob --help' for more information.\n") catch {};
        std.process.exit(2);
    };
    defer opts.deinit();

    // Handle help/version
    if (opts.show_help) {
        stdout.writeAll(usage) catch {};
        return;
    }

    if (opts.show_version) {
        stdout.writeAll("zig-glob " ++ version ++ "\n") catch {};
        return;
    }

    // Require at least one pattern
    if (opts.patterns.items.len == 0) {
        stderr.writeAll("Error: No pattern specified\n") catch {};
        stderr.writeAll("Try 'zig-glob --help' for more information.\n") catch {};
        std.process.exit(2);
    }

    // Default path is current directory
    const paths = if (opts.paths.items.len > 0) opts.paths.items else &[_][]const u8{"."};

    // Separator for output
    const sep: []const u8 = if (opts.null_sep) "\x00" else "\n";

    var total_count: usize = 0;
    var had_error = false;

    for (paths) |base_path| {
        const glob_opts = zig_glob.GlobOptions{
            .cwd = base_path,
            .dot = opts.dot,
            .nocase = opts.nocase,
            .follow_dir_symlinks = opts.follow,
            .absolute = opts.absolute,
            .mark_directories = opts.mark_dirs,
            .max_depth = opts.max_depth,
            .types = opts.type_filter,
            .exclude = if (opts.exclude.items.len > 0) opts.exclude.items else null,
        };

        var iter = zig_glob.glob(allocator, opts.patterns.items, glob_opts) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: Failed to glob '{s}': {}\n", .{ base_path, err }) catch "Error: Failed to glob\n";
            stderr.writeAll(msg) catch {};
            had_error = true;
            continue;
        };
        defer iter.deinit();

        while (iter.next() catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error during traversal: {}\n", .{err}) catch "Error during traversal\n";
            stderr.writeAll(msg) catch {};
            had_error = true;
            break;
        }) |entry| {
            defer allocator.free(entry.path);
            total_count += 1;

            if (!opts.quiet and !opts.count_only) {
                stdout.writeAll(entry.path) catch {};
                stdout.writeAll(sep) catch {};
            }
        }
    }

    // Output count if requested
    if (opts.count_only and !opts.quiet) {
        var buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&buf, "{}\n", .{total_count}) catch "?\n";
        stdout.writeAll(count_str) catch {};
    }

    // Exit status
    if (had_error) {
        std.process.exit(2);
    } else if (total_count == 0) {
        std.process.exit(1);
    }
    // Exit 0 on success (implicit)
}
