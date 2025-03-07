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

    switch (val) {
        .object => {
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
        .array => {
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
        .f64 => {
            var buf: [128]u8 = undefined;
            try self.writer.writeAll(try std.fmt.formatFloat(&buf, val.f64, .{ .precision = self.options.float_precision, .mode = .decimal }));
        },
        .f32 => {
            var buf: [128]u8 = undefined;
            try self.writer.writeAll(try std.fmt.formatFloat(&buf, val.f32, .{ .precision = self.options.float_precision, .mode = .decimal }));
        },
        .i64 => try std.fmt.formatInt(val.i64, 10, .lower, .{}, self.writer),
        .i32 => try std.fmt.formatInt(val.i32, 10, .lower, .{}, self.writer),
        .i16 => try std.fmt.formatInt(val.i16, 10, .lower, .{}, self.writer),
        .i8 => try std.fmt.formatInt(val.i8, 10, .lower, .{}, self.writer),
        .u64 => try std.fmt.formatInt(val.u64, 10, .lower, .{}, self.writer),
        .u32 => try std.fmt.formatInt(val.u32, 10, .lower, .{}, self.writer),
        .u16 => try std.fmt.formatInt(val.u16, 10, .lower, .{}, self.writer),
        .u8 => try std.fmt.formatInt(val.u8, 10, .lower, .{}, self.writer),
        .bool => try self.writer.writeAll(if (val.bool) "true" else "false"),
        .bytes => try self.writeString(val.bytes),
        .varIntBytes => try self.writeString(val.varIntBytes),
        .null => try self.writer.writeAll("null"),
        .containerEnd => try self.writer.writeAll("END"),
        .varIntUnsigned, .varIntSigned => {},
    }
}

/// Inspect the encoded data and print it to the writer.
/// If the first tag is an Object, it will be printed as JSON.
pub fn inspect(self: *Inspect) !void {
    const root_value = try self.reader.read();
    try self.printValue(root_value, 0);
}