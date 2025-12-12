const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bufzilla = b.addModule("bufzilla", .{ .root_source_file = b.path("src/lib.zig") });

    // Whether to use self-hosted backend
    const no_llvm = b.option(bool, "no-llvm", "don't use LLVM and LLD") orelse false;

    // Unit tests
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .imports = &.{.{ .name = "bufzilla", .module = bufzilla }},
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = !no_llvm and target.result.os.tag != .macos,
        .use_llvm = !no_llvm,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_exe_unit_tests.step);

    // Benchmarks
    const benchmark = b.addExecutable(.{
        .name = "bufzilla-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .imports = &.{.{ .name = "bufzilla", .module = bufzilla }},
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = !no_llvm and target.result.os.tag != .macos,
        .use_llvm = !no_llvm,
    });

    // Install benchmark binary to zig-out/bin
    b.installArtifact(benchmark);

    const run_benchmark = b.addRunArtifact(benchmark);
    b.step("bench", "Run benchmarks").dependOn(&run_benchmark.step);

    // Large buffer benchmark
    const large_buffer_bench = b.addExecutable(.{
        .name = "bufzilla-bench-large",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/large_buffer.zig"),
            .imports = &.{.{ .name = "bufzilla", .module = bufzilla }},
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = !no_llvm and target.result.os.tag != .macos,
        .use_llvm = !no_llvm,
    });

    b.installArtifact(large_buffer_bench);

    const run_large_bench = b.addRunArtifact(large_buffer_bench);
    b.step("bench-large", "Run large buffer benchmarks").dependOn(&run_large_bench.step);
}
