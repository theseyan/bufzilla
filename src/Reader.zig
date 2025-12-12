/// Reader API
const std = @import("std");
const common = @import("common.zig");
const path = @import("path.zig");

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

    /// Maximum array element count. Set to null for unlimited. Requires max_depth to be set.
    max_array_length: ?usize = null,

    /// Maximum object key-value pair count. Set to null for unlimited. Requires max_depth to be set.
    max_object_size: ?usize = null,
};

const PeekResult = struct {
    tag: std.meta.Tag(common.Value),
    data: u3,
};

/// A single path query for readPaths.
pub const PathQuery = struct {
    path: []const u8,
    value: ?common.Value = null,
    resolved: bool = false,
    orig_index: usize = 0,
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
                .object, .array => {
                    // Check depth limit
                    if (limits.max_depth) |max| {
                        if (self.depth >= max) return error.MaxDepthExceeded;
                    }
                    self.depth += 1;
                    // Reset iteration counter for this new container
                    if (needs_counters) {
                        self.iteration_counts[self.depth - 1] = 0;
                    }
                    return if (val_type == .object) .{ .object = self.depth } else .{ .array = self.depth };
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

        /// Peeks at the next tag without advancing position.
        fn peekTag(self: *Self) !PeekResult {
            if (self.pos >= self.bytes.len) return error.UnexpectedEof;
            const tag_byte = self.bytes[self.pos];
            const decoded = common.decodeTag(tag_byte);
            const tag = try std.meta.intToEnum(std.meta.Tag(common.Value), decoded.tag);
            return .{ .tag = tag, .data = decoded.data };
        }

        /// Reads the length from a varIntBytes or bytes tag.
        inline fn readBytesLength(self: *Self, val_type: std.meta.Tag(common.Value), tag_data: u3) !usize {
            if (val_type == .varIntBytes) {
                const size_len: usize = @as(usize, tag_data) + 1;
                if (size_len > self.bytes.len - self.pos) return error.UnexpectedEof;
                const len = common.decodeVarInt(self.bytes[self.pos..][0..size_len]);
                self.pos += size_len;

                if (limits.max_bytes_length) |max| {
                    if (len > max) return error.BytesTooLong;
                }
                return len;
            } else { // .bytes
                if (8 > self.bytes.len - self.pos) return error.UnexpectedEof;
                const len = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
                self.pos += 8;

                if (limits.max_bytes_length) |max| {
                    if (len > max) return error.BytesTooLong;
                }
                return len;
            }
        }

        /// Skips a single value without materializing it.
        pub fn skipValue(self: *Self) !void {
            if (self.pos >= self.bytes.len) return error.UnexpectedEof;

            const tag_byte = self.bytes[self.pos];
            self.pos += 1;

            const decoded = common.decodeTag(tag_byte);
            const val_type = try std.meta.intToEnum(std.meta.Tag(common.Value), decoded.tag);

            switch (val_type) {
                // Fixed size types
                .f64, .i64, .u64 => self.pos += 8,
                .f32, .i32, .u32 => self.pos += 4,
                .i16, .u16 => self.pos += 2,
                .i8, .u8 => self.pos += 1,
                .null, .bool => {},

                // Variable length integers
                .varIntUnsigned, .varIntSigned => {
                    const size: usize = @as(usize, decoded.data) + 1;
                    if (size > self.bytes.len - self.pos) return error.UnexpectedEof;
                    self.pos += size;
                },

                // Byte arrays
                .varIntBytes, .bytes => {
                    const len = try self.readBytesLength(val_type, decoded.data);
                    if (len > self.bytes.len - self.pos) return error.UnexpectedEof;
                    self.pos += len;
                },

                // Containers
                .array, .object => {
                    if (limits.max_depth) |max| {
                        if (self.depth >= max) return error.MaxDepthExceeded;
                    }

                    var nest_depth: u32 = 1;
                    while (nest_depth > 0) {
                        if (self.pos >= self.bytes.len) return error.UnexpectedEof;

                        const inner_tag = self.bytes[self.pos];
                        self.pos += 1;

                        const inner_decoded = common.decodeTag(inner_tag);
                        const inner_type = try std.meta.intToEnum(std.meta.Tag(common.Value), inner_decoded.tag);

                        switch (inner_type) {
                            .f64, .i64, .u64 => self.pos += 8,
                            .f32, .i32, .u32 => self.pos += 4,
                            .i16, .u16 => self.pos += 2,
                            .i8, .u8 => self.pos += 1,
                            .null, .bool => {},
                            .varIntUnsigned, .varIntSigned => {
                                const size: usize = @as(usize, inner_decoded.data) + 1;
                                if (size > self.bytes.len - self.pos) return error.UnexpectedEof;
                                self.pos += size;
                            },
                            .varIntBytes, .bytes => {
                                const len = try self.readBytesLength(inner_type, inner_decoded.data);
                                if (len > self.bytes.len - self.pos) return error.UnexpectedEof;
                                self.pos += len;
                            },
                            .array, .object => {
                                if (limits.max_depth) |max| {
                                    if (self.depth + nest_depth >= max) return error.MaxDepthExceeded;
                                }
                                nest_depth += 1;
                            },
                            .containerEnd => nest_depth -= 1,
                        }
                    }
                },

                .containerEnd => return error.UnexpectedContainerEnd,
            }
        }

        /// Reads the bytes content of a varIntBytes or bytes tag and returns a slice.
        fn readBytesSlice(self: *Self) ![]const u8 {
            if (self.pos >= self.bytes.len) return error.UnexpectedEof;

            const tag_byte = self.bytes[self.pos];
            self.pos += 1;

            const decoded = common.decodeTag(tag_byte);
            const val_type = try std.meta.intToEnum(std.meta.Tag(common.Value), decoded.tag);

            if (val_type != .varIntBytes and val_type != .bytes) {
                return error.InvalidEnumTag;
            }

            const len = try self.readBytesLength(val_type, decoded.data);
            if (len > self.bytes.len - self.pos) return error.UnexpectedEof;

            const result = self.bytes[self.pos..][0..len];
            self.pos += len;
            return result;
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

        fn lessThanByIndex(_: void, lhs: PathQuery, rhs: PathQuery) bool {
            return lhs.orig_index < rhs.orig_index;
        }

        /// Reads multiple paths from the buffer in a single pass.
        /// Each query's `value` is populated with the found Value or null.
        /// Malformed paths yield null for that query.
        pub fn readPaths(self: *Self, queries: []PathQuery) Error!void {
            const saved_pos = self.pos;
            const saved_depth = self.depth;
            const saved_counts = self.iteration_counts;

            self.pos = 0;
            self.depth = 0;
            self.iteration_counts = [_]usize{0} ** counter_stack_size;

            try self.readPathsInternal(queries);

            self.pos = saved_pos;
            self.depth = saved_depth;
            self.iteration_counts = saved_counts;
        }

        fn readPathsInternal(self: *Self, queries: []PathQuery) Error!void {
            if (queries.len == 0) return;

            var remaining: usize = queries.len;
            for (queries, 0..) |*q, i| {
                q.value = null;
                q.resolved = false;
                q.orig_index = i;
                if (!path.validate(q.path)) {
                    q.resolved = true;
                    remaining -= 1;
                }
            }

            if (queries.len > 1) {
                const LessSeg = struct {
                    fn lt(_: void, a: PathQuery, b: PathQuery) bool {
                        return path.lessThanPathSegments(a.path, b.path);
                    }
                };
                std.sort.pdq(PathQuery, queries, {}, LessSeg.lt);
            }

            if (remaining == 0) {
                if (queries.len > 1) {
                    const LessIdx = struct {
                        fn lt(_: void, a: PathQuery, b: PathQuery) bool {
                            return lessThanByIndex({}, a, b);
                        }
                    };
                    std.sort.pdq(PathQuery, queries, {}, LessIdx.lt);
                }
                return;
            }

            const root_peek = try self.peekTag();

                if (root_peek.tag != .object and root_peek.tag != .array) {
                    if (remaining > 0) {
                        var has_empty = false;
                        for (queries) |q| {
                            if (!q.resolved and q.path.len == 0) {
                            has_empty = true;
                            break;
                        }
                    }

                    if (has_empty) {
                        const root_val = try self.read();
                        for (queries) |*q| {
                            if (!q.resolved and q.path.len == 0) {
                                q.value = root_val;
                                q.resolved = true;
                                remaining -= 1;
                            }
                        }
                        }
                    }

                if (queries.len > 1) {
                    const LessIdx = struct {
                        fn lt(_: void, a: PathQuery, b: PathQuery) bool {
                            return lessThanByIndex({}, a, b);
                        }
                    };
                    std.sort.pdq(PathQuery, queries, {}, LessIdx.lt);
                }
                return;
            }

            const root_val = try self.read();
            for (queries) |*q| {
                if (!q.resolved and q.path.len == 0) {
                    q.value = root_val;
                    q.resolved = true;
                    remaining -= 1;
                }
            }

            if (remaining > 0) {
                if (root_val == .object) {
                    try self.readPathsObject(queries, 0, &remaining);
                } else {
                    try self.readPathsArray(queries, 0, &remaining);
                }
            }

            if (queries.len > 1) {
                const LessIdx = struct {
                    fn lt(_: void, a: PathQuery, b: PathQuery) bool {
                        return lessThanByIndex({}, a, b);
                    }
                };
                std.sort.pdq(PathQuery, queries, {}, LessIdx.lt);
            }
        }

        fn readPathsObject(self: *Self, queries: []PathQuery, path_depth: usize, remaining: *usize) Error!void {
            var kv_count: usize = 0;

            while (true) {
                if (remaining.* == 0) {
                    return;
                }

                const peek = try self.peekTag();
                if (peek.tag == .containerEnd) {
                    _ = try self.read();
                    return;
                }

                if (limits.max_object_size) |max| {
                    if (kv_count >= max) return error.ObjectTooLarge;
                }

                // Keys must be bytes; if not, skip key+value and continue.
                if (peek.tag != .varIntBytes and peek.tag != .bytes) {
                    try self.skipValue();
                    try self.skipValue();
                    continue;
                }

                const key_slice = try self.readBytesSlice();
                defer kv_count += 1;

                var match_start: ?usize = null;
                var match_end: usize = 0;
                var any_leaf = false;
                var any_child = false;

                for (queries, 0..) |*q, i| {
                    if (q.resolved) continue;
                    const seg = path.segmentAtDepth(q.path, path_depth) orelse {
                        q.resolved = true;
                        remaining.* -= 1;
                        continue;
                    };
                    if (seg.is_index) {
                        q.resolved = true;
                        remaining.* -= 1;
                        continue;
                    }
                    if (std.mem.eql(u8, seg.key, key_slice)) {
                        if (match_start == null) match_start = i;
                        match_end = i + 1;
                        if (seg.rest.len == 0) {
                            any_leaf = true;
                        } else {
                            any_child = true;
                        }
                    }
                }

                if (match_start == null) {
                    try self.skipValue();
                    continue;
                }

                const matching = queries[match_start.?..match_end];

                if (any_leaf) {
                    const val = try self.read();
                    for (matching) |*q| {
                        if (q.resolved) continue;
                        const seg = path.segmentAtDepth(q.path, path_depth) orelse continue;
                        if (!seg.is_index and std.mem.eql(u8, seg.key, key_slice) and seg.rest.len == 0) {
                            q.value = val;
                            q.resolved = true;
                            remaining.* -= 1;
                        }
                    }

                    if (val == .object or val == .array) {
                        if (any_child) {
                            if (val == .object) {
                                try self.readPathsObject(matching, path_depth + 1, remaining);
                            } else {
                                try self.readPathsArray(matching, path_depth + 1, remaining);
                            }
                        } else {
                            const target = if (val == .object) val.object - 1 else val.array - 1;
                            try self.discardUntilDepth(target);
                        }
                    } else if (any_child) {
                        for (matching) |*q| {
                            if (q.resolved) continue;
                            const seg = path.segmentAtDepth(q.path, path_depth) orelse continue;
                            if (!seg.is_index and std.mem.eql(u8, seg.key, key_slice) and seg.rest.len > 0) {
                                q.resolved = true;
                                remaining.* -= 1;
                            }
                        }
                    }
                } else {
                    const val_peek = try self.peekTag();
                    if (val_peek.tag != .object and val_peek.tag != .array) {
                        for (matching) |*q| {
                            if (q.resolved) continue;
                            const seg = path.segmentAtDepth(q.path, path_depth) orelse continue;
                            if (!seg.is_index and std.mem.eql(u8, seg.key, key_slice)) {
                                q.resolved = true;
                                remaining.* -= 1;
                            }
                        }
                        try self.skipValue();
                    } else {
                        const val = try self.read();
                        if (val == .object) {
                            try self.readPathsObject(matching, path_depth + 1, remaining);
                        } else {
                            try self.readPathsArray(matching, path_depth + 1, remaining);
                        }
                    }
                }
            }
        }

        fn readPathsArray(self: *Self, queries: []PathQuery, path_depth: usize, remaining: *usize) Error!void {
            var idx: usize = 0;

            while (true) {
                if (remaining.* == 0) {
                    return;
                }

                const peek = try self.peekTag();
                if (peek.tag == .containerEnd) {
                    _ = try self.read();
                    return;
                }

                if (limits.max_array_length) |max| {
                    if (idx >= max) return error.ArrayTooLarge;
                }

                var match_start: ?usize = null;
                var match_end: usize = 0;
                var any_leaf = false;
                var any_child = false;

                for (queries, 0..) |*q, i| {
                    if (q.resolved) continue;
                    const seg = path.segmentAtDepth(q.path, path_depth) orelse {
                        q.resolved = true;
                        remaining.* -= 1;
                        continue;
                    };
                    if (!seg.is_index) {
                        q.resolved = true;
                        remaining.* -= 1;
                        continue;
                    }
                    if (seg.index == idx) {
                        if (match_start == null) match_start = i;
                        match_end = i + 1;
                        if (seg.rest.len == 0) {
                            any_leaf = true;
                        } else {
                            any_child = true;
                        }
                    }
                }

                if (match_start == null) {
                    try self.skipValue();
                    idx += 1;
                    continue;
                }

                const matching = queries[match_start.?..match_end];

                if (any_leaf) {
                    const val = try self.read();
                    for (matching) |*q| {
                        if (q.resolved) continue;
                        const seg = path.segmentAtDepth(q.path, path_depth) orelse continue;
                        if (seg.is_index and seg.index == idx and seg.rest.len == 0) {
                            q.value = val;
                            q.resolved = true;
                            remaining.* -= 1;
                        }
                    }

                    if (val == .object or val == .array) {
                        if (any_child) {
                            if (val == .object) {
                                try self.readPathsObject(matching, path_depth + 1, remaining);
                            } else {
                                try self.readPathsArray(matching, path_depth + 1, remaining);
                            }
                        } else {
                            const target = if (val == .object) val.object - 1 else val.array - 1;
                            try self.discardUntilDepth(target);
                        }
                    } else if (any_child) {
                        for (matching) |*q| {
                            if (q.resolved) continue;
                            const seg = path.segmentAtDepth(q.path, path_depth) orelse continue;
                            if (seg.is_index and seg.index == idx and seg.rest.len > 0) {
                                q.resolved = true;
                                remaining.* -= 1;
                            }
                        }
                    }
                } else {
                    const val_peek = try self.peekTag();
                    if (val_peek.tag != .object and val_peek.tag != .array) {
                        for (matching) |*q| {
                            if (q.resolved) continue;
                            const seg = path.segmentAtDepth(q.path, path_depth) orelse continue;
                            if (seg.is_index and seg.index == idx) {
                                q.resolved = true;
                                remaining.* -= 1;
                            }
                        }
                        try self.skipValue();
                    } else {
                        const val = try self.read();
                        if (val == .object) {
                            try self.readPathsObject(matching, path_depth + 1, remaining);
                        } else {
                            try self.readPathsArray(matching, path_depth + 1, remaining);
                        }
                    }
                }

                idx += 1;
            }
        }

        /// Reads a value at a given path. Path format: "key", "key.nested", "array[0]", "obj.arr[2].name"
        /// Returns null if the path doesn't exist or points to an incompatible type.
        pub fn readPath(self: *Self, path_str: []const u8) Error!?common.Value {
            var q = [_]PathQuery{.{ .path = path_str }};
            try self.readPaths(q[0..]);
            return q[0].value;
        }
    };
}
