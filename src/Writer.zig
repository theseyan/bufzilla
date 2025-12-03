/// Writer API
const std = @import("std");
const common = @import("common.zig");

const Writer = @This();

allocator: std.mem.Allocator,
raw: std.ArrayList(u8),

/// Initializes the writer.
pub fn init(allocator: std.mem.Allocator) Writer {
    return Writer{ .allocator = allocator, .raw = .empty };
}

/// Writes a single data item to the underlying array list.
pub fn write(self: *Writer, data: common.Value, comptime tag: std.meta.Tag(common.Value)) !void {
    const writer = self.raw.writer(self.allocator);

    // Write value
    switch (comptime tag) {
        .varIntUnsigned => {
            const varint = common.encodeVarInt(data.varIntUnsigned);

            // Write tag byte
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try writer.writeInt(u8, tag_byte, .little);

            // Write varint bytes
            try self.raw.appendSlice(self.allocator, varint.bytes[0 .. varint.size + 1]);
        },
        .varIntSigned => {
            const varint = common.encodeVarInt(common.encodeZigZag(data.varIntSigned));

            // Write tag byte
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try writer.writeInt(u8, tag_byte, .little);

            // Write varint bytes
            try self.raw.appendSlice(self.allocator, varint.bytes[0 .. varint.size + 1]);
        },
        .varIntBytes => {
            const varint = common.encodeVarInt(data.varIntBytes.len);

            // Grow arraylist in one step if needed
            try self.raw.ensureUnusedCapacity(self.allocator, 1 + (varint.size + 1) + data.varIntBytes.len);

            // Write tag byte
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try writer.writeInt(u8, tag_byte, .little);

            // Write bytes length
            self.raw.appendSliceAssumeCapacity(varint.bytes[0 .. varint.size + 1]);

            // Write bytes
            self.raw.appendSliceAssumeCapacity(data.varIntBytes);
        },
        .bool => {
            const val = @intFromBool(data.bool);
            try writer.writeInt(u8, common.encodeTag(@intFromEnum(data), val), .little);
        },
        else => {
            try writer.writeInt(u8, common.encodeTag(@intFromEnum(data), 0), .little);

            switch (comptime tag) {
                .u64 => try writer.writeInt(u64, data.u64, .little),
                .u32 => try writer.writeInt(u32, data.u32, .little),
                .u16 => try writer.writeInt(u16, data.u16, .little),
                .u8 => try writer.writeInt(u8, data.u8, .little),
                .i64 => try writer.writeInt(i64, data.i64, .little),
                .i32 => try writer.writeInt(i32, data.i32, .little),
                .i16 => try writer.writeInt(i16, data.i16, .little),
                .i8 => try writer.writeInt(i8, data.i8, .little),
                .f64 => try writer.writeInt(u64, @bitCast(data.f64), .little),
                .f32 => try writer.writeInt(u32, @bitCast(data.f32), .little),
                .object, .array, .containerEnd, .null => {},
                .bytes => {
                    // Write bytes length
                    try writer.writeInt(u64, data.bytes.len, .little);

                    // Write bytes
                    try self.raw.appendSlice(self.allocator, data.bytes);
                },
                else => unreachable,
            }
        },
    }
}

/// Write any of the supported primitive data types.
/// Serializes structs and arrays recursively.
pub fn writeAny(self: *Writer, value: anytype) !void {
    const T = @TypeOf(value);
    try self.writeAnyExplicit(T, value);
}

/// Writes an item when type is known at comptime, but value may be runtime-known.
pub fn writeAnyExplicit(self: *Writer, comptime T: type, data: T) !void {
    switch (@typeInfo(T)) {
        .comptime_int => try self.writeAnyExplicit(i64, @intCast(data)),
        .comptime_float => try self.writeAnyExplicit(f64, @floatCast(data)),
        .int => switch (T) {
            // u64 => try self.write(common.Value{ .u64 = data }, .u64),
            // u32 => try self.write(common.Value{ .u32 = data }, .u32),
            // u16 => try self.write(common.Value{ .u16 = data }, .u16),
            // u8 => try self.write(common.Value{ .u8 = data }, .u8),
            u64 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
            u32 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
            u16 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
            u8 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
            // i64 => try self.write(common.Value{ .i64 = data }, .i64),
            // i32 => try self.write(common.Value{ .i32 = data }, .i32),
            // i16 => try self.write(common.Value{ .i16 = data }, .i16),
            // i8 => try self.write(common.Value{ .i8 = data }, .i8),
            i64 => try self.write(common.Value{ .varIntSigned = data }, .varIntSigned),
            i32 => try self.write(common.Value{ .varIntSigned = data }, .varIntSigned),
            i16 => try self.write(common.Value{ .varIntSigned = data }, .varIntSigned),
            i8 => try self.write(common.Value{ .varIntSigned = data }, .varIntSigned),
            else => @compileError("bufzilla: unsupported integer type: " ++ @typeName(T)),
        },
        .float => switch (T) {
            f64 => try self.write(common.Value{ .f64 = data }, .f64),
            f32 => try self.write(common.Value{ .f32 = data }, .f32),
            else => @compileError("bufzilla: unsupported float type: " ++ @typeName(T)),
        },
        .optional => {
            if (data) |v| {
                try self.writeAnyExplicit(@TypeOf(v), v);
            } else {
                try self.writeAnyExplicit(@TypeOf(null), null);
            }
        },
        .bool => try self.write(common.Value{ .bool = data }, .bool),
        .null => try self.write(common.Value{ .null = undefined }, .null),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                // u8 slice (string)
                try self.write(common.Value{ .varIntBytes = data }, .varIntBytes);
            } else if (ptr_info.size == .slice) {
                // slice of any supported type
                try self.startArray();
                for (data) |item| {
                    try self.writeAnyExplicit(@TypeOf(item), item);
                }
                try self.endContainer();
            } else if (ptr_info.size == .one) {
                // support null-terminated string pointers
                switch (@typeInfo(ptr_info.child)) {
                    .array => |arr| {
                        if (arr.child == u8 and arr.sentinel() != null) {
                            try self.write(common.Value{ .varIntBytes = data }, .varIntBytes);
                        }
                    },
                    else => @compileError("bufzilla: unsupported pointer type: " ++ @typeName(T)),
                }
            } else {
                // std.debug.print("bufzilla: cannot serialize pointer type: {any} {s}\n", .{ptr_info.size, @typeName(ptr_info.child)});
                @compileError("bufzilla: unsupported pointer type: " ++ @typeName(T));
            }
        },
        .@"struct" => |struct_info| {
            try self.startObject();
            inline for (struct_info.fields) |field| {
                try self.write(common.Value{ .varIntBytes = field.name }, .varIntBytes);
                const val = @field(data, field.name);
                try self.writeAnyExplicit(@TypeOf(val), val);
            }
            try self.endContainer();
        },
        .array => {
            try self.startArray();
            inline for (data) |item| {
                try self.writeAnyExplicit(@TypeOf(item), item);
            }
            try self.endContainer();
        },
        .vector => |vector_info| {
            try self.startArray();
            var i: usize = 0;
            inline while (i < vector_info.len) : (i += 1) {
                try self.writeAnyExplicit(@TypeOf(data[i]), data[i]);
            }
            try self.endContainer();
        },
        .@"union" => |union_info| {
            if (union_info.tag_type) |TT| {
                const tag: TT = data;
                inline for (union_info.fields) |field| {
                    const field_tag = @field(TT, field.name);
                    if (field_tag == tag) {
                        const field_value = @field(data, field.name);
                        try self.writeAnyExplicit(@TypeOf(field_value), field_value);
                        break;
                    }
                }
            } else {
                @compileError("bufzilla: untagged unions are not supported");
            }
        },
        .void => {},
        else => |info| {
            _ = info;
            // std.debug.print("bufzilla: cannot serialize type: {any} | {s}\n", .{info, @typeName(T)});
            @compileError("bufzilla: unsupported data type: " ++ @typeName(T));
        },
    }
}

/// Writes an array tag.
pub inline fn startArray(self: *Writer) !void {
    try self.write(common.Value{ .array = undefined }, .array);
}

/// Writes an object tag.
pub inline fn startObject(self: *Writer) !void {
    try self.write(common.Value{ .object = undefined }, .object);
}

/// Writes a container end marker.
pub inline fn endContainer(self: *Writer) !void {
    try self.write(common.Value{ .containerEnd = undefined }, .containerEnd);
}

/// Number of bytes written.
pub fn len(self: *Writer) usize {
    return self.raw.items.len;
}

/// Returns the underlying bytes.
pub fn bytes(self: *Writer) []u8 {
    return self.raw.items;
}

/// Returns the serialized data as an owned slice.
/// Caller is responsible for freeing the returned memory.
/// This function makes it unnecessary to call `deinit`.
pub fn toOwnedSlice(self: *Writer) ![]u8 {
    return try self.raw.toOwnedSlice(self.allocator);
}

/// Deinitializes the writer.
pub fn deinit(self: *Writer) void {
    self.raw.deinit(self.allocator);
}
