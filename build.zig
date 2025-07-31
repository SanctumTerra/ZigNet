const std = @import("std");

const targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("Raknet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Todo! Make this a direct import instead
    const binarystream_dep = b.dependency("BinaryStream", .{});
    mod.addImport("BinaryStream", binarystream_dep.module("BinaryStream"));

    const exe = b.addExecutable(.{
        .name = "Raknet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Raknet", .module = mod },
            },
        }),
    });
    // exe.addModule("network", b.dependency("network", .{}).module("network"));

    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ws2_32"); // For windows sockets.
        mod.linkSystemLibrary("ws2_32", .{});
    }
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Cross-platform builds
    const build_all_step = b.step("build-all", "Build for all target platforms");

    for (targets) |query| {
        const resolved_target = b.resolveTargetQuery(query);

        // Create module for this target
        const target_mod = b.addModule(b.fmt("Raknet-{s}-{s}", .{ @tagName(query.cpu_arch.?), @tagName(query.os_tag.?) }), .{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved_target,
        });
        target_mod.addImport("BinaryStream", binarystream_dep.module("BinaryStream"));

        // Create executable for this target
        const target_exe = b.addExecutable(.{
            .name = b.fmt("Raknet-{s}-{s}", .{ @tagName(query.cpu_arch.?), @tagName(query.os_tag.?) }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "Raknet", .module = target_mod },
                },
            }),
        });

        // Link Windows sockets if needed
        if (query.os_tag == .windows) {
            target_exe.linkSystemLibrary("ws2_32");
            target_mod.linkSystemLibrary("ws2_32", .{});
        }

        const install_target = b.addInstallArtifact(target_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("bin/{s}-{s}", .{ @tagName(query.cpu_arch.?), @tagName(query.os_tag.?) }) } },
        });

        build_all_step.dependOn(&install_target.step);
    }
}
