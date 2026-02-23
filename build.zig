const std = @import("std");
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
        exe.linkSystemLibrary("ws2_32");
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
}
