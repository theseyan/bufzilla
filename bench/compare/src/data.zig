//! The datasets every library encodes, and the checksum that proves a decode read all of it.

const std = @import("std");

pub const Address = struct {
    street: []const u8,
    city: []const u8,
    zip: []const u8,
    country: []const u8,
};

pub const Person = struct {
    id: u64,
    username: []const u8,
    email: []const u8,
    age: u32,
    balance: f64,
    verified: bool,
    tags: []const []const u8,
    address: Address,
    scores: []const i64,
};

pub const Embedding = struct {
    id: u64,
    model: []const u8,
    values: []const f32,
};

pub const Kind = enum {
    /// One record: a small API object.
    person,
    /// 1000 records: a large document.
    people,
    /// 768 floats: a vector embedding.
    embedding,

    pub fn description(kind: Kind) []const u8 {
        return switch (kind) {
            .person => "one record (strings, ints, a float, a nested object, arrays)",
            .people => "1000 records",
            .embedding => "768-float vector embedding",
        };
    }

    /// The field read by the single-field access benchmark.
    pub fn accessPath(kind: Kind) []const u8 {
        return switch (kind) {
            .person => "address.city",
            .people => "[500].username",
            .embedding => "values[700]",
        };
    }
};

pub const people_count = 1000;
pub const embedding_len = 768;
pub const access_index = 500;
pub const access_value_index = 700;

pub const Data = struct {
    person: Person,
    people: []const Person,
    embedding: Embedding,

    /// The value the single-field access benchmark must find.
    pub fn accessed(data: Data, kind: Kind) Field {
        return switch (kind) {
            .person => .{ .string = data.person.address.city },
            .people => .{ .string = data.people[access_index].username },
            .embedding => .{ .float = data.embedding.values[access_value_index] },
        };
    }

    pub fn checksum(data: Data, kind: Kind) u64 {
        var c: Checksum = .{};
        switch (kind) {
            .person => c.value(data.person),
            .people => c.value(data.people),
            .embedding => c.value(data.embedding),
        }
        return c.sum;
    }
};

pub const Field = union(enum) {
    string: []const u8,
    float: f64,

    pub fn eql(a: Field, b: Field) bool {
        return switch (a) {
            .string => |s| b == .string and std.mem.eql(u8, s, b.string),
            .float => |f| b == .float and f == b.float,
        };
    }
};

/// Generates the datasets deterministically.
pub fn generate(arena: std.mem.Allocator) !Data {
    var prng = std.Random.DefaultPrng.init(0xb0f2111a);
    const random = prng.random();

    const people = try arena.alloc(Person, people_count);
    for (people, 0..) |*p, i| p.* = try person(arena, random, i);

    const values = try arena.alloc(f32, embedding_len);
    for (values) |*v| v.* = random.float(f32) * 2 - 1;

    return .{
        .person = .{
            .id = 98765,
            .username = "alice_wonder",
            .email = "alice@example.com",
            .age = 34,
            .balance = 12345.67,
            .verified = true,
            .tags = &.{ "admin", "beta", "early-adopter" },
            .address = .{ .street = "221B Baker Street", .city = "London", .zip = "NW1 6XE", .country = "UK" },
            .scores = &.{ 100, 95, 87, 92, 78 },
        },
        .people = people,
        .embedding = .{ .id = 42, .model = "text-embedding-3-small", .values = values },
    };
}

const tag_pool = [_][]const u8{ "admin", "beta", "early-adopter", "moderator", "verified", "premium", "staff" };
const street_pool = [_][]const u8{ "221B Baker Street", "742 Evergreen Terrace", "1600 Pennsylvania Ave", "12 Grimmauld Place" };
const city_pool = [_][]const u8{ "London", "Springfield", "Washington", "Berlin", "Tokyo", "São Paulo" };
const country_pool = [_][]const u8{ "UK", "US", "DE", "JP", "BR" };

fn person(arena: std.mem.Allocator, random: std.Random, i: usize) !Person {
    const tags = try arena.alloc([]const u8, random.uintAtMost(usize, 4));
    for (tags) |*t| t.* = tag_pool[random.uintLessThan(usize, tag_pool.len)];
    const scores = try arena.alloc(i64, random.uintAtMost(usize, 8));
    for (scores) |*s| s.* = random.intRangeAtMost(i64, -1000, 100_000);
    return .{
        .id = 1_000_000 + i,
        .username = try std.fmt.allocPrint(arena, "user_{d}", .{i}),
        .email = try std.fmt.allocPrint(arena, "user_{d}@example.com", .{i}),
        .age = random.intRangeAtMost(u32, 18, 90),
        .balance = @as(f64, @floatFromInt(random.intRangeAtMost(i64, -100_000, 10_000_000))) / 100,
        .verified = random.boolean(),
        .tags = tags,
        .address = .{
            .street = street_pool[random.uintLessThan(usize, street_pool.len)],
            .city = city_pool[random.uintLessThan(usize, city_pool.len)],
            .zip = try std.fmt.allocPrint(arena, "{d:0>5}", .{random.uintLessThan(u32, 100_000)}),
            .country = country_pool[random.uintLessThan(usize, country_pool.len)],
        },
        .scores = scores,
    };
}

/// An order-independent digest of every value in a document (object keys excluded): each value is
/// mixed separately and the results are added, so maps that reorder fields still match. Every
/// decode benchmark computes it from what it decoded, which both proves the decode is complete and
/// makes "read every field" part of the measured work. Strings contribute their length and first
/// and last bytes, so the cost of the checksum itself stays small.
pub const Checksum = struct {
    sum: u64 = 0,

    fn mix(x: u64) u64 {
        var z = x +% 0x9e3779b97f4a7c15;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    pub fn int(c: *Checksum, v: anytype) void {
        const wide: i128 = v;
        c.sum +%= mix(@truncate(@as(u128, @bitCast(wide))));
    }

    /// Floats are mixed as f64, so an f32 decoded as f64 (or the reverse) matches.
    pub fn float(c: *Checksum, v: anytype) void {
        c.sum +%= mix(@bitCast(@as(f64, v)));
    }

    pub fn boolean(c: *Checksum, v: bool) void {
        c.sum +%= mix(@as(u64, @intFromBool(v)) + 2);
    }

    pub fn string(c: *Checksum, s: []const u8) void {
        const first: u64 = if (s.len > 0) s[0] else 0;
        const last: u64 = if (s.len > 0) s[s.len - 1] else 0;
        c.sum +%= mix(s.len ^ (first << 32) ^ (last << 40));
    }

    /// Digests a Zig value: structs, slices, optionals, `std.ArrayList`s, and scalars.
    pub fn value(c: *Checksum, v: anytype) void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .int, .comptime_int => c.int(v),
            .float => c.float(v),
            .bool => c.boolean(v),
            .optional => if (v) |inner| c.value(inner),
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    c.string(v);
                } else if (p.size == .slice) {
                    for (v) |item| c.value(item);
                } else {
                    c.value(v.*);
                }
            },
            .@"struct" => |s| {
                if (@hasField(T, "items") and @hasField(T, "capacity")) {
                    // std.ArrayList
                    for (v.items) |item| c.value(item);
                    return;
                }
                inline for (s.field_names) |name| c.value(@field(v, name));
            },
            else => @compileError("unsupported type " ++ @typeName(T)),
        }
    }
};
