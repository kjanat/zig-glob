const std = @import("std");

const release_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = b.option(bool, "release", "Build all release targets") orelse false;

    const mod = b.addModule("zig_glob", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    if (release) {
        for (release_targets) |t| {
            const exe_name = std.fmt.allocPrint(b.allocator, "zig-glob-{s}-{s}", .{
                @tagName(t.cpu_arch.?),
                @tagName(t.os_tag.?),
            }) catch @panic("OOM");
            const release_exe = b.addExecutable(.{
                .name = exe_name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = b.resolveTargetQuery(t),
                    .optimize = .ReleaseSafe,
                    .imports = &.{
                        .{ .name = "zig_glob", .module = mod },
                        .{ .name = "build_options", .module = options.createModule() },
                    },
                }),
            });
            b.installArtifact(release_exe);
        }
    } else {
        // Normal single-target build
        const exe = b.addExecutable(.{
            .name = "zig-glob",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zig_glob", .module = mod },
                    .{ .name = "build_options", .module = options.createModule() },
                },
            }),
        });
        b.installArtifact(exe);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
}
