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
    /// Set by `readPaths`: the value at `path`, or null if there is none.
    value: ?common.Value = null,
    /// Internal to `readPaths`.
    resolved: bool = false,
    /// Internal to `readPaths`: the query's position in the caller's slice.
    orig_index: usize = 0,
    /// Internal to `readPaths`: where the path segment being processed starts in `path`.
    offset: usize = 0,
};

/// Error type for read operations.
pub const Error = error{ UnexpectedEof, InvalidEnumTag, InvalidSignedMagnitude, UnexpectedContainerEnd, MaxDepthExceeded, BytesTooLong, ArrayTooLarge, ObjectTooLarge };

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
        iteration_counts: [counter_stack_size]usize = @splat(0),

        /// Initializes the reader.
        pub fn init(bytes: []const u8) Self {
            return .{ .bytes = bytes };
        }

        /// Reads a single data item of given type and advances the position.
        fn readBytes(self: *Self, comptime T: type) !T {
            if (comptime T == u8) {
                if (self.pos >= self.bytes.len) return error.UnexpectedEof;
                const byte = self.bytes[self.pos];
                self.pos += 1;
                return byte;
            }

            if (@sizeOf(T) > self.bytes.len - self.pos) return error.UnexpectedEof;

            const bytes = self.bytes[self.pos..(self.pos + @sizeOf(T))];
            self.pos += @sizeOf(T);

            switch (@typeInfo(T)) {
                .int => return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little),
                .float => {
                    const IntType = @Int(.unsigned, @bitSizeOf(T));
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
            const val_type = std.enums.fromInt(std.meta.Tag(common.Value), decoded_tag.tag) orelse return error.InvalidEnumTag;

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
                .smallIntPositive => {
                    return .{ .i64 = @as(i64, decoded_tag.data) };
                },
                .smallIntNegative => {
                    if (decoded_tag.data == 0) return error.InvalidSignedMagnitude;
                    return .{ .i64 = -@as(i64, decoded_tag.data) };
                },
                .smallUint => {
                    return .{ .u64 = @as(u64, decoded_tag.data) };
                },
                .varIntUnsigned => {
                    const size: usize = @as(usize, decoded_tag.data) + 1;
                    if (size > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const intBytes = self.bytes[self.pos..(self.pos + size)];
                    self.pos += size;

                    return .{ .u64 = common.decodeVarInt(intBytes) };
                },
                .varIntSignedPositive => {
                    const size: usize = @as(usize, decoded_tag.data) + 1;
                    if (size > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const intBytes = self.bytes[self.pos..(self.pos + size)];
                    self.pos += size;
                    const magnitude = common.decodeVarInt(intBytes);
                    if (magnitude > @as(u64, @intCast(std.math.maxInt(i64)))) return error.InvalidSignedMagnitude;
                    return .{ .i64 = @intCast(magnitude) };
                },
                .varIntSignedNegative => {
                    const size: usize = @as(usize, decoded_tag.data) + 1;
                    if (size > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const intBytes = self.bytes[self.pos..(self.pos + size)];
                    self.pos += size;
                    const magnitude = common.decodeVarInt(intBytes);
                    if (magnitude == 0) return error.InvalidSignedMagnitude;
                    if (magnitude == (@as(u64, 1) << 63)) return .{ .i64 = std.math.minInt(i64) };
                    if (magnitude > @as(u64, @intCast(std.math.maxInt(i64)))) return error.InvalidSignedMagnitude;
                    return .{ .i64 = -@as(i64, @intCast(magnitude)) };
                },
                .f64 => {
                    const f = try self.readBytes(f64);
                    return .{ .f64 = f };
                },
                .f32 => {
                    const f = try self.readBytes(f32);
                    return .{ .f32 = f };
                },
                .f16 => {
                    const bits = try self.readBytes(u16);
                    return .{ .f16 = @bitCast(bits) };
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
                    const len = try self.readBytesLength(.varIntBytes, decoded_tag.data);
                    if (len > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const str_ptr = self.pos;
                    self.pos += len;
                    return .{ .bytes = self.bytes[str_ptr..(str_ptr + len)] };
                },
                .smallBytes => {
                    const len: usize = decoded_tag.data;

                    if (limits.max_bytes_length) |max| {
                        if (len > max) return error.BytesTooLong;
                    }

                    if (len > self.bytes.len - self.pos) return error.UnexpectedEof;

                    const str_ptr = self.pos;
                    self.pos += len;
                    return .{ .bytes = self.bytes[str_ptr..(str_ptr + len)] };
                },
                .typedArray => {
                    const hdr = try self.readTypedArrayHeader(decoded_tag.data);
                    const start = self.pos;
                    self.pos += hdr.payload_len;
                    return .{ .typedArray = .{ .elem = hdr.elem, .count = hdr.count, .bytes = self.bytes[start..][0..hdr.payload_len] } };
                },
                .bytes => {
                    const len = try self.readBytesLength(.bytes, decoded_tag.data);
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
            const tag = std.enums.fromInt(std.meta.Tag(common.Value), decoded.tag) orelse return error.InvalidEnumTag;
            return .{ .tag = tag, .data = decoded.data };
        }

        /// Reads the length from a varIntBytes or bytes tag.
        inline fn readBytesLength(self: *Self, val_type: std.meta.Tag(common.Value), tag_data: u3) !usize {
            const len_u64 = if (val_type == .varIntBytes) blk: {
                const size_len: usize = @as(usize, tag_data) + 1;
                if (size_len > self.bytes.len - self.pos) return error.UnexpectedEof;
                const len = common.decodeVarInt(self.bytes[self.pos..][0..size_len]);
                self.pos += size_len;
                break :blk len;
            } else blk: { // .bytes
                if (8 > self.bytes.len - self.pos) return error.UnexpectedEof;
                const len = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
                self.pos += 8;
                break :blk len;
            };

            if (len_u64 > std.math.maxInt(usize)) return error.BytesTooLong;
            const len: usize = @intCast(len_u64);
            if (limits.max_bytes_length) |max| {
                if (len > max) return error.BytesTooLong;
            }
            return len;
        }

        const TypedArrayHeader = struct {
            elem: common.TypedArrayElem,
            count: usize,
            payload_len: usize,
        };

        inline fn readTypedArrayHeader(self: *Self, tag_data: u3) !TypedArrayHeader {
            if (self.pos >= self.bytes.len) return error.UnexpectedEof;
            const elem_byte = self.bytes[self.pos];
            self.pos += 1;
            const elem = std.enums.fromInt(common.TypedArrayElem, elem_byte) orelse return error.InvalidEnumTag;

            const count_len: usize = @as(usize, tag_data) + 1;
            if (count_len > self.bytes.len - self.pos) return error.UnexpectedEof;
            const count_u64 = common.decodeVarInt(self.bytes[self.pos..][0..count_len]);
            self.pos += count_len;

            if (count_u64 > std.math.maxInt(usize)) return error.BytesTooLong;
            const count: usize = @intCast(count_u64);

            const payload_len = std.math.mul(usize, count, common.typedArrayElemSize(elem)) catch return error.BytesTooLong;
            if (limits.max_bytes_length) |max| {
                if (payload_len > max) return error.BytesTooLong;
            }
            if (payload_len > self.bytes.len - self.pos) return error.UnexpectedEof;

            return .{ .elem = elem, .count = count, .payload_len = payload_len };
        }

        const SkipEvent = enum { done, enter_container, exit_container };

        inline fn skipBytes(self: *Self, len: usize) !void {
            if (len > self.bytes.len - self.pos) return error.UnexpectedEof;
            self.pos += len;
        }

        inline fn skipOneValue(self: *Self, decoded: common.Tag, typ: std.meta.Tag(common.Value)) !SkipEvent {
            switch (typ) {
                // Fixed size types
                .f64, .i64, .u64 => try self.skipBytes(8),
                .f32, .i32, .u32 => try self.skipBytes(4),
                .f16 => try self.skipBytes(2),
                .i16, .u16 => try self.skipBytes(2),
                .i8, .u8 => try self.skipBytes(1),
                .null, .bool => {},
                .smallIntPositive, .smallIntNegative, .smallUint => {},

                // Variable length integers
                .varIntUnsigned, .varIntSignedPositive, .varIntSignedNegative => {
                    const size: usize = @as(usize, decoded.data) + 1;
                    try self.skipBytes(size);
                },

                // Byte arrays
                .smallBytes => {
                    const len: usize = decoded.data;
                    if (limits.max_bytes_length) |max| {
                        if (len > max) return error.BytesTooLong;
                    }
                    try self.skipBytes(len);
                },
                .typedArray => {
                    const hdr = try self.readTypedArrayHeader(decoded.data);
                    try self.skipBytes(hdr.payload_len);
                },
                .varIntBytes, .bytes => {
                    const len = try self.readBytesLength(typ, decoded.data);
                    try self.skipBytes(len);
                },

                .array, .object => return .enter_container,
                .containerEnd => return .exit_container,
            }

            return .done;
        }

        /// Skips a single value without materializing it.
        pub fn skipValue(self: *Self) !void {
            if (self.pos >= self.bytes.len) return error.UnexpectedEof;

            const tag_byte = self.bytes[self.pos];
            self.pos += 1;

            const decoded = common.decodeTag(tag_byte);
            const val_type = std.enums.fromInt(std.meta.Tag(common.Value), decoded.tag) orelse return error.InvalidEnumTag;

            switch (val_type) {
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
                        const inner_type = std.enums.fromInt(std.meta.Tag(common.Value), inner_decoded.tag) orelse return error.InvalidEnumTag;

                        const ev = try skipOneValue(self, inner_decoded, inner_type);
                        switch (ev) {
                            .done => {},
                            .enter_container => {
                                if (limits.max_depth) |max| {
                                    if (self.depth + nest_depth >= max) return error.MaxDepthExceeded;
                                }
                                nest_depth += 1;
                            },
                            .exit_container => nest_depth -= 1,
                        }
                    }
                },

                .containerEnd => return error.UnexpectedContainerEnd,
                else => _ = try skipOneValue(self, decoded, val_type),
            }
        }

        /// Reads the bytes content of a varIntBytes or bytes tag and returns a slice.
        fn readBytesSlice(self: *Self) ![]const u8 {
            if (self.pos >= self.bytes.len) return error.UnexpectedEof;

            const tag_byte = self.bytes[self.pos];
            self.pos += 1;

            const decoded = common.decodeTag(tag_byte);
            const val_type = std.enums.fromInt(std.meta.Tag(common.Value), decoded.tag) orelse return error.InvalidEnumTag;

            if (val_type != .varIntBytes and val_type != .bytes and val_type != .smallBytes) {
                return error.InvalidEnumTag;
            }

            const len = if (val_type == .smallBytes) blk: {
                const l: usize = decoded.data;
                if (limits.max_bytes_length) |max| {
                    if (l > max) return error.BytesTooLong;
                }
                break :blk l;
            } else try self.readBytesLength(val_type, decoded.data);
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
            if (value == .containerEnd) return error.UnexpectedContainerEnd;

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

        /// Valid paths grouped by segments, so that at every level the queries addressing one key or
        /// index are contiguous, followed by malformed paths (already resolved).
        fn lessThanBySegments(_: void, lhs: PathQuery, rhs: PathQuery) bool {
            if (lhs.resolved or rhs.resolved) return !lhs.resolved and rhs.resolved;
            return path.lessThanPathSegments(lhs.path, rhs.path);
        }

        /// Reads multiple paths from the buffer in a single pass.
        /// Each query's `value` is set to what `readPath` would return for its path: the found Value,
        /// or null if the path does not exist or is malformed.
        /// Like `readPath`, this does not move the reader, even on error.
        /// On error, queries keep their order but their values are unspecified.
        pub fn readPaths(self: *Self, queries: []PathQuery) Error!void {
            if (queries.len == 0) return;
            if (queries.len == 1) {
                queries[0].value = try self.readPath(queries[0].path);
                queries[0].resolved = true;
                queries[0].orig_index = 0;
                return;
            }

            const saved_pos = self.pos;
            const saved_depth = self.depth;
            const saved_counts = self.iteration_counts;
            defer {
                self.pos = saved_pos;
                self.depth = saved_depth;
                self.iteration_counts = saved_counts;
            }
            // Queries are sorted while being resolved; put them back in caller order.
            defer std.mem.sort(PathQuery, queries, {}, lessThanByIndex);

            self.pos = 0;
            self.depth = 0;
            self.iteration_counts = @splat(0);

            var remaining: usize = 0;
            for (queries, 0..) |*q, i| {
                q.* = .{ .path = q.path, .orig_index = i };
                if (path.validate(q.path)) remaining += 1 else q.resolved = true;
            }

            std.sort.pdq(PathQuery, queries, {}, lessThanBySegments);
            const valid = queries[0..remaining];

            // Read even if every path is malformed: `readPath` reads the root first, too.
            const root = try self.read();
            // Empty paths address the root itself; they sort first.
            var first: usize = 0;
            while (first < valid.len and valid[first].path.len == 0) : (first += 1) resolveQuery(&valid[first], root, &remaining);
            try self.resolveIn(root, valid[first..], &remaining, 0);
        }

        // Path queries are resolved in one pass over the data. At each container, the queries whose
        // current segment addresses its contents are a sorted, contiguous slice: object entries find
        // theirs by binary search, array elements by a cursor. Each query's `offset` marks its current
        // segment (see `path.descend`). A container's scan stops once its own queries are resolved, so
        // it reads exactly as far as `readPath` would for the furthest of them.

        fn resolveQuery(query: *PathQuery, value: ?common.Value, remaining: *usize) void {
            query.value = value;
            query.resolved = true;
            remaining.* -= 1;
        }

        /// Resolves `queries`, whose current segments (at path depth `depth`) address the contents
        /// of `value`, which was just read. Unless no queries remain at all, this leaves the reader
        /// after `value`.
        fn resolveIn(self: *Self, value: common.Value, queries: []PathQuery, remaining: *usize, depth: usize) Error!void {
            switch (value) {
                .object => try self.resolveInObject(queries, remaining, depth),
                .array => try self.resolveInArray(queries, remaining, depth),
                .typedArray => |ta| for (queries) |*q| resolveQuery(q, typedArrayElementAt(ta, q), remaining),
                else => for (queries) |*q| resolveQuery(q, null, remaining),
            }
        }

        fn typedArrayElementAt(ta: common.TypedArray, query: *const PathQuery) ?common.Value {
            const seg = path.currentSegment(query) orelse return null;
            if (!seg.is_index or seg.index >= ta.count or seg.rest.len != 0) return null;
            return common.typedArrayElementToValue(ta, seg.index) catch null;
        }

        fn resolveInObject(self: *Self, queries: []PathQuery, remaining: *usize, depth: usize) Error!void {
            // Keys sort before indices, and an index cannot match in an object.
            var keyed: usize = 0;
            while (keyed < queries.len) : (keyed += 1) {
                const seg = path.currentSegment(&queries[keyed]) orelse break;
                if (seg.is_index) break;
            }
            for (queries[keyed..]) |*q| resolveQuery(q, null, remaining);

            var pending = keyed;
            var entries: usize = 0;
            while (true) {
                if (remaining.* == 0) return;
                if (pending == 0) return self.skipRestOfContainer();

                const peek = try self.peekTag();
                if (peek.tag == .containerEnd) break;
                if (limits.max_object_size) |max| {
                    if (entries >= max) return error.ObjectTooLarge;
                }
                entries += 1;

                if (peek.tag != .varIntBytes and peek.tag != .bytes and peek.tag != .smallBytes) {
                    // Only byte string keys can match: skip the key and its value.
                    try self.skipValue();
                    try self.skipValue();
                    continue;
                }
                const key = try self.readBytesSlice();
                const run = pendingKeyRun(queries[0..keyed], key) orelse {
                    try self.skipValue();
                    continue;
                };
                pending -= run.len;
                try self.resolveEntry(run, remaining, depth);
            }

            _ = try self.read();
            for (queries[0..keyed]) |*q| {
                if (!q.resolved) resolveQuery(q, null, remaining);
            }
        }

        /// The unresolved queries whose current segment is the key `key`, found by binary search.
        /// Null if there are none: a run is resolved as a whole by the first entry with its key, as
        /// in `readPath`.
        fn pendingKeyRun(queries: []PathQuery, key: []const u8) ?[]PathQuery {
            var lo: usize = 0;
            var hi: usize = queries.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (std.mem.order(u8, segmentKey(&queries[mid]), key) == .lt) lo = mid + 1 else hi = mid;
            }
            if (lo == queries.len or queries[lo].resolved) return null;
            var end = lo;
            while (end < queries.len and std.mem.eql(u8, segmentKey(&queries[end]), key)) end += 1;
            return if (end == lo) null else queries[lo..end];
        }

        fn segmentKey(query: *const PathQuery) []const u8 {
            return if (path.currentSegment(query)) |seg| seg.key else "";
        }

        fn resolveInArray(self: *Self, queries: []PathQuery, remaining: *usize, depth: usize) Error!void {
            // Keys sort before indices, and a key cannot match in an array.
            var cursor: usize = 0;
            while (cursor < queries.len) : (cursor += 1) {
                const seg = path.currentSegment(&queries[cursor]) orelse break;
                if (seg.is_index) break;
            }
            for (queries[0..cursor]) |*q| resolveQuery(q, null, remaining);

            // Queries are sorted by index; the cursor's index is parsed once per query.
            var cursor_index = indexAt(queries, cursor);
            var idx: usize = 0;
            while (true) {
                if (remaining.* == 0) return;
                const target = cursor_index orelse return self.skipRestOfContainer();

                const peek = try self.peekTag();
                if (peek.tag == .containerEnd) break;
                if (limits.max_array_length) |max| {
                    if (idx >= max) return error.ArrayTooLarge;
                }

                if (idx == target) {
                    const start = cursor;
                    while (cursor_index != null and cursor_index.? == idx) {
                        cursor += 1;
                        cursor_index = indexAt(queries, cursor);
                    }
                    try self.resolveEntry(queries[start..cursor], remaining, depth);
                } else {
                    try self.skipValue();
                }
                idx += 1;
            }

            _ = try self.read();
            for (queries[cursor..]) |*q| resolveQuery(q, null, remaining);
        }

        fn indexAt(queries: []PathQuery, i: usize) ?usize {
            if (i == queries.len) return null;
            return (path.currentSegment(&queries[i]) orelse return null).index;
        }

        /// Reads the value of one container entry and resolves the queries addressing it. Queries
        /// ending at this segment sort first and get the value itself; the rest look inside it.
        fn resolveEntry(self: *Self, run: []PathQuery, remaining: *usize, depth: usize) Error!void {
            const value = try self.read();
            // An object key without a value.
            if (value == .containerEnd) return error.UnexpectedContainerEnd;
            var leaves: usize = 0;
            while (leaves < run.len) : (leaves += 1) {
                const seg = path.currentSegment(&run[leaves]) orelse break;
                if (seg.rest.len != 0) break;
            }
            for (run[0..leaves]) |*q| resolveQuery(q, value, remaining);
            if (remaining.* == 0) return;

            const children = run[leaves..];
            if (children.len == 0) {
                // Nothing looks inside the value: skip its contents.
                if (value == .object or value == .array) try self.skipRestOfContainer();
                return;
            }
            path.descend(children);
            try self.resolveIn(value, children, remaining, depth + 1);
            path.ascend(children, depth);
        }

        /// Skips the remaining entries of the container the reader is in, and its end.
        fn skipRestOfContainer(self: *Self) Error!void {
            while ((try self.peekTag()).tag != .containerEnd) try self.skipValue();
            _ = try self.read();
        }

        /// `segment` is the index of the first segment of `remaining_path` in the whole path.
        fn readPathFromValue(self: *Self, val: common.Value, remaining_path: []const u8, segment: usize) Error!?common.Value {
            // Each segment is a level of recursion: stop at the same limit `path.validate` enforces.
            if (segment >= path.max_segments) return null;
            switch (val) {
                .object => return try self.readPathFromObject(remaining_path, segment),
                .array => return try self.readPathFromArray(remaining_path, segment),
                .typedArray => |ta| return self.readPathFromTypedArray(ta, remaining_path),
                else => return null,
            }
        }

        fn readPathFromObject(self: *Self, remaining_path: []const u8, segment: usize) Error!?common.Value {
            const seg = path.parseSegment(remaining_path) orelse return null;
            if (seg.is_index) return null;

            var kv_count: usize = 0;
            while (true) {
                const peek = try self.peekTag();
                if (peek.tag == .containerEnd) {
                    _ = try self.read();
                    return null;
                }

                if (limits.max_object_size) |max| {
                    if (kv_count >= max) return error.ObjectTooLarge;
                }

                if (peek.tag != .varIntBytes and peek.tag != .bytes and peek.tag != .smallBytes) {
                    try self.skipValue();
                    try self.skipValue();
                    kv_count += 1;
                    continue;
                }

                const key = try self.readBytesSlice();
                if (!std.mem.eql(u8, key, seg.key)) {
                    try self.skipValue();
                    kv_count += 1;
                    continue;
                }

                const child = try self.read();
                if (child == .containerEnd) return error.UnexpectedContainerEnd;
                if (seg.rest.len == 0) return child;
                return try self.readPathFromValue(child, seg.rest, segment + 1);
            }
        }

        fn readPathFromArray(self: *Self, remaining_path: []const u8, segment: usize) Error!?common.Value {
            const seg = path.parseSegment(remaining_path) orelse return null;
            if (!seg.is_index) return null;

            var idx: usize = 0;
            while (true) : (idx += 1) {
                const peek = try self.peekTag();
                if (peek.tag == .containerEnd) {
                    _ = try self.read();
                    return null;
                }

                if (limits.max_array_length) |max| {
                    if (idx >= max) return error.ArrayTooLarge;
                }

                if (idx != seg.index) {
                    try self.skipValue();
                    continue;
                }

                const child = try self.read();
                if (child == .containerEnd) return error.UnexpectedContainerEnd;
                if (seg.rest.len == 0) return child;
                return try self.readPathFromValue(child, seg.rest, segment + 1);
            }
        }

        fn readPathFromTypedArray(self: *Self, ta: common.TypedArray, remaining_path: []const u8) ?common.Value {
            _ = self;
            const seg = path.parseSegment(remaining_path) orelse return null;
            if (!seg.is_index or seg.index >= ta.count or seg.rest.len != 0) return null;
            return common.typedArrayElementToValue(ta, seg.index) catch null;
        }

        /// Reads a value at a given path. Path format: "key", "key.nested", "array[0]", "obj.arr[2].name"
        /// Returns null if the path doesn't exist or points to an incompatible type.
        pub fn readPath(self: *Self, path_str: []const u8) Error!?common.Value {
            const saved_pos = self.pos;
            const saved_depth = self.depth;
            const saved_counts = self.iteration_counts;
            defer {
                self.pos = saved_pos;
                self.depth = saved_depth;
                self.iteration_counts = saved_counts;
            }

            self.pos = 0;
            self.depth = 0;
            self.iteration_counts = @splat(0);

            const root_val = try self.read();
            if (path_str.len == 0) return root_val;

            return try self.readPathFromValue(root_val, path_str, 0);
        }
    };
}
