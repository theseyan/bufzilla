//! Comparison benchmarks against other Zig serialization libraries. A separate package, so that
//! bufzilla itself does not depend on them.
//!
//!     cd bench/compare && zig build run -Doptimize=ReleaseFast
//!
//! To update the README's chart (misc/bench-{light,dark}.svg) and tables from a run:
//!
//!     zig build run -Doptimize=ReleaseFast -- --csv > results.csv
//!     zig build chart -- results.csv ../../misc --machine="<machine>"

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_options = .{ .target = target, .optimize = optimize };

    const bufzilla = b.dependency("bufzilla", dep_options);
    const exe = b.addExecutable(.{
        .name = "bufzilla-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bufzilla", .module = bufzilla.module("bufzilla") },
                .{ .name = "harness", .module = b.createModule(.{ .root_source_file = bufzilla.path("bench/harness.zig") }) },
                .{ .name = "zbor", .module = b.dependency("zbor", dep_options).module("zbor") },
                .{ .name = "msgpack", .module = b.dependency("msgpack", dep_options).module("msgpack") },
                .{ .name = "protobuf", .module = b.dependency("protobuf", dep_options).module("protobuf") },
            },
        }),
        // Every library is compiled the same way; LLVM is also required on aarch64.
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the comparison benchmarks").dependOn(&run.step);

    // Renders results (from `run -- --csv`) as the README's chart and tables; see `src/chart.zig`.
    const chart = b.addExecutable(.{
        .name = "bufzilla-compare-chart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/chart.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    const run_chart = b.addRunArtifact(chart);
    run_chart.addPassthruArgs();
    // Paths given to the chart tool are relative to this directory.
    run_chart.setCwd(b.path("."));
    b.step("chart", "Render benchmark results as the README's chart and tables").dependOn(&run_chart.step);
}
