/// Inspect API

const std = @import("std");
const common = @import("common.zig");
const Reader = @import("Reader.zig");

pub const InspectOptions = struct {
    indent_size: usize = 4,
    float_precision: usize = 14,
};

const Inspect = @This();

writer: std.io.AnyWriter,
reader: Reader,
options: InspectOptions,
current_depth: usize = 0,

/// Initialize the Inspector with a encoded data buffer and writer.
pub fn init(data: []const u8, writer: anytype, options: InspectOptions) Inspect {
    const reader = Reader.init(data);

    return .{
        .writer = writer.any(),
        .reader = reader,
        .options = options,
    };
}

fn writeIndent(self: *Inspect, depth: u32) !void {
    var i: usize = 0;
    while (i < depth * self.options.indent_size) : (i += 1) {
        try self.writer.writeByte(' ');
    }
}

fn writeString(self: *Inspect, str: []const u8) !void {
    try self.writer.writeByte('"');
    for (str) |c| {
        switch (c) {
            '"' => try self.writer.writeAll("\\\""),
            '\\' => try self.writer.writeAll("\\\\"),
            '\n' => try self.writer.writeAll("\\n"),
            '\r' => try self.writer.writeAll("\\r"),
            '\t' => try self.writer.writeAll("\\t"),
            else => try self.writer.writeByte(c),
        }
    }
    try self.writer.writeByte('"');
}

/// Prints a single value to the stream.
pub fn printValue(self: *Inspect, val: common.Value, depth: u32) !void {
    var count: usize = 0;

    switch (val.type) {
        .Object => {
            try self.writer.writeAll("{\n");

            while (try self.reader.iterateObject(val)) |kv| {
                if (count > 0) {
                    try self.writer.writeAll(",\n");
                }
                count += 1;

                try self.writeIndent(depth + 1);
                try self.printValue(kv.key, depth + 1);
                try self.writer.writeAll(": ");
                try self.printValue(kv.value, depth + 1);
            }

            if (count > 0) try self.writer.writeByte('\n');
            try self.writeIndent(depth);
            try self.writer.writeByte('}');
        },
        .Array => {
            try self.writer.writeAll("[\n");

            while (try self.reader.iterateArray(val)) |item| {
                if (count > 0) {
                    try self.writer.writeAll(",\n");
                }
                count += 1;

                try self.writeIndent(depth + 1);
                try self.printValue(item, depth + 1);
            }

            if (count > 0) try self.writer.writeByte('\n');
            try self.writeIndent(depth);
            try self.writer.writeByte(']');
        },
        .f64 => try std.fmt.formatFloatHexadecimal(val.value.f64, .{ .precision = self.options.float_precision }, self.writer),
        .f32 => try std.fmt.formatFloatHexadecimal(val.value.f32, .{ .precision = self.options.float_precision }, self.writer),
        .i64 => try std.fmt.formatInt(val.value.i64, 10, .lower, .{}, self.writer),
        .i32 => try std.fmt.formatInt(val.value.i32, 10, .lower, .{}, self.writer),
        .i16 => try std.fmt.formatInt(val.value.i16, 10, .lower, .{}, self.writer),
        .i8 => try std.fmt.formatInt(val.value.i8, 10, .lower, .{}, self.writer),
        .u64 => try std.fmt.formatInt(val.value.u64, 10, .lower, .{}, self.writer),
        .u32 => try std.fmt.formatInt(val.value.u32, 10, .lower, .{}, self.writer),
        .u16 => try std.fmt.formatInt(val.value.u16, 10, .lower, .{}, self.writer),
        .u8 => try std.fmt.formatInt(val.value.u8, 10, .lower, .{}, self.writer),
        .Bool => try self.writer.writeAll(if (val.value.bool) "true" else "false"),
        .String => try self.writeString(val.value.string),
        .Null => try self.writer.writeAll("null"),
        .ContainerEnd => try self.writer.writeAll("END"),
    }
}

/// Inspect the encoded data and print it to the writer.
/// If the first tag is an Object, it will be printed as JSON.
pub fn inspect(self: *Inspect) !void {
    const root_value = try self.reader.read();
    try self.printValue(root_value, 0);
    try self.writer.writeByte('\n');
}

test "inspector" {
    const data = [_]u8{ 14, 0, 4, 0, 0, 0, 0, 0, 0, 0, 110, 97, 109, 101, 0, 5, 0, 0, 0, 0, 0, 0, 0, 115, 97, 121, 97, 110, 0, 8, 0, 0, 0, 0, 0, 0, 0, 108, 111, 99, 97, 116, 105, 111, 110, 14, 0, 4, 0, 0, 0, 0, 0, 0, 0, 99, 105, 116, 121, 0, 7, 0, 0, 0, 0, 0, 0, 0, 75, 111, 108, 107, 97, 116, 97, 15, 0, 4, 0, 0, 0, 0, 0, 0, 0, 116, 97, 103, 115, 13, 0, 4, 0, 0, 0, 0, 0, 0, 0, 98, 111, 122, 111, 11, 0, 15, 15 };

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer();

    var inspector = Inspect.init(&data, &writer, .{});
    try inspector.inspect();

    std.debug.print("{s}", .{buf.items});

    // const expected =
    //     \\{
    //     \\    "hello": 42
    //     \\}
    //     \\
    // ;
    // try std.testing.expectEqualStrings(expected, buf.items);
}