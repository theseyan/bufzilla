/// Reader API

const std = @import("std");
const common = @import("common.zig");

/// A Key-value pair inside an Object.
pub const KeyValuePair = struct {
    key: common.Value,
    value: common.Value,
};

const Reader = @This();

// The underlying byte array.
bytes: []const u8,

// The current position in the byte array.
pos: usize = 0,

// The current traversal depth.
depth: u32 = 0,

/// Initializes the reader.
pub fn init(bytes: []const u8) Reader {
    return Reader{
        .bytes = bytes
    };
}

/// Reads a single data item of given type and advances the position.
fn readBytes(self: *Reader, comptime T: type) !T {
    if (self.pos + @sizeOf(T) > self.bytes.len) return error.UnexpectedEof;

    const bytes = self.bytes[self.pos..(self.pos + @sizeOf(T))];
    self.pos += @sizeOf(T);

    return std.mem.bytesAsValue(T, bytes[0..@sizeOf(T)]).*;
}

/// Reads a single data item from the underlying byte array and advances the position.
pub fn read(self: *Reader) !common.Value {
    const type_byte = try self.readBytes(u8);
    const val_type = try std.meta.intToEnum(common.ValueType, type_byte);

    switch (val_type) {
        .ContainerEnd => {
            self.depth -= 1;
            return .{ .type = .ContainerEnd, .value = .{ .depth = self.depth } };
        },
        .Object, .Array => {
            self.depth += 1;
            return .{ .type = val_type, .value = .{ .depth = self.depth } };
        },
        .f64 => {
            const f = try self.readBytes(f64);
            return .{ .type = .f64, .value = .{ .f64 = f } };
        },
        .f32 => {
            const f = try self.readBytes(f32);
            return .{ .type = .f32, .value = .{ .f32 = f } };
        },
        .i64 => {
            const i = try self.readBytes(i64);
            return .{ .type = .i64, .value = .{ .i64 = i } };
        },
        .i32 => {
            const i = try self.readBytes(i32);
            return .{ .type = .i32, .value = .{ .i32 = i } };
        },
        .i16 => {
            const i = try self.readBytes(i16);
            return .{ .type = .i16, .value = .{ .i16 = i } };
        },
        .i8 => {
            const i = try self.readBytes(i8);
            return .{ .type = .i8, .value = .{ .i8 = i } };
        },
        .u64 => {
            const u = try self.readBytes(u64);
            return .{ .type = .u64, .value = .{ .u64 = u } };
        },
        .u32 => {
            const u = try self.readBytes(u32);
            return .{ .type = .u32, .value = .{ .u32 = u } };
        },
        .u16 => {
            const u = try self.readBytes(u16);
            return .{ .type = .u16, .value = .{ .u16 = u } };
        },
        .u8 => {
            const u = try self.readBytes(u8);
            return .{ .type = .u8, .value = .{ .u8 = u } };
        },
        .Null => {
            return .{ .type = .Null, .value = undefined };
        },
        .Bool => {
            const b = try self.readBytes(u8);
            return .{ .type = .Bool, .value = .{ .bool = (b != 0) } };
        },
        .String => {
            const len = try self.readBytes(usize);
            if (self.pos + len > self.bytes.len) return error.UnexpectedEof;

            const str_ptr = self.pos;
            self.pos += len;
            return .{ .type = .String, .value = .{ .string = self.bytes[str_ptr..(str_ptr + len)] } };
        },
    }
}

/// Discards data items until the target depth is reached.
fn discardUntilDepth(self: *Reader, target_depth: u32) !void {
    while (self.depth > target_depth) {
        _ = try self.read();
    }
}

/// Iterates over the key-value pairs of a given Value Object.
pub fn iterateObject(self: *Reader, obj: common.Value) !?KeyValuePair {
    std.debug.assert(obj.type == .Object);
    try self.discardUntilDepth(obj.value.depth);

    const key = try self.read();
    if (key.type == .ContainerEnd) return null;

    const value = try self.read();
    
    return .{
        .key = key,
        .value = value
    };
}

/// Iterates over the values of a given Value Array.
pub fn iterateArray(self: *Reader, arr: common.Value) !?common.Value {
    std.debug.assert(arr.type == .Array);
    try self.discardUntilDepth(arr.value.depth);

    const value = try self.read();
    if (value.type == .ContainerEnd) return null;

    return value;
}

test "reader" {
    const data = [_]u8{ 14, 5, 123, 0, 0, 0, 0, 0, 0, 0, 11, 1, 0, 11, 0, 0, 0, 0, 0, 0, 0, 104, 97, 104, 97, 104, 97, 32, 98, 111, 121, 121, 15 };

    var timer = try std.time.Timer.start();
    var reader = Reader.init(&data);
    
    std.mem.doNotOptimizeAway(try reader.read());
    std.mem.doNotOptimizeAway(try reader.read());
    std.mem.doNotOptimizeAway(try reader.read());
    std.mem.doNotOptimizeAway(try reader.read());
    std.mem.doNotOptimizeAway(try reader.read());

    std.debug.print("Reader Elapsed: {d} ns\n", .{ timer.read() });

    // std.debug.print("{}\n", .{ try reader.read() });
    // std.debug.print("{}\n", .{ try reader.read() });
    // std.debug.print("{}\n", .{ try reader.read() });
    // std.debug.print("{s}\n", .{ (try reader.read()).value.string });
    // std.debug.print("{}\n", .{ try reader.read() });
}