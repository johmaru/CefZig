const std = @import("std");


pub fn build(b: *std.Build) void {
  
    const target = b.standardTargetOptions(.{});

    
    const optimize = b.standardOptimizeOption(.{});

    const websocket_options = b.addOptions();
    websocket_options.addOption(bool, "websocket_blocking", false);

    const websocket_deps = b.allocator.create(std.Build.Module.Import) catch unreachable;
    websocket_deps.* = .{
        .name = "build",
        .module = websocket_options.createModule(),
    };

    const websocket_mod = b.addModule("websocket", .{
        .root_source_file = b.path("websocket.zig/src/websocket.zig"),
        .imports = &[_]std.Build.Module.Import{websocket_deps.*},
    });

    websocket_mod.addOptions("build", websocket_options);

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

    exe.linkLibC();

    b.installArtifact(exe);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}