const std = @import("std");
const data = @import("../data.zig");

const Io = std.Io;

pub const name = "std.json";
pub const format = "JSON";
pub const strategy = "encodes structs directly; decode parses into structs (arena, strings borrowed from the input when possible); access parses the whole document";
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

pub fn encode(state: *State, comptime kind: data.Kind, out: *Io.Writer) !void {
    switch (kind) {
        .person => try std.json.Stringify.value(state.dataset.person, .{}, out),
        .people => try std.json.Stringify.value(state.dataset.people, .{}, out),
        .embedding => try std.json.Stringify.value(state.dataset.embedding, .{}, out),
    }
}

fn Decoded(comptime kind: data.Kind) type {
    return switch (kind) {
        .person => data.Person,
        .people => []const data.Person,
        .embedding => data.Embedding,
    };
}

fn parse(state: *State, comptime kind: data.Kind, bytes: []const u8) !Decoded(kind) {
    _ = state.arena.reset(.retain_capacity);
    return std.json.parseFromSliceLeaky(Decoded(kind), state.arena.allocator(), bytes, .{ .allocate = .alloc_if_needed });
}

pub fn decode(state: *State, comptime kind: data.Kind, bytes: []const u8) !u64 {
    var c: data.Checksum = .{};
    c.value(try parse(state, kind, bytes));
    return c.sum;
}

pub fn access(state: *State, comptime kind: data.Kind, bytes: []const u8) !data.Field {
    const value = try parse(state, kind, bytes);
    return switch (kind) {
        .person => .{ .string = value.address.city },
        .people => .{ .string = value[data.access_index].username },
        .embedding => .{ .float = value.values[data.access_value_index] },
    };
}
