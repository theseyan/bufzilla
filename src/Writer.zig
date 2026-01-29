/// Writer API
const std = @import("std");
const common = @import("common.zig");
const updates_mod = @import("updates.zig");
const reader_mod = @import("Reader.zig");
const Io = std.Io;
const builtin = @import("builtin");

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

/// A single update to apply to an already-encoded buffer
pub const Update = struct {
    path: []const u8,
    ctx: *const anyopaque,
    writeFn: *const fn (writer: *Writer, ctx: *const anyopaque) Error!void,
    applied: bool = false,

    /// Creates an update
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

/// Applies a set of updates to an already-encoded object buffer, streaming the new encoding to the current writer
pub fn applyUpdates(self: *Writer, encoded_buf: []const u8, updates: []Update) (Error || reader_mod.Error || updates_mod.Error)!void {
    try updates_mod.applyUpdates(Writer, self, encoded_buf, updates);
}

/// Writes a single data item to the underlying writer
pub fn write(self: *Writer, data: common.Value, comptime tag: std.meta.Tag(common.Value)) Error!void {
    const w = self.raw;

    switch (comptime tag) {
        .smallIntPositive => {
            std.debug.assert(data.smallIntPositive <= 7);
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), @truncate(data.smallIntPositive));
            try w.writeByte(tag_byte);
        },
        .smallIntNegative => {
            std.debug.assert(data.smallIntNegative > 0 and data.smallIntNegative <= 7);
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), @truncate(data.smallIntNegative));
            try w.writeByte(tag_byte);
        },
        .smallUint => {
            std.debug.assert(data.smallUint <= 7);
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), @truncate(data.smallUint));
            try w.writeByte(tag_byte);
        },
        .varIntUnsigned => {
            const varint = common.encodeVarInt(data.varIntUnsigned);
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try w.writeByte(tag_byte);
            try w.writeAll(varint.bytes[0 .. @as(usize, varint.size) + 1]);
        },
        .varIntSignedPositive => {
            const magnitude: u64 = @intCast(data.varIntSignedPositive);
            const varint = common.encodeVarInt(magnitude);
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), varint.size);
            try w.writeByte(tag_byte);
            try w.writeAll(varint.bytes[0 .. @as(usize, varint.size) + 1]);
        },
        .varIntSignedNegative => {
            const signed = data.varIntSignedNegative;
            std.debug.assert(signed < 0);
            const magnitude: u64 = if (signed == std.math.minInt(i64)) (@as(u64, 1) << 63) else @intCast(-signed);
            const varint = common.encodeVarInt(magnitude);
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
        .smallBytes => {
            std.debug.assert(data.smallBytes.len <= 7);
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), @truncate(data.smallBytes.len));
            try w.writeByte(tag_byte);
            try w.writeAll(data.smallBytes);
        },
        .typedArray => {
            const ta = data.typedArray;
            const elem_size = common.typedArrayElemSize(ta.elem);
            const expected_len = std.math.mul(usize, ta.count, elem_size) catch @panic("bufzilla: typedArray payload length overflow");
            std.debug.assert(expected_len == ta.bytes.len);
            const count_varint = common.encodeVarInt(@intCast(ta.count));
            const tag_byte: u8 = common.encodeTag(@intFromEnum(data), count_varint.size);
            try w.writeByte(tag_byte);
            try w.writeByte(@intFromEnum(ta.elem));
            try w.writeAll(count_varint.bytes[0 .. @as(usize, count_varint.size) + 1]);
            try w.writeAll(ta.bytes);
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
                .f16 => try w.writeInt(u16, @bitCast(data.f16), .little),
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

pub fn writeTypedArray(self: *Writer, values: anytype) Error!void {
    const ValuesT = @TypeOf(values);
    switch (@typeInfo(ValuesT)) {
        .pointer => |p| switch (p.size) {
            .slice => try writeTypedArraySlice(self, p.child, values),
            .one => switch (@typeInfo(p.child)) {
                .array => |arr| {
                    const slice: []const arr.child = values;
                    try writeTypedArraySlice(self, arr.child, slice);
                },
                else => @compileError("bufzilla: writeTypedArray expects a slice or pointer to array, got: " ++ @typeName(ValuesT)),
            },
            else => @compileError("bufzilla: writeTypedArray expects a slice or pointer to array, got: " ++ @typeName(ValuesT)),
        },
        .array => |arr| {
            const ptr: *const [arr.len]arr.child = &values;
            const slice: []const arr.child = ptr;
            try writeTypedArraySlice(self, arr.child, slice);
        },
        else => @compileError("bufzilla: writeTypedArray expects a slice or array, got: " ++ @typeName(ValuesT)),
    }
}

fn writeTypedArraySlice(self: *Writer, comptime ElemT: type, slice: []const ElemT) Error!void {
    const elem: common.TypedArrayElem = comptime blk: {
        const maybe = common.typedArrayElemFromType(ElemT);
        if (maybe == null) @compileError("bufzilla: writeTypedArray unsupported element type: " ++ @typeName(ElemT));
        break :blk maybe.?;
    };
    try writeTypedArraySliceWithElem(self, ElemT, elem, slice);
}

fn writeTypedArraySliceWithElem(self: *Writer, comptime ElemT: type, comptime elem: common.TypedArrayElem, slice: []const ElemT) Error!void {
    const count: usize = slice.len;
    const count_varint = common.encodeVarInt(@intCast(count));
    const tag_byte: u8 = common.encodeTag(@intFromEnum(common.Value.typedArray), count_varint.size);

    try self.raw.writeByte(tag_byte);
    try self.raw.writeByte(@intFromEnum(elem));
    try self.raw.writeAll(count_varint.bytes[0 .. @as(usize, count_varint.size) + 1]);

    if (count == 0) return;

    if (builtin.cpu.arch.endian() == .little) {
        try self.raw.writeAll(std.mem.sliceAsBytes(slice));
        return;
    }

    switch (elem) {
        .u8 => for (slice) |v| try self.raw.writeInt(u8, v, .little),
        .i8 => for (slice) |v| try self.raw.writeInt(i8, v, .little),
        .u16 => for (slice) |v| try self.raw.writeInt(u16, v, .little),
        .i16 => for (slice) |v| try self.raw.writeInt(i16, v, .little),
        .u32 => for (slice) |v| try self.raw.writeInt(u32, v, .little),
        .i32 => for (slice) |v| try self.raw.writeInt(i32, v, .little),
        .u64 => for (slice) |v| try self.raw.writeInt(u64, v, .little),
        .i64 => for (slice) |v| try self.raw.writeInt(i64, v, .little),
        .f16 => for (slice) |v| try self.raw.writeInt(u16, @bitCast(v), .little),
        .f32 => for (slice) |v| try self.raw.writeInt(u32, @bitCast(v), .little),
        .f64 => for (slice) |v| try self.raw.writeInt(u64, @bitCast(v), .little),
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
            u64 => {
                if (data <= 7) {
                    try self.write(common.Value{ .smallUint = @intCast(data) }, .smallUint);
                } else {
                    try self.write(common.Value{ .varIntUnsigned = data }, .varIntUnsigned);
                }
            },
            u32 => try self.writeAnyExplicit(u64, data),
            u16 => try self.writeAnyExplicit(u64, data),
            u8 => try self.writeAnyExplicit(u64, data),
            i64 => {
                if (data >= 0 and data <= 7) {
                    try self.write(common.Value{ .smallIntPositive = @intCast(data) }, .smallIntPositive);
                } else if (data < 0 and data >= -7) {
                    try self.write(common.Value{ .smallIntNegative = @intCast(-data) }, .smallIntNegative);
                } else if (data >= 0) {
                    try self.write(common.Value{ .varIntSignedPositive = data }, .varIntSignedPositive);
                } else {
                    try self.write(common.Value{ .varIntSignedNegative = data }, .varIntSignedNegative);
                }
            },
            i32 => try self.writeAnyExplicit(i64, data),
            i16 => try self.writeAnyExplicit(i64, data),
            i8 => try self.writeAnyExplicit(i64, data),
            else => @compileError("bufzilla: unsupported integer type: " ++ @typeName(T)),
        },
        .float => switch (T) {
            f64 => try self.write(common.Value{ .f64 = data }, .f64),
            f32 => try self.write(common.Value{ .f32 = data }, .f32),
            f16 => try self.write(common.Value{ .f16 = data }, .f16),
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
                if (data.len <= 7) {
                    try self.write(common.Value{ .smallBytes = data }, .smallBytes);
                } else {
                    try self.write(common.Value{ .varIntBytes = data }, .varIntBytes);
                }
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
                            const slice: []const u8 = data;
                            if (slice.len <= 7) {
                                try self.write(common.Value{ .smallBytes = slice }, .smallBytes);
                            } else {
                                try self.write(common.Value{ .varIntBytes = slice }, .varIntBytes);
                            }
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
                    if (field.name.len <= 7) {
                        const tag_byte = common.encodeTag(@intFromEnum(common.Value.smallBytes), @truncate(field.name.len));
                        var prefix: [1 + field.name.len]u8 = undefined;
                        prefix[0] = tag_byte;
                        for (0..field.name.len) |i| {
                            prefix[1 + i] = field.name[i];
                        }
                        break :blk prefix[0 .. 1 + field.name.len].*;
                    } else {
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
                    }
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
            while (i < vector_info.len) : (i += 1) {
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
