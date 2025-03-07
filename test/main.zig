/// Unit tests
const std = @import("std");
const bufzilla = @import("bufzilla");

pub const Writer = bufzilla.Writer;
pub const Reader = bufzilla.Reader;
pub const Inspect = bufzilla.Inspect;
pub const Value = bufzilla.Value;
pub const Common = bufzilla.Common;

pub const encodingTests = @import("encoding.zig");

var buf1: [1024]u8 = undefined;
var buf1_len: usize = undefined;

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "writer: primitive data types" {
    var writer = Writer.init(std.testing.allocator);
    defer writer.deinit();

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

    @memcpy(buf1[0..writer.len()], writer.bytes());
    buf1_len = writer.len();
}

test "writer: zig data types" {
    var sba = std.heap.stackFallback(1024, std.testing.allocator);
    var writer = Writer.init(sba.get());
    defer writer.deinit();

    const DataType = struct { a: i64, b: struct {
        c: bool,
    }, d: []const union(enum) {
        null: ?void,
        f64: f64,
        string: []const u8,
    } };

    const data = DataType{
        .a = 123,
        .b = .{ .c = true },
        .d = &.{ .{ .f64 = 123.123 }, .{ .null = null }, .{ .string = "value" } },
    };

    var timer = try std.time.Timer.start();
    try writer.writeAny(data);
    const elapsed = timer.read();

    std.debug.print("size: {d} bytes\n{any}\nelapsed: {d} ns\n", .{ writer.len(), writer.bytes(), elapsed });

    try std.testing.expect(std.mem.eql(u8, buf1[0..buf1_len], writer.bytes()));
}

test "reader: simple" {
    var reader = Reader.init(buf1[0..buf1_len]);

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

test "inspect api" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer();

    var inspector = Inspect.init(buf1[0..buf1_len], &writer, .{});
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

    try std.testing.expectEqualStrings(expected, buf.items);
}
