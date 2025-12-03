/// Reader API
const std = @import("std");
const common = @import("common.zig");

/// A Key-value pair inside an Object.
pub const KeyValuePair = struct {
    key: common.Value,
    value: common.Value,
};

const Reader = @This();

/// Error type for read operations.
pub const Error = error{ UnexpectedEof, InvalidEnumTag, UnexpectedContainerEnd };

// The underlying byte array.
bytes: []const u8,

// The current position in the byte array.
pos: usize = 0,

// The current traversal depth.
depth: u32 = 0,

/// Initializes the reader.
pub fn init(bytes: []const u8) Reader {
    return Reader{ .bytes = bytes };
}

/// Reads a single data item of given type and advances the position.
fn readBytes(self: *Reader, comptime T: type) !T {
    if (self.pos + @sizeOf(T) > self.bytes.len) return error.UnexpectedEof;

    const bytes = self.bytes[self.pos..(self.pos + @sizeOf(T))];
    self.pos += @sizeOf(T);

    switch (@typeInfo(T)) {
        .int => return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little),
        .float => {
            const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
            return @bitCast(std.mem.readInt(IntType, bytes[0..@sizeOf(T)], .little));
        },
        else => @compileError("readBytes: unsupported type"),
    }
}

/// Reads a single data item from the underlying byte array and advances the position.
pub fn read(self: *Reader) !common.Value {
    const tag_byte = try self.readBytes(u8);

    // Decode the tag
    const decoded_tag = common.decodeTag(tag_byte);
    const val_type = try std.meta.intToEnum(std.meta.Tag(common.Value), decoded_tag.tag);

    switch (val_type) {
        .containerEnd => {
            if (self.depth == 0) return error.UnexpectedContainerEnd;
            self.depth -= 1;
            return .{ .containerEnd = self.depth };
        },
        .object => {
            self.depth += 1;
            return .{ .object = self.depth };
        },
        .array => {
            self.depth += 1;
            return .{ .array = self.depth };
        },
        .varIntUnsigned => {
            const size = decoded_tag.data + 1;
            if (self.pos + size > self.bytes.len) return error.UnexpectedEof;

            const intBytes = self.bytes[self.pos..(self.pos + size)];
            self.pos += size;

            return .{ .u64 = common.decodeVarInt(intBytes) };
        },
        .varIntSigned => {
            const size = decoded_tag.data + 1;
            if (self.pos + size > self.bytes.len) return error.UnexpectedEof;

            const intBytes = self.bytes[self.pos..(self.pos + size)];
            self.pos += size;

            return .{ .i64 = common.decodeZigZag(common.decodeVarInt(intBytes)) };
        },
        .f64 => {
            const f = try self.readBytes(f64);
            return .{ .f64 = f };
        },
        .f32 => {
            const f = try self.readBytes(f32);
            return .{ .f32 = f };
        },
        .i64 => {
            const i = try self.readBytes(i64);
            return .{ .i64 = i };
        },
        .i32 => {
            const i = try self.readBytes(i32);
            return .{ .i32 = i };
        },
        .i16 => {
            const i = try self.readBytes(i16);
            return .{ .i16 = i };
        },
        .i8 => {
            const i = try self.readBytes(i8);
            return .{ .i8 = i };
        },
        .u64 => {
            const u = try self.readBytes(u64);
            return .{ .u64 = u };
        },
        .u32 => {
            const u = try self.readBytes(u32);
            return .{ .u32 = u };
        },
        .u16 => {
            const u = try self.readBytes(u16);
            return .{ .u16 = u };
        },
        .u8 => {
            const u = try self.readBytes(u8);
            return .{ .u8 = u };
        },
        .null => {
            return .{ .null = undefined };
        },
        .bool => {
            return .{ .bool = (decoded_tag.data != 0) };
        },
        .varIntBytes => {
            const size_len = decoded_tag.data + 1;
            if (self.pos + size_len > self.bytes.len) return error.UnexpectedEof;

            const intBytes = self.bytes[self.pos..(self.pos + size_len)];
            self.pos += size_len;
            const len = common.decodeVarInt(intBytes);

            if (len > self.bytes.len - self.pos) return error.UnexpectedEof;

            const str_ptr = self.pos;
            self.pos += len;
            return .{ .bytes = self.bytes[str_ptr..(str_ptr + len)] };
        },
        .bytes => {
            const len = try self.readBytes(u64);
            if (len > self.bytes.len - self.pos) return error.UnexpectedEof;

            const str_ptr = self.pos;
            self.pos += len;
            return .{ .bytes = self.bytes[str_ptr..(str_ptr + len)] };
        },
    }
}

/// Discards data items until the target depth is reached.
fn discardUntilDepth(self: *Reader, target_depth: u32) !void {
    while (self.depth > target_depth) {
        _ = try self.read();
    }
}

/// Iterates over the key-value pairs of a given Value Object.
pub fn iterateObject(self: *Reader, obj: common.Value) !?KeyValuePair {
    std.debug.assert(obj == .object);
    try self.discardUntilDepth(obj.object);

    const key = try self.read();
    if (key == .containerEnd) return null;

    const value = try self.read();

    return .{ .key = key, .value = value };
}

/// Iterates over the values of a given Value Array.
pub fn iterateArray(self: *Reader, arr: common.Value) !?common.Value {
    std.debug.assert(arr == .array);
    try self.discardUntilDepth(arr.array);

    const value = try self.read();
    if (value == .containerEnd) return null;

    return value;
}
