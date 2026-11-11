//! Compares bufzilla with other Zig serialization libraries on the same data.
//!
//!     zig build run -Doptimize=ReleaseFast -- [--csv] [--quick] [--filter=<library>]
//!
//! For each dataset (see `data.zig`) and library, this measures:
//!   - size:   bytes of the encoding.
//!   - encode: the library's in-memory representation to bytes, into a preallocated buffer. That
//!             representation (Zig structs for most, a Payload tree for zig-msgpack, message
//!             structs for protobuf) is built beforehand and not timed.
//!   - decode: bytes to values, then reading every value (a checksum over all of them).
//!   - access: reading one field (`Kind.accessPath`) from the bytes.
//! Each library is used the way its documentation suggests; libraries that allocate get an arena
//! that is reset before every operation, so the system allocator is not measured.
//!
//! Before measuring, each library's decode must reproduce the dataset's checksum and its access must
//! return the expected value, which shows that every library does the same, complete work.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const data = @import("data.zig");

const Io = std.Io;

const libraries = .{
    @import("libs/bufzilla.zig"),
    @import("libs/zbor.zig"),
    @import("libs/msgpack.zig"),
    @import("libs/protobuf.zig"),
    @import("libs/std_json.zig"),
};

const kinds = [_]data.Kind{ .person, .people, .embedding };

const Op = enum { encode, decode, access };

fn Bench(comptime Lib: type, comptime kind: data.Kind, comptime op: Op) type {
    return struct {
        state: *Lib.State,
        input: []const u8,
        output: []u8,

        pub fn run(self: *@This()) !void {
            switch (op) {
                .encode => {
                    var out = Io.Writer.fixed(self.output);
                    try Lib.encode(self.state, kind, &out);
                    std.mem.doNotOptimizeAway(out.end);
                },
                .decode => std.mem.doNotOptimizeAway(try Lib.decode(self.state, kind, self.input)),
                .access => std.mem.doNotOptimizeAway(try Lib.access(self.state, kind, self.input)),
            }
        }
    };
}

const Measured = struct {
    size: usize,
    results: [3]?harness.Result,
};

fn measureLibrary(
    comptime Lib: type,
    comptime kind: data.Kind,
    io: Io,
    gpa: std.mem.Allocator,
    dataset: *const data.Data,
    buffers: *[2][]u8,
    options: harness.Options,
) !Measured {
    var state = try Lib.State.init(gpa, dataset);
    defer state.deinit();

    // Encode once for the input of decode and access, and check that the library round-trips.
    var out = Io.Writer.fixed(buffers[0]);
    try Lib.encode(&state, kind, &out);
    const encoded = out.buffered();
    if (try Lib.decode(&state, kind, encoded) != dataset.checksum(kind)) {
        std.debug.print("{s}: decoding {s} does not reproduce the data\n", .{ Lib.name, @tagName(kind) });
        return error.ChecksumMismatch;
    }
    const field = try Lib.access(&state, kind, encoded);
    if (!field.eql(dataset.accessed(kind))) {
        std.debug.print("{s}: {s} in {s} returned {any}\n", .{ Lib.name, kind.accessPath(), @tagName(kind), field });
        return error.WrongAccessResult;
    }

    var measured: Measured = .{ .size = encoded.len, .results = @splat(null) };
    inline for (.{ Op.encode, Op.decode, Op.access }, 0..) |op, i| {
        if (op != .encode or Lib.reports_encode) {
            var bench: Bench(Lib, kind, op) = .{ .state = &state, .input = encoded, .output = buffers[1] };
            measured.results[i] = try harness.measure(io, &bench, Bench(Lib, kind, op).run, options);
        }
    }
    return measured;
}

fn printCell(out: *Io.Writer, result: ?harness.Result, reference: ?harness.Result) Io.Writer.Error!void {
    const r = result orelse return out.print("  {s:<20}", .{"-"});
    var time_buf: [32]u8 = undefined;
    var cell_buf: [64]u8 = undefined;
    const time = harness.formatTime(&time_buf, r.median_ns);
    const cell = if (reference) |ref|
        std.fmt.bufPrint(&cell_buf, "{s} ({d:.1}x)", .{ time, r.median_ns / ref.median_ns }) catch unreachable
    else
        time;
    try out.print("  {s:<20}", .{cell});
}

pub fn main(init: std.process.Init) !void {
    const args = try harness.Args.parse(init);
    const options = args.options();
    const gpa = init.gpa;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const dataset = try data.generate(arena.allocator());

    var buffers: [2][]u8 = undefined;
    for (&buffers) |*b| b.* = try gpa.alloc(u8, 4 << 20);
    defer for (buffers) |b| gpa.free(b);

    // Results go to stdout, so that `--csv > results.csv` captures them; errors go to stderr.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;

    harness.warmUpCpu(init.io);
    if (args.csv) {
        try out.print("dataset,library,format,size,operation,median_ns,min_ns,spread,mib_per_s\n", .{});
    } else {
        try out.print("\nZig serialization libraries on the same data ({s}, {s}-{s}, {s})\n", .{ @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), builtin.cpu.model.name });
        try out.print("time per operation: median of {d} samples; (Nx) = time relative to bufzilla\n", .{options.samples});
    }

    inline for (kinds) |kind| {
        if (!args.csv) {
            try out.print("\n{s}: {s}\n  {s:<14} {s:<12} {s:>9}  {s:<20}  {s:<20}  {s:<20}\n", .{
                @tagName(kind),                          kind.description(), "library", "format", "size", "encode", "decode (all values)",
                "access " ++ comptime kind.accessPath(),
            });
        }
        try out.flush();
        var reference: ?Measured = null;
        inline for (libraries) |Lib| {
            if (args.selected(Lib.name)) {
                const m = try measureLibrary(Lib, kind, init.io, gpa, &dataset, &buffers, options);
                if (reference == null and std.mem.eql(u8, Lib.name, "bufzilla")) reference = m;
                if (args.csv) {
                    inline for (.{ "encode", "decode", "access" }, 0..) |op_name, i| {
                        if (m.results[i]) |r| {
                            try out.print("{s},{s},{s},{d},{s},{d:.1},{d:.1},{d:.3},{d:.1}\n", .{ @tagName(kind), Lib.name, Lib.format, m.size, op_name, r.median_ns, r.min_ns, r.spread, r.mibPerSec(m.size) });
                        }
                    }
                } else {
                    try out.print("  {s:<14} {s:<12} {d:>7} B", .{ Lib.name, Lib.format, m.size });
                    const is_reference = std.mem.eql(u8, Lib.name, "bufzilla");
                    for (m.results, 0..) |r, i| try printCell(out, r, if (is_reference or reference == null) null else reference.?.results[i]);
                    try out.writeAll("\n");
                }
                try out.flush();
            }
        }
    }

    if (!args.csv) {
        try out.writeAll("\nHow each library is used:\n");
        inline for (libraries) |Lib| try out.print("  {s}: {s}.\n", .{ Lib.name, Lib.strategy });
    }
    try out.flush();
}
