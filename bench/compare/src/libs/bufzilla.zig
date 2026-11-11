const std = @import("std");
const builtin = @import("builtin");
const bufzilla = @import("bufzilla");
const data = @import("../data.zig");

const Io = std.Io;
const Writer = bufzilla.Writer;
const Reader = bufzilla.Reader(.{});

pub const name = "bufzilla";
pub const format = "bufzilla";
pub const strategy = "encodes structs directly (floats as a typed array); decode is a zero-copy pass over the encoding; access is a lazy path lookup";
pub const reports_encode = true;

pub const State = struct {
    dataset: *const data.Data,

    pub fn init(gpa: std.mem.Allocator, dataset: *const data.Data) !State {
        _ = gpa;
        return .{ .dataset = dataset };
    }

    pub fn deinit(_: *State) void {}
};

pub fn encode(state: *State, comptime kind: data.Kind, out: *Io.Writer) !void {
    var w = Writer.init(out);
    switch (kind) {
        .person => try w.writeAny(state.dataset.person),
        .people => try w.writeAny(state.dataset.people),
        .embedding => {
            const e = state.dataset.embedding;
            try w.startObject();
            try w.writeAny("id");
            try w.writeAny(e.id);
            try w.writeAny("model");
            try w.writeAny(e.model);
            try w.writeAny("values");
            try w.writeTypedArray(e.values);
            try w.endContainer();
        },
    }
}

fn visit(r: *Reader, v: bufzilla.Value, c: *data.Checksum) !void {
    switch (v) {
        .object => while (try r.iterateObject(v)) |kv| try visit(r, kv.value, c),
        .array => while (try r.iterateArray(v)) |item| try visit(r, item, c),
        .typedArray => |ta| if (comptime builtin.cpu.arch.endian() == .little) {
            // Zero-copy: the payload is little-endian f32s.
            for (try bufzilla.Common.typedArrayAsView(f32, ta)) |f| c.float(f);
        } else {
            var buf: [data.embedding_len]f32 = undefined;
            for (try bufzilla.Common.typedArrayAsSlice(f32, ta, &buf)) |f| c.float(f);
        },
        .bytes => |s| c.string(s),
        .i64 => |n| c.int(n),
        .u64 => |n| c.int(n),
        .f64 => |f| c.float(f),
        .f32 => |f| c.float(f),
        .bool => |b| c.boolean(b),
        .null => {},
        else => return error.UnexpectedValue,
    }
}

pub fn decode(_: *State, comptime _: data.Kind, bytes: []const u8) !u64 {
    var r = Reader.init(bytes);
    var c: data.Checksum = .{};
    try visit(&r, try r.read(), &c);
    return c.sum;
}

pub fn access(_: *State, comptime kind: data.Kind, bytes: []const u8) !data.Field {
    var r = Reader.init(bytes);
    const v = (try r.readPath(kind.accessPath())) orelse return error.NotFound;
    return switch (kind) {
        .person, .people => .{ .string = v.bytes },
        .embedding => .{ .float = v.f32 },
    };
}
