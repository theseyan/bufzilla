/// Writer API

const std = @import("std");
const common = @import("common.zig");

const Writer = @This();

allocator: std.mem.Allocator,
raw: std.ArrayList(u8),

/// Initializes the writer.
pub fn init(allocator: std.mem.Allocator) Writer {
    const arraylist = std.ArrayList(u8).init(allocator);

    return Writer{
        .allocator = allocator,
        .raw = arraylist
    };
}

/// Writes a single data item to the underlying array list.
pub fn write(self: *Writer, data: common.Value, comptime tag: std.meta.Tag(common.Value)) !void {
    const writer = self.raw.writer();

    // Write value
    switch (comptime tag) {
        .varIntUnsigned => {
            const varint = common.encodeVarInt(data.varIntUnsigned);

            // Write tag byte
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try writer.writeInt(u8, tag_byte, .little);

            // Write varint bytes
            try self.raw.appendSlice(varint.bytes[0..varint.size + 1]);
        },
        .varIntSigned => {
            const varint = common.encodeVarInt(common.encodeZigZag(data.varIntSigned));

            // Write tag byte
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try writer.writeInt(u8, tag_byte, .little);

            // Write varint bytes
            try self.raw.appendSlice(varint.bytes[0..varint.size + 1]);
        },
        .varIntBytes => {
            const varint = common.encodeVarInt(data.varIntBytes.len);

            // Write tag byte
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try writer.writeInt(u8, tag_byte, .little);

            // Write bytes length
            try self.raw.appendSlice(varint.bytes[0..varint.size + 1]);

            // Write bytes
            try self.raw.appendSlice(data.varIntBytes);
        },
        .bool => {
            const val = @intFromBool(data.bool);
            try writer.writeInt(u8, common.encodeTag(@intFromEnum(data), val), .little);
        },
        else => {
            try writer.writeInt(u8, common.encodeTag(@intFromEnum(data), 0), .little);

            switch(comptime tag) {
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
                    try self.raw.appendSlice(data.bytes);
                },
                else => unreachable
            }
        }
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
        .ComptimeInt => try self.writeAnyExplicit(i64, @intCast(data)),
        .ComptimeFloat => try self.writeAnyExplicit(f64, @floatCast(data)),
        .Int => switch (T) {
            u64 => try self.write(common.Value{ .u64 = data }, .u64),
            // u64 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
            u32 => try self.write(common.Value{ .u32 = data }, .u32),
            u16 => try self.write(common.Value{ .u16 = data }, .u16),
            u8 => try self.write(common.Value{ .u8 = data }, .u8),
            i64 => try self.write(common.Value{ .i64 = data }, .i64),
            // i64 => try self.write(common.Value{ .varIntSigned = data }, .varIntSigned),
            i32 => try self.write(common.Value{ .i32 = data }, .i32),
            i16 => try self.write(common.Value{ .i16 = data }, .i16),
            i8 => try self.write(common.Value{ .i8 = data }, .i8),
            else => @compileError("zbuffers: unsupported integer type: " ++ @typeName(T)),
        },
        .Float => switch (T) {
            f64 => try self.write(common.Value{ .f64 = data }, .f64),
            f32 => try self.write(common.Value{ .f32 = data }, .f32),
            else => @compileError("zbuffers: unsupported float type: " ++ @typeName(T)),
        },
        .Optional => {
            if (data) |v| {
                try self.writeAnyExplicit(@TypeOf(v), v);
            } else {
                try self.writeAnyExplicit(@TypeOf(null), null);
            }
        },
        .Bool => try self.write(common.Value{ .bool = data }, .bool),
        .Null => try self.write(common.Value{ .null = undefined }, .null),
        .Pointer => |ptr_info| {
            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                // u8 slice (string)
                try self.write(common.Value{ .varIntBytes = data }, .varIntBytes);
            } else if (ptr_info.size == .Slice) {
                // slice of any supported type
                try self.startArray();
                for (data) |item| {
                    try self.writeAnyExplicit(@TypeOf(item), item);
                }
                try self.endContainer();
            } else if (ptr_info.size == .One) {
                // support null-terminated string pointers
                switch (@typeInfo(ptr_info.child)) {
                    .Array => |arr| {
                        if (arr.child == u8 and arr.sentinel != null) {
                            try self.write(common.Value{ .varIntBytes = data }, .varIntBytes);
                        }
                    },
                    else => @compileError("zbuffers: unsupported pointer type: " ++ @typeName(T)),
                }
            } else {
                // std.debug.print("zBuffers: cannot serialize pointer type: {any} {s}\n", .{ptr_info.size, @typeName(ptr_info.child)});
                @compileError("zbuffers: unsupported pointer type: " ++ @typeName(T));
            }
        },
        .Struct => |struct_info| {
            try self.startObject();
            inline for (struct_info.fields) |field| {
                try self.write(common.Value{ .varIntBytes = field.name }, .varIntBytes);
                const val = @field(data, field.name);
                try self.writeAnyExplicit(@TypeOf(val), val);
            }
            try self.endContainer();
        },
        .Array => {
            try self.startArray();
            inline for (data) |item| {
                try self.writeAnyExplicit(@TypeOf(item), item);
            }
            try self.endContainer();
        },
        .Vector => |vector_info| {
            try self.startArray();
            var i: usize = 0;
            inline while (i < vector_info.len) : (i += 1) {
                try self.writeAnyExplicit(@TypeOf(data[i]), data[i]);
            }
            try self.endContainer();
        },
        .Union => |union_info| {
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
                @compileError("zbuffers: untagged unions are not supported");
            }
        },
        .Void => {},
        else => |info| {
            _ = info;
            // std.debug.print("zBuffers: cannot serialize type: {any} | {s}\n", .{info, @typeName(T)});
            @compileError("zbuffers: unsupported data type: " ++ @typeName(T));
        }
    }
}

/// Writes an array tag.
pub inline fn startArray(self: *Writer) !void {
    try self.write(common.Value{ .array = undefined }, .array);
}

/// Writes an object tag.
pub inline  fn startObject(self: *Writer) !void {
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
    return try self.raw.toOwnedSlice();
}

/// Deinitializes the writer.
pub fn deinit(self: *Writer) void {
    self.raw.deinit();
}