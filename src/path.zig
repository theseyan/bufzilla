const std = @import("std");

/// A single parsed path segment.
/// - Objects: `is_index=false`, `key` set
/// - Arrays: `is_index=true`, `index` set
pub const Segment = struct {
    is_index: bool,
    index: usize,
    key: []const u8,
    rest: []const u8,
};

/// Parses a single path segment from `path`.
/// Returns null for malformed paths.
pub fn parseSegment(path: []const u8) ?Segment {
    var i: usize = 0;

    // Check for array index or quoted key at start: [N] or ['key'] or ["key"]
    if (path.len > 0 and path[0] == '[') {
        i = 1;

        // Check if it's a quoted key
        if (i < path.len and (path[i] == '\'' or path[i] == '"')) {
            const quote_char = path[i];
            i += 1;
            const key_start = i;

            // Find closing quote
            while (i < path.len and path[i] != quote_char) : (i += 1) {}

            if (i >= path.len) return null;
            const key = path[key_start..i];

            // Skip past quote
            i += 1;

            // Skip past ']' if present
            if (i < path.len and path[i] == ']') {
                i += 1;
            }

            // Skip '.' if present
            if (i < path.len and path[i] == '.') {
                i += 1;
            }

            return .{ .is_index = false, .index = 0, .key = key, .rest = path[i..] };
        }

        // Numeric index
        while (i < path.len and path[i] != ']') : (i += 1) {}
        if (i >= path.len) return null;

        const idx_str = path[1..i];
        const index = std.fmt.parseInt(usize, idx_str, 10) catch return null;

        // Skip past ']'
        i += 1;

        // Skip '.' if present
        if (i < path.len and path[i] == '.') {
            i += 1;
        }

        return .{ .is_index = true, .index = index, .key = "", .rest = path[i..] };
    }

    // Check for quoted key without brackets: 'key' or "key"
    if (path.len > 0 and (path[0] == '\'' or path[0] == '"')) {
        const quote_char = path[0];
        i = 1;
        const key_start = i;

        while (i < path.len and path[i] != quote_char) : (i += 1) {}
        if (i >= path.len) return null;

        const key = path[key_start..i];
        i += 1;

        if (i < path.len and path[i] == '.') {
            i += 1;
        }

        return .{ .is_index = false, .index = 0, .key = key, .rest = path[i..] };
    }

    // Object key: read until '.', '[', or end
    while (i < path.len and path[i] != '.' and path[i] != '[') : (i += 1) {}
    const key = path[0..i];

    // Determine rest
    var rest_start = i;
    if (i < path.len) {
        if (path[i] == '.') {
            rest_start = i + 1;
        }
        // '[' is kept for next segment
    }

    return .{ .is_index = false, .index = 0, .key = key, .rest = path[rest_start..] };
}

pub fn validate(path: []const u8) bool {
    if (path.len == 0) return true;
    var remaining = path;
    while (true) {
        const seg = parseSegment(remaining) orelse return false;
        remaining = seg.rest;
        if (remaining.len == 0) return true;
    }
}

pub fn segmentAtDepth(path: []const u8, depth: usize) ?Segment {
    var remaining = path;
    var d: usize = 0;
    while (true) : (d += 1) {
        const seg = parseSegment(remaining) orelse return null;
        if (d == depth) return seg;
        remaining = seg.rest;
        if (remaining.len == 0) return null;
    }
}

/// Orders full paths by their segments.
/// Keys sort before indices, parents sort before children.
/// Invalid paths sort by raw bytes.
pub fn lessThanPathSegments(a: []const u8, b: []const u8) bool {
    var ra = a;
    var rb = b;

    while (true) {
        const sa_opt = parseSegment(ra);
        const sb_opt = parseSegment(rb);
        if (sa_opt == null or sb_opt == null) {
            return std.mem.order(u8, a, b) == .lt;
        }

        const sa = sa_opt.?;
        const sb = sb_opt.?;

        if (sa.is_index != sb.is_index) {
            return !sa.is_index;
        }

        if (!sa.is_index) {
            const ord = std.mem.order(u8, sa.key, sb.key);
            if (ord != .eq) return ord == .lt;
        } else if (sa.index != sb.index) {
            return sa.index < sb.index;
        }

        if (sa.rest.len == 0 or sb.rest.len == 0) {
            return sa.rest.len == 0 and sb.rest.len != 0;
        }

        ra = sa.rest;
        rb = sb.rest;
    }
}
