/// Common data types and methods
const std = @import("std");
const builtin = @import("builtin");

/// A serializeable tag. Must fit in 8 bits.
pub const Tag = packed struct(u8) { tag: u5, data: u3 };

pub const TypedArrayElem = enum(u8) {
    u8,
    i8,
    u16,
    i16,
    u32,
    i32,
    u64,
    i64,
    f16,
    f32,
    f64,
};

pub const TypedArray = struct {
    elem: TypedArrayElem,
    count: usize,
    bytes: []const u8,
};

pub const TypedArraySliceError = error{ EndianMismatch, TypeMismatch, LengthMismatch, BufferTooSmall };

/// Returns a zero-copy typed view of the typedArray payload.
/// This is only valid on little-endian targets.
pub fn typedArrayAsView(comptime T: type, ta: TypedArray) TypedArraySliceError![]align(1) const T {
    if (comptime builtin.cpu.arch.endian() != .little) @compileError("bufzilla: typedArrayAsView only supported on little-endian targets");

    const expected_elem: TypedArrayElem = comptime blk: {
        const maybe = typedArrayElemFromType(T);
        if (maybe == null) @compileError("bufzilla: typedArrayAsView unsupported element type: " ++ @typeName(T));
        break :blk maybe.?;
    };
    if (ta.elem != expected_elem) return error.TypeMismatch;

    const needed = ta.count * @sizeOf(T);
    if (ta.bytes.len != needed) return error.LengthMismatch;

    const ptr: [*]align(1) const T = @ptrCast(ta.bytes.ptr);
    return ptr[0..ta.count];
}

/// Decodes the typedArray payload into a caller-provided output buffer and returns the written slice.
/// Output buffer must be large enough to hold the typedArray payload.
pub fn typedArrayAsSlice(comptime T: type, ta: TypedArray, out: []T) TypedArraySliceError![]T {
    const expected_elem: TypedArrayElem = comptime blk: {
        const maybe = typedArrayElemFromType(T);
        if (maybe == null) @compileError("bufzilla: typedArrayAsSlice unsupported element type: " ++ @typeName(T));
        break :blk maybe.?;
    };

    if (ta.elem != expected_elem) return error.TypeMismatch;

    const elem_size = typedArrayElemSize(ta.elem);
    const needed_bytes = ta.count * elem_size;
    if (ta.bytes.len != needed_bytes) return error.LengthMismatch;
    if (out.len < ta.count) return error.BufferTooSmall;

    const dst = out[0..ta.count];

    // if native is little-endian and element type matches byte layout, just copy.
    if (builtin.cpu.arch.endian() == .little and elem_size == @sizeOf(T)) {
        @memcpy(std.mem.sliceAsBytes(dst), ta.bytes);
        return dst;
    }

    var i: usize = 0;
    while (i < ta.count) : (i += 1) {
        const off = i * elem_size;
        const chunk = ta.bytes[off..][0..elem_size];
        switch (expected_elem) {
            .u8 => dst[i] = chunk[0],
            .i8 => dst[i] = @bitCast(chunk[0]),
            .u16 => dst[i] = std.mem.readInt(u16, chunk[0..2], .little),
            .i16 => dst[i] = std.mem.readInt(i16, chunk[0..2], .little),
            .u32 => dst[i] = std.mem.readInt(u32, chunk[0..4], .little),
            .i32 => dst[i] = std.mem.readInt(i32, chunk[0..4], .little),
            .u64 => dst[i] = std.mem.readInt(u64, chunk[0..8], .little),
            .i64 => dst[i] = std.mem.readInt(i64, chunk[0..8], .little),
            .f16 => dst[i] = @bitCast(std.mem.readInt(u16, chunk[0..2], .little)),
            .f32 => dst[i] = @bitCast(std.mem.readInt(u32, chunk[0..4], .little)),
            .f64 => dst[i] = @bitCast(std.mem.readInt(u64, chunk[0..8], .little)),
        }
    }

    return dst;
}

pub inline fn typedArrayElemSize(elem: TypedArrayElem) usize {
    return switch (elem) {
        .u8, .i8 => 1,
        .u16, .i16, .f16 => 2,
        .u32, .i32, .f32 => 4,
        .u64, .i64, .f64 => 8,
    };
}

pub fn typedArrayElemFromType(comptime T: type) ?TypedArrayElem {
    return switch (T) {
        u8 => .u8,
        i8 => .i8,
        u16 => .u16,
        i16 => .i16,
        u32 => .u32,
        i32 => .i32,
        u64 => .u64,
        i64 => .i64,
        f16 => .f16,
        f32 => .f32,
        f64 => .f64,
        else => null,
    };
}

/// A value/type that can be serialized
pub const Value = union(enum) {
    // Arbitrary byte arrays (strings, binary blobs, etc.)
    bytes: []const u8,

    // Byte arrays backed by a variable length integer to represent it's size
    varIntBytes: []const u8,

    // Small byte arrays where length (0..7) is stored in the tag data bits.
    // Encoded payload is the raw bytes, length implied by the tag.
    smallBytes: []const u8,

    // Integer types
    u64: u64,
    u32: u32,
    u16: u16,
    u8: u8,
    i64: i64,
    i32: i32,
    i16: i16,
    i8: i8,

    // Float types
    f64: f64,
    f32: f32,
    f16: f16,

    // Simple types
    bool: bool,
    null: void,

    // Small signed integers where magnitude (0..7) is stored in the tag data bits.
    // For negative small ints, magnitude 0 is invalid (no negative zero).
    smallIntPositive: u8,
    smallIntNegative: u8,

    // Variable length signed integers (signed magnitude)
    // Encoded as an unsigned magnitude varint. Sign is stored in the tag type.
    // In encoded form, they can take anywhere from 1 to 8 bytes.
    // Decoded form is always 64-bit signed.
    varIntSignedPositive: i64,
    varIntSignedNegative: i64,

    // Variable length unsigned integers
    // In encoded form, they can take anywhere from 1 to 8 bytes.
    // Decoded form is always 64-bit unsigned.
    varIntUnsigned: u64,

    // Container tags
    array: u32,
    object: u32,

    // Container ending tag
    containerEnd: u32,

    // Packed typed numeric array
    typedArray: TypedArray,
};

/// Encodes a 64-bit unsigned integer to a 8-byte buffer in variable length format.
/// The number of bytes written is reduced by 1 to fit into 3-bits.
pub fn encodeVarInt(val: u64) struct { bytes: [8]u8, size: u3 } {
    const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, val));
    return .{ .bytes = bytes, .size = if (val == 0) 0 else @truncate(((64 - @clz(val) + 7) / 8) - 1) };
}

/// Decodes a variable length integer from a buffer.
pub inline fn decodeVarInt(buf: []const u8) u64 {
    std.debug.assert(buf.len > 0 and buf.len <= 8);
    return std.mem.readVarInt(u64, buf, .little);
}

/// Encodes a 64-bit signed integer using ZigZag encoding.
pub inline fn encodeZigZag(x: i64) u64 {
    return @bitCast((x << 1) ^ (x >> 63));
}

/// Decodes a ZigZag-encoded integer.
pub inline fn decodeZigZag(x: u64) i64 {
    return @bitCast(@as(i64, @intCast(x >> 1)) ^ -@as(i64, @intCast(x & 1)));
}

/// Encodes a tag and data into a byte.
pub inline fn encodeTag(tag: u5, data: u3) u8 {
    return @bitCast(Tag{ .tag = tag, .data = data });
}

/// Decodes a tag and data from a byte.
pub inline fn decodeTag(byte: u8) Tag {
    return @bitCast(byte);
}
