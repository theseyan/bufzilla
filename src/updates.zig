const std = @import("std");
const common = @import("common.zig");
const reader_mod = @import("Reader.zig");
const path = @import("path.zig");
const Io = std.Io;

pub const Error = error{
    /// Root value is not an object
    InvalidRoot,
    /// Path string is malformed
    MalformedPath,
    /// Path expects object vs array that doesn't match data
    PathTypeMismatch,
    /// Two updates conflict on the same prefix
    ConflictingUpdates,
    /// Array index update is negative or too large for existing array (when not upserting)
    IndexOutOfRange,
    /// An update to a typed array element is not a number that fits the element type
    TypeMismatch,
};

/// Limits applied to the output produced by updates.
pub const Limits = struct {
    /// Maximum number of elements in arrays created or extended by update paths.
    /// Does not limit existing arrays that are not extended or replacement values.
    /// Guards against unbounded output amplification from hostile paths.
    /// Set to null for unlimited (only when paths are trusted).
    max_array_length: ?usize = 1 << 20,
};

const ReadError = reader_mod.Error;

fn peekTagType(reader: anytype, buf: []const u8) ReadError!std.meta.Tag(common.Value) {
    if (reader.pos >= buf.len) return ReadError.UnexpectedEof;
    const decoded = common.decodeTag(buf[reader.pos]);
    return std.enums.fromInt(std.meta.Tag(common.Value), decoded.tag) orelse ReadError.InvalidEnumTag;
}

// =============================================================================
// Traversal state
//
// Updates are sorted by path segments, so at every container level the updates addressing one key
// or index form a contiguous run. Each update's `offset` marks the start of its segment at the
// level being processed: it moves down when a run descends into a child container and back up when
// the run returns (`path.descend` / `path.ascend`), so finding an update's current segment never
// re-parses the start of its path.
// =============================================================================

fn segmentOf(upd: anytype) Error!path.Segment {
    return path.currentSegment(upd) orelse Error.MalformedPath;
}

/// The updates addressing one key or index of a container: `updates[start..end]`.
const Run = struct {
    start: usize,
    end: usize,
    /// The last pending update that replaces the entry itself; it wins over earlier ones.
    leaf_last: ?usize = null,
    /// The first pending update that addresses a descendant of the entry. Updates replacing an
    /// entry sort before those addressing its descendants, so `updates[child_first..end]` are
    /// all descendants.
    child_first: ?usize = null,
};

fn classifyRun(updates: anytype, start: usize, end: usize) Error!Run {
    var run: Run = .{ .start = start, .end = end };
    for (updates[start..end], start..) |*upd, i| {
        if (upd.applied) continue;
        if ((try segmentOf(upd)).rest.len == 0) {
            run.leaf_last = i;
        } else if (run.child_first == null) {
            run.child_first = i;
        }
    }
    if (run.leaf_last != null and run.child_first != null) return Error.ConflictingUpdates;
    return run;
}

/// Writes the winning leaf update of `run` and marks the whole run applied.
fn writeLeaf(comptime WriterT: type, writer: *WriterT, updates: anytype, run: Run) WriterT.Error!void {
    for (updates[run.start..run.end]) |*upd| upd.applied = true;
    const upd = &updates[run.leaf_last.?];
    try upd.writeFn(writer, upd.ctx);
}

// =============================================================================
// Typed array elements
// =============================================================================

/// Decodes an update's value by encoding it into a small buffer. Typed array elements are numbers,
/// which encode in at most 9 bytes, so a value that does not fit is not a number.
fn decodeUpdateValue(comptime WriterT: type, upd: anytype) Error!common.Value {
    var tmp_buf: [16]u8 = undefined;
    var fixed = Io.Writer.fixed(&tmp_buf);
    var tmp_writer = WriterT.init(&fixed);
    upd.writeFn(&tmp_writer, upd.ctx) catch return Error.TypeMismatch;
    var r = reader_mod.Reader(.{}).init(fixed.buffered());
    return r.read() catch Error.TypeMismatch;
}

/// Converts an update value to a typed array element: any integer encoding that fits an integer
/// element, and any float that does not overflow a float element (it may be rounded).
fn elementValue(comptime T: type, value: common.Value) Error!T {
    switch (@typeInfo(T)) {
        .int => return std.math.cast(T, common.integerValue(value) orelse return Error.TypeMismatch) orelse Error.TypeMismatch,
        .float => {
            const wide: f64 = switch (value) {
                .f64 => |v| v,
                .f32 => |v| v,
                .f16 => |v| v,
                else => return Error.TypeMismatch,
            };
            const narrow: T = @floatCast(wide);
            if (std.math.isInf(narrow) and !std.math.isInf(wide)) return Error.TypeMismatch;
            return narrow;
        },
        else => comptime unreachable,
    }
}

fn writeTypedArrayElement(comptime WriterT: type, writer: *WriterT, elem: common.TypedArrayElem, value: common.Value) (Error || WriterT.Error)!void {
    switch (elem) {
        inline else => |e| {
            const T = common.TypedArrayElemType(e);
            const element = try elementValue(T, value);
            try writer.raw.writeInt(@Int(.unsigned, @bitSizeOf(T)), @bitCast(element), .little);
        },
    }
}

fn applyTypedArray(comptime WriterT: type, reader: anytype, writer: *WriterT, buf: []const u8, updates: anytype) (Error || ReadError || WriterT.Error)!void {
    const start_pos = reader.pos;
    const ta_val = try reader.read();
    if (ta_val != .typedArray) return ReadError.InvalidEnumTag;

    const payload_start: usize = @intFromPtr(ta_val.typedArray.bytes.ptr) - @intFromPtr(buf.ptr);
    try writer.raw.writeAll(buf[start_pos..payload_start]);

    const elem = ta_val.typedArray.elem;
    const count = ta_val.typedArray.count;
    const payload = ta_val.typedArray.bytes;
    const elem_size = common.typedArrayElemSize(elem);

    var cursor: usize = 0;

    var i: usize = 0;
    while (i < updates.len) {
        const seg_i = try segmentOf(&updates[i]);
        if (!seg_i.is_index) return Error.PathTypeMismatch;
        if (seg_i.rest.len != 0) return Error.PathTypeMismatch;
        const idx = seg_i.index;
        if (idx >= count) return Error.IndexOutOfRange;

        var group_end: usize = i + 1;
        var leaf_last: usize = i;
        while (group_end < updates.len) : (group_end += 1) {
            const seg_g = try segmentOf(&updates[group_end]);
            if (!seg_g.is_index) return Error.PathTypeMismatch;
            if (seg_g.index != idx) break;
            if (seg_g.rest.len != 0) return Error.PathTypeMismatch;
            leaf_last = group_end;
        }

        for (updates[i..group_end]) |*upd| {
            upd.applied = true;
        }

        const off = idx * elem_size;
        try writer.raw.writeAll(payload[cursor..off]);

        const decoded_val = try decodeUpdateValue(WriterT, &updates[leaf_last]);
        try writeTypedArrayElement(WriterT, writer, elem, decoded_val);

        cursor = off + elem_size;
        i = group_end;
    }

    try writer.raw.writeAll(payload[cursor..]);
}

// =============================================================================
// Applying updates to existing data
// =============================================================================

pub fn applyUpdates(comptime WriterT: type, writer: *WriterT, encoded_buf: []const u8, updates: anytype, limits: Limits) (Error || ReadError || WriterT.Error)!void {
    const UpdatesT = @TypeOf(updates);
    const UpdateT = switch (@typeInfo(UpdatesT)) {
        .pointer => |p| p.child,
        else => @compileError("applyUpdates expects a mutable slice of updates"),
    };

    for (updates) |*u| {
        u.applied = false;
        u.offset = 0;
    }

    if (updates.len == 0) {
        try writer.raw.writeAll(encoded_buf);
        return;
    }

    for (updates) |u| {
        if (!path.validate(u.path)) return Error.MalformedPath;
    }

    // Sorting groups updates by container level, so each level finds its updates in contiguous runs.
    // The sort is stable so that, of several updates to the same path, the last one wins.
    const Less = struct {
        fn lt(_: void, lhs: UpdateT, rhs: UpdateT) bool {
            return path.lessThanPathSegments(lhs.path, rhs.path);
        }
    };
    // For few updates, insertion sort (also stable) avoids the block sort's large buffer.
    if (updates.len <= 16) {
        std.sort.insertion(UpdateT, updates, {}, Less.lt);
    } else {
        std.mem.sort(UpdateT, updates, {}, Less.lt);
    }

    // Root replacements (empty paths) sort first. They replace the whole document, so they cannot be
    // combined with other updates; of several, the last wins.
    var root_count: usize = 0;
    while (root_count < updates.len and updates[root_count].path.len == 0) root_count += 1;
    if (root_count > 0) {
        if (root_count != updates.len) return Error.ConflictingUpdates;
        var reader = reader_mod.Reader(.{}).init(encoded_buf);
        try reader.skipValue();
        for (updates) |*u| u.applied = true;
        const upd = &updates[updates.len - 1];
        try upd.writeFn(writer, upd.ctx);
        return;
    }

    // Root must be object
    var reader = reader_mod.Reader(.{}).init(encoded_buf);
    const root_tag = try peekTagType(&reader, encoded_buf);
    if (root_tag != .object) return Error.InvalidRoot;

    const open_start = reader.pos;
    _ = try reader.read();
    try writer.raw.writeAll(encoded_buf[open_start..reader.pos]);

    try applyObject(WriterT, &reader, writer, encoded_buf, updates, 0, limits);
}

/// Emits one existing container entry (the reader is positioned at its value) with the updates of
/// `run` applied. `depth` is the level of the container holding the entry.
fn applyRun(comptime WriterT: type, reader: anytype, writer: *WriterT, buf: []const u8, updates: anytype, depth: usize, limits: Limits, run: Run) (Error || ReadError || WriterT.Error)!void {
    if (run.leaf_last != null) {
        try writeLeaf(WriterT, writer, updates, run);
        try reader.skipValue();
        return;
    }

    const child_first = run.child_first orelse {
        // Nothing pending for this entry: copy its encoding through unchanged.
        const val_start = reader.pos;
        try reader.skipValue();
        try writer.raw.writeAll(buf[val_start..reader.pos]);
        return;
    };

    // Only descendants are updated: descend into the existing container.
    const child_updates = updates[child_first..run.end];
    const val_tag = try peekTagType(reader, buf);
    switch (val_tag) {
        .object, .array, .typedArray => {},
        else => return Error.PathTypeMismatch,
    }

    path.descend(child_updates);
    switch (val_tag) {
        .typedArray => try applyTypedArray(WriterT, reader, writer, buf, child_updates),
        .object, .array => {
            const open_start = reader.pos;
            _ = try reader.read();
            try writer.raw.writeAll(buf[open_start..reader.pos]);
            if (val_tag == .object) {
                try applyObject(WriterT, reader, writer, buf, child_updates, depth + 1, limits);
            } else {
                try applyArray(WriterT, reader, writer, buf, child_updates, depth + 1, limits);
            }
        },
        else => unreachable,
    }
    path.ascend(child_updates, depth);
}

/// Finds the run of updates whose current segment is the object key `key`, by binary search.
/// Returns null if there is none or it has already been applied (runs are applied as a whole, so
/// a later occurrence of a duplicate key is skipped without rescanning the run).
/// Every update at this level must address a key.
fn pendingKeyRun(updates: anytype, key: []const u8) Error!?struct { usize, usize } {
    var lo: usize = 0;
    var hi: usize = updates.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, (try segmentOf(&updates[mid])).key, key) == .lt) lo = mid + 1 else hi = mid;
    }
    if (lo == updates.len or updates[lo].applied) return null;
    var end = lo;
    while (end < updates.len and std.mem.eql(u8, (try segmentOf(&updates[end])).key, key)) end += 1;
    if (end == lo) return null;
    return .{ lo, end };
}

fn applyObject(comptime WriterT: type, reader: anytype, writer: *WriterT, buf: []const u8, updates: anytype, depth: usize, limits: Limits) (Error || ReadError || WriterT.Error)!void {
    for (updates) |*upd| {
        if (!upd.applied and (try segmentOf(upd)).is_index) return Error.PathTypeMismatch;
    }

    while (true) {
        const tag = try peekTagType(reader, buf);
        if (tag == .containerEnd) {
            try emitObjectFromUpdates(WriterT, writer, updates, depth, limits);
            _ = try reader.read();
            try writer.endContainer();
            break;
        }

        const key_start = reader.pos;
        const key_val = try reader.read();
        const key = switch (key_val) {
            .bytes => key_val.bytes,
            .varIntBytes => key_val.varIntBytes,
            .smallBytes => key_val.smallBytes,
            else => return ReadError.InvalidEnumTag,
        };
        try writer.raw.writeAll(buf[key_start..reader.pos]);

        const run: Run = if (try pendingKeyRun(updates, key)) |bounds|
            try classifyRun(updates, bounds[0], bounds[1])
        else
            .{ .start = 0, .end = 0 };
        try applyRun(WriterT, reader, writer, buf, updates, depth, limits, run);
    }
}

fn applyArray(comptime WriterT: type, reader: anytype, writer: *WriterT, buf: []const u8, updates: anytype, depth: usize, limits: Limits) (Error || ReadError || WriterT.Error)!void {
    for (updates) |*upd| {
        if (!upd.applied and !(try segmentOf(upd)).is_index) return Error.PathTypeMismatch;
    }

    // Updates are sorted by index, so one cursor walks them alongside the elements. The index the
    // cursor's update addresses is parsed once per update, not once per element.
    var cursor: usize = 0;
    var cursor_index: ?usize = if (updates.len > 0) (try segmentOf(&updates[0])).index else null;
    var idx: usize = 0;
    while (true) {
        const tag = try peekTagType(reader, buf);
        if (tag == .containerEnd) {
            try emitArrayFromUpdates(WriterT, writer, updates[cursor..], depth, idx, limits);
            _ = try reader.read();
            try writer.endContainer();
            break;
        }

        const start = cursor;
        while (cursor_index != null and cursor_index.? == idx) {
            cursor += 1;
            cursor_index = if (cursor < updates.len) (try segmentOf(&updates[cursor])).index else null;
        }
        try applyRun(WriterT, reader, writer, buf, updates, depth, limits, try classifyRun(updates, start, cursor));
        idx += 1;
    }
}

// =============================================================================
// Creating missing entries
// =============================================================================

fn emitObjectFromUpdates(comptime WriterT: type, writer: *WriterT, updates: anytype, depth: usize, limits: Limits) (Error || ReadError || WriterT.Error)!void {
    var i: usize = 0;
    while (i < updates.len) {
        if (updates[i].applied) {
            i += 1;
            continue;
        }

        const seg_i = try segmentOf(&updates[i]);
        if (seg_i.is_index) return Error.PathTypeMismatch;
        const key = seg_i.key;

        // The group must stop exactly at the next key, applied updates included: it is passed down
        // to deeper levels, which expect every update in it to share this key.
        var group_end: usize = i + 1;
        while (group_end < updates.len) : (group_end += 1) {
            const seg_g = try segmentOf(&updates[group_end]);
            if (seg_g.is_index) return Error.PathTypeMismatch;
            if (!std.mem.eql(u8, seg_g.key, key)) break;
        }

        const run = try classifyRun(updates, i, group_end);
        try writer.writeAny(key);
        if (run.leaf_last != null) {
            try writeLeaf(WriterT, writer, updates, run);
        } else {
            const child_updates = updates[run.child_first.?..run.end];
            path.descend(child_updates);
            try emitContainerFromUpdates(WriterT, writer, child_updates, depth + 1, limits);
            path.ascend(child_updates, depth);
        }

        i = group_end;
    }
}

fn emitContainerFromUpdates(comptime WriterT: type, writer: *WriterT, updates: anytype, depth: usize, limits: Limits) (Error || ReadError || WriterT.Error)!void {
    if (updates.len == 0) return;
    const first_seg = try segmentOf(&updates[0]);

    if (first_seg.is_index) {
        try writer.startArray();
        try emitArrayFromUpdates(WriterT, writer, updates, depth, 0, limits);
        try writer.endContainer();
    } else {
        try writer.startObject();
        try emitObjectFromUpdates(WriterT, writer, updates, depth, limits);
        try writer.endContainer();
    }
}

fn emitArrayFromUpdates(comptime WriterT: type, writer: *WriterT, updates: anytype, depth: usize, start_index: usize, limits: Limits) (Error || ReadError || WriterT.Error)!void {
    var max_index: ?usize = null;
    for (updates) |*upd| {
        if (upd.applied) continue;
        const seg = try segmentOf(upd);
        if (!seg.is_index) return Error.PathTypeMismatch;
        max_index = @max(max_index orelse seg.index, seg.index);
    }
    const last_index = max_index orelse return;

    // Reject extensions that would produce an array larger than the limit.
    // Checked before writing padding, so hostile paths (e.g. arr[18446744073709551615])
    // fail fast instead of amplifying the output.
    if (limits.max_array_length) |max| {
        if (last_index >= max) return ReadError.ArrayTooLarge;
    }

    // Updates are sorted by index: walk them once, padding gaps with nulls.
    var idx = start_index;
    var cursor: usize = 0;
    while (cursor < updates.len) {
        if (updates[cursor].applied) {
            cursor += 1;
            continue;
        }
        const target = (try segmentOf(&updates[cursor])).index;
        std.debug.assert(target >= idx);
        while (idx < target) : (idx += 1) try writer.writeAny(null);

        const start = cursor;
        while (cursor < updates.len and (try segmentOf(&updates[cursor])).index == target) cursor += 1;
        const run = try classifyRun(updates, start, cursor);
        if (run.leaf_last != null) {
            try writeLeaf(WriterT, writer, updates, run);
        } else {
            const child_updates = updates[run.child_first.?..run.end];
            path.descend(child_updates);
            try emitContainerFromUpdates(WriterT, writer, child_updates, depth + 1, limits);
            path.ascend(child_updates, depth);
        }

        // Guard against usize wraparound when limits are disabled (max_array_length = null)
        // and an update targets the maximum possible index.
        if (target == std.math.maxInt(usize)) break;
        idx = target + 1;
    }
}
