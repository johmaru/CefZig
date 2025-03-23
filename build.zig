const std = @import("std");


pub fn build(b: *std.Build) void {
  
    const target = b.standardTargetOptions(.{});

    
    const optimize = b.standardOptimizeOption(.{});

    const websocket_mod = b.addModule("websocket", .{
        .root_source_file = b.path("websocket.zig/src/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });


    exe_mod.addImport("websocket", websocket_mod);

    const exe = b.addExecutable(.{
        .name = "CefZig",
        .root_module = exe_mod,
    });

    // Using LibCurl

    exe.linkSystemLibrary2("curl", .{ .preferred_link_mode = .static, });
    exe.linkLibC();

    b.installArtifact(exe);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    exe_unit_tests.linkSystemLibrary2("curl", .{ .preferred_link_mode = .static, });
    exe_unit_tests.linkLibC();

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
