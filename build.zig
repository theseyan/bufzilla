const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zbuffers = b.addModule("zbuffers", .{ .root_source_file = b.path("src/lib.zig") });

    // Unit tests
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("zbuffers", zbuffers);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_exe_unit_tests.step);
}
