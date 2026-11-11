const std = @import("std");
const msgpack = @import("msgpack");
const data = @import("../data.zig");

const Io = std.Io;
const Payload = msgpack.Payload;

pub const name = "zig-msgpack";
pub const format = "MessagePack";
pub const strategy = "encodes a Payload tree (built from the structs beforehand, not timed); decode and access both build a Payload tree (arena)";
pub const reports_encode = true;

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    /// The library's data model, built once from the dataset.
    models: std.heap.ArenaAllocator,
    person: Payload,
    people: Payload,
    embedding: Payload,

    pub fn init(gpa: std.mem.Allocator, dataset: *const data.Data) !State {
        var models: std.heap.ArenaAllocator = .init(gpa);
        errdefer models.deinit();
        const a = models.allocator();
        // Build everything before copying `models` into the result, so the copy owns the allocations.
        const person = try toPayload(a, dataset.person);
        const people = try toPayload(a, dataset.people);
        const embedding = try toPayload(a, dataset.embedding);
        return .{ .arena = .init(gpa), .models = models, .person = person, .people = people, .embedding = embedding };
    }

    pub fn deinit(state: *State) void {
        state.arena.deinit();
        state.models.deinit();
    }
};

/// Converts a Zig value to the library's dynamic representation, as an application would.
fn toPayload(a: std.mem.Allocator, v: anytype) !Payload {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .int => |i| if (i.signedness == .signed) Payload.intToPayload(v) else Payload.uintToPayload(v),
        .float => Payload.floatToPayload(v),
        .bool => Payload.boolToPayload(v),
        .pointer => |p| if (p.child == u8) try Payload.strToPayload(v, a) else blk: {
            var arr = try Payload.arrPayload(v.len, a);
            for (v, 0..) |item, i| try arr.setArrElement(i, try toPayload(a, item));
            break :blk arr;
        },
        .@"struct" => |s| blk: {
            var map = Payload.mapPayload(a);
            inline for (s.field_names) |field| try map.mapPut(field, try toPayload(a, @field(v, field)));
            break :blk map;
        },
        else => @compileError("unsupported type " ++ @typeName(T)),
    };
}

pub fn encode(state: *State, comptime kind: data.Kind, out: *Io.Writer) !void {
    const encoder: msgpack.Encoder = .{ .writer = out };
    try encoder.write(switch (kind) {
        .person => state.person,
        .people => state.people,
        .embedding => state.embedding,
    });
}

fn checksum(p: Payload, c: *data.Checksum) void {
    switch (p) {
        .nil => {},
        .bool => |b| c.boolean(b),
        .int => |n| c.int(n),
        .uint => |n| c.int(n),
        .float => |f| c.float(f),
        .str => |s| c.string(s.value()),
        .arr => |items| for (items) |item| checksum(item, c),
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |entry| checksum(entry.value_ptr.*, c);
        },
        else => {},
    }
}

fn read(state: *State, bytes: []const u8) !Payload {
    _ = state.arena.reset(.retain_capacity);
    var reader = Io.Reader.fixed(bytes);
    const decoder: msgpack.Decoder = .{ .reader = &reader };
    return decoder.read(state.arena.allocator());
}

pub fn decode(state: *State, comptime _: data.Kind, bytes: []const u8) !u64 {
    var c: data.Checksum = .{};
    checksum(try read(state, bytes), &c);
    return c.sum;
}

pub fn access(state: *State, comptime kind: data.Kind, bytes: []const u8) !data.Field {
    const root = try read(state, bytes);
    return switch (kind) {
        .person => .{ .string = ((try ((try root.mapGet("address")) orelse return error.NotFound).mapGet("city")) orelse return error.NotFound).str.value() },
        .people => .{ .string = ((try (try root.getArrElement(data.access_index)).mapGet("username")) orelse return error.NotFound).str.value() },
        .embedding => .{ .float = (try ((try root.mapGet("values")) orelse return error.NotFound).getArrElement(data.access_value_index)).float },
    };
}
