/// Common data types and methods
const std = @import("std");
const builtin = @import("builtin");

/// The kind of an encoded item, as named by its tag byte.
pub const Kind = std.meta.Tag(Value);

/// What a tag byte says about the item it starts.
///
/// Every item starts with one tag byte, which gives its kind and, for small values, the value itself:
///
///     0x00-0x3F  smallUint             unsigned 0..63, the value is the byte
///     0x40-0x9F  smallIntNegative,     signed -32..63, the value is the byte minus 0x60
///                smallIntPositive
///     0xA0-0xBF  smallBytes            byte string of length 0..31, the length is the byte minus 0xA0
///     0xC0-0xC7  varIntUnsigned        then the value, 1..8 bytes little-endian
///     0xC8-0xCF  varIntSignedPositive  then the magnitude, 1..8 bytes
///     0xD0-0xD7  varIntSignedNegative  then the magnitude, 1..8 bytes
///     0xD8-0xDF  varIntBytes           then the length, 1..8 bytes, then the bytes
///     0xE0-0xE7  typedArray            then the element type byte, the count (1..8 bytes), the elements
///     0xE8       array                 then items, then containerEnd
///     0xE9       object                then key, value pairs, then containerEnd
///     0xEA       containerEnd
///     0xEB       bytes                 then a u64 length, then the bytes
///     0xEC-0xF3  u8, u16, u32, u64, i8, i16, i32, i64, then the value, little-endian
///     0xF4-0xF6  f16, f32, f64, then the value, little-endian
///     0xF7-0xF8  bool                  false, true
///     0xF9       null
///     0xFA-0xFF  reserved, rejected by readers
///
/// For the varint-sized kinds, the low 3 bits of the byte hold the size of the varint minus one.
pub const Tag = struct {
    kind: Kind,
    /// smallUint, smallIntPositive: the value. smallIntNegative: the magnitude (1..32).
    /// smallBytes: the length. varInt*, varIntBytes, typedArray: the size of the varint minus one.
    /// bool: the value. Otherwise 0.
    data: u8,
};

/// The largest smallUint.
pub const small_uint_max = 63;
/// The range of values smallIntPositive and smallIntNegative cover.
pub const small_int_min = -32;
pub const small_int_max = 63;
/// The longest smallBytes.
pub const small_bytes_max = 31;

/// Code of the signed inline value 0; signed inline values are `small_int_zero + value`.
pub const small_int_zero = 0x60;

/// First tag byte of each kind; the item's data is added to it (subtracted for smallIntNegative).
const tag_base = std.enums.EnumArray(Kind, u8).init(.{
    .smallUint = 0x00,
    .smallIntNegative = small_int_zero,
    .smallIntPositive = small_int_zero,
    .smallBytes = 0xA0,
    .varIntUnsigned = 0xC0,
    .varIntSignedPositive = 0xC8,
    .varIntSignedNegative = 0xD0,
    .varIntBytes = 0xD8,
    .typedArray = 0xE0,
    .array = 0xE8,
    .object = 0xE9,
    .containerEnd = 0xEA,
    .bytes = 0xEB,
    .u8 = 0xEC,
    .u16 = 0xED,
    .u32 = 0xEE,
    .u64 = 0xEF,
    .i8 = 0xF0,
    .i16 = 0xF1,
    .i32 = 0xF2,
    .i64 = 0xF3,
    .f16 = 0xF4,
    .f32 = 0xF5,
    .f64 = 0xF6,
    .bool = 0xF7,
    .null = 0xF9,
});

/// The range of `Tag.data` each kind can carry.
fn dataRange(kind: Kind) struct { min: u8, max: u8 } {
    return switch (kind) {
        .smallUint => .{ .min = 0, .max = small_uint_max },
        .smallIntPositive => .{ .min = 0, .max = small_int_max },
        .smallIntNegative => .{ .min = 1, .max = -small_int_min },
        .smallBytes => .{ .min = 0, .max = small_bytes_max },
        .varIntUnsigned, .varIntSignedPositive, .varIntSignedNegative, .varIntBytes, .typedArray => .{ .min = 0, .max = 7 },
        .bool => .{ .min = 0, .max = 1 },
        else => .{ .min = 0, .max = 0 },
    };
}

/// The tag bytes a kind uses.
pub const ByteRange = struct { first: u8, last: u8 };

fn byteRange(kind: Kind) ByteRange {
    const range = dataRange(kind);
    const a = encodeTag(kind, range.min);
    const b = encodeTag(kind, range.max);
    return .{ .first = @min(a, b), .last = @max(a, b) };
}

/// Tag byte values, for decoders that dispatch on the byte itself. A `switch` on the byte with every
/// value as its own case (`inline` ranges or `inline else`) compiles to one jump table; decoding to a
/// `Tag` first adds a dependent table load, and plain ranges compile to a chain of comparisons.
pub const tag_bytes = struct {
    pub const small_uint = byteRange(.smallUint);
    pub const small_int_negative = byteRange(.smallIntNegative);
    pub const small_int_positive = byteRange(.smallIntPositive);
    pub const small_bytes = byteRange(.smallBytes);
    pub const varint_unsigned = byteRange(.varIntUnsigned);
    pub const varint_positive = byteRange(.varIntSignedPositive);
    pub const varint_negative = byteRange(.varIntSignedNegative);
    pub const varint_bytes = byteRange(.varIntBytes);
    pub const typed_array = byteRange(.typedArray);
    pub const array = encodeTag(.array, 0);
    pub const object = encodeTag(.object, 0);
    pub const container_end = encodeTag(.containerEnd, 0);
    pub const bytes = encodeTag(.bytes, 0);
    pub const @"u8" = encodeTag(.u8, 0);
    pub const @"u16" = encodeTag(.u16, 0);
    pub const @"u32" = encodeTag(.u32, 0);
    pub const @"u64" = encodeTag(.u64, 0);
    pub const @"i8" = encodeTag(.i8, 0);
    pub const @"i16" = encodeTag(.i16, 0);
    pub const @"i32" = encodeTag(.i32, 0);
    pub const @"i64" = encodeTag(.i64, 0);
    pub const @"f16" = encodeTag(.f16, 0);
    pub const @"f32" = encodeTag(.f32, 0);
    pub const @"f64" = encodeTag(.f64, 0);
    pub const @"false" = encodeTag(.bool, 0);
    pub const @"true" = encodeTag(.bool, 1);
    pub const @"null" = encodeTag(.null, 0);

    /// Whether the byte is reserved rather than a tag: the bytes after `null`.
    pub inline fn isReserved(byte: u8) bool {
        return byte > @"null";
    }

    /// Whether the byte starts a byte string (smallBytes, varIntBytes or bytes).
    pub inline fn isBytes(byte: u8) bool {
        return (byte >= small_bytes.first and byte <= small_bytes.last) or
            (byte >= varint_bytes.first and byte <= varint_bytes.last) or byte == bytes;
    }
};

comptime {
    // The signed inline ranges are adjacent, so a decoder can treat them as one.
    std.debug.assert(tag_bytes.small_int_negative.last + 1 == tag_bytes.small_int_positive.first);
    std.debug.assert(encodeTag(.smallIntPositive, 0) == small_int_zero);
    // Varint-sized kinds start at 8-aligned bytes, so the low 3 bits of their tag bytes are the
    // varint's size minus one; the integer groups are also adjacent, so they can be skipped alike.
    for ([_]ByteRange{ tag_bytes.varint_unsigned, tag_bytes.varint_positive, tag_bytes.varint_negative, tag_bytes.varint_bytes, tag_bytes.typed_array }) |range| {
        std.debug.assert(range.first % 8 == 0 and range.last == range.first + 7);
    }
    std.debug.assert(tag_bytes.varint_unsigned.last + 1 == tag_bytes.varint_positive.first);
    std.debug.assert(tag_bytes.varint_positive.last + 1 == tag_bytes.varint_negative.first);
}

comptime {
    // Reserved bytes are exactly the ones `tag_bytes.isReserved` reports.
    for (tag_table, 0..) |tag, byte| std.debug.assert((tag == null) == tag_bytes.isReserved(byte));
}

/// Decoding table: the tag each byte stands for, or null for reserved bytes. Built from `encodeTag`,
/// which also proves at compile time that no two tags share a byte.
const tag_table: [256]?Tag = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]?Tag = @splat(null);
    for (std.enums.values(Kind)) |kind| {
        const range = dataRange(kind);
        for (range.min..@as(usize, range.max) + 1) |data| {
            const byte = encodeTag(kind, data);
            if (table[byte] != null) @compileError("bufzilla: two tags share a byte");
            table[byte] = .{ .kind = kind, .data = data };
        }
    }
    break :blk table;
};

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
pub const TypedArrayElementError = error{ IndexOutOfBounds, LengthMismatch };

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

    const needed = std.math.mul(usize, ta.count, @sizeOf(T)) catch return error.LengthMismatch;
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
    const needed_bytes = std.math.mul(usize, ta.count, elem_size) catch return error.LengthMismatch;
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

pub fn typedArrayElementToValue(ta: TypedArray, index: usize) TypedArrayElementError!Value {
    if (index >= ta.count) return error.IndexOutOfBounds;

    const elem_size = typedArrayElemSize(ta.elem);
    const expected_len = std.math.mul(usize, ta.count, elem_size) catch return error.LengthMismatch;
    if (ta.bytes.len != expected_len) return error.LengthMismatch;

    const off = index * elem_size;
    const chunk = ta.bytes[off..][0..elem_size];

    return switch (ta.elem) {
        .u8 => .{ .u8 = chunk[0] },
        .i8 => .{ .i8 = @bitCast(chunk[0]) },
        .u16 => .{ .u16 = std.mem.readInt(u16, chunk[0..2], .little) },
        .i16 => .{ .i16 = std.mem.readInt(i16, chunk[0..2], .little) },
        .u32 => .{ .u32 = std.mem.readInt(u32, chunk[0..4], .little) },
        .i32 => .{ .i32 = std.mem.readInt(i32, chunk[0..4], .little) },
        .u64 => .{ .u64 = std.mem.readInt(u64, chunk[0..8], .little) },
        .i64 => .{ .i64 = std.mem.readInt(i64, chunk[0..8], .little) },
        .f16 => .{ .f16 = @bitCast(std.mem.readInt(u16, chunk[0..2], .little)) },
        .f32 => .{ .f32 = @bitCast(std.mem.readInt(u32, chunk[0..4], .little)) },
        .f64 => .{ .f64 = @bitCast(std.mem.readInt(u64, chunk[0..8], .little)) },
    };
}

pub inline fn typedArrayElemSize(elem: TypedArrayElem) usize {
    return switch (elem) {
        .u8, .i8 => 1,
        .u16, .i16, .f16 => 2,
        .u32, .i32, .f32 => 4,
        .u64, .i64, .f64 => 8,
    };
}

/// The value of any integer encoding, widened; null if `value` is not an integer.
pub fn integerValue(value: Value) ?i128 {
    return switch (value) {
        .u64, .varIntUnsigned => |v| v,
        .u32 => |v| v,
        .u16 => |v| v,
        .u8, .smallUint, .smallIntPositive => |v| v,
        .i64, .varIntSignedPositive, .varIntSignedNegative => |v| v,
        .i32 => |v| v,
        .i16 => |v| v,
        .i8 => |v| v,
        .smallIntNegative => |v| -@as(i128, v),
        else => null,
    };
}

/// The Zig type of a typed array element.
pub fn TypedArrayElemType(comptime elem: TypedArrayElem) type {
    return switch (elem) {
        .u8 => u8,
        .i8 => i8,
        .u16 => u16,
        .i16 => i16,
        .u32 => u32,
        .i32 => i32,
        .u64 => u64,
        .i64 => i64,
        .f16 => f16,
        .f32 => f32,
        .f64 => f64,
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

    // Small byte arrays (0..31 bytes) whose length is stored in the tag byte.
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

    // Small signed integers stored in the tag byte: smallIntPositive holds 0..63, smallIntNegative
    // holds the magnitude of -32..-1 (1..32; there is no negative zero).
    smallIntPositive: u8,
    smallIntNegative: u8,

    // Small unsigned integers (0..63) stored in the tag byte.
    smallUint: u8,

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
/// `size` is the number of bytes used minus one, as stored in the tag byte.
pub fn encodeVarInt(val: u64) struct { bytes: [8]u8, size: u3 } {
    const bytes: [8]u8 = @bitCast(std.mem.nativeToLittle(u64, val));
    return .{ .bytes = bytes, .size = if (val == 0) 0 else @truncate(((64 - @clz(val) + 7) / 8) - 1) };
}

/// Decodes a variable length integer from a buffer.
pub inline fn decodeVarInt(buf: []const u8) u64 {
    std.debug.assert(buf.len > 0 and buf.len <= 8);
    return std.mem.readVarInt(u64, buf, .little);
}

/// The tag byte of an item of `kind` carrying `data` (see `Tag.data` for what it holds).
pub inline fn encodeTag(kind: Kind, data: u8) u8 {
    std.debug.assert(data >= dataRange(kind).min and data <= dataRange(kind).max);
    return if (kind == .smallIntNegative) tag_base.get(kind) - data else tag_base.get(kind) + data;
}

/// The tag byte of a signed value in `small_int_min..small_int_max`.
pub inline fn smallIntTag(value: i64) u8 {
    std.debug.assert(value >= small_int_min and value <= small_int_max);
    return @intCast(small_int_zero + value);
}

/// Decodes a tag byte; null if the byte is reserved.
pub inline fn decodeTag(byte: u8) ?Tag {
    return tag_table[byte];
}
