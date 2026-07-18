const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bufzilla = b.addModule("bufzilla", .{ .root_source_file = b.path("src/lib.zig") });

    // Whether to use self-hosted backend
    const no_llvm = b.option(bool, "no-llvm", "don't use LLVM and LLD") orelse false;

    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .imports = &.{.{ .name = "bufzilla", .module = bufzilla }},
        .target = target,
        .optimize = optimize,
    });

    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "bufzilla",
        .root_module = c_api_module,
        .use_lld = !no_llvm and target.result.os.tag != .macos,
        .use_llvm = !no_llvm,
    });

    const dynamic_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "bufzilla",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .imports = &.{.{ .name = "bufzilla", .module = bufzilla }},
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = !no_llvm and target.result.os.tag != .macos,
        .use_llvm = !no_llvm,
    });

    b.installArtifact(static_lib);
    b.installArtifact(dynamic_lib);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("include/bufzilla.h"), .header, "bufzilla.h").step);

    // Unit tests
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .imports = &.{
                .{ .name = "bufzilla", .module = bufzilla },
                .{ .name = "bufzilla_c", .module = b.createModule(.{
                    .root_source_file = b.path("src/c_api.zig"),
                    .imports = &.{.{ .name = "bufzilla", .module = bufzilla }},
                }) },
            },
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = !no_llvm and target.result.os.tag != .macos,
        .use_llvm = !no_llvm,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const c_api_smoke = b.addExecutable(.{
        .name = "bufzilla-c-api-smoke",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_lld = !no_llvm and target.result.os.tag != .macos,
        .use_llvm = !no_llvm,
    });
    c_api_smoke.root_module.addCSourceFile(.{
        .file = b.path("test/c_api_smoke.c"),
        .flags = &.{"-std=c11"},
    });
    c_api_smoke.root_module.addIncludePath(b.path("include"));
    c_api_smoke.root_module.linkLibrary(static_lib);
    test_step.dependOn(&b.addRunArtifact(c_api_smoke).step);

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
