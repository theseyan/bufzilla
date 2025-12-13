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

    try std.testing.expect(written.len == 33);
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

test "writer/fixed: small tags are used" {
    // smallIntPositive
    {
        var buffer: [16]u8 = undefined;
        var fixed = Io.Writer.fixed(&buffer);
        var writer = Writer.init(&fixed);

        try writer.writeAny(@as(i64, 7));
        const written = fixed.buffered();
        try std.testing.expectEqual(@as(usize, 1), written.len);

        const decoded = Common.decodeTag(written[0]);
        try std.testing.expectEqual(@as(u5, @intCast(@intFromEnum(Value.smallIntPositive))), decoded.tag);
        try std.testing.expectEqual(@as(u3, 7), decoded.data);
    }

    // smallIntNegative
    {
        var buffer: [16]u8 = undefined;
        var fixed = Io.Writer.fixed(&buffer);
        var writer = Writer.init(&fixed);

        try writer.writeAny(@as(i64, -7));
        const written = fixed.buffered();
        try std.testing.expectEqual(@as(usize, 1), written.len);

        const decoded = Common.decodeTag(written[0]);
        try std.testing.expectEqual(@as(u5, @intCast(@intFromEnum(Value.smallIntNegative))), decoded.tag);
        try std.testing.expectEqual(@as(u3, 7), decoded.data);
    }

    // smallBytes
    {
        var buffer: [32]u8 = undefined;
        var fixed = Io.Writer.fixed(&buffer);
        var writer = Writer.init(&fixed);

        try writer.writeAny("1234567"); // len=7
        const written = fixed.buffered();
        try std.testing.expectEqual(@as(usize, 1 + 7), written.len);

        const decoded = Common.decodeTag(written[0]);
        try std.testing.expectEqual(@as(u5, @intCast(@intFromEnum(Value.smallBytes))), decoded.tag);
        try std.testing.expectEqual(@as(u3, 7), decoded.data);
    }

    // Struct keys also use smallBytes when short
    {
        const S = struct { a: i64 };
        var buffer: [32]u8 = undefined;
        var fixed = Io.Writer.fixed(&buffer);
        var writer = Writer.init(&fixed);

        try writer.writeAny(S{ .a = 1 });
        const written = fixed.buffered();
        try std.testing.expect(written.len > 0);

        // [ object_tag ][ key_tag ][ 'a' ][ value_tag ][ end_tag ]
        const key_decoded = Common.decodeTag(written[1]);
        try std.testing.expectEqual(@as(u5, @intCast(@intFromEnum(Value.smallBytes))), key_decoded.tag);
        try std.testing.expectEqual(@as(u3, 1), key_decoded.data);
        try std.testing.expectEqual(@as(u8, 'a'), written[2]);
    }
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
// Writer.applyUpdates Tests
// =============================================================================

test "writer/applyUpdates: leaf, nested, and upsert" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);

    // Original object:
    // { a: 1, b: { c: true, d: "old" }, arr: [10, 20] }
    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny("b");
    try writer.startObject();
    try writer.writeAny("c");
    try writer.writeAny(true);
    try writer.writeAny("d");
    try writer.writeAny("old");
    try writer.endContainer();
    try writer.writeAny("arr");
    try writer.startArray();
    try writer.writeAny(@as(i64, 10));
    try writer.writeAny(@as(i64, 20));
    try writer.endContainer();
    try writer.endContainer();

    const encoded = aw.written();

    var new_a: i64 = 2;
    var new_d: []const u8 = "new";
    var new_x: i64 = 999;
    var new_f: i64 = 5;
    var new_arr1: i64 = 99;
    var new_arr3: i64 = 33;

    var updates = [_]Writer.Update{
        Writer.Update.init("a", &new_a),
        Writer.Update.init("b.d", &new_d),
        Writer.Update.init("x", &new_x),
        Writer.Update.init("b.e.f", &new_f),
        Writer.Update.init("arr[1]", &new_arr1),
        Writer.Update.init("arr[3]", &new_arr3),
    };

    var out_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer out_aw.deinit();
    var out_writer = Writer.init(&out_aw.writer);

    try out_writer.applyUpdates(encoded, updates[0..]);

    const out_buf = out_aw.written();
    var reader = Reader(.{}).init(out_buf);

    try std.testing.expectEqual(2, (try reader.readPath("a")).?.i64);
    try std.testing.expectEqualStrings("new", (try reader.readPath("b.d")).?.bytes);
    try std.testing.expectEqual(true, (try reader.readPath("b.c")).?.bool);
    try std.testing.expectEqual(5, (try reader.readPath("b.e.f")).?.i64);
    try std.testing.expectEqual(999, (try reader.readPath("x")).?.i64);

    try std.testing.expectEqual(10, (try reader.readPath("arr[0]")).?.i64);
    try std.testing.expectEqual(99, (try reader.readPath("arr[1]")).?.i64);
    const arr2 = (try reader.readPath("arr[2]")).?;
    try std.testing.expect(arr2 == .null);
    try std.testing.expectEqual(33, (try reader.readPath("arr[3]")).?.i64);
}

test "writer/applyUpdates: conflicting leaf and child updates" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);
    try writer.startObject();
    try writer.writeAny("b");
    try writer.startObject();
    try writer.writeAny("c");
    try writer.writeAny(true);
    try writer.endContainer();
    try writer.endContainer();

    const encoded = aw.written();

    var new_b: i64 = 1;
    var new_c: i64 = 2;

    var updates = [_]Writer.Update{
        Writer.Update.init("b", &new_b),
        Writer.Update.init("b.c", &new_c),
    };

    var out_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer out_aw.deinit();
    var out_writer = Writer.init(&out_aw.writer);

    try std.testing.expectError(bufzilla.ApplyUpdatesError.ConflictingUpdates, out_writer.applyUpdates(encoded, updates[0..]));
}

test "writer/applyUpdates: invalid root" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);
    try writer.writeAny(@as(i64, 1));

    const encoded = aw.written();

    var new_a: i64 = 2;
    var updates = [_]Writer.Update{
        Writer.Update.init("a", &new_a),
    };

    var out_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer out_aw.deinit();
    var out_writer = Writer.init(&out_aw.writer);

    try std.testing.expectError(bufzilla.ApplyUpdatesError.InvalidRoot, out_writer.applyUpdates(encoded, updates[0..]));
}

test "writer/applyUpdates: malformed path" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);
    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(@as(i64, 1));
    try writer.endContainer();

    const encoded = aw.written();

    var new_b: i64 = 2;
    var updates = [_]Writer.Update{
        Writer.Update.init("a[", &new_b),
    };

    var out_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer out_aw.deinit();
    var out_writer = Writer.init(&out_aw.writer);

    try std.testing.expectError(bufzilla.ApplyUpdatesError.MalformedPath, out_writer.applyUpdates(encoded, updates[0..]));
}

test "writer/applyUpdates: path type mismatch" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);
    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(@as(i64, 1));
    try writer.endContainer();

    const encoded = aw.written();

    var new_b: i64 = 2;
    var updates = [_]Writer.Update{
        Writer.Update.init("a.b", &new_b),
    };

    var out_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer out_aw.deinit();
    var out_writer = Writer.init(&out_aw.writer);

    try std.testing.expectError(bufzilla.ApplyUpdatesError.PathTypeMismatch, out_writer.applyUpdates(encoded, updates[0..]));
}

test "writer/applyUpdates: root replacement conflicts" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);
    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(@as(i64, 1));
    try writer.endContainer();

    const encoded = aw.written();

    var new_root: i64 = 123;
    var new_a: i64 = 2;
    var updates = [_]Writer.Update{
        Writer.Update.init("", &new_root),
        Writer.Update.init("a", &new_a),
    };

    var out_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer out_aw.deinit();
    var out_writer = Writer.init(&out_aw.writer);

    try std.testing.expectError(bufzilla.ApplyUpdatesError.ConflictingUpdates, out_writer.applyUpdates(encoded, updates[0..]));
}

test "writer/applyUpdates: propagates reader unexpected eof" {
    var aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);
    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(@as(i64, 1));
    try writer.endContainer();

    const encoded = aw.written();
    std.debug.assert(encoded.len > 1);
    const truncated = encoded[0 .. encoded.len - 1];

    var new_z: i64 = 2;
    var updates = [_]Writer.Update{
        Writer.Update.init("z", &new_z),
    };

    var out_aw = Io.Writer.Allocating.init(std.testing.allocator);
    defer out_aw.deinit();
    var out_writer = Writer.init(&out_aw.writer);

    try std.testing.expectError(bufzilla.ReadError.UnexpectedEof, out_writer.applyUpdates(truncated, updates[0..]));
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

test "readPath: max_object_size counts non-byte keys" {
    var enc_buffer: [256]u8 = undefined;
    var enc_fixed = Io.Writer.fixed(&enc_buffer);
    var writer = Writer.init(&enc_fixed);

    try writer.startObject();
    // Non-byte keys: each pair should still count toward max_object_size
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny(true);
    try writer.writeAny(@as(i64, 2));
    try writer.writeAny(true);
    try writer.writeAny(@as(i64, 3));
    try writer.writeAny(true);
    try writer.endContainer();

    var reader = Reader(.{ .max_depth = 10, .max_object_size = 2 }).init(enc_fixed.buffered());
    try std.testing.expectError(error.ObjectTooLarge, reader.readPath("anything"));
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

// =============================================================================
// readPath Tests
// =============================================================================

test "readPath: simple object key" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("name");
    try writer.writeAny("Alice");
    try writer.writeAny("age");
    try writer.writeAny(@as(i64, 30));
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const name = try reader.readPath("name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Alice", name.?.bytes);

    const age = try reader.readPath("age");
    try std.testing.expect(age != null);
    try std.testing.expectEqual(@as(i64, 30), age.?.i64);

    // Position should be unchanged
    try std.testing.expectEqual(@as(usize, 0), reader.pos);
}

test "readPaths: multiple queries single pass" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("name");
    try writer.writeAny("Alice");
    try writer.writeAny("age");
    try writer.writeAny(@as(i64, 30));
    try writer.writeAny("address");
    try writer.startObject();
    try writer.writeAny("city");
    try writer.writeAny("NYC");
    try writer.endContainer();
    try writer.writeAny("items");
    try writer.startArray();
    try writer.startObject();
    try writer.writeAny("score");
    try writer.writeAny(@as(i64, 10));
    try writer.endContainer();
    try writer.startObject();
    try writer.writeAny("score");
    try writer.writeAny(@as(i64, 20));
    try writer.endContainer();
    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    var queries = [_]bufzilla.PathQuery{
        .{ .path = "name" },
        .{ .path = "address.city" },
        .{ .path = "items[1].score" },
        .{ .path = "nonexistent.path" },
        .{ .path = "" },
        .{ .path = "[0" }, // malformed
    };

    try reader.readPaths(queries[0..]);

    try std.testing.expectEqualStrings("name", queries[0].path);
    try std.testing.expectEqualStrings("address.city", queries[1].path);
    try std.testing.expectEqualStrings("items[1].score", queries[2].path);

    try std.testing.expectEqualStrings("Alice", queries[0].value.?.bytes);
    try std.testing.expectEqualStrings("NYC", queries[1].value.?.bytes);
    try std.testing.expectEqual(@as(i64, 20), queries[2].value.?.i64);
    try std.testing.expect(queries[3].value == null);
    try std.testing.expect(queries[4].value != null and queries[4].value.? == .object);
    try std.testing.expect(queries[5].value == null);

    // Position should be unchanged.
    try std.testing.expectEqual(@as(usize, 0), reader.pos);
}

test "readPath: nested object" {
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("person");
    try writer.startObject();
    try writer.writeAny("name");
    try writer.writeAny("Bob");
    try writer.writeAny("address");
    try writer.startObject();
    try writer.writeAny("city");
    try writer.writeAny("NYC");
    try writer.endContainer();
    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const name = try reader.readPath("person.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Bob", name.?.bytes);

    const city = try reader.readPath("person.address.city");
    try std.testing.expect(city != null);
    try std.testing.expectEqualStrings("NYC", city.?.bytes);
}

test "readPath: array index" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    try writer.writeAny("first");
    try writer.writeAny("second");
    try writer.writeAny("third");
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const first = try reader.readPath("[0]");
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("first", first.?.bytes);

    const second = try reader.readPath("[1]");
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("second", second.?.bytes);

    const third = try reader.readPath("[2]");
    try std.testing.expect(third != null);
    try std.testing.expectEqualStrings("third", third.?.bytes);
}

test "readPath: array in object" {
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("items");
    try writer.startArray();
    try writer.writeAny("apple");
    try writer.writeAny("banana");
    try writer.writeAny("cherry");
    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const first_item = try reader.readPath("items[0]");
    try std.testing.expect(first_item != null);
    try std.testing.expectEqualStrings("apple", first_item.?.bytes);

    const third_item = try reader.readPath("items[2]");
    try std.testing.expect(third_item != null);
    try std.testing.expectEqualStrings("cherry", third_item.?.bytes);
}

test "readPath: complex nested path" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // { "users": [{"name": "Alice", "scores": [100, 95]}, {"name": "Bob", "scores": [80, 90]}] }
    try writer.startObject();
    try writer.writeAny("users");
    try writer.startArray();

    try writer.startObject();
    try writer.writeAny("name");
    try writer.writeAny("Alice");
    try writer.writeAny("scores");
    try writer.startArray();
    try writer.writeAny(@as(i64, 100));
    try writer.writeAny(@as(i64, 95));
    try writer.endContainer();
    try writer.endContainer();

    try writer.startObject();
    try writer.writeAny("name");
    try writer.writeAny("Bob");
    try writer.writeAny("scores");
    try writer.startArray();
    try writer.writeAny(@as(i64, 80));
    try writer.writeAny(@as(i64, 90));
    try writer.endContainer();
    try writer.endContainer();

    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const alice_name = try reader.readPath("users[0].name");
    try std.testing.expect(alice_name != null);
    try std.testing.expectEqualStrings("Alice", alice_name.?.bytes);

    const bob_name = try reader.readPath("users[1].name");
    try std.testing.expect(bob_name != null);
    try std.testing.expectEqualStrings("Bob", bob_name.?.bytes);

    const alice_first_score = try reader.readPath("users[0].scores[0]");
    try std.testing.expect(alice_first_score != null);
    try std.testing.expectEqual(@as(i64, 100), alice_first_score.?.i64);

    const bob_second_score = try reader.readPath("users[1].scores[1]");
    try std.testing.expect(bob_second_score != null);
    try std.testing.expectEqual(@as(i64, 90), bob_second_score.?.i64);
}

test "readPath: non-existent key returns null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("name");
    try writer.writeAny("Alice");
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const missing = try reader.readPath("age");
    try std.testing.expect(missing == null);

    const nested_missing = try reader.readPath("person.name");
    try std.testing.expect(nested_missing == null);
}

test "readPath: out of bounds array index returns null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    try writer.writeAny("only");
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const out_of_bounds = try reader.readPath("[5]");
    try std.testing.expect(out_of_bounds == null);
}

test "readPath: empty path returns root" {
    var buffer: [64]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.writeAny("hello");

    var reader = Reader(.{}).init(fixed.buffered());

    const root = try reader.readPath("");
    try std.testing.expect(root != null);
    try std.testing.expectEqualStrings("hello", root.?.bytes);
}

test "readPath: preserves reader position after multiple calls" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny("b");
    try writer.writeAny(@as(i64, 2));
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // Advance reader to middle of buffer
    _ = try reader.read(); // object
    _ = try reader.read(); // "a"
    const saved_pos = reader.pos;

    // Multiple readPath calls
    _ = try reader.readPath("a");
    _ = try reader.readPath("b");
    _ = try reader.readPath("nonexistent");

    // Position should be unchanged
    try std.testing.expectEqual(saved_pos, reader.pos);
}

test "readPath: type mismatch returns null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("value");
    try writer.writeAny(@as(i64, 42));
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // Trying to access index on non-array
    const result = try reader.readPath("value[0]");
    try std.testing.expect(result == null);

    // Trying to access key on non-object
    const result2 = try reader.readPath("value.key");
    try std.testing.expect(result2 == null);
}

test "readPath: nested arrays" {
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // [[1, 2], [3, 4], [5, 6]]
    try writer.startArray();
    try writer.startArray();
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny(@as(i64, 2));
    try writer.endContainer();
    try writer.startArray();
    try writer.writeAny(@as(i64, 3));
    try writer.writeAny(@as(i64, 4));
    try writer.endContainer();
    try writer.startArray();
    try writer.writeAny(@as(i64, 5));
    try writer.writeAny(@as(i64, 6));
    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const val_0_0 = try reader.readPath("[0][0]");
    try std.testing.expect(val_0_0 != null);
    try std.testing.expectEqual(@as(i64, 1), val_0_0.?.i64);

    const val_1_1 = try reader.readPath("[1][1]");
    try std.testing.expect(val_1_1 != null);
    try std.testing.expectEqual(@as(i64, 4), val_1_1.?.i64);

    const val_2_0 = try reader.readPath("[2][0]");
    try std.testing.expect(val_2_0 != null);
    try std.testing.expectEqual(@as(i64, 5), val_2_0.?.i64);
}

test "readPath: various value types" {
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("str");
    try writer.writeAny("hello");
    try writer.writeAny("int");
    try writer.writeAny(@as(i64, 42));
    try writer.writeAny("float");
    try writer.writeAny(@as(f64, 3.14));
    try writer.writeAny("bool_t");
    try writer.writeAny(true);
    try writer.writeAny("bool_f");
    try writer.writeAny(false);
    try writer.writeAny("null_val");
    try writer.writeAny(null);
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const str_val = try reader.readPath("str");
    try std.testing.expect(str_val != null);
    try std.testing.expectEqualStrings("hello", str_val.?.bytes);

    const int_val = try reader.readPath("int");
    try std.testing.expect(int_val != null);
    try std.testing.expectEqual(@as(i64, 42), int_val.?.i64);

    const float_val = try reader.readPath("float");
    try std.testing.expect(float_val != null);
    try std.testing.expectEqual(@as(f64, 3.14), float_val.?.f64);

    const bool_t = try reader.readPath("bool_t");
    try std.testing.expect(bool_t != null);
    try std.testing.expectEqual(true, bool_t.?.bool);

    const bool_f = try reader.readPath("bool_f");
    try std.testing.expect(bool_f != null);
    try std.testing.expectEqual(false, bool_f.?.bool);

    const null_val = try reader.readPath("null_val");
    try std.testing.expect(null_val != null);
    try std.testing.expect(null_val.? == .null);
}

test "readPath: quoted keys with single quotes" {
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("John Marston");
    try writer.writeAny(@as(i64, 42));
    try writer.writeAny("key.with.dots");
    try writer.writeAny("dotted");
    try writer.writeAny("has spaces");
    try writer.writeAny("spacy");
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const john = try reader.readPath("['John Marston']");
    try std.testing.expect(john != null);
    try std.testing.expectEqual(@as(i64, 42), john.?.i64);

    const dotted = try reader.readPath("['key.with.dots']");
    try std.testing.expect(dotted != null);
    try std.testing.expectEqualStrings("dotted", dotted.?.bytes);

    const spacy = try reader.readPath("['has spaces']");
    try std.testing.expect(spacy != null);
    try std.testing.expectEqualStrings("spacy", spacy.?.bytes);
}

test "readPath: quoted keys with double quotes" {
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("John Marston");
    try writer.writeAny(@as(i64, 42));
    try writer.writeAny("key.with.dots");
    try writer.writeAny("dotted");
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const john = try reader.readPath("[\"John Marston\"]");
    try std.testing.expect(john != null);
    try std.testing.expectEqual(@as(i64, 42), john.?.i64);

    const dotted = try reader.readPath("[\"key.with.dots\"]");
    try std.testing.expect(dotted != null);
    try std.testing.expectEqualStrings("dotted", dotted.?.bytes);
}

test "readPath: nested quoted keys" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // { "persons": { "John Marston": { "age": 42 } } }
    try writer.startObject();
    try writer.writeAny("persons");
    try writer.startObject();
    try writer.writeAny("John Marston");
    try writer.startObject();
    try writer.writeAny("age");
    try writer.writeAny(@as(i64, 42));
    try writer.endContainer();
    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const age = try reader.readPath("persons['John Marston'].age");
    try std.testing.expect(age != null);
    try std.testing.expectEqual(@as(i64, 42), age.?.i64);

    // Also test with double quotes
    const age2 = try reader.readPath("persons[\"John Marston\"].age");
    try std.testing.expect(age2 != null);
    try std.testing.expectEqual(@as(i64, 42), age2.?.i64);
}

test "readPath: mixed quoted and unquoted keys" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // { "data": { "special key": { "normal": 123 } } }
    try writer.startObject();
    try writer.writeAny("data");
    try writer.startObject();
    try writer.writeAny("special key");
    try writer.startObject();
    try writer.writeAny("normal");
    try writer.writeAny(@as(i64, 123));
    try writer.endContainer();
    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const val = try reader.readPath("data['special key'].normal");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 123), val.?.i64);
}

test "readPath: does not modify position" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny("b");
    try writer.writeAny(@as(i64, 2));
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // Advance to some position
    _ = try reader.read(); // object
    _ = try reader.read(); // "a"
    const saved_pos = reader.pos;
    const saved_depth = reader.depth;

    _ = try reader.readPath("b");

    try std.testing.expectEqual(saved_pos, reader.pos);
    try std.testing.expectEqual(saved_depth, reader.depth);
}

test "readPath: quoted keys in arrays" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // { "items": [{"name with space": "val1"}, {"name with space": "val2"}] }
    try writer.startObject();
    try writer.writeAny("items");
    try writer.startArray();
    try writer.startObject();
    try writer.writeAny("name with space");
    try writer.writeAny("val1");
    try writer.endContainer();
    try writer.startObject();
    try writer.writeAny("name with space");
    try writer.writeAny("val2");
    try writer.endContainer();
    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    const val1 = try reader.readPath("items[0]['name with space']");
    try std.testing.expect(val1 != null);
    try std.testing.expectEqualStrings("val1", val1.?.bytes);

    const val2 = try reader.readPath("items[1]['name with space']");
    try std.testing.expect(val2 != null);
    try std.testing.expectEqualStrings("val2", val2.?.bytes);
}

test "readPath: malformed path missing bracket returns null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    try writer.writeAny(@as(i64, 1));
    try writer.writeAny(@as(i64, 2));
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // Missing closing bracket
    const result = try reader.readPath("[0");
    try std.testing.expect(result == null);
}

test "readPath: malformed path missing quote returns null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("key");
    try writer.writeAny(@as(i64, 42));
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // Missing closing quote in bracket notation
    const result = try reader.readPath("['key");
    try std.testing.expect(result == null);

    // Missing closing quote without brackets
    const result2 = try reader.readPath("'key");
    try std.testing.expect(result2 == null);
}

test "readPath: malformed path invalid index returns null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    try writer.writeAny(@as(i64, 1));
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // Invalid index (not a number)
    const result = try reader.readPath("[abc]");
    try std.testing.expect(result == null);
}

test "readPath: propagates errors from malformed buffer" {
    // Create a truncated/malformed buffer
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("key");
    // Don't write value or close object - truncated

    const written = fixed.buffered();
    // Truncate even more to create malformed data
    const truncated = written[0 .. written.len - 2];

    var reader = Reader(.{}).init(truncated);

    // Should return error, not null
    const result = reader.readPath("key");
    try std.testing.expectError(error.UnexpectedEof, result);
}

test "readPath: propagates max_depth error" {
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // Create nested structure: { "a": { "b": { "c": 42 } } }
    try writer.startObject();
    try writer.writeAny("a");
    try writer.startObject();
    try writer.writeAny("b");
    try writer.startObject();
    try writer.writeAny("c");
    try writer.writeAny(@as(i64, 42));
    try writer.endContainer();
    try writer.endContainer();
    try writer.endContainer();

    // Reader with max_depth = 2 - should fail when trying to navigate 3 levels deep
    var reader = Reader(.{ .max_depth = 2 }).init(fixed.buffered());

    const result = reader.readPath("a.b.c");
    try std.testing.expectError(error.MaxDepthExceeded, result);
}

test "readPath: propagates max_bytes_length error" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // Create structure with a long string that we need to skip
    try writer.startObject();
    try writer.writeAny("long_key");
    try writer.writeAny("x" ** 100); // 100 byte string
    try writer.writeAny("target");
    try writer.writeAny(@as(i64, 42));
    try writer.endContainer();

    // Reader with max_bytes_length = 50 - should fail when skipping the 100-byte string
    var reader = Reader(.{ .max_bytes_length = 50 }).init(fixed.buffered());

    const result = reader.readPath("target");
    try std.testing.expectError(error.BytesTooLong, result);
}

test "readPaths: propagates max_bytes_length error" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // Create structure with a long string that we need to skip
    try writer.startObject();
    try writer.writeAny("long_key");
    try writer.writeAny("x" ** 100); // 100 byte string
    try writer.writeAny("target");
    try writer.writeAny(@as(i64, 42));
    try writer.endContainer();

    var reader = Reader(.{ .max_bytes_length = 50 }).init(fixed.buffered());

    var queries = [_]bufzilla.PathQuery{
        .{ .path = "target" },
    };

    try std.testing.expectError(error.BytesTooLong, reader.readPaths(queries[0..]));
}

test "readPath: propagates max_array_length error" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // Create array with 20 elements
    try writer.startArray();
    for (0..20) |i| {
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();

    // Reader with max_array_length = 10 - should fail when accessing index 15
    var reader = Reader(.{ .max_depth = 10, .max_array_length = 10 }).init(fixed.buffered());

    const result = reader.readPath("[15]");
    try std.testing.expectError(error.ArrayTooLarge, result);
}

test "readPaths: propagates max_array_length error" {
    var buffer: [512]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // Create array with 20 elements
    try writer.startArray();
    for (0..20) |i| {
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();

    var reader = Reader(.{ .max_depth = 10, .max_array_length = 10 }).init(fixed.buffered());

    var queries = [_]bufzilla.PathQuery{
        .{ .path = "[15]" },
    };

    try std.testing.expectError(error.ArrayTooLarge, reader.readPaths(queries[0..]));
}

test "readPath: propagates max_object_size error" {
    var buffer: [1024]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // Create object with 20 keys
    try writer.startObject();
    for (0..20) |i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try writer.writeAny(key);
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();

    // Reader with max_object_size = 10 - should fail when looking for key15
    var reader = Reader(.{ .max_depth = 10, .max_object_size = 10 }).init(fixed.buffered());

    const result = reader.readPath("key15");
    try std.testing.expectError(error.ObjectTooLarge, result);
}

test "readPaths: propagates max_object_size error" {
    var buffer: [1024]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // Create object with 20 keys
    try writer.startObject();
    for (0..20) |i| {
        var key_buf: [8]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try writer.writeAny(key);
        try writer.writeAny(@as(i64, @intCast(i)));
    }
    try writer.endContainer();

    var reader = Reader(.{ .max_depth = 10, .max_object_size = 10 }).init(fixed.buffered());

    var queries = [_]bufzilla.PathQuery{
        .{ .path = "key15" },
    };

    try std.testing.expectError(error.ObjectTooLarge, reader.readPaths(queries[0..]));
}

test "readPaths: non-container root returns only root on empty path" {
    var buffer: [64]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.writeAny(@as(i64, 5));

    var reader = Reader(.{}).init(fixed.buffered());

    var queries = [_]bufzilla.PathQuery{
        .{ .path = "" },
        .{ .path = "a" },
        .{ .path = "[0]" },
    };

    try reader.readPaths(queries[0..]);

    try std.testing.expect(queries[0].value != null);
    try std.testing.expectEqual(@as(i64, 5), queries[0].value.?.i64);
    try std.testing.expect(queries[1].value == null);
    try std.testing.expect(queries[2].value == null);
}

test "readPaths: root type mismatch yields null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("a");
    try writer.writeAny(@as(i64, 1));
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    var queries = [_]bufzilla.PathQuery{
        .{ .path = "[0]" },
        .{ .path = "a" },
    };

    try reader.readPaths(queries[0..]);
    try std.testing.expect(queries[0].value == null);
    try std.testing.expectEqual(@as(i64, 1), queries[1].value.?.i64);
}

test "readPath: array root with key path returns null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startArray();
    try writer.writeAny("element");
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // Key path on array root should return null, not error
    const result = try reader.readPath("name");
    try std.testing.expect(result == null);
}

test "readPath: object root with index path returns null" {
    var buffer: [128]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    try writer.startObject();
    try writer.writeAny("key");
    try writer.writeAny("value");
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // Index path on object root should return null, not a value
    const result = try reader.readPath("[0]");
    try std.testing.expect(result == null);
}

test "readPath: nested type mismatch returns null" {
    var buffer: [256]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);

    // { "data": ["a", "b", "c"] }
    try writer.startObject();
    try writer.writeAny("data");
    try writer.startArray();
    try writer.writeAny("a");
    try writer.writeAny("b");
    try writer.writeAny("c");
    try writer.endContainer();
    try writer.endContainer();

    var reader = Reader(.{}).init(fixed.buffered());

    // data is an array, not object - key access should return null
    const result = try reader.readPath("data.key");
    try std.testing.expect(result == null);

    // Nested object access on array should return null
    const result2 = try reader.readPath("data[0].nested");
    try std.testing.expect(result2 == null);
}
