/// zbor Benchmark Suite
const std = @import("std");
const zbor = @import("zbor");
const DataItem = zbor.DataItem;
const Builder = zbor.Builder;

/// Benchmark timer helper
/// Run a benchmark and print results
fn benchmark(
    comptime name: []const u8,
    comptime iterations: usize,
    comptime func: fn (allocator: std.mem.Allocator) anyerror!void,
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Warmup
    for (0..10) |_| {
        try func(allocator);
    }

    // Actual benchmark
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        try func(allocator);
    }
    const elapsed_ns = timer.read();

    const avg_ns = elapsed_ns / iterations;
    const ops_per_sec = if (avg_ns > 0) (1_000_000_000 / avg_ns) else 0;

    std.debug.print(
        "{s:40} | {d:8} iterations | {d:8} ns/op | {d:8} ops/sec\n",
        .{ name, iterations, avg_ns, ops_per_sec },
    );
}

// ============================================================================
// Basic Type Benchmarks
// ============================================================================

fn benchNullWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    try zbor.stringify(null, .{}, &fixed);
}

fn benchNullRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        State.buffer[0] = 0xf6; // CBOR null
        State.len = 1;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.getType();
}

fn benchBoolWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    try zbor.stringify(true, .{}, &fixed);
}

fn benchBoolRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        State.buffer[0] = 0xf5; // CBOR true
        State.len = 1;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.boolean();
}

fn benchSmallIntWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    try zbor.stringify(@as(i64, 42), .{}, &fixed);
}

fn benchSmallIntRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();
        zbor.stringify(@as(i64, 42), .{}, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.int();
}

fn benchLargeIntWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    try zbor.stringify(@as(i64, 9223372036854775807), .{}, &fixed);
}

fn benchLargeIntRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();
        zbor.stringify(@as(i64, 9223372036854775807), .{}, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.int();
}

fn benchFloatWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    try zbor.stringify(@as(f64, 3.14159265359), .{}, &fixed);
}

fn benchFloatRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();
        zbor.stringify(@as(f64, 3.14159265359), .{}, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.float();
}

// ============================================================================
// String Benchmarks
// ============================================================================

fn benchShortStrWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    const str: []const u8 = "hello";
    try zbor.stringify(str, .{ .slice_serialization_type = .TextString }, &fixed);
}

fn benchShortStrRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 1000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();
        const str: []const u8 = "hello";
        zbor.stringify(str, .{ .slice_serialization_type = .TextString }, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.string();
}

fn benchMediumStrWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [2000]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    const test_str: []const u8 = "This is a medium length string for benchmarking CBOR performance. " ** 4;
    try zbor.stringify(test_str, .{ .slice_serialization_type = .TextString }, &fixed);
}

fn benchMediumStrRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 2000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();
        const test_str: []const u8 = "This is a medium length string for benchmarking CBOR performance. " ** 4;
        zbor.stringify(test_str, .{ .slice_serialization_type = .TextString }, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.string();
}

// ============================================================================
// Binary Data Benchmarks
// ============================================================================

fn benchSmallBinWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    const data: []const u8 = &([_]u8{1} ** 32);
    try zbor.stringify(data, .{ .slice_serialization_type = .ByteString }, &fixed);
}

fn benchSmallBinRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 1000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();
        const data: []const u8 = &([_]u8{1} ** 32);
        zbor.stringify(data, .{ .slice_serialization_type = .ByteString }, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.string();
}

fn benchLargeBinWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [2000]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    const data: []const u8 = &([_]u8{0x42} ** 1024);
    try zbor.stringify(data, .{ .slice_serialization_type = .ByteString }, &fixed);
}

fn benchLargeBinRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 2000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();
        const data: []const u8 = &([_]u8{0x42} ** 1024);
        zbor.stringify(data, .{ .slice_serialization_type = .ByteString }, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    _ = di.string();
}

// ============================================================================
// Array Benchmarks
// ============================================================================

fn benchSmallArrayWrite(allocator: std.mem.Allocator) !void {
    var b = try Builder.withType(allocator, .Array);
    for (0..10) |i| {
        try b.pushInt(@intCast(i));
    }
    const x = try b.finish();
    defer allocator.free(x);
}

fn benchSmallArrayRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 1000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var b = Builder.withType(std.heap.page_allocator, .Array) catch unreachable;
        for (0..10) |i| {
            b.pushInt(@intCast(i)) catch unreachable;
        }
        const x = b.finish() catch unreachable;
        defer std.heap.page_allocator.free(x);
        @memcpy(State.buffer[0..x.len], x);
        State.len = x.len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    var iter = di.array().?;
    while (iter.next()) |_| {}
}

fn benchMediumArrayWrite(allocator: std.mem.Allocator) !void {
    var b = try Builder.withType(allocator, .Array);
    for (0..100) |i| {
        try b.pushInt(@intCast(i));
    }
    const x = try b.finish();
    defer allocator.free(x);
}

fn benchMediumArrayRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 5000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var b = Builder.withType(std.heap.page_allocator, .Array) catch unreachable;
        for (0..100) |i| {
            b.pushInt(@intCast(i)) catch unreachable;
        }
        const x = b.finish() catch unreachable;
        defer std.heap.page_allocator.free(x);
        @memcpy(State.buffer[0..x.len], x);
        State.len = x.len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    var iter = di.array().?;
    while (iter.next()) |_| {}
}

// ============================================================================
// Map Benchmarks
// ============================================================================

fn benchSmallMapWrite(allocator: std.mem.Allocator) !void {
    var b = try Builder.withType(allocator, .Map);
    for (0..10) |i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try b.pushTextString(key);
        try b.pushInt(@intCast(i));
    }
    const x = try b.finish();
    defer allocator.free(x);
}

fn benchSmallMapRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 2000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var b = Builder.withType(std.heap.page_allocator, .Map) catch unreachable;
        for (0..10) |i| {
            var key_buf: [8]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            b.pushTextString(key) catch unreachable;
            b.pushInt(@intCast(i)) catch unreachable;
        }
        const x = b.finish() catch unreachable;
        defer std.heap.page_allocator.free(x);
        @memcpy(State.buffer[0..x.len], x);
        State.len = x.len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    var iter = di.map().?;
    while (iter.next()) |_| {}
}

fn benchMediumMapWrite(allocator: std.mem.Allocator) !void {
    var b = try Builder.withType(allocator, .Map);
    for (0..50) |i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try b.pushTextString(key);
        try b.pushInt(@intCast(i));
    }
    const x = try b.finish();
    defer allocator.free(x);
}

fn benchMediumMapRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 10000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var b = Builder.withType(std.heap.page_allocator, .Map) catch unreachable;
        for (0..50) |i| {
            var key_buf: [8]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            b.pushTextString(key) catch unreachable;
            b.pushInt(@intCast(i)) catch unreachable;
        }
        const x = b.finish() catch unreachable;
        defer std.heap.page_allocator.free(x);
        @memcpy(State.buffer[0..x.len], x);
        State.len = x.len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    var iter = di.map().?;
    while (iter.next()) |_| {}
}

// ============================================================================
// Complex Structure Benchmarks
// ============================================================================

fn benchNestedStructureWrite(allocator: std.mem.Allocator) !void {
    // Create: {"users": [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]}
    var root = try Builder.withType(allocator, .Map);
    try root.pushTextString("users");
    try root.enter(.Array);

    try root.enter(.Map);
    try root.pushTextString("id");
    try root.pushInt(1);
    try root.pushTextString("name");
    try root.pushTextString("Alice");
    try root.leave();

    try root.enter(.Map);
    try root.pushTextString("id");
    try root.pushInt(2);
    try root.pushTextString("name");
    try root.pushTextString("Bob");
    try root.leave();

    const x = try root.finish();
    defer allocator.free(x);
}

fn benchNestedStructureRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 10000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var root = Builder.withType(std.heap.page_allocator, .Map) catch unreachable;
        root.pushTextString("users") catch unreachable;
        root.enter(.Array) catch unreachable;

        root.enter(.Map) catch unreachable;
        root.pushTextString("id") catch unreachable;
        root.pushInt(1) catch unreachable;
        root.pushTextString("name") catch unreachable;
        root.pushTextString("Alice") catch unreachable;
        root.leave() catch unreachable;

        root.enter(.Map) catch unreachable;
        root.pushTextString("id") catch unreachable;
        root.pushInt(2) catch unreachable;
        root.pushTextString("name") catch unreachable;
        root.pushTextString("Bob") catch unreachable;
        root.leave() catch unreachable;

        const x = root.finish() catch unreachable;
        defer std.heap.page_allocator.free(x);
        @memcpy(State.buffer[0..x.len], x);
        State.len = x.len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    var map_iter = di.map().?;
    while (map_iter.next()) |pair| {
        _ = pair.key.string();
        if (pair.value.array()) |*arr_iter| {
            var iter = arr_iter.*;
            while (iter.next()) |item| {
                if (item.map()) |*inner_map| {
                    var inner = inner_map.*;
                    while (inner.next()) |_| {}
                }
            }
        }
    }
}

fn benchMixedTypesWrite(allocator: std.mem.Allocator) !void {
    var b = try Builder.withType(allocator, .Array);
    try b.pushSimple(22); // null
    try b.pushSimple(21); // true
    try b.pushInt(-100);
    try b.pushInt(200);

    // Float - write manually
    var float_buf: [9]u8 = undefined;
    var float_writer = std.Io.Writer.fixed(&float_buf);
    try zbor.stringify(@as(f64, 3.14), .{}, &float_writer);
    try b.pushCbor(float_writer.buffered());

    try b.pushTextString("hello");

    const bin_data: []const u8 = &([_]u8{1} ** 8);
    try b.pushByteString(bin_data);

    try b.enter(.Array);
    try b.pushInt(1);
    try b.pushInt(2);
    try b.leave();

    try b.enter(.Map);
    try b.pushTextString("key");
    try b.pushInt(42);
    try b.leave();

    const x = try b.finish();
    defer allocator.free(x);
}

fn benchMixedTypesRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 5000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var b = Builder.withType(std.heap.page_allocator, .Array) catch unreachable;
        b.pushSimple(22) catch unreachable; // null
        b.pushSimple(21) catch unreachable; // true
        b.pushInt(-100) catch unreachable;
        b.pushInt(200) catch unreachable;

        // Float
        var float_buf: [9]u8 = undefined;
        var float_writer = std.Io.Writer.fixed(&float_buf);
        zbor.stringify(@as(f64, 3.14), .{}, &float_writer) catch unreachable;
        b.pushCbor(float_writer.buffered()) catch unreachable;

        b.pushTextString("hello") catch unreachable;

        const bin_data: []const u8 = &([_]u8{1} ** 8);
        b.pushByteString(bin_data) catch unreachable;

        b.enter(.Array) catch unreachable;
        b.pushInt(1) catch unreachable;
        b.pushInt(2) catch unreachable;
        b.leave() catch unreachable;

        b.enter(.Map) catch unreachable;
        b.pushTextString("key") catch unreachable;
        b.pushInt(42) catch unreachable;
        b.leave() catch unreachable;

        const x = b.finish() catch unreachable;
        defer std.heap.page_allocator.free(x);
        @memcpy(State.buffer[0..x.len], x);
        State.len = x.len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    var iter = di.array().?;
    while (iter.next()) |_| {}
}

// ============================================================================
// Struct Serialization Benchmarks
// ============================================================================

const User = struct {
    id: i64,
    name: []const u8,
    active: bool,
    score: f64,
};

const ComplexStruct = struct {
    users: []const User,
    metadata: struct {
        version: i64,
        name: []const u8,
    },
    tags: []const []const u8,
};

fn benchStructWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [2000]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    const user = User{
        .id = 12345,
        .name = "Alice Smith",
        .active = true,
        .score = 98.5,
    };

    try zbor.stringify(user, .{
        .field_settings = &.{
            .{ .name = "name", .value_options = .{ .slice_serialization_type = .TextString } },
        },
    }, &fixed);
}

fn benchStructRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 2000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();

        const user = User{
            .id = 12345,
            .name = "Alice Smith",
            .active = true,
            .score = 98.5,
        };

        zbor.stringify(user, .{
            .field_settings = &.{
                .{ .name = "name", .value_options = .{ .slice_serialization_type = .TextString } },
            },
        }, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    var iter = di.map().?;
    while (iter.next()) |_| {}
}

fn benchComplexStructWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [5000]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&arr);

    const users = [_]User{
        .{ .id = 1, .name = "Alice", .active = true, .score = 95.0 },
        .{ .id = 2, .name = "Bob", .active = false, .score = 87.5 },
        .{ .id = 3, .name = "Charlie", .active = true, .score = 92.0 },
    };

    const tags = [_][]const u8{ "admin", "verified", "premium" };

    const data = ComplexStruct{
        .users = &users,
        .metadata = .{ .version = 1, .name = "test" },
        .tags = &tags,
    };

    try zbor.stringify(data, .{
        .field_settings = &.{
            .{ .name = "name", .value_options = .{ .slice_serialization_type = .TextString } },
            .{ .name = "tags", .value_options = .{ .slice_serialization_type = .TextString } },
        },
    }, &fixed);
}

fn benchComplexStructRead(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const BufferLen = 5000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var arr = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer arr.deinit();

        const users = [_]User{
            .{ .id = 1, .name = "Alice", .active = true, .score = 95.0 },
            .{ .id = 2, .name = "Bob", .active = false, .score = 87.5 },
            .{ .id = 3, .name = "Charlie", .active = true, .score = 92.0 },
        };

        const tags = [_][]const u8{ "admin", "verified", "premium" };

        const data = ComplexStruct{
            .users = &users,
            .metadata = .{ .version = 1, .name = "test" },
            .tags = &tags,
        };

        zbor.stringify(data, .{
            .field_settings = &.{
                .{ .name = "name", .value_options = .{ .slice_serialization_type = .TextString } },
                .{ .name = "tags", .value_options = .{ .slice_serialization_type = .TextString } },
            },
        }, &arr.writer) catch unreachable;
        @memcpy(State.buffer[0..arr.written().len], arr.written());
        State.len = arr.written().len;
        State.initialized = true;
    }

    const di = try DataItem.new(State.buffer[0..State.len]);
    var iter = di.map().?;
    while (iter.next()) |_| {}
}

// ============================================================================
// Main Benchmark Runner
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 80 ++ "\n", .{});
    std.debug.print("zbor (CBOR) Benchmark Suite\n", .{});
    std.debug.print("=" ** 80 ++ "\n\n", .{});

    // Basic Types
    std.debug.print("Basic Types:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});
    try benchmark("Null Write", 1000000, benchNullWrite);
    try benchmark("Null Read", 1000000, benchNullRead);
    try benchmark("Bool Write", 1000000, benchBoolWrite);
    try benchmark("Bool Read", 1000000, benchBoolRead);
    try benchmark("Small Int Write", 1000000, benchSmallIntWrite);
    try benchmark("Small Int Read", 1000000, benchSmallIntRead);
    try benchmark("Large Int Write", 1000000, benchLargeIntWrite);
    try benchmark("Large Int Read", 1000000, benchLargeIntRead);
    try benchmark("Float Write", 1000000, benchFloatWrite);
    try benchmark("Float Read", 1000000, benchFloatRead);
    std.debug.print("\n", .{});

    // Strings
    std.debug.print("Strings:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});
    try benchmark("Short String Write (5 bytes)", 500000, benchShortStrWrite);
    try benchmark("Short String Read (5 bytes)", 500000, benchShortStrRead);
    try benchmark("Medium String Write (~300 bytes)", 100000, benchMediumStrWrite);
    try benchmark("Medium String Read (~300 bytes)", 100000, benchMediumStrRead);
    std.debug.print("\n", .{});

    // Binary Data
    std.debug.print("Binary Data:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});
    try benchmark("Small Binary Write (32 bytes)", 500000, benchSmallBinWrite);
    try benchmark("Small Binary Read (32 bytes)", 500000, benchSmallBinRead);
    try benchmark("Large Binary Write (1KB)", 100000, benchLargeBinWrite);
    try benchmark("Large Binary Read (1KB)", 100000, benchLargeBinRead);
    std.debug.print("\n", .{});

    // Arrays
    std.debug.print("Arrays:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});
    try benchmark("Small Array Write (10 elements)", 100000, benchSmallArrayWrite);
    try benchmark("Small Array Read (10 elements)", 100000, benchSmallArrayRead);
    try benchmark("Medium Array Write (100 elements)", 50000, benchMediumArrayWrite);
    try benchmark("Medium Array Read (100 elements)", 50000, benchMediumArrayRead);
    std.debug.print("\n", .{});

    // Maps
    std.debug.print("Maps:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});
    try benchmark("Small Map Write (10 entries)", 100000, benchSmallMapWrite);
    try benchmark("Small Map Read (10 entries)", 100000, benchSmallMapRead);
    try benchmark("Medium Map Write (50 entries)", 50000, benchMediumMapWrite);
    try benchmark("Medium Map Read (50 entries)", 50000, benchMediumMapRead);
    std.debug.print("\n", .{});

    // Complex Structures
    std.debug.print("Complex Structures:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});
    try benchmark("Nested Structure Write", 50000, benchNestedStructureWrite);
    try benchmark("Nested Structure Read", 50000, benchNestedStructureRead);
    try benchmark("Mixed Types Write", 50000, benchMixedTypesWrite);
    try benchmark("Mixed Types Read", 50000, benchMixedTypesRead);
    std.debug.print("\n", .{});

    // Struct Serialization
    std.debug.print("Struct Serialization:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});
    try benchmark("Simple Struct Write", 100000, benchStructWrite);
    try benchmark("Simple Struct Read", 100000, benchStructRead);
    try benchmark("Complex Struct Write", 50000, benchComplexStructWrite);
    try benchmark("Complex Struct Read", 50000, benchComplexStructRead);
    std.debug.print("\n", .{});

    std.debug.print("=" ** 80 ++ "\n", .{});
    std.debug.print("Benchmark Complete\n", .{});
    std.debug.print("=" ** 80 ++ "\n", .{});
}
