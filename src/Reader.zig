/// Reader API
const std = @import("std");
const common = @import("common.zig");

/// A Key-value pair inside an Object.
pub const KeyValuePair = struct {
    key: common.Value,
    value: common.Value,
};

/// Iteration limits to protect against malformed input.
pub const ReadLimits = struct {
    /// Maximum nesting depth. Set to null for unlimited.
    max_depth: ?u32 = 2048,

    /// Maximum byte array length for strings/binary blobs. Set to null for unlimited.
    max_bytes_length: ?usize = null,

    /// Maximum array element count. Set to null for unlimited.
    /// Requires max_depth to be set.
    max_array_length: ?usize = null,

    /// Maximum object key-value pair count. Set to null for unlimited.
    /// Requires max_depth to be set.
    max_object_size: ?usize = null,
};

/// Error type for read operations.
pub const Error = error{ UnexpectedEof, InvalidEnumTag, UnexpectedContainerEnd, MaxDepthExceeded, BytesTooLong, ArrayTooLarge, ObjectTooLarge };

pub fn Reader(comptime limits: ReadLimits) type {
    // Array/object limits require depth limit for counter stack allocation
    if (limits.max_depth == null) {
        if (limits.max_array_length != null) {
            @compileError("max_array_length requires max_depth to be set (non-null)");
        }
        if (limits.max_object_size != null) {
            @compileError("max_object_size requires max_depth to be set (non-null)");
        }
    }

    const needs_counters = limits.max_array_length != null or limits.max_object_size != null;
    const counter_stack_size: usize = if (needs_counters) limits.max_depth.? else 0;

    return struct {
        const Self = @This();

        // The underlying byte array.
        bytes: []const u8,

        // The current position in the byte array.
        pos: usize = 0,

        // The current traversal depth.
        depth: u32 = 0,

        // Per-depth iteration counters.
        iteration_counts: [counter_stack_size]usize = [_]usize{0} ** counter_stack_size,

        /// Initializes the reader.
        pub fn init(bytes: []const u8) Self {
            return .{ .bytes = bytes };
        }

        /// Reads a single data item of given type and advances the position.
        fn readBytes(self: *Self, comptime T: type) !T {
            if (@sizeOf(T) > self.bytes.len - self.pos) return error.UnexpectedEof;

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
        pub fn read(self: *Self) !common.Value {
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
                    if (limits.max_depth) |max| {
                        if (self.depth >= max) return error.MaxDepthExceeded;
                    }
                    self.depth += 1;
                    // Reset iteration counter for this new container
                    if (needs_counters) {
                        self.iteration_counts[self.depth - 1] = 0;
                    }
                    return .{ .object = self.depth };
                },
                .array => {
                    if (limits.max_depth) |max| {
                        if (self.depth >= max) return error.MaxDepthExceeded;
                    }
                    self.depth += 1;
                    // Reset iteration counter for this new container
                    if (needs_counters) {
                        self.iteration_counts[self.depth - 1] = 0;
                    }
                    return .{ .array = self.depth };
                },
                .varIntUnsigned => {
                    const size: usize = @as(usize, decoded_tag.data) + 1;
                    if (size > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const intBytes = self.bytes[self.pos..(self.pos + size)];
                    self.pos += size;

                    return .{ .u64 = common.decodeVarInt(intBytes) };
                },
                .varIntSigned => {
                    const size: usize = @as(usize, decoded_tag.data) + 1;
                    if (size > self.bytes.len - self.pos) return error.UnexpectedEof;

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
                    const size_len: usize = @as(usize, decoded_tag.data) + 1;
                    if (size_len > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const intBytes = self.bytes[self.pos..(self.pos + size_len)];
                    self.pos += size_len;
                    const len = common.decodeVarInt(intBytes);

                    // Check length limit
                    if (limits.max_bytes_length) |max| {
                        if (len > max) return error.BytesTooLong;
                    }

                    if (len > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const str_ptr = self.pos;
                    self.pos += len;
                    return .{ .bytes = self.bytes[str_ptr..(str_ptr + len)] };
                },
                .bytes => {
                    const len = try self.readBytes(u64);

                    // Check length limit
                    if (limits.max_bytes_length) |max| {
                        if (len > max) return error.BytesTooLong;
                    }

                    if (len > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const str_ptr = self.pos;
                    self.pos += len;
                    return .{ .bytes = self.bytes[str_ptr..(str_ptr + len)] };
                },
            }
        }

        /// Discards data items until the target depth is reached.
        fn discardUntilDepth(self: *Self, target_depth: u32) !void {
            while (self.depth > target_depth) {
                _ = try self.read();
            }
        }

        /// Iterates over the key-value pairs of a given Value Object.
        pub fn iterateObject(self: *Self, obj: common.Value) !?KeyValuePair {
            std.debug.assert(obj == .object);
            try self.discardUntilDepth(obj.object);

            const key = try self.read();
            if (key == .containerEnd) return null;

            const value = try self.read();

            // Check limit using per-depth counter
            if (limits.max_object_size) |max| {
                const idx = obj.object - 1;
                self.iteration_counts[idx] += 1;
                if (self.iteration_counts[idx] > max) return error.ObjectTooLarge;
            }

            return .{ .key = key, .value = value };
        }

        /// Iterates over the values of a given Value Array.
        pub fn iterateArray(self: *Self, arr: common.Value) !?common.Value {
            std.debug.assert(arr == .array);
            try self.discardUntilDepth(arr.array);

            const value = try self.read();
            if (value == .containerEnd) return null;

            // Check limit using per-depth counter
            if (limits.max_array_length) |max| {
                const idx = arr.array - 1;
                self.iteration_counts[idx] += 1;
                if (self.iteration_counts[idx] > max) return error.ArrayTooLarge;
            }

            return value;
        }
    };
}
