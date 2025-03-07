const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bufzilla = b.addModule("bufzilla", .{ .root_source_file = b.path("src/lib.zig") });

    // Whether to use self-hosted backend
    const no_llvm = b.option(bool, "no-llvm", "don't use LLVM and LLD") orelse false;

    // Unit tests
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
        .use_lld = !no_llvm,
        .use_llvm = !no_llvm,
    });
    exe_unit_tests.root_module.addImport("bufzilla", bufzilla);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_exe_unit_tests.step);
}
