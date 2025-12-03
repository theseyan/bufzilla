/// Unit tests
const std = @import("std");
const Io = std.Io;
const bufzilla = @import("bufzilla");

pub const Writer = bufzilla.Writer;
pub const Reader = bufzilla.Reader;
pub const Inspect = bufzilla.Inspect;
pub const Value = bufzilla.Value;
pub const Common = bufzilla.Common;

pub const encodingTests = @import("encoding.zig");

var shared_encoded: [1024]u8 = undefined;
var shared_encoded_len: usize = 0;

test {
    std.testing.refAllDeclsRecursive(@This());
}

// =============================================================================
// Writer Tests - Allocating
// =============================================================================

test "writer/allocating: primitive data types" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);

    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(123);
    try writer.writeAny("b");
    try writer.startObject();
    try writer.writeAny("c");
    try writer.writeAny(true);
    try writer.endContainer();
    try writer.writeAny("d");
    try writer.startArray();
    try writer.writeAny(123.123);
    try writer.writeAny(null);
    try writer.writeAny("value");
    try writer.endContainer();
    try writer.endContainer();

    const written = aw.written();
    @memcpy(shared_encoded[0..written.len], written);
    shared_encoded_len = written.len;

    try std.testing.expect(written.len == 38);
}

test "writer/allocating: zig struct serialization" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);

    const DataType = struct {
        a: i64,
        b: struct {
            c: bool,
        },
        d: []const union(enum) {
            null: ?void,
            f64: f64,
            string: []const u8,
        },
    };

    const data = DataType{
        .a = 123,
        .b = .{ .c = true },
        .d = &.{ .{ .f64 = 123.123 }, .{ .null = null }, .{ .string = "value" } },
    };

    try writer.writeAny(data);

    const written = aw.written();

    // Should produce identical output to manual construction
    try std.testing.expectEqualSlices(u8, shared_encoded[0..shared_encoded_len], written);
}

// =============================================================================
// Writer Tests - Fixed Buffer
// =============================================================================

test "writer/fixed: primitive data types" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);

    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(123);
    try writer.writeAny("b");
    try writer.startObject();
    try writer.writeAny("c");
    try writer.writeAny(true);
    try writer.endContainer();
    try writer.writeAny("d");
    try writer.startArray();
    try writer.writeAny(123.123);
    try writer.writeAny(null);
    try writer.writeAny("value");
    try writer.endContainer();
    try writer.endContainer();

    const written = fixed.buffered();

    // Fixed buffer should produce identical output to allocating
    try std.testing.expectEqualSlices(u8, shared_encoded[0..shared_encoded_len], written);
}

test "writer/fixed: simple values" {
    var buffer: [64]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);

    var writer = Writer.init(&fixed);

    try writer.writeAny("hello");
    try writer.writeAny(@as(i64, 42));
    try writer.writeAny(@as(f64, 3.14));
    try writer.writeAny(true);
    try writer.writeAny(false);
    try writer.writeAny(null);

    const written = fixed.buffered();
    try std.testing.expect(written.len > 0);

    // Verify we can read it back
    var reader = Reader.init(written);
    try std.testing.expectEqualStrings("hello", (try reader.read()).bytes);
    try std.testing.expectEqual(42, (try reader.read()).i64);
    try std.testing.expectEqual(3.14, (try reader.read()).f64);
    try std.testing.expectEqual(true, (try reader.read()).bool);
    try std.testing.expectEqual(false, (try reader.read()).bool);
    try std.testing.expect((try reader.read()) == .null);
}

test "writer/fixed: empty containers" {
    var buffer: [32]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);

    var writer = Writer.init(&fixed);

    // Empty object
    try writer.startObject();
    try writer.endContainer();

    // Empty array
    try writer.startArray();
    try writer.endContainer();

    const written = fixed.buffered();

    // Verify we can read it back
    var reader = Reader.init(written);
    try std.testing.expect((try reader.read()) == .object);
    try std.testing.expect((try reader.read()) == .containerEnd);
    try std.testing.expect((try reader.read()) == .array);
    try std.testing.expect((try reader.read()) == .containerEnd);
}

// =============================================================================
// Reader Tests
// =============================================================================

test "reader: sequential reading" {
    var reader = Reader.init(shared_encoded[0..shared_encoded_len]);

    try std.testing.expect(try reader.read() == Value.object);
    try std.testing.expectEqualStrings("a", (try reader.read()).bytes);
    try std.testing.expectEqual(123, (try reader.read()).i64);
    try std.testing.expectEqualStrings("b", (try reader.read()).bytes);
    try std.testing.expect(try reader.read() == Value.object);
    try std.testing.expectEqualStrings("c", (try reader.read()).bytes);
    try std.testing.expectEqual(true, (try reader.read()).bool);
    try std.testing.expect(try reader.read() == Value.containerEnd);
    try std.testing.expectEqualStrings("d", (try reader.read()).bytes);
    try std.testing.expect(try reader.read() == Value.array);
    try std.testing.expectEqual(123.123, (try reader.read()).f64);
    try std.testing.expect(try reader.read() == Value.null);
    try std.testing.expectEqualStrings("value", (try reader.read()).bytes);
    try std.testing.expect(try reader.read() == Value.containerEnd);
    try std.testing.expect(try reader.read() == Value.containerEnd);

    try std.testing.expectError(error.UnexpectedEof, reader.read());
}

test "reader: object iteration" {
    // Encode a simple object
    var buffer: [64]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("key1");
    try writer.writeAny(@as(i64, 100));
    try writer.writeAny("key2");
    try writer.writeAny("value2");
    try writer.endContainer();

    var reader = Reader.init(fixed.buffered());
    const obj = try reader.read();
    try std.testing.expect(obj == .object);

    // Iterate key-value pairs
    var count: usize = 0;
    while (try reader.iterateObject(obj)) |kv| {
        count += 1;
        if (count == 1) {
            try std.testing.expectEqualStrings("key1", kv.key.bytes);
            try std.testing.expectEqual(100, kv.value.i64);
        } else if (count == 2) {
            try std.testing.expectEqualStrings("key2", kv.key.bytes);
            try std.testing.expectEqualStrings("value2", kv.value.bytes);
        }
    }
    try std.testing.expectEqual(2, count);
}

test "reader: array iteration" {
    // Encode a simple array
    var buffer: [64]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny(@as(i64, 2));
    try writer.writeAny(@as(i64, 3));
    try writer.endContainer();

    var reader = Reader.init(fixed.buffered());
    const arr = try reader.read();
    try std.testing.expect(arr == .array);

    // Iterate values
    var sum: i64 = 0;
    while (try reader.iterateArray(arr)) |val| {
        sum += val.i64;
    }
    try std.testing.expectEqual(6, sum);
}

// =============================================================================
// Inspect Tests
// =============================================================================

test "inspect/allocating: json output" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var inspector = Inspect.init(shared_encoded[0..shared_encoded_len], &aw.writer, .{});
    try inspector.inspect();

    const expected =
        \\{
        \\    "a": 123,
        \\    "b": {
        \\        "c": true
        \\    },
        \\    "d": [
        \\        123.12300000000000,
        \\        null,
        \\        "value"
        \\    ]
        \\}
    ;

    try std.testing.expectEqualStrings(expected, aw.written());
}

test "inspect: custom options" {
    // Encode simple data
    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    try writer.startObject();
    try writer.writeAny("pi");
    try writer.writeAny(@as(f64, 3.14159265358979));
    try writer.endContainer();

    // Inspect with custom indent and precision
    var out_buffer: [128]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);

    var inspector = Inspect.init(enc_fixed.buffered(), &out_fixed, .{
        .indent_size = 2,
        .float_precision = 4,
    });
    try inspector.inspect();

    const expected =
        \\{
        \\  "pi": 3.1416
        \\}
    ;

    try std.testing.expectEqualStrings(expected, out_fixed.buffered());
}

test "consistency: allocating and fixed produce identical output" {
    const TestData = struct {
        name: []const u8,
        values: []const i64,
        active: bool,
    };

    const data = TestData{
        .name = "test",
        .values = &.{ 1, 2, 3 },
        .active = true,
    };

    // Write with allocating
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var writer1 = Writer.init(&aw.writer);
    try writer1.writeAny(data);

    // Write with fixed
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer2 = Writer.init(&fixed);
    try writer2.writeAny(data);

    // Must be identical
    try std.testing.expectEqualSlices(u8, aw.written(), fixed.buffered());
}
