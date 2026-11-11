//! Benchmark harness: calibrated batches, repeated samples and robust statistics.
//!
//! Timing one call of a nanosecond-scale operation is dominated by clock overhead and noise. Instead,
//! each sample times a batch of iterations long enough (`Options.min_sample_ns`) for the clock to be
//! negligible, and the reported figure is the median over several samples, with the interquartile
//! range as a measure of how stable the result is.

const std = @import("std");
const Io = std.Io;

pub const Options = struct {
    /// Minimum duration of one sample. Iterations per sample are calibrated to reach it.
    min_sample_ns: u64 = 5 * std.time.ns_per_ms,
    /// Number of timed samples.
    samples: usize = 15,
    /// Untimed samples run first, to warm caches and branch predictors.
    warmup_samples: usize = 2,
};

pub const Result = struct {
    /// Median time per operation.
    median_ns: f64,
    /// Fastest sample's time per operation.
    min_ns: f64,
    /// Interquartile range relative to the median: how much samples vary.
    spread: f64,
    /// Iterations per sample.
    iterations: usize,

    /// Throughput in MiB/s when each operation processes `bytes` bytes.
    pub fn mibPerSec(r: Result, bytes: usize) f64 {
        return @as(f64, @floatFromInt(bytes)) / (r.median_ns / std.time.ns_per_s) / (1024 * 1024);
    }
};

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn timeBatch(io: Io, ctx: anytype, comptime op: anytype, iterations: usize) !u64 {
    const start = now(io);
    for (0..iterations) |_| try op(ctx);
    return @intCast(now(io) - start);
}

/// Measures `op(ctx)`. The operation must consume its results (for example with
/// `std.mem.doNotOptimizeAway`) so that the work cannot be optimized away.
pub fn measure(io: Io, ctx: anytype, comptime op: anytype, options: Options) !Result {
    // Calibrate: grow the batch until one takes at least the minimum sample time.
    var iterations: usize = 1;
    while (true) {
        const elapsed = try timeBatch(io, ctx, op, iterations);
        if (elapsed >= options.min_sample_ns) break;
        // Aim slightly past the target to avoid creeping up in small steps.
        const scale: u64 = if (elapsed == 0) 10 else @max(2, (options.min_sample_ns * 5 / 4) / elapsed);
        iterations *|= std.math.cast(usize, scale) orelse std.math.maxInt(usize);
    }

    for (0..options.warmup_samples) |_| _ = try timeBatch(io, ctx, op, iterations);

    var per_op: [64]f64 = undefined;
    const samples = @min(options.samples, per_op.len);
    for (per_op[0..samples]) |*sample| {
        const elapsed = try timeBatch(io, ctx, op, iterations);
        sample.* = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
    }
    const sorted = per_op[0..samples];
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const median = sorted[samples / 2];
    return .{
        .median_ns = median,
        .min_ns = sorted[0],
        .spread = (sorted[samples * 3 / 4] - sorted[samples / 4]) / median,
        .iterations = iterations,
    };
}

/// Keeps the CPU busy for a while, so that it reaches a steady clock speed before the first
/// measurement instead of ramping up during it.
pub fn warmUpCpu(io: Io) void {
    const start = now(io);
    var x: u64 = 1;
    while (now(io) - start < 300 * std.time.ns_per_ms) {
        for (0..10_000) |i| x = x *% 6364136223846793005 +% i;
    }
    std.mem.doNotOptimizeAway(x);
}

/// Formats a time per operation with a unit suited to its magnitude.
pub fn formatTime(buf: []u8, ns: f64) []const u8 {
    return if (ns < 1_000)
        std.fmt.bufPrint(buf, "{d:.1} ns", .{ns}) catch unreachable
    else if (ns < 1_000_000)
        std.fmt.bufPrint(buf, "{d:.2} us", .{ns / 1_000}) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d:.2} ms", .{ns / 1_000_000}) catch unreachable;
}

/// Command line options shared by the benchmark programs.
pub const Args = struct {
    /// Print comma-separated values instead of a table.
    csv: bool = false,
    /// Only run benchmarks whose name contains this.
    filter: ?[]const u8 = null,
    /// Fewer, shorter samples, for a quick look.
    quick: bool = false,

    /// Parses the process arguments. They are copied into the process arena, which works on every
    /// target (iterating them in place does not on Windows and WASI).
    pub fn parse(init: std.process.Init) !Args {
        var result: Args = .{};
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        for (args[@min(args.len, 1)..]) |arg| {
            if (std.mem.eql(u8, arg, "--csv")) {
                result.csv = true;
            } else if (std.mem.eql(u8, arg, "--quick")) {
                result.quick = true;
            } else if (std.mem.startsWith(u8, arg, "--filter=")) {
                result.filter = arg["--filter=".len..];
            }
        }
        return result;
    }

    pub fn options(args: Args) Options {
        return if (args.quick) .{ .min_sample_ns = std.time.ns_per_ms, .samples = 5, .warmup_samples = 1 } else .{};
    }

    pub fn selected(args: Args, name: []const u8) bool {
        const filter = args.filter orelse return true;
        return std.mem.find(u8, name, filter) != null;
    }
};
