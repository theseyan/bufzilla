/// Writer API
const std = @import("std");
const common = @import("common.zig");
const updates_mod = @import("updates.zig");
const reader_mod = @import("Reader.zig");
const Io = std.Io;

const Writer = @This();

/// The underlying Writer.
raw: *Io.Writer,

/// Error type for write operations.
pub const Error = Io.Writer.Error;

/// Initializes the writer with an std.Io.Writer.
/// The caller is responsible for managing the writer's lifecycle (flushing, freeing, etc.)
pub fn init(writer: *Io.Writer) Writer {
    return .{ .raw = writer };
}

/// A single update to apply to an already-encoded buffer.
pub const Update = struct {
    path: []const u8,
    ctx: *const anyopaque,
    writeFn: *const fn (writer: *Writer, ctx: *const anyopaque) Error!void,
    applied: bool = false,

    /// Creates an update that will write `new_value_ptr.*` at `path`.
    pub fn init(path: []const u8, new_value_ptr: anytype) Update {
        const PtrT = @TypeOf(new_value_ptr);
        const ptr_info = @typeInfo(PtrT);
        if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
            @compileError("Update.init expects a pointer to a value");
        }
        const T = @TypeOf(new_value_ptr.*);
        return .{
            .path = path,
            .ctx = @ptrCast(new_value_ptr),
            .writeFn = struct {
                fn write(writer: *Writer, ctx: *const anyopaque) Error!void {
                    const ptr: *const T = @ptrCast(@alignCast(ctx));
                    try writer.writeAny(ptr.*);
                }
            }.write,
        };
    }
};

/// Applies a set of updates to an already-encoded object buffer, streaming the new encoding to the current writer.
pub fn applyUpdates(self: *Writer, encoded_buf: []const u8, updates: []Update) (Error || reader_mod.Error || updates_mod.Error)!void {
    try updates_mod.applyUpdates(Writer, self, encoded_buf, updates);
}

/// Writes a single data item to the underlying writer.
pub fn write(self: *Writer, data: common.Value, comptime tag: std.meta.Tag(common.Value)) Error!void {
    const w = self.raw;

    switch (comptime tag) {
        .varIntUnsigned => {
            const varint = common.encodeVarInt(data.varIntUnsigned);
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try w.writeByte(tag_byte);
            try w.writeAll(varint.bytes[0 .. @as(usize, varint.size) + 1]);
        },
        .varIntSigned => {
            const varint = common.encodeVarInt(common.encodeZigZag(data.varIntSigned));
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try w.writeByte(tag_byte);
            try w.writeAll(varint.bytes[0 .. @as(usize, varint.size) + 1]);
        },
        .varIntBytes => {
            const varint = common.encodeVarInt(data.varIntBytes.len);
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try w.writeByte(tag_byte);
            try w.writeAll(varint.bytes[0 .. @as(usize, varint.size) + 1]);
            try w.writeAll(data.varIntBytes);
        },
        .bool => {
            const val = @intFromBool(data.bool);
            try w.writeByte(common.encodeTag(@intFromEnum(data), val));
        },
        else => {
            try w.writeByte(common.encodeTag(@intFromEnum(data), 0));

            switch (comptime tag) {
                .u64 => try w.writeInt(u64, data.u64, .little),
                .u32 => try w.writeInt(u32, data.u32, .little),
                .u16 => try w.writeInt(u16, data.u16, .little),
                .u8 => try w.writeInt(u8, data.u8, .little),
                .i64 => try w.writeInt(i64, data.i64, .little),
                .i32 => try w.writeInt(i32, data.i32, .little),
                .i16 => try w.writeInt(i16, data.i16, .little),
                .i8 => try w.writeInt(i8, data.i8, .little),
                .f64 => try w.writeInt(u64, @bitCast(data.f64), .little),
                .f32 => try w.writeInt(u32, @bitCast(data.f32), .little),
                .object, .array, .containerEnd, .null => {},
                .bytes => {
                    try w.writeInt(u64, data.bytes.len, .little);
                    try w.writeAll(data.bytes);
                },
                else => unreachable,
            }
        },
    }
}

/// Write any of the supported primitive data types.
/// Serializes structs and arrays recursively.
pub fn writeAny(self: *Writer, value: anytype) Error!void {
    const T = @TypeOf(value);
    try self.writeAnyExplicit(T, value);
}

/// Writes an item when type is known at comptime, but value may be runtime-known.
pub fn writeAnyExplicit(self: *Writer, comptime T: type, data: T) Error!void {
    switch (@typeInfo(T)) {
        .comptime_int => try self.writeAnyExplicit(i64, @intCast(data)),
        .comptime_float => try self.writeAnyExplicit(f64, @floatCast(data)),
        .int => switch (T) {
            u64 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
            u32 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
            u16 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
            u8 => try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned),
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
                // pointer to single item - dereference and encode
                switch (@typeInfo(ptr_info.child)) {
                    .array => |arr| {
                        if (arr.child == u8) {
                            // pointer to byte array - write as bytes
                            try self.write(common.Value{ .varIntBytes = data }, .varIntBytes);
                        } else {
                            // pointer to array of other types - write as array
                            try self.startArray();
                            for (data) |item| {
                                try self.writeAnyExplicit(@TypeOf(item), item);
                            }
                            try self.endContainer();
                        }
                    },
                    else => {
                        // pointer to single value - dereference and write
                        try self.writeAnyExplicit(ptr_info.child, data.*);
                    },
                }
            } else {
                @compileError("bufzilla: unsupported pointer type: " ++ @typeName(T));
            }
        },
        .@"struct" => |struct_info| {
            try self.startObject();
            inline for (struct_info.fields) |field| {
                // Precompute encoded key prefix
                const key_prefix = comptime blk: {
                    const varint = common.encodeVarInt(field.name.len);
                    const tag_byte = common.encodeTag(@intFromEnum(common.Value.varIntBytes), varint.size);
                    const len_size: usize = @as(usize, varint.size) + 1;
                    var prefix: [1 + 8 + field.name.len]u8 = undefined;
                    prefix[0] = tag_byte;
                    for (0..len_size) |i| {
                        prefix[1 + i] = varint.bytes[i];
                    }
                    // Include the field name in the prefix
                    for (0..field.name.len) |i| {
                        prefix[1 + len_size + i] = field.name[i];
                    }
                    break :blk prefix[0 .. 1 + len_size + field.name.len].*;
                };
                try self.raw.writeAll(&key_prefix);
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
        else => {
            @compileError("bufzilla: unsupported data type: " ++ @typeName(T));
        },
    }
}

/// Writes an array tag.
pub inline fn startArray(self: *Writer) Error!void {
    try self.write(common.Value{ .array = undefined }, .array);
}

/// Writes an object tag.
pub inline fn startObject(self: *Writer) Error!void {
    try self.write(common.Value{ .object = undefined }, .object);
}

/// Writes a container end marker.
pub inline fn endContainer(self: *Writer) Error!void {
    try self.write(common.Value{ .containerEnd = undefined }, .containerEnd);
}
