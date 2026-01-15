const std = @import("std");
const zig_glob = @import("zig_glob");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.posix.STDERR_FILENO;
        _ = std.posix.write(stderr, "Usage: zig-glob <pattern> [path...]\n") catch {};
        _ = std.posix.write(stderr, "Example: zig-glob '**/*.zig' src/\n") catch {};
        std.process.exit(1);
    }

    const pattern = args[1];
    const paths = if (args.len > 2) args[2..] else &[_][]const u8{"."};

    const stdout = std.posix.STDOUT_FILENO;
    for (paths) |base_path| {
        var iter = try zig_glob.glob(allocator, &.{pattern}, .{ .cwd = base_path });
        defer iter.deinit();

        while (try iter.next()) |entry| {
            defer allocator.free(entry.path);
            _ = std.posix.write(stdout, entry.path) catch {};
            _ = std.posix.write(stdout, "\n") catch {};
        }
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
