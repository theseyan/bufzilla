/// Inspect API
const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Reader = @import("Reader.zig");

pub const InspectOptions = struct {
    indent_size: usize = 4,
    float_precision: usize = 14,
    /// Limits for the underlying Reader.
    limits: Reader.ReadLimits = .{},
};

const Inspect = @This();

/// Error type for inspect operations.
pub const Error = Io.Writer.Error || Reader.Error || error{ InvalidUtf8, NonFiniteFloat };

writer: *Io.Writer,
reader: Reader,
options: InspectOptions,

/// Initialize the Inspector with encoded data buffer and a Writer to write the strings to.
/// The caller is responsible for managing the writer's lifecycle (flushing, etc.)
pub fn init(data: []const u8, writer: *Io.Writer, options: InspectOptions) Inspect {
    return .{
        .writer = writer,
        .reader = Reader.init(data, options.limits),
        .options = options,
    };
}

fn writeIndent(self: *Inspect, depth: u32) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < depth * self.options.indent_size) : (i += 1) {
        try self.writer.writeByte(' ');
    }
}

fn writeString(self: *Inspect, str: []const u8) (Io.Writer.Error || error{InvalidUtf8})!void {
    if (!std.unicode.utf8ValidateSlice(str)) return error.InvalidUtf8;

    const hex = "0123456789abcdef";
    try self.writer.writeByte('"');
    for (str) |c| {
        switch (c) {
            '"' => try self.writer.writeAll("\\\""),
            '\\' => try self.writer.writeAll("\\\\"),
            '\n' => try self.writer.writeAll("\\n"),
            '\r' => try self.writer.writeAll("\\r"),
            '\t' => try self.writer.writeAll("\\t"),
            0x08 => try self.writer.writeAll("\\b"),
            0x0C => try self.writer.writeAll("\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                try self.writer.writeAll(&[_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xF] });
            },
            else => try self.writer.writeByte(c),
        }
    }
    try self.writer.writeByte('"');
}

/// Prints a single value to the stream.
pub fn printValue(self: *Inspect, val: common.Value, depth: u32) Error!void {
    const w = self.writer;
    var count: usize = 0;

    switch (val) {
        .object => {
            try w.writeAll("{\n");

            while (try self.reader.iterateObject(val)) |kv| {
                if (count > 0) {
                    try w.writeAll(",\n");
                }
                count += 1;

                try self.writeIndent(depth + 1);
                try self.printValue(kv.key, depth + 1);
                try w.writeAll(": ");
                try self.printValue(kv.value, depth + 1);
            }

            if (count > 0) try w.writeByte('\n');
            try self.writeIndent(depth);
            try w.writeByte('}');
        },
        .array => {
            try w.writeAll("[\n");

            while (try self.reader.iterateArray(val)) |item| {
                if (count > 0) {
                    try w.writeAll(",\n");
                }
                count += 1;

                try self.writeIndent(depth + 1);
                try self.printValue(item, depth + 1);
            }

            if (count > 0) try w.writeByte('\n');
            try self.writeIndent(depth);
            try w.writeByte(']');
        },
        .f64 => {
            if (!std.math.isFinite(val.f64)) return error.NonFiniteFloat;
            try w.printFloat(val.f64, .{ .precision = self.options.float_precision, .mode = .decimal });
        },
        .f32 => {
            if (!std.math.isFinite(val.f32)) return error.NonFiniteFloat;
            try w.printFloat(val.f32, .{ .precision = self.options.float_precision, .mode = .decimal });
        },
        .i64 => try w.print("{d}", .{val.i64}),
        .i32 => try w.print("{d}", .{val.i32}),
        .i16 => try w.print("{d}", .{val.i16}),
        .i8 => try w.print("{d}", .{val.i8}),
        .u64 => try w.print("{d}", .{val.u64}),
        .u32 => try w.print("{d}", .{val.u32}),
        .u16 => try w.print("{d}", .{val.u16}),
        .u8 => try w.print("{d}", .{val.u8}),
        .bool => try w.writeAll(if (val.bool) "true" else "false"),
        .bytes => try self.writeString(val.bytes),
        .varIntBytes => try self.writeString(val.varIntBytes),
        .null => try w.writeAll("null"),
        .containerEnd => try w.writeAll("END"),
        .varIntUnsigned, .varIntSigned => {},
    }
}

/// Inspect the encoded data and print it to the writer as JSON.
pub fn inspect(self: *Inspect) Error!void {
    const root_value = try self.reader.read();
    try self.printValue(root_value, 0);
}
