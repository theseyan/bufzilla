/// bufzilla Benchmark Suite
const std = @import("std");
const bufzilla = @import("bufzilla");
const Io = std.Io;

const Writer = bufzilla.Writer;
const Reader = bufzilla.Reader;
const Value = bufzilla.Value;

/// Benchmark timer helper
/// Run a benchmark and print results
fn benchmark(
    comptime name: []const u8,
    comptime iterations: usize,
    comptime func: fn () anyerror!void,
) !void {
    // Warmup
    for (0..10) |_| {
        try func();
    }

    // Actual benchmark
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        try func();
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

fn benchNullWrite() !void {
    var arr: [100]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.writeAny(null);
}

fn benchNullRead() !void {
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.writeAny(null);
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

fn benchBoolWrite() !void {
    var arr: [100]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.writeAny(true);
}

fn benchBoolRead() !void {
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.writeAny(true);
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

fn benchSmallIntWrite() !void {
    var arr: [100]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.writeAny(@as(i64, 42));
}

fn benchSmallIntRead() !void {
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.writeAny(@as(i64, 42));
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

fn benchLargeIntWrite() !void {
    var arr: [100]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    // i64 max - requires full 8 bytes after ZigZag encoding
    try writer.writeAny(@as(i64, 9223372036854775807));
}

fn benchLargeIntRead() !void {
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.writeAny(@as(i64, 9223372036854775807));
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

fn benchFloatWrite() !void {
    var arr: [100]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.writeAny(@as(f64, 3.14159265359));
}

fn benchFloatRead() !void {
    const BufferLen = 100;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.writeAny(@as(f64, 3.14159265359));
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

// ============================================================================
// String Benchmarks
// ============================================================================

fn benchShortStrWrite() !void {
    var arr: [1000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.writeAny("hello");
}

fn benchShortStrRead() !void {
    const BufferLen = 1000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.writeAny("hello");
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

fn benchMediumStrWrite() !void {
    var arr: [2000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    const test_str = "This is a medium length string for benchmarking bufzilla performance. " ** 4;
    try writer.writeAny(test_str);
}

fn benchMediumStrRead() !void {
    const BufferLen = 2000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        const test_str = "This is a medium length string for benchmarking bufzilla performance. " ** 4;
        try writer.writeAny(test_str);
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

// ============================================================================
// Binary Data Benchmarks
// ============================================================================

fn benchSmallBinWrite() !void {
    var arr: [1000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    const data: []const u8 = &([_]u8{1} ** 32);
    try writer.writeAny(data);
}

fn benchSmallBinRead() !void {
    const BufferLen = 1000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        const data: []const u8 = &([_]u8{1} ** 32);
        try writer.writeAny(data);
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

fn benchLargeBinWrite() !void {
    var arr: [2000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    const data: []const u8 = &([_]u8{0x42} ** 1024);
    try writer.writeAny(data);
}

fn benchLargeBinRead() !void {
    const BufferLen = 2000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        const data: []const u8 = &([_]u8{0x42} ** 1024);
        try writer.writeAny(data);
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    _ = try reader.read();
}

// ============================================================================
// Array Benchmarks
// ============================================================================

fn benchSmallArrayWrite() !void {
    var arr: [1000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    for (0..10) |i| {
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();
}

fn benchSmallArrayRead() !void {
    const BufferLen = 1000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.startArray();
        for (0..10) |i| {
            try writer.writeAny(@as(i64, @intCast(i)));
        }
        try writer.endContainer();
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    const array = try reader.read();
    while (try reader.iterateArray(array)) |_| {}
}

fn benchMediumArrayWrite() !void {
    var arr: [5000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    for (0..100) |i| {
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();
}

fn benchMediumArrayRead() !void {
    const BufferLen = 5000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.startArray();
        for (0..100) |i| {
            try writer.writeAny(@as(i64, @intCast(i)));
        }
        try writer.endContainer();
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    const array = try reader.read();
    while (try reader.iterateArray(array)) |_| {}
}

// ============================================================================
// Object (Map) Benchmarks
// ============================================================================

fn benchSmallObjectWrite() !void {
    var arr: [2000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    for (0..10) |i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try writer.writeAny(key);
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();
}

fn benchSmallObjectRead() !void {
    const BufferLen = 2000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.startObject();
        for (0..10) |i| {
            var key_buf: [8]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            try writer.writeAny(key);
            try writer.writeAny(@as(i64, @intCast(i)));
        }
        try writer.endContainer();
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    const obj = try reader.read();
    while (try reader.iterateObject(obj)) |_| {}
}

fn benchMediumObjectWrite() !void {
    var arr: [10000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    for (0..50) |i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try writer.writeAny(key);
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();
}

fn benchMediumObjectRead() !void {
    const BufferLen = 10000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);
        try writer.startObject();
        for (0..50) |i| {
            var key_buf: [8]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            try writer.writeAny(key);
            try writer.writeAny(@as(i64, @intCast(i)));
        }
        try writer.endContainer();
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    const obj = try reader.read();
    while (try reader.iterateObject(obj)) |_| {}
}

// ============================================================================
// Complex Structure Benchmarks
// ============================================================================

fn benchNestedStructureWrite() !void {
    var arr: [10000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    // Create: {"users": [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]}
    try writer.startObject();
    try writer.writeAny("users");
    try writer.startArray();

    try writer.startObject();
    try writer.writeAny("id");
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny("name");
    try writer.writeAny("Alice");
    try writer.endContainer();

    try writer.startObject();
    try writer.writeAny("id");
    try writer.writeAny(@as(i64, 2));
    try writer.writeAny("name");
    try writer.writeAny("Bob");
    try writer.endContainer();

    try writer.endContainer();
    try writer.endContainer();
}

fn benchNestedStructureRead() !void {
    const BufferLen = 10000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);

        try writer.startObject();
        try writer.writeAny("users");
        try writer.startArray();

        try writer.startObject();
        try writer.writeAny("id");
        try writer.writeAny(@as(i64, 1));
        try writer.writeAny("name");
        try writer.writeAny("Alice");
        try writer.endContainer();

        try writer.startObject();
        try writer.writeAny("id");
        try writer.writeAny(@as(i64, 2));
        try writer.writeAny("name");
        try writer.writeAny("Bob");
        try writer.endContainer();

        try writer.endContainer();
        try writer.endContainer();
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    while (reader.pos < State.len) {
        _ = try reader.read();
    }
}

fn benchMixedTypesWrite() !void {
    var arr: [5000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    try writer.writeAny(null);
    try writer.writeAny(true);
    try writer.writeAny(@as(i64, -100));
    try writer.writeAny(@as(u64, 200));
    try writer.writeAny(@as(f64, 3.14));
    try writer.writeAny("hello");

    const bin_data: []const u8 = &([_]u8{1} ** 8);
    try writer.writeAny(bin_data);

    try writer.startArray();
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny(@as(i64, 2));
    try writer.endContainer();

    try writer.startObject();
    try writer.writeAny("key");
    try writer.writeAny(@as(i64, 42));
    try writer.endContainer();

    try writer.endContainer();
}

fn benchMixedTypesRead() !void {
    const BufferLen = 5000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);

        try writer.startArray();
        try writer.writeAny(null);
        try writer.writeAny(true);
        try writer.writeAny(@as(i64, -100));
        try writer.writeAny(@as(u64, 200));
        try writer.writeAny(@as(f64, 3.14));
        try writer.writeAny("hello");

        const bin_data: []const u8 = &([_]u8{1} ** 8);
        try writer.writeAny(bin_data);

        try writer.startArray();
        try writer.writeAny(@as(i64, 1));
        try writer.writeAny(@as(i64, 2));
        try writer.endContainer();

        try writer.startObject();
        try writer.writeAny("key");
        try writer.writeAny(@as(i64, 42));
        try writer.endContainer();

        try writer.endContainer();
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    while (reader.pos < State.len) {
        _ = try reader.read();
    }
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

fn benchStructWrite() !void {
    var arr: [2000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

    const user = User{
        .id = 12345,
        .name = "Alice Smith",
        .active = true,
        .score = 98.5,
    };

    try writer.writeAny(user);
}

fn benchStructRead() !void {
    const BufferLen = 2000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);

        const user = User{
            .id = 12345,
            .name = "Alice Smith",
            .active = true,
            .score = 98.5,
        };

        try writer.writeAny(user);
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    const obj = try reader.read();
    while (try reader.iterateObject(obj)) |_| {}
}

fn benchComplexStructWrite() !void {
    var arr: [5000]u8 = undefined;
    var fixed = Io.Writer.fixed(&arr);
    var writer = Writer.init(&fixed);

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

    try writer.writeAny(data);
}

fn benchComplexStructRead() !void {
    const BufferLen = 5000;
    const State = struct {
        var initialized = false;
        var buffer: [BufferLen]u8 = [_]u8{0} ** BufferLen;
        var len: usize = 0;
    };

    if (!State.initialized) {
        var fixed = Io.Writer.fixed(&State.buffer);
        var writer = Writer.init(&fixed);

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

        try writer.writeAny(data);
        State.len = fixed.buffered().len;
        State.initialized = true;
    }

    var reader = Reader(.{}).init(State.buffer[0..State.len]);
    while (reader.pos < State.len) {
        _ = try reader.read();
    }
}

// ============================================================================
// Main Benchmark Runner
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 80 ++ "\n", .{});
    std.debug.print("bufzilla Benchmark Suite\n", .{});
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

    // Objects (Maps)
    std.debug.print("Objects (Maps):\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});
    try benchmark("Small Object Write (10 entries)", 100000, benchSmallObjectWrite);
    try benchmark("Small Object Read (10 entries)", 100000, benchSmallObjectRead);
    try benchmark("Medium Object Write (50 entries)", 50000, benchMediumObjectWrite);
    try benchmark("Medium Object Read (50 entries)", 50000, benchMediumObjectRead);
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
