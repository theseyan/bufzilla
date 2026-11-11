const std = @import("std");
const pb = @import("protobuf");
const data = @import("../data.zig");

const Io = std.Io;
const fd = pb.fd;

pub const name = "zig-protobuf";
pub const format = "Protobuf";
pub const strategy = "schema-based: field numbers instead of names on the wire; encodes message structs (built beforehand, not timed); decode builds messages (arena); access walks fields lazily with StreamDecoder";
pub const reports_encode = true;

// The messages protoc-gen-zig would generate for:
//   message Address { string street = 1; string city = 2; string zip = 3; string country = 4; }
//   message Person { uint64 id = 1; string username = 2; string email = 3; uint32 age = 4;
//     double balance = 5; bool verified = 6; repeated string tags = 7; Address address = 8;
//     repeated int64 scores = 9; }
//   message People { repeated Person people = 1; }
//   message Embedding { uint64 id = 1; string model = 2; repeated float values = 3; }

const Address = struct {
    street: []const u8 = &.{},
    city: []const u8 = &.{},
    zip: []const u8 = &.{},
    country: []const u8 = &.{},

    pub const _desc_table = .{
        .street = fd(1, .{ .scalar = .string }),
        .city = fd(2, .{ .scalar = .string }),
        .zip = fd(3, .{ .scalar = .string }),
        .country = fd(4, .{ .scalar = .string }),
    };
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pb.deinit(allocator, self);
    }
};

const Person = struct {
    id: u64 = 0,
    username: []const u8 = &.{},
    email: []const u8 = &.{},
    age: u32 = 0,
    balance: f64 = 0,
    verified: bool = false,
    tags: std.ArrayList([]const u8) = .empty,
    address: ?Address = null,
    scores: std.ArrayList(i64) = .empty,

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .username = fd(2, .{ .scalar = .string }),
        .email = fd(3, .{ .scalar = .string }),
        .age = fd(4, .{ .scalar = .uint32 }),
        .balance = fd(5, .{ .scalar = .double }),
        .verified = fd(6, .{ .scalar = .bool }),
        .tags = fd(7, .{ .repeated = .{ .scalar = .string } }),
        .address = fd(8, .submessage),
        .scores = fd(9, .{ .packed_repeated = .{ .scalar = .int64 } }),
    };
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pb.deinit(allocator, self);
    }
};

const People = struct {
    people: std.ArrayList(Person) = .empty,

    pub const _desc_table = .{
        .people = fd(1, .{ .repeated = .submessage }),
    };
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pb.deinit(allocator, self);
    }
};

const Embedding = struct {
    id: u64 = 0,
    model: []const u8 = &.{},
    values: std.ArrayList(f32) = .empty,

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .model = fd(2, .{ .scalar = .string }),
        .values = fd(3, .{ .packed_repeated = .{ .scalar = .float } }),
    };
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        pb.deinit(allocator, self);
    }
};

/// zig-protobuf 7.0.0's StreamDecoder cannot be instantiated for a message with a repeated string
/// field (a comptime assertion in its packed-field dispatch), so access streams through a view of
/// Person with only the fields it reads. Decoders skip fields they do not know, as protobuf
/// requires, so the view reads the same bytes.
const PersonView = struct {
    username: []const u8 = &.{},
    address: ?Address = null,

    pub const _desc_table = .{
        .username = fd(2, .{ .scalar = .string }),
        .address = fd(8, .submessage),
    };
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    /// The library's data model, built once from the dataset.
    models: std.heap.ArenaAllocator,
    person: Person,
    people: People,
    embedding: Embedding,

    pub fn init(gpa: std.mem.Allocator, dataset: *const data.Data) !State {
        var models: std.heap.ArenaAllocator = .init(gpa);
        errdefer models.deinit();
        const a = models.allocator();
        // Build everything before copying `models` into the result, so the copy owns the allocations.
        const person = try toPerson(a, dataset.person);
        var people: People = .{};
        for (dataset.people) |p| try people.people.append(a, try toPerson(a, p));
        var embedding: Embedding = .{ .id = dataset.embedding.id, .model = dataset.embedding.model };
        try embedding.values.appendSlice(a, dataset.embedding.values);
        return .{ .arena = .init(gpa), .models = models, .person = person, .people = people, .embedding = embedding };
    }

    pub fn deinit(state: *State) void {
        state.arena.deinit();
        state.models.deinit();
    }
};

fn toPerson(a: std.mem.Allocator, p: data.Person) !Person {
    var result: Person = .{
        .id = p.id,
        .username = p.username,
        .email = p.email,
        .age = p.age,
        .balance = p.balance,
        .verified = p.verified,
        .address = .{ .street = p.address.street, .city = p.address.city, .zip = p.address.zip, .country = p.address.country },
    };
    try result.tags.appendSlice(a, p.tags);
    try result.scores.appendSlice(a, p.scores);
    return result;
}

pub fn encode(state: *State, comptime kind: data.Kind, out: *Io.Writer) !void {
    _ = state.arena.reset(.retain_capacity);
    const a = state.arena.allocator();
    switch (kind) {
        .person => try pb.encode(out, a, state.person),
        .people => try pb.encode(out, a, state.people),
        .embedding => try pb.encode(out, a, state.embedding),
    }
}

fn Message(comptime kind: data.Kind) type {
    return switch (kind) {
        .person => Person,
        .people => People,
        .embedding => Embedding,
    };
}

pub fn decode(state: *State, comptime kind: data.Kind, bytes: []const u8) !u64 {
    _ = state.arena.reset(.retain_capacity);
    var reader = Io.Reader.fixed(bytes);
    const message = try pb.decode(Message(kind), &reader, state.arena.allocator());
    var c: data.Checksum = .{};
    c.value(message);
    return c.sum;
}

pub fn access(state: *State, comptime kind: data.Kind, bytes: []const u8) !data.Field {
    _ = state.arena.reset(.retain_capacity);
    const a = state.arena.allocator();
    var reader = Io.Reader.fixed(bytes);
    switch (kind) {
        .person => {
            var sd = pb.StreamDecoder(PersonView).init(&reader);
            while (try sd.next()) |event| if (event == .address) return .{ .string = try city(a, event.address) };
        },
        .people => {
            var sd = pb.StreamDecoder(People).init(&reader);
            var index: usize = 0;
            while (try sd.next()) |event| {
                if (event != .people) continue;
                if (index == data.access_index) {
                    var person = pb.StreamDecoder(PersonView).init(event.people);
                    while (try person.next()) |field| if (field == .username) return .{ .string = try field.username.allocRemaining(a, .unlimited) };
                }
                index += 1;
            }
        },
        .embedding => {
            var sd = pb.StreamDecoder(Embedding).init(&reader);
            var index: usize = 0;
            while (try sd.next()) |event| {
                if (event != .values) continue;
                if (index == data.access_value_index) return .{ .float = event.values };
                index += 1;
            }
        },
    }
    return error.NotFound;
}

fn city(a: std.mem.Allocator, address: *Io.Reader) ![]const u8 {
    var sd = pb.StreamDecoder(Address).init(address);
    while (try sd.next()) |field| if (field == .city) return field.city.allocRemaining(a, .unlimited);
    return error.NotFound;
}
