const std = @import("std");
const common = @import("common.zig");
const reader_mod = @import("Reader.zig");
const path = @import("path.zig");

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
};

const ReadError = reader_mod.Error;

fn peekTagType(reader: anytype, buf: []const u8) ReadError!std.meta.Tag(common.Value) {
    if (reader.pos >= buf.len) return ReadError.UnexpectedEof;
    const decoded = common.decodeTag(buf[reader.pos]);
    return std.meta.intToEnum(std.meta.Tag(common.Value), decoded.tag);
}

pub fn applyUpdates(comptime WriterT: type, writer: *WriterT, encoded_buf: []const u8, updates: anytype) (Error || ReadError || WriterT.Error)!void {
    const UpdatesT = @TypeOf(updates);
    const UpdateT = switch (@typeInfo(UpdatesT)) {
        .pointer => |p| p.child,
        else => @compileError("applyUpdates expects a mutable slice of updates"),
    };

    for (updates) |*u| {
        u.applied = false;
    }

    if (updates.len == 0) {
        try writer.raw.writeAll(encoded_buf);
        return;
    }

    for (updates) |u| {
        if (!path.validate(u.path)) return Error.MalformedPath;
    }

    const Less = struct {
        fn lt(_: void, lhs: UpdateT, rhs: UpdateT) bool {
            return path.lessThanPathSegments(lhs.path, rhs.path);
        }
    };
    std.sort.pdq(UpdateT, updates, {}, Less.lt);

    // Root replacement update
    var root_update_idx: ?usize = null;
    for (updates, 0..) |u, i| {
        if (u.path.len == 0) {
            root_update_idx = i;
            break;
        }
    }
    if (root_update_idx != null) {
        if (updates.len != 1) return Error.ConflictingUpdates;
        var reader = reader_mod.Reader(.{}).init(encoded_buf);
        try reader.skipValue();
        const upd = &updates[root_update_idx.?];
        try upd.writeFn(writer, upd.ctx);
        upd.applied = true;
        return;
    }

    // Root must be object
    var reader = reader_mod.Reader(.{}).init(encoded_buf);
    const root_tag = try peekTagType(&reader, encoded_buf);
    if (root_tag != .object) return Error.InvalidRoot;

    const open_start = reader.pos;
    _ = try reader.read();
    try writer.raw.writeAll(encoded_buf[open_start..reader.pos]);

    try applyObject(WriterT, &reader, writer, encoded_buf, updates, 0);
}

fn applyObject(comptime WriterT: type, reader: anytype, writer: *WriterT, buf: []const u8, updates: anytype, depth: usize) (Error || ReadError || WriterT.Error)!void {
    while (true) {
        const tag = try peekTagType(reader, buf);
        if (tag == .containerEnd) {
            try emitObjectFromUpdates(WriterT, writer, updates, depth);
            _ = try reader.read();
            try writer.endContainer();
            break;
        }

        const key_start = reader.pos;
        const key_val = try reader.read();
        if (key_val != .bytes) return ReadError.InvalidEnumTag;
        const key_raw = buf[key_start..reader.pos];
        const key = key_val.bytes;

        var match_start: ?usize = null;
        var match_end: usize = 0;
        var leaf_last: ?usize = null;
        var child_start: ?usize = null;

        for (updates, 0..) |*upd, i| {
            if (upd.applied) continue;
            const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
            if (seg.is_index) return Error.PathTypeMismatch;
            if (std.mem.eql(u8, seg.key, key)) {
                if (match_start == null) match_start = i;
                match_end = i + 1;
                if (seg.rest.len == 0) {
                    leaf_last = i;
                } else if (child_start == null) {
                    child_start = i;
                }
            }
        }

        try writer.raw.writeAll(key_raw);

        if (match_start == null) {
            const val_start = reader.pos;
            try reader.skipValue();
            try writer.raw.writeAll(buf[val_start..reader.pos]);
            continue;
        }

        if (leaf_last != null and child_start != null) return Error.ConflictingUpdates;

        if (leaf_last != null) {
            // Apply last leaf update, mark all leaf updates applied
            for (updates[match_start.?..match_end]) |*upd| {
                if (upd.applied) continue;
                const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
                if (!seg.is_index and std.mem.eql(u8, seg.key, key) and seg.rest.len == 0) {
                    upd.applied = true;
                }
            }
            const upd = &updates[leaf_last.?];
            try upd.writeFn(writer, upd.ctx);
            try reader.skipValue();
            continue;
        }

        // Child updates only
        const val_tag = try peekTagType(reader, buf);
        if (val_tag != .object and val_tag != .array) return Error.PathTypeMismatch;

        const open_start = reader.pos;
        const open_val = try reader.read();
        try writer.raw.writeAll(buf[open_start..reader.pos]);

        const child_updates = updates[child_start.?..match_end];
        if (open_val == .object) {
            try applyObject(WriterT, reader, writer, buf, child_updates, depth + 1);
        } else {
            try applyArray(WriterT, reader, writer, buf, child_updates, depth + 1);
        }
    }
}

fn applyArray(comptime WriterT: type, reader: anytype, writer: *WriterT, buf: []const u8, updates: anytype, depth: usize) (Error || ReadError || WriterT.Error)!void {
    var idx: usize = 0;

    while (true) {
        const tag = try peekTagType(reader, buf);
        if (tag == .containerEnd) {
            try emitArrayFromUpdates(WriterT, writer, updates, depth, idx);
            _ = try reader.read();
            try writer.endContainer();
            break;
        }

        var match_start: ?usize = null;
        var match_end: usize = 0;
        var leaf_last: ?usize = null;
        var child_start: ?usize = null;

        for (updates, 0..) |*upd, i| {
            if (upd.applied) continue;
            const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
            if (!seg.is_index) return Error.PathTypeMismatch;
            if (seg.index == idx) {
                if (match_start == null) match_start = i;
                match_end = i + 1;
                if (seg.rest.len == 0) {
                    leaf_last = i;
                } else if (child_start == null) {
                    child_start = i;
                }
            }
        }

        if (match_start == null) {
            const val_start = reader.pos;
            try reader.skipValue();
            try writer.raw.writeAll(buf[val_start..reader.pos]);
        } else {
            if (leaf_last != null and child_start != null) return Error.ConflictingUpdates;

            if (leaf_last != null) {
                for (updates[match_start.?..match_end]) |*upd| {
                    if (upd.applied) continue;
                    const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
                    if (seg.is_index and seg.index == idx and seg.rest.len == 0) {
                        upd.applied = true;
                    }
                }
                const upd = &updates[leaf_last.?];
                try upd.writeFn(writer, upd.ctx);
                try reader.skipValue();
            } else {
                const val_tag = try peekTagType(reader, buf);
                if (val_tag != .object and val_tag != .array) return Error.PathTypeMismatch;

                const open_start = reader.pos;
                const open_val = try reader.read();
                try writer.raw.writeAll(buf[open_start..reader.pos]);

                const child_updates = updates[child_start.?..match_end];
                if (open_val == .object) {
                    try applyObject(WriterT, reader, writer, buf, child_updates, depth + 1);
                } else {
                    try applyArray(WriterT, reader, writer, buf, child_updates, depth + 1);
                }
            }
        }

        idx += 1;
    }
}

fn emitObjectFromUpdates(comptime WriterT: type, writer: *WriterT, updates: anytype, depth: usize) (Error || ReadError || WriterT.Error)!void {
    var i: usize = 0;
    while (i < updates.len) {
        if (updates[i].applied) {
            i += 1;
            continue;
        }

        const seg_i = path.segmentAtDepth(updates[i].path, depth) orelse return Error.MalformedPath;
        if (seg_i.is_index) return Error.PathTypeMismatch;
        const key = seg_i.key;

        var group_end: usize = i + 1;
        while (group_end < updates.len) : (group_end += 1) {
            if (updates[group_end].applied) continue;
            const seg_g = path.segmentAtDepth(updates[group_end].path, depth) orelse return Error.MalformedPath;
            if (seg_g.is_index) return Error.PathTypeMismatch;
            if (!std.mem.eql(u8, seg_g.key, key)) break;
        }

        const group = updates[i..group_end];

        var leaf_last: ?usize = null;
        var child_first: ?usize = null;
        for (group, 0..) |*upd, gi| {
            if (upd.applied) continue;
            const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
            if (seg.rest.len == 0) {
                leaf_last = gi;
            } else if (child_first == null) {
                child_first = gi;
            }
        }

        if (leaf_last != null and child_first != null) return Error.ConflictingUpdates;

        try writer.writeAny(key);

        if (leaf_last != null) {
            for (group) |*upd| {
                if (upd.applied) continue;
                const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
                if (seg.rest.len == 0) upd.applied = true;
            }
            const upd = &group[leaf_last.?];
            try upd.writeFn(writer, upd.ctx);
        } else if (child_first != null) {
            try emitContainerFromUpdates(WriterT, writer, group[child_first.?..], depth + 1);
        }

        i = group_end;
    }
}

fn emitContainerFromUpdates(comptime WriterT: type, writer: *WriterT, updates: anytype, depth: usize) (Error || ReadError || WriterT.Error)!void {
    if (updates.len == 0) return;
    const first_seg = path.segmentAtDepth(updates[0].path, depth) orelse return Error.MalformedPath;

    if (first_seg.is_index) {
        try writer.startArray();
        try emitArrayFromUpdates(WriterT, writer, updates, depth, 0);
        try writer.endContainer();
    } else {
        try writer.startObject();
        try emitObjectFromUpdates(WriterT, writer, updates, depth);
        try writer.endContainer();
    }
}

fn emitArrayFromUpdates(comptime WriterT: type, writer: *WriterT, updates: anytype, depth: usize, start_index: usize) (Error || ReadError || WriterT.Error)!void {
    var max_index: usize = start_index;
    var any_unapplied = false;

    for (updates) |*upd| {
        if (upd.applied) continue;
        const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
        if (!seg.is_index) return Error.PathTypeMismatch;
        any_unapplied = true;
        if (seg.index > max_index) max_index = seg.index;
    }

    if (!any_unapplied) return;

    var idx: usize = start_index;
    while (idx <= max_index) : (idx += 1) {
        var match_start: ?usize = null;
        var match_end: usize = 0;
        var leaf_last: ?usize = null;
        var child_first: ?usize = null;

        for (updates, 0..) |*upd, i| {
            if (upd.applied) continue;
            const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
            if (!seg.is_index) return Error.PathTypeMismatch;
            if (seg.index == idx) {
                if (match_start == null) match_start = i;
                match_end = i + 1;
                if (seg.rest.len == 0) {
                    leaf_last = i;
                } else if (child_first == null) {
                    child_first = i;
                }
            }
        }

        if (match_start == null) {
            try writer.writeAny(null);
            continue;
        }

        if (leaf_last != null and child_first != null) return Error.ConflictingUpdates;

        const group = updates[match_start.?..match_end];
        if (leaf_last != null) {
            for (group) |*upd| {
                if (upd.applied) continue;
                const seg = path.segmentAtDepth(upd.path, depth) orelse return Error.MalformedPath;
                if (seg.is_index and seg.index == idx and seg.rest.len == 0) upd.applied = true;
            }
            const upd = &updates[leaf_last.?];
            try upd.writeFn(writer, upd.ctx);
        } else if (child_first != null) {
            try emitContainerFromUpdates(WriterT, writer, updates[child_first.?..match_end], depth + 1);
        } else {
            try writer.writeAny(null);
        }
    }
}
