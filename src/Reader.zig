/// Reader API
const std = @import("std");
const common = @import("common.zig");
const path = @import("path.zig");
const tb = common.tag_bytes;

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

/// A single path query for readPaths.
pub const PathQuery = struct {
    path: []const u8,
    /// Set by `readPaths`: the value at `path`, or null if there is none.
    value: ?common.Value = null,
    /// Internal to `readPaths`.
    resolved: bool = false,
    /// Internal to `readPaths`: the path segment being processed.
    segment: path.Segment = undefined,
};

/// `readPaths` resolves this many queries per pass over the data. Bounds the stack it uses.
pub const read_paths_batch = 256;

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

            // Every byte is its own (inline) case, so this compiles to one 256-entry jump table, as cheap
            // as dispatching on a 5-bit field; ranges would compile to a chain of comparisons.
            switch (tag_byte) {
                inline tb.small_uint.first...tb.small_uint.last => return .{ .u64 = tag_byte - tb.small_uint.first },
                inline tb.small_int_negative.first...tb.small_int_positive.last => return .{ .i64 = @as(i64, tag_byte) - common.small_int_zero },
                inline tb.small_bytes.first...tb.small_bytes.last => {
                    const len: usize = tag_byte - tb.small_bytes.first;
                    if (limits.max_bytes_length) |max| {
                        if (len > max) return error.BytesTooLong;
                    }
                    return .{ .bytes = try self.takeBytes(len) };
                },
                inline tb.varint_unsigned.first...tb.varint_unsigned.last => |b| return .{ .u64 = try self.readVarInt(@truncate(b)) },
                inline tb.varint_positive.first...tb.varint_positive.last => |b| {
                    const magnitude = try self.readVarInt(@truncate(b));
                    if (magnitude > @as(u64, @intCast(std.math.maxInt(i64)))) return error.InvalidSignedMagnitude;
                    return .{ .i64 = @intCast(magnitude) };
                },
                inline tb.varint_negative.first...tb.varint_negative.last => |b| {
                    const magnitude = try self.readVarInt(@truncate(b));
                    if (magnitude == 0) return error.InvalidSignedMagnitude;
                    if (magnitude == (@as(u64, 1) << 63)) return .{ .i64 = std.math.minInt(i64) };
                    if (magnitude > @as(u64, @intCast(std.math.maxInt(i64)))) return error.InvalidSignedMagnitude;
                    return .{ .i64 = -@as(i64, @intCast(magnitude)) };
                },
                inline tb.varint_bytes.first...tb.varint_bytes.last => |b| {
                    const len = try self.readBytesLength(.varIntBytes, @truncate(b));
                    return .{ .bytes = try self.takeBytes(len) };
                },
                inline tb.typed_array.first...tb.typed_array.last => |b| {
                    const hdr = try self.readTypedArrayHeader(@truncate(b));
                    const start = self.pos;
                    self.pos += hdr.payload_len;
                    return .{ .typedArray = .{ .elem = hdr.elem, .count = hdr.count, .bytes = self.bytes[start..][0..hdr.payload_len] } };
                },
                tb.object, tb.array => {
                    if (limits.max_depth) |max| {
                        if (self.depth >= max) return error.MaxDepthExceeded;
                    }
                    self.depth += 1;
                    // Reset iteration counter for this new container
                    if (needs_counters) {
                        self.iteration_counts[self.depth - 1] = 0;
                    }
                    return if (tag_byte == tb.object) .{ .object = self.depth } else .{ .array = self.depth };
                },
                tb.container_end => {
                    if (self.depth == 0) return error.UnexpectedContainerEnd;
                    self.depth -= 1;
                    return .{ .containerEnd = self.depth };
                },
                tb.bytes => {
                    const len = try self.readBytesLength(.bytes, 0);
                    return .{ .bytes = try self.takeBytes(len) };
                },
                tb.u8 => return .{ .u8 = try self.readBytes(u8) },
                tb.u16 => return .{ .u16 = try self.readBytes(u16) },
                tb.u32 => return .{ .u32 = try self.readBytes(u32) },
                tb.u64 => return .{ .u64 = try self.readBytes(u64) },
                tb.i8 => return .{ .i8 = try self.readBytes(i8) },
                tb.i16 => return .{ .i16 = try self.readBytes(i16) },
                tb.i32 => return .{ .i32 = try self.readBytes(i32) },
                tb.i64 => return .{ .i64 = try self.readBytes(i64) },
                tb.f16 => return .{ .f16 = @bitCast(try self.readBytes(u16)) },
                tb.f32 => return .{ .f32 = try self.readBytes(f32) },
                tb.f64 => return .{ .f64 = try self.readBytes(f64) },
                tb.false, tb.true => return .{ .bool = tag_byte == tb.true },
                tb.null => return .{ .null = {} },
                else => return error.InvalidEnumTag,
            }
        }

        /// Takes the next `len` bytes.
        inline fn takeBytes(self: *Self, len: usize) ![]const u8 {
            if (len > self.bytes.len - self.pos) return error.UnexpectedEof;
            const result = self.bytes[self.pos..][0..len];
            self.pos += len;
            return result;
        }

        /// Reads a varint of `size_minus_one + 1` bytes. Varint-sized kinds start at 8-aligned tag bytes,
        /// so callers pass the low 3 bits of the tag byte.
        inline fn readVarInt(self: *Self, size_minus_one: u3) !u64 {
            const size: usize = @as(usize, size_minus_one) + 1;
            if (size > self.bytes.len - self.pos) return error.UnexpectedEof;
            const value = common.decodeVarInt(self.bytes[self.pos..][0..size]);
            self.pos += size;
            return value;
        }

        /// Discards data items until the target depth is reached.
        fn discardUntilDepth(self: *Self, target_depth: u32) !void {
            while (self.depth > target_depth) {
                _ = try self.read();
            }
        }

        /// The next tag byte, without advancing. A reserved byte is an error here, before callers check
        /// container size limits.
        inline fn peekByte(self: *Self) !u8 {
            if (self.pos >= self.bytes.len) return error.UnexpectedEof;
            const byte = self.bytes[self.pos];
            if (tb.isReserved(byte)) return error.InvalidEnumTag;
            return byte;
        }

        /// Reads the length of a varIntBytes or bytes item.
        inline fn readBytesLength(self: *Self, comptime kind: common.Kind, size_minus_one: u3) !usize {
            const len_u64 = switch (kind) {
                .varIntBytes => try self.readVarInt(size_minus_one),
                .bytes => try self.readBytes(u64),
                else => comptime unreachable,
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

        inline fn readTypedArrayHeader(self: *Self, size_minus_one: u3) !TypedArrayHeader {
            const elem_byte = try self.readBytes(u8);
            const elem = std.enums.fromInt(common.TypedArrayElem, elem_byte) orelse return error.InvalidEnumTag;
            const count_u64 = try self.readVarInt(size_minus_one);

            if (count_u64 > std.math.maxInt(usize)) return error.BytesTooLong;
            const count: usize = @intCast(count_u64);

            const payload_len = std.math.mul(usize, count, common.typedArrayElemSize(elem)) catch return error.BytesTooLong;
            if (limits.max_bytes_length) |max| {
                if (payload_len > max) return error.BytesTooLong;
            }
            if (payload_len > self.bytes.len - self.pos) return error.UnexpectedEof;

            return .{ .elem = elem, .count = count, .payload_len = payload_len };
        }

        inline fn skipBytes(self: *Self, len: usize) !void {
            if (len > self.bytes.len - self.pos) return error.UnexpectedEof;
            self.pos += len;
        }

        /// Skips the item that `tag_byte` (already consumed) starts. Callers handle container tags
        /// first, and pass the byte as a comptime value from an `inline else`, so that every byte is a
        /// case of the caller's single jump table.
        inline fn skipScalar(self: *Self, comptime tag_byte: u8) !void {
            switch (tag_byte) {
                tb.small_uint.first...tb.small_uint.last,
                tb.small_int_negative.first...tb.small_int_positive.last,
                tb.false,
                tb.true,
                tb.null,
                => {},
                tb.small_bytes.first...tb.small_bytes.last => {
                    const len: usize = tag_byte - tb.small_bytes.first;
                    if (limits.max_bytes_length) |max| {
                        if (len > max) return error.BytesTooLong;
                    }
                    try self.skipBytes(len);
                },
                tb.varint_unsigned.first...tb.varint_negative.last => try self.skipBytes(@as(usize, @as(u3, @truncate(tag_byte))) + 1),
                tb.varint_bytes.first...tb.varint_bytes.last => try self.skipBytes(try self.readBytesLength(.varIntBytes, @truncate(tag_byte))),
                tb.typed_array.first...tb.typed_array.last => {
                    const hdr = try self.readTypedArrayHeader(@truncate(tag_byte));
                    try self.skipBytes(hdr.payload_len);
                },
                tb.bytes => try self.skipBytes(try self.readBytesLength(.bytes, 0)),
                tb.u8, tb.i8 => try self.skipBytes(1),
                tb.u16, tb.i16, tb.f16 => try self.skipBytes(2),
                tb.u32, tb.i32, tb.f32 => try self.skipBytes(4),
                tb.u64, tb.i64, tb.f64 => try self.skipBytes(8),
                tb.array, tb.object, tb.container_end => comptime unreachable,
                else => return error.InvalidEnumTag,
            }
        }

        /// Skips a single value without materializing it.
        pub fn skipValue(self: *Self) !void {
            @setEvalBranchQuota(4000); // for the `inline else` over every byte value
            switch (try self.readBytes(u8)) {
                tb.array, tb.object => {},
                tb.container_end => return error.UnexpectedContainerEnd,
                inline else => |tag_byte| return self.skipScalar(tag_byte),
            }

            if (limits.max_depth) |max| {
                if (self.depth >= max) return error.MaxDepthExceeded;
            }
            var nest_depth: u32 = 1;
            while (nest_depth > 0) {
                switch (try self.readBytes(u8)) {
                    tb.array, tb.object => {
                        if (limits.max_depth) |max| {
                            if (self.depth + nest_depth >= max) return error.MaxDepthExceeded;
                        }
                        nest_depth += 1;
                    },
                    tb.container_end => nest_depth -= 1,
                    inline else => |tag_byte| try self.skipScalar(tag_byte),
                }
            }
        }

        /// Reads a byte string item (smallBytes, varIntBytes or bytes) and returns its contents.
        fn readBytesSlice(self: *Self) ![]const u8 {
            const tag_byte = try self.readBytes(u8);
            // Comparisons rather than a jump table: keys are nearly always short strings, so the
            // first one is predictable.
            const len: usize = if (tag_byte >= tb.small_bytes.first and tag_byte <= tb.small_bytes.last) blk: {
                const l: usize = tag_byte - tb.small_bytes.first;
                if (limits.max_bytes_length) |max| {
                    if (l > max) return error.BytesTooLong;
                }
                break :blk l;
            } else if (tag_byte >= tb.varint_bytes.first and tag_byte <= tb.varint_bytes.last)
                try self.readBytesLength(.varIntBytes, @truncate(tag_byte))
            else if (tag_byte == tb.bytes)
                try self.readBytesLength(.bytes, 0)
            else
                return error.InvalidEnumTag;
            return self.takeBytes(len);
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

        /// Orders query indices by their current segment: keys (by bytes) before indices (by value),
        /// and, for the same key or index, queries ending at this segment before those looking deeper.
        fn lessThanBySegment(queries: []const PathQuery, lhs: u16, rhs: u16) bool {
            const a = &queries[lhs].segment;
            const b = &queries[rhs].segment;
            if (a.is_index != b.is_index) return !a.is_index;
            if (a.is_index) {
                if (a.index != b.index) return a.index < b.index;
            } else switch (std.mem.order(u8, a.key, b.key)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            return a.rest.len == 0 and b.rest.len != 0;
        }

        /// Reads multiple paths from the buffer in a single pass (per `read_paths_batch` queries).
        /// Each query's `value` is set to what `readPath` would return for its path: the found Value,
        /// or null if the path does not exist or is malformed. Queries are not reordered.
        /// Like `readPath`, this does not move the reader, even on error.
        /// On error, query values are unspecified.
        pub fn readPaths(self: *Self, queries: []PathQuery) Error!void {
            if (queries.len == 0) return;
            if (queries.len == 1) {
                queries[0].value = try self.readPath(queries[0].path);
                queries[0].resolved = true;
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

            var start: usize = 0;
            while (start < queries.len) : (start += read_paths_batch) {
                try self.readPathsBatch(queries[start..@min(start + read_paths_batch, queries.len)]);
            }
        }

        fn readPathsBatch(self: *Self, queries: []PathQuery) Error!void {
            std.debug.assert(queries.len <= read_paths_batch);
            self.pos = 0;
            self.depth = 0;
            self.iteration_counts = @splat(0);

            // The traversal works on indices of the queries, which are cheap to sort and leave the
            // caller's queries in place. Empty paths (the root) are resolved directly.
            var order_buf: [read_paths_batch]u16 = undefined;
            var count: usize = 0;
            var remaining: usize = 0;
            for (queries, 0..) |*q, i| {
                q.value = null;
                q.resolved = !path.validate(q.path);
                if (q.resolved) continue;
                remaining += 1;
                if (q.path.len == 0) continue;
                q.segment = path.parseSegment(q.path) orelse unreachable; // validated
                order_buf[count] = @intCast(i);
                count += 1;
            }

            // Read even if every path is malformed: `readPath` reads the root first, too.
            const root = try self.read();
            for (queries) |*q| {
                if (!q.resolved and q.path.len == 0) resolveQuery(q, root, &remaining);
            }
            try self.resolveIn(root, queries, order_buf[0..count], &remaining, 0);
        }

        // Path queries are resolved in one pass over the data. Each query caches the segment of its
        // path being processed. At each container, the queries addressing its contents are a slice
        // of indices, sorted by that segment: object entries find theirs by binary search, array
        // elements by a cursor. A container's scan stops once its own queries are resolved, so it
        // reads exactly as far as `readPath` would for the furthest of them.

        fn resolveQuery(query: *PathQuery, value: ?common.Value, remaining: *usize) void {
            query.value = value;
            query.resolved = true;
            remaining.* -= 1;
        }

        fn resolveAll(queries: []PathQuery, order: []const u16, value: ?common.Value, remaining: *usize) void {
            for (order) |i| {
                if (!queries[i].resolved) resolveQuery(&queries[i], value, remaining);
            }
        }

        /// Resolves the queries `order` refers to, whose current segments (at path depth `depth`)
        /// address the contents of `value`, which was just read. Unless no queries remain at all,
        /// this leaves the reader after `value`.
        fn resolveIn(self: *Self, value: common.Value, queries: []PathQuery, order: []u16, remaining: *usize, depth: usize) Error!void {
            switch (value) {
                .object, .array => {
                    std.sort.pdq(u16, order, @as([]const PathQuery, queries), lessThanBySegment);
                    if (value == .object) {
                        try self.resolveInObject(queries, order, remaining, depth);
                    } else {
                        try self.resolveInArray(queries, order, remaining, depth);
                    }
                },
                .typedArray => |ta| for (order) |i| resolveQuery(&queries[i], typedArrayElementAt(ta, queries[i].segment), remaining),
                else => resolveAll(queries, order, null, remaining),
            }
        }

        fn typedArrayElementAt(ta: common.TypedArray, seg: path.Segment) ?common.Value {
            if (!seg.is_index or seg.index >= ta.count or seg.rest.len != 0) return null;
            return common.typedArrayElementToValue(ta, seg.index) catch null;
        }

        fn resolveInObject(self: *Self, queries: []PathQuery, order: []u16, remaining: *usize, depth: usize) Error!void {
            // Keys sort before indices, and an index cannot match in an object.
            var keyed: usize = 0;
            while (keyed < order.len and !queries[order[keyed]].segment.is_index) keyed += 1;
            resolveAll(queries, order[keyed..], null, remaining);

            var pending = keyed;
            var entries: usize = 0;
            while (true) {
                if (remaining.* == 0) return;
                if (pending == 0) return self.skipRestOfContainer();

                const peek = try self.peekByte();
                if (peek == tb.container_end) break;
                if (limits.max_object_size) |max| {
                    if (entries >= max) return error.ObjectTooLarge;
                }
                entries += 1;

                if (!tb.isBytes(peek)) {
                    // Only byte string keys can match: skip the key and its value.
                    try self.skipValue();
                    try self.skipValue();
                    continue;
                }
                const key = try self.readBytesSlice();
                const run = pendingKeyRun(queries, order[0..keyed], key) orelse {
                    try self.skipValue();
                    continue;
                };
                pending -= run.len;
                try self.resolveEntry(queries, run, remaining, depth);
            }

            _ = try self.read();
            resolveAll(queries, order[0..keyed], null, remaining);
        }

        /// The unresolved queries whose current segment is the key `key`, found by binary search.
        /// Null if there are none: a run is resolved as a whole by the first entry with its key, as
        /// in `readPath`.
        fn pendingKeyRun(queries: []const PathQuery, order: []u16, key: []const u8) ?[]u16 {
            var lo: usize = 0;
            var hi: usize = order.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (std.mem.order(u8, queries[order[mid]].segment.key, key) == .lt) lo = mid + 1 else hi = mid;
            }
            if (lo == order.len or queries[order[lo]].resolved) return null;
            var end = lo;
            while (end < order.len and std.mem.eql(u8, queries[order[end]].segment.key, key)) end += 1;
            return if (end == lo) null else order[lo..end];
        }

        fn resolveInArray(self: *Self, queries: []PathQuery, order: []u16, remaining: *usize, depth: usize) Error!void {
            // Keys sort before indices, and a key cannot match in an array.
            var cursor: usize = 0;
            while (cursor < order.len and !queries[order[cursor]].segment.is_index) cursor += 1;
            resolveAll(queries, order[0..cursor], null, remaining);

            var idx: usize = 0;
            while (true) {
                if (remaining.* == 0) return;
                if (cursor == order.len) return self.skipRestOfContainer();
                const target = queries[order[cursor]].segment.index;

                if (try self.peekByte() == tb.container_end) break;
                if (limits.max_array_length) |max| {
                    if (idx >= max) return error.ArrayTooLarge;
                }

                if (idx == target) {
                    const start = cursor;
                    while (cursor < order.len and queries[order[cursor]].segment.index == idx) cursor += 1;
                    try self.resolveEntry(queries, order[start..cursor], remaining, depth);
                } else {
                    try self.skipValue();
                }
                idx += 1;
            }

            _ = try self.read();
            resolveAll(queries, order[cursor..], null, remaining);
        }

        /// Reads the value of one container entry and resolves the queries addressing it. Queries
        /// ending at this segment sort first and get the value itself; the rest look inside it.
        fn resolveEntry(self: *Self, queries: []PathQuery, run: []u16, remaining: *usize, depth: usize) Error!void {
            const value = try self.read();
            // An object key without a value.
            if (value == .containerEnd) return error.UnexpectedContainerEnd;
            var leaves: usize = 0;
            while (leaves < run.len and queries[run[leaves]].segment.rest.len == 0) leaves += 1;
            for (run[0..leaves]) |i| resolveQuery(&queries[i], value, remaining);
            if (remaining.* == 0) return;

            const children = run[leaves..];
            if (children.len == 0) {
                // Nothing looks inside the value: skip its contents.
                if (value == .object or value == .array) try self.skipRestOfContainer();
                return;
            }
            for (children) |i| {
                const q = &queries[i];
                q.segment = path.parseSegment(q.segment.rest) orelse unreachable; // validated
            }
            try self.resolveIn(value, queries, children, remaining, depth + 1);
            // This level's binary search still compares these queries' segments at `depth`.
            for (children) |i| segmentAtDepth(&queries[i], depth);
        }

        /// Sets the query's current segment to the one at `depth` in its path.
        fn segmentAtDepth(query: *PathQuery, depth: usize) void {
            var seg = path.parseSegment(query.path) orelse unreachable; // validated
            for (0..depth) |_| seg = path.parseSegment(seg.rest) orelse unreachable;
            query.segment = seg;
        }

        /// Skips the remaining entries of the container the reader is in, and its end.
        fn skipRestOfContainer(self: *Self) Error!void {
            while (try self.peekByte() != tb.container_end) try self.skipValue();
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
                const peek = try self.peekByte();
                if (peek == tb.container_end) {
                    _ = try self.read();
                    return null;
                }

                if (limits.max_object_size) |max| {
                    if (kv_count >= max) return error.ObjectTooLarge;
                }

                if (!tb.isBytes(peek)) {
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
                if (try self.peekByte() == tb.container_end) {
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
