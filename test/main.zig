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
    var reader = Reader(.{}).init(written);
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
    var reader = Reader(.{}).init(written);
    try std.testing.expect((try reader.read()) == .object);
    try std.testing.expect((try reader.read()) == .containerEnd);
    try std.testing.expect((try reader.read()) == .array);
    try std.testing.expect((try reader.read()) == .containerEnd);
}

test "writer/fixed: pointer to array" {
    var buffer: [64]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);

    var writer = Writer.init(&fixed);

    // Pointer to byte array (should encode as bytes)
    const byte_arr = [_]u8{ 1, 2, 3 };
    try writer.writeAny(&byte_arr);

    // Pointer to int array (should encode as array)
    const int_arr = [_]i64{ 10, 20, 30 };
    try writer.writeAny(&int_arr);

    // Pointer to single value
    const single: i64 = 42;
    try writer.writeAny(&single);

    const written = fixed.buffered();
    try std.testing.expect(written.len > 0);

    // Verify we can read it back
    var reader = Reader(.{}).init(written);

    // Byte array
    const bytes = try reader.read();
    try std.testing.expect(bytes == .bytes);
    try std.testing.expectEqualSlices(u8, &byte_arr, bytes.bytes);

    // Int array
    const arr = try reader.read();
    try std.testing.expect(arr == .array);
    try std.testing.expectEqual(10, (try reader.read()).i64);
    try std.testing.expectEqual(20, (try reader.read()).i64);
    try std.testing.expectEqual(30, (try reader.read()).i64);
    try std.testing.expect((try reader.read()) == .containerEnd);

    // Single value
    try std.testing.expectEqual(42, (try reader.read()).i64);
}

// =============================================================================
// Reader Tests
// =============================================================================

test "reader: sequential reading" {
    var reader = Reader(.{}).init(shared_encoded[0..shared_encoded_len]);

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

    var reader = Reader(.{}).init(fixed.buffered());
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

    var reader = Reader(.{}).init(fixed.buffered());
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

    var inspector = Inspect(.{}).init(shared_encoded[0..shared_encoded_len], &aw.writer, .{});
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

    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{
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

// =============================================================================
// Robustness Tests
// =============================================================================

test "reader: containerEnd at depth 0" {
    // malformed: a containerEnd tag without any preceding container
    const containerEndTag = Common.encodeTag(@intFromEnum(Value.containerEnd), 0);
    const malformed = &[_]u8{containerEndTag};

    var reader = Reader(.{}).init(malformed);
    try std.testing.expectError(error.UnexpectedContainerEnd, reader.read());
}

test "reader: nested containerEnd underflow" {
    // Create valid object and add extra containerEnd
    var buffer: [32]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.endContainer();

    // append an extra containerEnd tag to get malformed data
    const written = fixed.buffered();
    var malformed: [33]u8 = undefined;
    @memcpy(malformed[0..written.len], written);
    malformed[written.len] = Common.encodeTag(@intFromEnum(Value.containerEnd), 0);

    var reader = Reader(.{}).init(malformed[0 .. written.len + 1]);

    try std.testing.expect((try reader.read()) == .object);
    try std.testing.expect((try reader.read()) == .containerEnd);
    // extra containerEnd should error, not underflow
    try std.testing.expectError(error.UnexpectedContainerEnd, reader.read());
}

test "reader: malformed varIntBytes length" {
    // malformed input with varIntBytes tag and a huge length that would overflow if added to pos.
    const varIntBytesTag = Common.encodeTag(@intFromEnum(Value.varIntBytes), 3);

    // large length (0xFFFFFFFF = ~4GB) that can cause overflow
    var malformed: [5]u8 = undefined;
    malformed[0] = varIntBytesTag;
    malformed[1] = 0xFF;
    malformed[2] = 0xFF;
    malformed[3] = 0xFF;
    malformed[4] = 0xFF;

    // With max_bytes_length limit set, returns BytesTooLong
    var reader = Reader(.{ .max_bytes_length = 1024 * 1024 }).init(&malformed);
    try std.testing.expectError(error.BytesTooLong, reader.read());

    // Without limit, returns UnexpectedEof
    var reader2 = Reader(.{}).init(&malformed);
    try std.testing.expectError(error.UnexpectedEof, reader2.read());
}

test "reader: malicious bytes length causes BytesTooLong" {
    // malformed input: bytes tag and a huge 8-byte length
    const bytesTag = Common.encodeTag(@intFromEnum(Value.bytes), 0);

    // 1 byte tag + 8 bytes for u64 length
    var malformed: [9]u8 = undefined;
    malformed[0] = bytesTag;
    std.mem.writeInt(u64, malformed[1..9], std.math.maxInt(u64), .little);

    // With max_bytes_length limit set, returns BytesTooLong
    var reader = Reader(.{ .max_bytes_length = 1024 * 1024 }).init(&malformed);
    try std.testing.expectError(error.BytesTooLong, reader.read());

    // Without limit, returns UnexpectedEof
    var reader2 = Reader(.{}).init(&malformed);
    try std.testing.expectError(error.UnexpectedEof, reader2.read());
}

test "inspect: control characters are escaped in JSON" {
    // control characters: backspace, form feed, and other control chars
    const test_string = "a\x08b\x0Cc\x00d\x1Fe";

    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);
    try writer.writeAny(test_string);

    var out_buffer: [64]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});
    try inspector.inspect();

    // Verify all control chars are properly escaped
    try std.testing.expectEqualStrings("\"a\\bb\\fc\\u0000d\\u001fe\"", out_fixed.buffered());
}

test "inspect: invalid UTF-8 returns error" {
    // invalid UTF-8: 0x80 is a continuation byte without a leading byte
    const invalid_utf8 = "hello\x80world";

    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);
    try writer.writeAny(invalid_utf8);

    var out_buffer: [64]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});

    try std.testing.expectError(error.InvalidUtf8, inspector.inspect());
}

test "inspect: valid UTF-8 with multibyte chars works" {
    // valid UTF-8: emoji and accented characters
    const valid_utf8 = "héllo 世界 🎉";

    var enc_buffer: [64]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);
    try writer.writeAny(valid_utf8);

    var out_buffer: [128]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});
    try inspector.inspect();

    try std.testing.expectEqualStrings("\"héllo 世界 🎉\"", out_fixed.buffered());
}

// =============================================================================
// Integer Tests
// =============================================================================

test "writer/reader: i64 max value" {
    var buffer: [100]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    const val: i64 = 9223372036854775807; // i64 max
    try writer.writeAny(val);

    const written = fixed.buffered();
    var reader = Reader(.{}).init(written);
    const read_val = try reader.read();
    try std.testing.expectEqual(val, read_val.i64);
}

test "writer/reader: i64 min value" {
    var buffer: [100]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    const val: i64 = -9223372036854775808; // i64 min
    try writer.writeAny(val);

    const written = fixed.buffered();
    var reader = Reader(.{}).init(written);
    const read_val = try reader.read();
    try std.testing.expectEqual(val, read_val.i64);
}

test "writer/reader: u64 max value" {
    var buffer: [100]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    const val: u64 = 18446744073709551615; // u64 max
    try writer.writeAny(val);

    const written = fixed.buffered();
    var reader = Reader(.{}).init(written);
    const read_val = try reader.read();
    try std.testing.expectEqual(val, read_val.u64);
}

// =============================================================================
// Float Tests
// =============================================================================

test "inspect: NaN f64 returns NonFiniteFloat error" {
    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    try writer.write(Value{ .f64 = std.math.nan(f64) }, .f64);

    var out_buffer: [64]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});

    try std.testing.expectError(error.NonFiniteFloat, inspector.inspect());
}

test "inspect: positive infinity f64 returns NonFiniteFloat error" {
    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    try writer.write(Value{ .f64 = std.math.inf(f64) }, .f64);

    var out_buffer: [64]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});

    try std.testing.expectError(error.NonFiniteFloat, inspector.inspect());
}

test "inspect: negative infinity f64 returns NonFiniteFloat error" {
    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    try writer.write(Value{ .f64 = -std.math.inf(f64) }, .f64);

    var out_buffer: [64]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});

    try std.testing.expectError(error.NonFiniteFloat, inspector.inspect());
}

test "inspect: NaN f32 returns NonFiniteFloat error" {
    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    try writer.write(Value{ .f32 = std.math.nan(f32) }, .f32);

    var out_buffer: [64]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});

    try std.testing.expectError(error.NonFiniteFloat, inspector.inspect());
}

test "inspect: infinity f32 returns NonFiniteFloat error" {
    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    try writer.write(Value{ .f32 = std.math.inf(f32) }, .f32);

    var out_buffer: [64]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});

    try std.testing.expectError(error.NonFiniteFloat, inspector.inspect());
}

test "inspect: finite floats work correctly" {
    var enc_buffer: [32]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    try writer.write(Value{ .f64 = 3.14159 }, .f64);

    var out_buffer: [64]u8 = undefined;
    var out_fixed = Io.Writer.fixed(&out_buffer);
    var inspector = Inspect(.{}).init(enc_fixed.buffered(), &out_fixed, .{});

    try inspector.inspect();
}

// =============================================================================
// Reader Limits Tests
// =============================================================================

test "reader: max_depth limit enforced" {
    var enc_buffer: [128]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    // Create 10 nested arrays
    for (0..10) |_| {
        try writer.startArray();
    }
    for (0..10) |_| {
        try writer.endContainer();
    }

    // Set max_depth to 5
    var reader = Reader(.{ .max_depth = 5 }).init(enc_fixed.buffered());

    // Should fail at depth 5
    var depth: usize = 0;
    while (depth < 10) : (depth += 1) {
        if (depth < 5) {
            _ = try reader.read();
        } else {
            try std.testing.expectError(error.MaxDepthExceeded, reader.read());
            break;
        }
    }
}

test "reader: max_depth null allows unlimited depth" {
    var enc_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer enc_aw.deinit();
    var writer = Writer.init(&enc_aw.writer);

    // Create 2000 nested arrays
    for (0..2000) |_| {
        try writer.startArray();
    }
    for (0..2000) |_| {
        try writer.endContainer();
    }

    // Set max_depth to null (unlimited)
    var reader = Reader(.{ .max_depth = null }).init(enc_aw.written());

    // Should be able to read all levels
    var depth: usize = 0;
    while (depth < 2000) : (depth += 1) {
        const val = try reader.read();
        try std.testing.expect(val == .array);
    }
}

test "reader: max_bytes_length limit enforced for varIntBytes" {
    var enc_buffer: [1024]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    // Write a 100-byte string
    const long_string = "x" ** 100;
    try writer.writeAny(long_string);

    // Set max_bytes_length to 50
    var reader = Reader(.{ .max_bytes_length = 50 }).init(enc_fixed.buffered());

    try std.testing.expectError(error.BytesTooLong, reader.read());
}

test "reader: max_bytes_length limit enforced for bytes" {
    var enc_buffer: [1024]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    // Write a 100-byte array using the fixed bytes type
    const long_data = [_]u8{0x42} ** 100;
    try writer.write(Value{ .bytes = &long_data }, .bytes);

    // Set max_bytes_length to 50
    var reader = Reader(.{ .max_bytes_length = 50 }).init(enc_fixed.buffered());

    try std.testing.expectError(error.BytesTooLong, reader.read());
}

test "reader: max_bytes_length null allows large bytes" {
    var enc_buffer: [2048]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    // Write a 1000-byte string
    const long_string = "y" ** 1000;
    try writer.writeAny(long_string);

    // Set max_bytes_length to null
    var reader = Reader(.{ .max_bytes_length = null }).init(enc_fixed.buffered());

    const val = try reader.read();
    try std.testing.expectEqualStrings(long_string, val.bytes);
}

test "reader: max_array_length limit enforced" {
    var enc_buffer: [1024]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    // Create array with 100 elements
    try writer.startArray();
    for (0..100) |i| {
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();

    // Set max_array_length to 50
    var reader = Reader(.{ .max_depth = 100, .max_array_length = 50 }).init(enc_fixed.buffered());

    const arr = try reader.read();
    try std.testing.expect(arr == .array);

    // Read 50 elements successfully
    var count: usize = 0;
    while (count < 51) : (count += 1) {
        if (count < 50) {
            _ = try reader.iterateArray(arr);
        } else {
            // 51st element should fail
            try std.testing.expectError(error.ArrayTooLarge, reader.iterateArray(arr));
            break;
        }
    }
}

test "reader: max_object_size limit enforced" {
    var enc_buffer: [2048]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    // Create object with 100 key-value pairs
    try writer.startObject();
    for (0..100) |i| {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try writer.writeAny(key);
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();

    // Set max_object_size to 50
    var reader = Reader(.{ .max_depth = 100, .max_object_size = 50 }).init(enc_fixed.buffered());

    const obj = try reader.read();
    try std.testing.expect(obj == .object);

    // Read 50 pairs successfully
    var count: usize = 0;
    while (count < 51) : (count += 1) {
        if (count < 50) {
            _ = try reader.iterateObject(obj);
        } else {
            // 51st pair should fail
            try std.testing.expectError(error.ObjectTooLarge, reader.iterateObject(obj));
            break;
        }
    }
}

test "reader: sibling containers have separate counts" {
    var enc_buffer: [2048]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    // Create two sibling arrays at the same depth
    try writer.startArray(); // outer array
    try writer.startArray(); // first inner array with 40 elements
    for (0..40) |i| {
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();
    try writer.startArray(); // second inner array with 40 elements
    for (0..40) |i| {
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();
    try writer.endContainer();

    // Set max_array_length to 50 - each array has 40, so both should pass
    var reader = Reader(.{ .max_depth = 100, .max_array_length = 50 }).init(enc_fixed.buffered());

    const outer = try reader.read();
    try std.testing.expect(outer == .array);

    const inner1 = (try reader.iterateArray(outer)).?;
    try std.testing.expect(inner1 == .array);
    var count1: usize = 0;
    while (try reader.iterateArray(inner1)) |_| {
        count1 += 1;
    }
    try std.testing.expectEqual(40, count1);

    const inner2 = (try reader.iterateArray(outer)).?;
    try std.testing.expect(inner2 == .array);
    var count2: usize = 0;
    while (try reader.iterateArray(inner2)) |_| {
        count2 += 1;
    }
    try std.testing.expectEqual(40, count2);
}

test "reader: combined limits enforced" {
    var enc_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer enc_aw.deinit();
    var writer = Writer.init(&enc_aw.writer);

    // Create nested structure with large string
    try writer.startObject();
    try writer.writeAny("data");
    try writer.writeAny("z" ** 200);
    try writer.endContainer();

    // Set strict limits on everything
    var reader = Reader(.{
        .max_depth = 10,
        .max_bytes_length = 100,
        .max_array_length = 50,
        .max_object_size = 50,
    }).init(enc_aw.written());

    const obj = try reader.read();
    try std.testing.expect(obj == .object);

    try std.testing.expectError(error.BytesTooLong, reader.iterateObject(obj));
}
