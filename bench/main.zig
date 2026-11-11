//! bufzilla micro-benchmarks.
//!
//!     zig build bench -Doptimize=ReleaseFast -- [--csv] [--quick] [--filter=<text>]
//!
//! Each benchmark times only the operation in its name: inputs are built and data to decode is
//! encoded beforehand. Inputs are hidden from the optimizer (`launder`), so encoders work on
//! runtime values rather than constants the compiler could fold. See `harness.zig` for timing.

const std = @import("std");
const bufzilla = @import("bufzilla");
const harness = @import("harness.zig");

const Io = std.Io;
const Writer = bufzilla.Writer;
const Reader = bufzilla.Reader(.{});

/// Returns `value` in a way the optimizer cannot see through.
fn launder(value: anytype) @TypeOf(value) {
    var v = value;
    std.mem.doNotOptimizeAway(&v);
    return v;
}

fn encode(buf: []u8, value: anytype) ![]const u8 {
    var fixed = Io.Writer.fixed(buf);
    var w = Writer.init(&fixed);
    try w.writeAny(value);
    return fixed.buffered();
}

// =============================================================================
// Inputs
// =============================================================================

const medium_string: [300]u8 = @splat('m');
const bytes_32: [32]u8 = @splat(0x42);
const bytes_1k: [1024]u8 = @splat(0x42);

const SimpleStruct = struct {
    id: u64,
    name: []const u8,
    score: f64,
    active: bool,
};

const ComplexStruct = struct {
    id: u64,
    username: []const u8,
    email: []const u8,
    age: u32,
    balance: f64,
    verified: bool,
    tags: []const []const u8,
    address: struct { street: []const u8, city: []const u8, zip: []const u8, country: []const u8 },
    scores: []const i64,
};

const simple_struct: SimpleStruct = .{ .id = 12345, .name = "Alice", .score = 98.5, .active = true };

const complex_struct: ComplexStruct = .{
    .id = 98765,
    .username = "alice_wonder",
    .email = "alice@example.com",
    .age = 34,
    .balance = 12345.67,
    .verified = true,
    .tags = &.{ "admin", "beta", "early-adopter" },
    .address = .{ .street = "221B Baker Street", .city = "London", .zip = "NW1 6XE", .country = "UK" },
    .scores = &.{ 100, 95, 87, 92, 78 },
};

// =============================================================================
// Benchmark cases
//
// A case is a type with `init` (untimed setup), `run` (the timed operation) and `bytes` (the size of
// the encoded data written or read by one operation).
// =============================================================================

/// Writes `value` with `writeAny`.
fn WriteAny(comptime value: anytype) type {
    return struct {
        buf: [4096]u8 = undefined,
        size: usize = 0,

        pub fn init(self: *@This()) !void {
            self.size = (try encode(&self.buf, value)).len;
        }
        pub fn run(self: *@This()) !void {
            var fixed = Io.Writer.fixed(&self.buf);
            var w = Writer.init(&fixed);
            try w.writeAny(launder(value));
            std.mem.doNotOptimizeAway(fixed.end);
        }
        pub fn bytes(self: *const @This()) usize {
            return self.size;
        }
    };
}

/// Reads one encoded `value` with `read`.
fn ReadOne(comptime value: anytype) type {
    return struct {
        buf: [4096]u8 = undefined,
        data: []const u8 = &.{},

        pub fn init(self: *@This()) !void {
            self.data = try encode(&self.buf, value);
        }
        pub fn run(self: *@This()) !void {
            var r = Reader.init(launder(self.data));
            std.mem.doNotOptimizeAway(try r.read());
        }
        pub fn bytes(self: *const @This()) usize {
            return self.data.len;
        }
    };
}

/// Writes an array of the integers 0..len.
fn WriteIntArray(comptime len: usize) type {
    return struct {
        buf: [len * 4 + 8]u8 = undefined,
        size: usize = 0,

        pub fn init(self: *@This()) !void {
            try self.run();
        }
        pub fn run(self: *@This()) !void {
            var fixed = Io.Writer.fixed(&self.buf);
            var w = Writer.init(&fixed);
            try w.startArray();
            for (0..launder(len)) |i| try w.writeAny(@as(i64, @intCast(i)));
            try w.endContainer();
            self.size = fixed.end;
        }
        pub fn bytes(self: *const @This()) usize {
            return self.size;
        }
    };
}

/// Iterates an array of the integers 0..len, summing them.
fn ReadIntArray(comptime len: usize) type {
    return struct {
        buf: [len * 4 + 8]u8 = undefined,
        data: []const u8 = &.{},

        pub fn init(self: *@This()) !void {
            var fixed = Io.Writer.fixed(&self.buf);
            var w = Writer.init(&fixed);
            try w.startArray();
            for (0..len) |i| try w.writeAny(@as(i64, @intCast(i)));
            try w.endContainer();
            self.data = fixed.buffered();
        }
        pub fn run(self: *@This()) !void {
            var r = Reader.init(launder(self.data));
            const array = try r.read();
            var sum: i64 = 0;
            while (try r.iterateArray(array)) |v| sum +%= v.i64;
            std.mem.doNotOptimizeAway(sum);
        }
        pub fn bytes(self: *const @This()) usize {
            return self.data.len;
        }
    };
}

/// Writes 768 elements of `T` as a typed array.
fn WriteTypedArray(comptime T: type) type {
    return struct {
        values: [768]T = @splat(1),
        buf: [768 * @sizeOf(T) + 16]u8 = undefined,
        size: usize = 0,

        pub fn init(self: *@This()) !void {
            try self.run();
        }
        pub fn run(self: *@This()) !void {
            var fixed = Io.Writer.fixed(&self.buf);
            var w = Writer.init(&fixed);
            try w.writeTypedArray(launder(&self.values));
            self.size = fixed.end;
        }
        pub fn bytes(self: *const @This()) usize {
            return self.size;
        }
    };
}

/// Reads (zero-copy) or skips a 768-element f32 typed array.
fn ReadTypedArray(comptime skip: bool) type {
    return struct {
        buf: [768 * 4 + 16]u8 = undefined,
        data: []const u8 = &.{},

        pub fn init(self: *@This()) !void {
            const values: [768]f32 = @splat(1);
            var fixed = Io.Writer.fixed(&self.buf);
            var w = Writer.init(&fixed);
            try w.writeTypedArray(&values);
            self.data = fixed.buffered();
        }
        pub fn run(self: *@This()) !void {
            var r = Reader.init(launder(self.data));
            if (skip) {
                try r.skipValue();
                std.mem.doNotOptimizeAway(r.pos);
            } else {
                std.mem.doNotOptimizeAway(try r.read());
            }
        }
        pub fn bytes(self: *const @This()) usize {
            return self.data.len;
        }
    };
}

/// `len` precomputed keys "key0", "key1", ...
fn Keys(comptime len: usize) type {
    return struct {
        storage: [len][8]u8 = undefined,
        keys: [len][]const u8 = undefined,

        fn init(self: *@This()) !void {
            for (&self.storage, &self.keys, 0..) |*s, *k, i| k.* = try std.fmt.bufPrint(s, "key{d}", .{i});
        }
    };
}

fn writeObject(w: *Writer, keys: []const []const u8) !void {
    try w.startObject();
    for (keys, 0..) |key, i| {
        try w.writeAny(key);
        try w.writeAny(@as(i64, @intCast(i)));
    }
    try w.endContainer();
}

/// Writes an object of `len` integer entries with precomputed keys.
fn WriteObject(comptime len: usize) type {
    return struct {
        keys: Keys(len) = .{},
        buf: [len * 16 + 8]u8 = undefined,
        size: usize = 0,

        pub fn init(self: *@This()) !void {
            try self.keys.init();
            try self.run();
        }
        pub fn run(self: *@This()) !void {
            var fixed = Io.Writer.fixed(&self.buf);
            var w = Writer.init(&fixed);
            try writeObject(&w, launder(&self.keys.keys));
            self.size = fixed.end;
        }
        pub fn bytes(self: *const @This()) usize {
            return self.size;
        }
    };
}

/// Iterates an object of `len` integer entries.
fn ReadObject(comptime len: usize) type {
    return struct {
        keys: Keys(len) = .{},
        buf: [len * 16 + 8]u8 = undefined,
        data: []const u8 = &.{},

        pub fn init(self: *@This()) !void {
            try self.keys.init();
            var fixed = Io.Writer.fixed(&self.buf);
            var w = Writer.init(&fixed);
            try writeObject(&w, &self.keys.keys);
            self.data = fixed.buffered();
        }
        pub fn run(self: *@This()) !void {
            var r = Reader.init(launder(self.data));
            const obj = try r.read();
            var sum: usize = 0;
            while (try r.iterateObject(obj)) |kv| sum +%= kv.key.bytes.len +% @as(usize, @truncate(@as(u64, @bitCast(kv.value.i64))));
            std.mem.doNotOptimizeAway(sum);
        }
        pub fn bytes(self: *const @This()) usize {
            return self.data.len;
        }
    };
}

/// Visits every value of an encoded `value`, recursing into containers.
fn ReadAll(comptime value: anytype) type {
    return struct {
        buf: [4096]u8 = undefined,
        data: []const u8 = &.{},

        pub fn init(self: *@This()) !void {
            self.data = try encode(&self.buf, value);
        }
        fn visit(r: *Reader, v: bufzilla.Value, sum: *u64) !void {
            switch (v) {
                .object => while (try r.iterateObject(v)) |kv| {
                    sum.* +%= kv.key.bytes.len;
                    try visit(r, kv.value, sum);
                },
                .array => while (try r.iterateArray(v)) |item| try visit(r, item, sum),
                .bytes => |b| sum.* +%= b.len,
                .i64 => |n| sum.* +%= @bitCast(n),
                .u64 => |n| sum.* +%= n,
                else => sum.* +%= 1,
            }
        }
        pub fn run(self: *@This()) !void {
            var r = Reader.init(launder(self.data));
            var sum: u64 = 0;
            try visit(&r, try r.read(), &sum);
            std.mem.doNotOptimizeAway(sum);
        }
        pub fn bytes(self: *const @This()) usize {
            return self.data.len;
        }
    };
}

/// Looks up `path` in the encoded `complex_struct`.
fn ReadPath(comptime path: []const u8, comptime expect_found: bool) type {
    return struct {
        buf: [4096]u8 = undefined,
        data: []const u8 = &.{},

        pub fn init(self: *@This()) !void {
            self.data = try encode(&self.buf, complex_struct);
            var r = Reader.init(self.data);
            if ((try r.readPath(path) != null) != expect_found) return error.UnexpectedResult;
        }
        pub fn run(self: *@This()) !void {
            var r = Reader.init(launder(self.data));
            std.mem.doNotOptimizeAway(try r.readPath(launder(path)));
        }
        pub fn bytes(self: *const @This()) usize {
            return self.data.len;
        }
    };
}

/// Looks up all of `paths` in the encoded `complex_struct` with one `readPaths` call.
fn ReadPaths(comptime paths: []const []const u8) type {
    return struct {
        buf: [4096]u8 = undefined,
        data: []const u8 = &.{},
        queries: [paths.len]bufzilla.PathQuery = undefined,

        pub fn init(self: *@This()) !void {
            self.data = try encode(&self.buf, complex_struct);
        }
        pub fn run(self: *@This()) !void {
            for (&self.queries, paths) |*q, p| q.* = .{ .path = p };
            var r = Reader.init(launder(self.data));
            try r.readPaths(launder(&self.queries));
            std.mem.doNotOptimizeAway(&self.queries);
        }
        pub fn bytes(self: *const @This()) usize {
            return self.data.len;
        }
    };
}

/// Applies updates to the encoded `complex_struct`.
fn ApplyUpdates(comptime count: usize) type {
    return struct {
        buf: [4096]u8 = undefined,
        out: [4096]u8 = undefined,
        data: []const u8 = &.{},
        number: i64 = 7,
        text: []const u8 = "updated",

        const paths = [_][]const u8{ "age", "address.city", "scores[2]", "tags[1]", "email", "address.zip", "new.key", "scores[9]" };

        pub fn init(self: *@This()) !void {
            self.data = try encode(&self.buf, complex_struct);
        }
        pub fn run(self: *@This()) !void {
            var updates: [count]Writer.Update = undefined;
            for (&updates, paths[0..count], 0..) |*u, p, i| u.* = if (i % 2 == 0) .init(p, &self.number) else .init(p, &self.text);
            var fixed = Io.Writer.fixed(&self.out);
            var w = Writer.init(&fixed);
            try w.applyUpdates(launder(self.data), &updates);
            std.mem.doNotOptimizeAway(fixed.end);
        }
        pub fn bytes(self: *const @This()) usize {
            return self.data.len;
        }
    };
}

/// Renders the encoded `complex_struct` as JSON.
const InspectJson = struct {
    buf: [4096]u8 = undefined,
    out: [4096]u8 = undefined,
    data: []const u8 = &.{},

    pub fn init(self: *@This()) !void {
        self.data = try encode(&self.buf, complex_struct);
    }
    pub fn run(self: *@This()) !void {
        var fixed = Io.Writer.fixed(&self.out);
        var inspector = bufzilla.Inspect(.{}).init(launder(self.data), &fixed, .{});
        try inspector.inspect();
        std.mem.doNotOptimizeAway(fixed.end);
    }
    pub fn bytes(self: *const @This()) usize {
        return self.data.len;
    }
};

const cases = .{
    .{ "Scalars", .{
        .{ "write null", WriteAny(null) },
        .{ "read null", ReadOne(null) },
        .{ "write bool", WriteAny(true) },
        .{ "read bool", ReadOne(true) },
        .{ "write int (small, 5)", WriteAny(@as(i64, 5)) },
        .{ "read int (small, 5)", ReadOne(@as(i64, 5)) },
        .{ "write int (varint, 42)", WriteAny(@as(i64, 42)) },
        .{ "read int (varint, 42)", ReadOne(@as(i64, 42)) },
        .{ "write int (large)", WriteAny(@as(i64, std.math.maxInt(i64))) },
        .{ "read int (large)", ReadOne(@as(i64, std.math.maxInt(i64))) },
        .{ "write f64", WriteAny(@as(f64, 3.14159265359)) },
        .{ "read f64", ReadOne(@as(f64, 3.14159265359)) },
    } },
    .{ "Strings and binary", .{
        .{ "write string (5 B)", WriteAny(@as([]const u8, "hello")) },
        .{ "read string (5 B)", ReadOne(@as([]const u8, "hello")) },
        .{ "write string (300 B)", WriteAny(@as([]const u8, &medium_string)) },
        .{ "read string (300 B)", ReadOne(@as([]const u8, &medium_string)) },
        .{ "write bytes (32 B)", WriteAny(@as([]const u8, &bytes_32)) },
        .{ "write bytes (1 KiB)", WriteAny(@as([]const u8, &bytes_1k)) },
        .{ "read bytes (1 KiB)", ReadOne(@as([]const u8, &bytes_1k)) },
    } },
    .{ "Arrays", .{
        .{ "write array (10 ints)", WriteIntArray(10) },
        .{ "read array (10 ints)", ReadIntArray(10) },
        .{ "write array (100 ints)", WriteIntArray(100) },
        .{ "read array (100 ints)", ReadIntArray(100) },
        .{ "write typed array (768 f32)", WriteTypedArray(f32) },
        .{ "read typed array (768 f32)", ReadTypedArray(false) },
        .{ "skip typed array (768 f32)", ReadTypedArray(true) },
        .{ "write typed array (768 u16)", WriteTypedArray(u16) },
    } },
    .{ "Objects and structs", .{
        .{ "write object (10 entries)", WriteObject(10) },
        .{ "read object (10 entries)", ReadObject(10) },
        .{ "write object (50 entries)", WriteObject(50) },
        .{ "read object (50 entries)", ReadObject(50) },
        .{ "write simple struct", WriteAny(simple_struct) },
        .{ "read simple struct (all values)", ReadAll(simple_struct) },
        .{ "write complex struct", WriteAny(complex_struct) },
        .{ "read complex struct (all values)", ReadAll(complex_struct) },
    } },
    .{ "Paths (complex struct)", .{
        .{ "readPath top-level key", ReadPath("age", true) },
        .{ "readPath nested key", ReadPath("address.city", true) },
        .{ "readPath array element", ReadPath("scores[3]", true) },
        .{ "readPath missing key", ReadPath("missing", false) },
        .{ "readPaths 3 paths", ReadPaths(&.{ "age", "address.city", "scores[3]" }) },
        .{ "readPaths 8 paths", ReadPaths(&.{ "tags[2]", "username", "scores[3]", "address.zip", "missing", "age", "address.city", "scores[0]" }) },
    } },
    .{ "Updates and JSON (complex struct)", .{
        .{ "applyUpdates 2 updates", ApplyUpdates(2) },
        .{ "applyUpdates 8 updates", ApplyUpdates(8) },
        .{ "inspect as JSON", InspectJson },
    } },
};

pub fn main(init: std.process.Init) !void {
    const args = try harness.Args.parse(init);
    const options = args.options();
    harness.warmUpCpu(init.io);

    if (args.csv) {
        std.debug.print("group,benchmark,median_ns,min_ns,spread,bytes,mib_per_s\n", .{});
    } else {
        std.debug.print("\nbufzilla micro-benchmarks ({s})\n", .{@tagName(@import("builtin").mode)});
        std.debug.print("time per operation: median of {d} samples; spread: interquartile range / median\n", .{options.samples});
        std.debug.print("size: encoded bytes written or read (reads are zero-copy and need not touch every byte)\n", .{});
    }

    inline for (cases) |group| {
        var any_selected = false;
        inline for (group[1]) |case| any_selected = any_selected or args.selected(case[0]);
        if (any_selected and !args.csv) std.debug.print("\n{s}\n  {s:<34} {s:>11} {s:>8} {s:>8}\n", .{ group[0], "", "time/op", "size", "spread" });
        inline for (group[1]) |case| {
            if (args.selected(case[0])) {
                var state: case[1] = .{};
                try state.init();
                const result = try harness.measure(init.io, &state, case[1].run, options);
                const size = state.bytes();
                if (args.csv) {
                    // Names are quoted: some contain commas.
                    std.debug.print("\"{s}\",\"{s}\",{d:.2},{d:.2},{d:.3},{d},{d:.1}\n", .{ group[0], case[0], result.median_ns, result.min_ns, result.spread, size, result.mibPerSec(size) });
                } else {
                    var time_buf: [32]u8 = undefined;
                    std.debug.print("  {s:<34} {s:>11} {d:>6} B {d:>7.1}%\n", .{ case[0], harness.formatTime(&time_buf, result.median_ns), size, result.spread * 100 });
                }
            }
        }
    }
}
