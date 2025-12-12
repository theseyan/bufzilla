/// Common data types and methods
const std = @import("std");

/// A serializeable tag. Must fit in 8 bits.
pub const Tag = packed struct(u8) { tag: u5, data: u3 };

/// A value/type that can be serialized
pub const Value = union(enum) {
    // Arbitrary byte arrays (strings, binary blobs, etc.)
    bytes: []const u8,

    // Byte arrays backed by a variable length integer to represent it's size
    varIntBytes: []const u8,

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

    // Simple types
    bool: bool,
    null: void,

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
