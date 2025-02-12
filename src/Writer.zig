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
pub fn write(self: *Writer, data: common.Value) !void {
    const writer = self.raw.writer();

    // Write tag byte
    try writer.writeInt(u8, @intFromEnum(data), .little);

    // Write value
    switch (data) {
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
        .bool => try writer.writeInt(u8, if (data.bool) 1 else 0, .little),
        .string => {
            // Write string length
            try writer.writeInt(u64, data.string.len, .little);

            // Write string bytes
            try writer.writeAll(data.string);
        },
        .object, .array, .containerEnd, .null => {},
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
        .ComptimeInt => try self.write(common.Value{ .i64 = @intCast(data) }),
        .ComptimeFloat => try self.write(common.Value{ .f64 = @floatCast(data) }),
        .Int => switch (T) {
            u64 => try self.write(common.Value{ .u64 = data }),
            u32 => try self.write(common.Value{ .u32 = data }),
            u16 => try self.write(common.Value{ .u16 = data }),
            u8 => try self.write(common.Value{ .u8 = data }),
            i64 => try self.write(common.Value{ .i64 = data }),
            i32 => try self.write(common.Value{ .i32 = data }),
            i16 => try self.write(common.Value{ .i16 = data }),
            i8 => try self.write(common.Value{ .i8 = data }),
            else => return error.UnsupportedType,
        },
        .Float => switch (T) {
            f64 => try self.write(common.Value{ .f64 = data }),
            f32 => try self.write(common.Value{ .f32 = data }),
            else => return error.UnsupportedType,
        },
        .Optional => {
            if (data) |v| {
                try self.writeAnyExplicit(@TypeOf(v), v);
            } else {
                try self.writeAnyExplicit(@TypeOf(null), null);
            }
        },
        .Bool => try self.write(common.Value{ .bool = data }),
        .Null => try self.write(common.Value{ .null = undefined }),
        .Pointer => |ptr_info| {
            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                // u8 slice (string)
                try self.write(common.Value{ .string = data });
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
                            try self.write(common.Value{ .string = data });
                        }
                    },
                    else => return error.UnsupportedType,
                }
            } else {
                // std.debug.print("zBuffers: cannot serialize pointer type: {any} {s}\n", .{ptr_info.size, @typeName(ptr_info.child)});
                return error.UnsupportedType;
            }
        },
        .Struct => |struct_info| {
            try self.startObject();
            inline for (struct_info.fields) |field| {
                try self.write(common.Value{ .string = field.name });
                const val = @field(data, field.name);
                try self.writeAnyExplicit(@TypeOf(val), val);
            }
            try self.endContainer();
        },
        .Array => {
            try self.startArray();
            for (data) |item| {
                try self.writeAnyExplicit(@TypeOf(item), item);
            }
            try self.endContainer();
        },
        .Vector => |vector_info| {
            try self.startArray();
            var i: usize = 0;
            while (i < vector_info.len) : (i += 1) {
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
                @compileError("zBuffers: untagged unions are not supported");
            }
        },
        else => |info| {
            // _ = info;
            std.debug.print("zBuffers: cannot serialize type: {any} | {s}\n", .{info, @typeName(T)});
            return error.UnsupportedType;
        }
    }
}

/// Writes an array tag.
pub fn startArray(self: *Writer) !void {
    try self.write(common.Value{ .array = undefined });
}

/// Writes an object tag.
pub fn startObject(self: *Writer) !void {
    try self.write(common.Value{ .object = undefined });
}

/// Writes a container end marker.
pub fn endContainer(self: *Writer) !void {
    try self.write(common.Value{ .containerEnd = undefined });
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