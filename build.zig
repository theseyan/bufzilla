const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bufzilla = b.addModule("bufzilla", .{ .root_source_file = b.path("src/lib.zig") });

    // Whether to use self-hosted backend
    const no_llvm = b.option(bool, "no-llvm", "don't use LLVM and LLD (ignored on aarch64)") orelse false;

    // The self-hosted aarch64 backend is not ready yet, so always use LLVM there.
    const use_llvm = !no_llvm or target.result.cpu.arch == .aarch64;
    const use_lld = use_llvm and target.result.os.tag != .macos;

    // C API: static and dynamic libraries plus the header.
    const options = b.addOptions();
    options.addOption([]const u8, "version", packageVersion(b));
    const c_api_imports: []const std.Build.Module.Import = &.{
        .{ .name = "bufzilla", .module = bufzilla },
        .{ .name = "build_options", .module = options.createModule() },
    };

    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "bufzilla",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .imports = c_api_imports,
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });

    const dynamic_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "bufzilla",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .imports = c_api_imports,
            .target = target,
            .optimize = optimize,
        }),
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });

    b.installArtifact(static_lib);
    b.installArtifact(dynamic_lib);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("include/bufzilla.h"), .header, "bufzilla.h").step);

    // Unit tests, including the C API called from Zig. `test/c_api_abi.c` is compiled against the
    // header so the tests can check that the Zig ABI types match it.
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .imports = &.{
                .{ .name = "bufzilla", .module = bufzilla },
                .{ .name = "bufzilla_c", .module = b.createModule(.{
                    .root_source_file = b.path("src/c_api.zig"),
                    .imports = c_api_imports,
                }) },
            },
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });
    exe_unit_tests.root_module.addCSourceFile(.{
        .file = b.path("test/c_api_abi.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
    });
    exe_unit_tests.root_module.addIncludePath(b.path("include"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // A C program using the installed header and static library.
    const c_api_smoke = b.addExecutable(.{
        .name = "bufzilla-c-api-smoke",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });
    c_api_smoke.root_module.addCSourceFile(.{
        .file = b.path("test/c_api_smoke.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
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
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });

    // Install benchmark binary to zig-out/bin
    b.installArtifact(benchmark);

    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.addPassthruArgs();
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
        .use_lld = use_lld,
        .use_llvm = use_llvm,
    });

    b.installArtifact(large_buffer_bench);

    const run_large_bench = b.addRunArtifact(large_buffer_bench);
    run_large_bench.addPassthruArgs();
    b.step("bench-large", "Run large buffer benchmarks").dependOn(&run_large_bench.step);
}

/// The package version, read from build.zig.zon so that it is defined in one place.
fn packageVersion(b: *std.Build) []const u8 {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(struct { version: []const u8 }, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = @embedFile("build.zig.zon"),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch @panic("build.zig.zon: cannot read the package version");
    return manifest.version;
}
