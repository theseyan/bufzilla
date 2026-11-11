const std = @import("std");
const zbor = @import("zbor");
const data = @import("../data.zig");

const Io = std.Io;

pub const name = "zbor";
pub const format = "CBOR";
pub const strategy = "encodes structs directly (strings as text strings); decode parses into structs (arena); access navigates DataItems lazily";
pub const reports_encode = true;

pub const State = struct {
    dataset: *const data.Data,
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, dataset: *const data.Data) !State {
        return .{ .dataset = dataset, .arena = .init(gpa) };
    }

    pub fn deinit(state: *State) void {
        state.arena.deinit();
    }
};

const options: zbor.Options = .{ .slice_serialization_type = .TextString };

pub fn encode(state: *State, comptime kind: data.Kind, out: *Io.Writer) !void {
    switch (kind) {
        .person => try zbor.stringify(state.dataset.person, options, out),
        .people => try zbor.stringify(state.dataset.people, options, out),
        .embedding => try zbor.stringify(state.dataset.embedding, options, out),
    }
}

fn Decoded(comptime kind: data.Kind) type {
    return switch (kind) {
        .person => data.Person,
        .people => []const data.Person,
        .embedding => data.Embedding,
    };
}

pub fn decode(state: *State, comptime kind: data.Kind, bytes: []const u8) !u64 {
    _ = state.arena.reset(.retain_capacity);
    const item = try zbor.DataItem.new(bytes);
    const value = try zbor.parse(Decoded(kind), item, .{ .allocator = state.arena.allocator() });
    var c: data.Checksum = .{};
    c.value(value);
    return c.sum;
}

fn get(item: zbor.DataItem, key: []const u8) !zbor.DataItem {
    var it = item.map() orelse return error.NotAMap;
    while (it.next()) |pair| {
        if (std.mem.eql(u8, pair.key.string() orelse continue, key)) return pair.value;
    }
    return error.NotFound;
}

fn at(item: zbor.DataItem, index: usize) !zbor.DataItem {
    var it = item.array() orelse return error.NotAnArray;
    for (0..index) |_| _ = it.next() orelse return error.NotFound;
    return it.next() orelse error.NotFound;
}

pub fn access(_: *State, comptime kind: data.Kind, bytes: []const u8) !data.Field {
    const root = try zbor.DataItem.new(bytes);
    return switch (kind) {
        .person => .{ .string = (try get(try get(root, "address"), "city")).string() orelse return error.NotAString },
        .people => .{ .string = (try get(try at(root, data.access_index), "username")).string() orelse return error.NotAString },
        .embedding => .{ .float = (try at(try get(root, "values"), data.access_value_index)).float() orelse return error.NotAFloat },
    };
}
