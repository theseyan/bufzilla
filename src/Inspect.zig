/// Inspect API
const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const reader_mod = @import("Reader.zig");

pub const ReadLimits = reader_mod.ReadLimits;

pub const InspectOptions = struct {
    indent_size: usize = 4,
    /// Digits after the decimal point for floats. Values that cannot be rendered with this many
    /// digits fall back to their shortest exact representation.
    float_precision: usize = 14,
};

/// Error type for inspect operations.
pub const Error = Io.Writer.Error || reader_mod.Error || error{ InvalidUtf8, NonFiniteFloat };

/// Nesting deeper than this cannot be inspected, even if the read limits allow it.
/// Bounds the stack used to track open containers (one bit per level).
pub const max_nesting = 1 << 16;

pub fn Inspect(comptime limits: ReadLimits) type {
    const ReaderType = reader_mod.Reader(limits);

    return struct {
        const Self = @This();

        /// One bit per open container: set for objects, clear for arrays.
        const OpenKinds = std.bit_set.Static(@min(limits.max_depth orelse max_nesting, max_nesting));

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
            // In bounded chunks: with a huge indent_size the count is too large to write at once.
            var remaining = @as(usize, depth) *| self.options.indent_size;
            while (remaining > 0) {
                const chunk = @min(remaining, 64);
                try self.writer.splatByteAll(' ', chunk);
                remaining -= chunk;
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

        fn writeFloat(self: *Self, value: anytype) Error!void {
            if (!std.math.isFinite(value)) return error.NonFiniteFloat;
            var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
            const precision = self.options.float_precision;
            // A precision longer than the buffer cannot fit (and near maxInt it overflows inside std),
            // so skip straight to the fallback. Full precision always fits a `bufferSize` buffer.
            const fixed = if (precision <= buf.len) std.fmt.float.render(&buf, value, .{ .mode = .decimal, .precision = precision }) catch null else null;
            const text = fixed orelse std.fmt.float.render(&buf, value, .{ .mode = .decimal }) catch unreachable;
            try self.writer.writeAll(text);
        }

        /// Prints a single value to the stream. For a container, the reader must be positioned just
        /// after its opening tag; all of its contents are read and printed.
        pub fn printValue(self: *Self, val: common.Value, depth: u32) Error!void {
            switch (val) {
                .object, .array => try self.printContainer(val, depth),
                else => try self.printScalar(val, depth),
            }
        }

        /// Prints a container and everything nested in it. Nesting is tracked explicitly rather
        /// than by recursion, so deeply nested input cannot overflow the stack.
        fn printContainer(self: *Self, root: common.Value, depth: u32) Error!void {
            const w = self.writer;
            const root_reader_depth = switch (root) {
                .object, .array => |d| d,
                else => unreachable,
            };

            var kinds: OpenKinds = .empty;
            kinds.setValue(0, root == .object);
            var open: u32 = 1;
            // Whether the innermost open container has no entries printed yet.
            var empty = true;
            try w.writeAll(if (root == .object) "{\n" else "[\n");

            while (open > 0) {
                const level = open - 1;
                const entry_depth = depth + level + 1;
                const is_object = kinds.isSet(level);

                const next: ?common.Value = if (is_object) blk: {
                    const kv = try self.reader.iterateObject(.{ .object = root_reader_depth + level }) orelse break :blk null;
                    try self.beginEntry(&empty, entry_depth);
                    try self.printKey(kv.key, entry_depth);
                    try w.writeAll(": ");
                    break :blk kv.value;
                } else blk: {
                    const item = try self.reader.iterateArray(.{ .array = root_reader_depth + level }) orelse break :blk null;
                    try self.beginEntry(&empty, entry_depth);
                    break :blk item;
                };

                const value = next orelse {
                    // The innermost container has ended; it was an entry of its parent.
                    if (!empty) try w.writeByte('\n');
                    try self.writeIndent(entry_depth - 1);
                    try w.writeByte(if (is_object) '}' else ']');
                    open -= 1;
                    empty = false;
                    continue;
                };

                switch (value) {
                    .object, .array => {
                        if (open == OpenKinds.bit_length) return error.MaxDepthExceeded;
                        kinds.setValue(open, value == .object);
                        open += 1;
                        empty = true;
                        try w.writeAll(if (value == .object) "{\n" else "[\n");
                    },
                    else => try self.printScalar(value, entry_depth),
                }
            }
        }

        /// JSON keys are strings: numbers, booleans and null are printed quoted.
        fn printKey(self: *Self, key: common.Value, depth: u32) Error!void {
            switch (key) {
                .bytes, .varIntBytes, .smallBytes => try self.printScalar(key, depth),
                // A container used as a key would swallow the entry's value, and a typed array
                // cannot be a key.
                .object, .array, .typedArray => return error.InvalidEnumTag,
                else => {
                    try self.writer.writeByte('"');
                    try self.printScalar(key, depth);
                    try self.writer.writeByte('"');
                },
            }
        }

        fn beginEntry(self: *Self, empty: *bool, depth: u32) Io.Writer.Error!void {
            if (!empty.*) try self.writer.writeAll(",\n");
            empty.* = false;
            try self.writeIndent(depth);
        }

        /// Prints any value other than an object or array.
        fn printScalar(self: *Self, val: common.Value, depth: u32) Error!void {
            const w = self.writer;
            switch (val) {
                .object, .array => unreachable,
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
                        const elem_val = common.typedArrayElementToValue(ta, i) catch return error.InvalidEnumTag;
                        try self.printScalar(elem_val, depth + 1);
                    }

                    if (ta.count > 0) try w.writeByte('\n');
                    try self.writeIndent(depth);
                    try w.writeByte(']');
                },
                .f64 => try self.writeFloat(val.f64),
                .f32 => try self.writeFloat(val.f32),
                .f16 => try self.writeFloat(@as(f64, @floatCast(val.f16))),
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
                .varIntUnsigned => try w.print("{d}", .{val.varIntUnsigned}),
                .varIntSignedPositive => try w.print("{d}", .{val.varIntSignedPositive}),
                .varIntSignedNegative => try w.print("{d}", .{val.varIntSignedNegative}),
            }
        }

        /// Inspect the encoded data and print it to the writer as JSON.
        pub fn inspect(self: *Self) Error!void {
            const root_value = try self.reader.read();
            try self.printValue(root_value, 0);
        }
    };
}
