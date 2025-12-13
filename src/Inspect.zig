/// Inspect API
const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const reader_mod = @import("Reader.zig");

pub const ReadLimits = reader_mod.ReadLimits;

pub const InspectOptions = struct {
    indent_size: usize = 4,
    float_precision: usize = 14,
};

/// Error type for inspect operations.
pub const Error = Io.Writer.Error || reader_mod.Error || error{ InvalidUtf8, NonFiniteFloat };

pub fn Inspect(comptime limits: ReadLimits) type {
    const ReaderType = reader_mod.Reader(limits);

    return struct {
        const Self = @This();

        writer: *Io.Writer,
        reader: ReaderType,
        options: InspectOptions,

        /// Initialize the Inspector with encoded data buffer and a Writer to write the strings to.
        /// The caller is responsible for managing the writer's lifecycle (flushing, etc.)
        pub fn init(data: []const u8, writer: *Io.Writer, options: InspectOptions) Self {
            return .{
                .writer = writer,
                .reader = ReaderType.init(data),
                .options = options,
            };
        }

        fn writeIndent(self: *Self, depth: u32) Io.Writer.Error!void {
            var i: usize = 0;
            while (i < depth * self.options.indent_size) : (i += 1) {
                try self.writer.writeByte(' ');
            }
        }

        fn writeString(self: *Self, str: []const u8) (Io.Writer.Error || error{InvalidUtf8})!void {
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
        pub fn printValue(self: *Self, val: common.Value, depth: u32) Error!void {
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
                .typedArray => {
                    const ta = val.typedArray;
                    const elem_size = common.typedArrayElemSize(ta.elem);
                    const expected_len = std.math.mul(usize, ta.count, elem_size) catch return error.InvalidEnumTag;
                    if (expected_len != ta.bytes.len) return error.InvalidEnumTag;

                    try w.writeAll("[\n");

                    var i: usize = 0;
                    while (i < ta.count) : (i += 1) {
                        if (i > 0) try w.writeAll(",\n");
                        try self.writeIndent(depth + 1);

                        const off = i * elem_size;
                        const chunk = ta.bytes[off..][0..elem_size];

	                        switch (ta.elem) {
	                            .u8 => try w.print("{d}", .{chunk[0]}),
	                            .i8 => try w.print("{d}", .{@as(i8, @bitCast(chunk[0]))}),
	                            .u16 => try w.print("{d}", .{std.mem.readInt(u16, chunk[0..2], .little)}),
	                            .i16 => try w.print("{d}", .{std.mem.readInt(i16, chunk[0..2], .little)}),
	                            .u32 => try w.print("{d}", .{std.mem.readInt(u32, chunk[0..4], .little)}),
	                            .i32 => try w.print("{d}", .{std.mem.readInt(i32, chunk[0..4], .little)}),
	                            .u64 => try w.print("{d}", .{std.mem.readInt(u64, chunk[0..8], .little)}),
	                            .i64 => try w.print("{d}", .{std.mem.readInt(i64, chunk[0..8], .little)}),
	                            .f16 => {
	                                const bits = std.mem.readInt(u16, chunk[0..2], .little);
	                                const fv: f16 = @bitCast(bits);
	                                const f: f64 = @floatCast(fv);
	                                if (!std.math.isFinite(f)) return error.NonFiniteFloat;
	                                try w.printFloat(f, .{ .precision = self.options.float_precision, .mode = .decimal });
	                            },
	                            .f32 => {
	                                const bits = std.mem.readInt(u32, chunk[0..4], .little);
	                                const fv: f32 = @bitCast(bits);
	                                const f: f64 = @floatCast(fv);
	                                if (!std.math.isFinite(f)) return error.NonFiniteFloat;
                                try w.printFloat(f, .{ .precision = self.options.float_precision, .mode = .decimal });
                            },
                            .f64 => {
                                const bits = std.mem.readInt(u64, chunk[0..8], .little);
                                const f: f64 = @bitCast(bits);
                                if (!std.math.isFinite(f)) return error.NonFiniteFloat;
                                try w.printFloat(f, .{ .precision = self.options.float_precision, .mode = .decimal });
                            },
                        }
                    }

                    if (ta.count > 0) try w.writeByte('\n');
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
                .f16 => {
                    const f: f64 = @floatCast(val.f16);
                    if (!std.math.isFinite(f)) return error.NonFiniteFloat;
                    try w.printFloat(f, .{ .precision = self.options.float_precision, .mode = .decimal });
                },
                .smallUint => try w.print("{d}", .{val.smallUint}),
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
                .smallBytes => try self.writeString(val.smallBytes),
                .null => try w.writeAll("null"),
                .containerEnd => try w.writeAll("END"),
                .smallIntPositive => try w.print("{d}", .{val.smallIntPositive}),
                .smallIntNegative => try w.print("-{d}", .{val.smallIntNegative}),
                .varIntUnsigned, .varIntSignedPositive, .varIntSignedNegative => {},
            }
        }

        /// Inspect the encoded data and print it to the writer as JSON.
        pub fn inspect(self: *Self) Error!void {
            const root_value = try self.reader.read();
            try self.printValue(root_value, 0);
        }
    };
}
