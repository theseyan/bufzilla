/// Large Buffer Benchmark for readPath
/// Tests readPath performance with random reads from a large encoded buffer
const std = @import("std");
const bufzilla = @import("bufzilla");
const Io = std.Io;

const Writer = bufzilla.Writer;
const Reader = bufzilla.Reader;

const TARGET_SIZE: usize = 4 * 1024 * 1024; // 4 MiB

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("=" ** 80 ++ "\n", .{});
    std.debug.print("Large Buffer readPath Benchmark\n", .{});
    std.debug.print("=" ** 80 ++ "\n\n", .{});

    // Generate large buffer
    std.debug.print("Generating large encoded buffer...\n", .{});

    var aw = Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    var writer = Writer.init(&aw.writer);

    // Structure: { "data": { "items": [...many items...], "target_at_end": { "nested": { "value": 42 } } } }
    try writer.startObject();
    try writer.writeAny("data");
    try writer.startObject();

    // Add many items to make buffer large
    try writer.writeAny("items");
    try writer.startArray();

    var item_count: usize = 0;
    while (aw.written().len < TARGET_SIZE - 1024) {
        try writer.startObject();

        try writer.writeAny("id");
        try writer.writeAny(@as(i64, @intCast(item_count)));

        try writer.writeAny("name");
        try writer.writeAny("This is a sample item with a reasonably long name string");

        try writer.writeAny("description");
        try writer.writeAny("Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.");

        try writer.writeAny("tags");
        try writer.startArray();
        try writer.writeAny("tag1");
        try writer.writeAny("tag2");
        try writer.writeAny("tag3");
        try writer.endContainer();

        try writer.writeAny("metadata");
        try writer.startObject();
        try writer.writeAny("created");
        try writer.writeAny(@as(i64, 1701792000));
        try writer.writeAny("modified");
        try writer.writeAny(@as(i64, 1701878400));
        try writer.endContainer();

        try writer.endContainer();
        item_count += 1;
    }
    try writer.endContainer(); // close items array

    // Add target at the end
    try writer.writeAny("target_at_end");
    try writer.startObject();
    try writer.writeAny("nested");
    try writer.startObject();
    try writer.writeAny("value");
    try writer.writeAny(@as(i64, 42));
    try writer.writeAny("secret");
    try writer.writeAny("found_it!");
    try writer.endContainer();
    try writer.endContainer();

    // Add one more key after target
    try writer.writeAny("final_key");
    try writer.writeAny("end");

    try writer.endContainer(); // close data
    try writer.endContainer(); // close root

    const encoded = aw.written();
    const buffer_size_mb = @as(f64, @floatFromInt(encoded.len)) / (1024.0 * 1024.0);

    std.debug.print("Buffer size: {d:.2} MiB ({} bytes)\n", .{ buffer_size_mb, encoded.len });
    std.debug.print("Total items: {}\n\n", .{item_count});

    // Benchmark different readPath scenarios
    std.debug.print("Benchmarks:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});

    const iterations = 1000;

    // Access key at start of buffer
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath("data", .{});
            std.debug.assert(result != null);
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("Access start (data):                     {d:8} ns/op\n", .{avg_ns});
    }

    // Access first item in array
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath("data.items[0].id", .{});
            std.debug.assert(result != null);
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("Access first item (data.items[0].id):    {d:8} ns/op\n", .{avg_ns});
    }

    // Access middle of array
    {
        const middle_idx = item_count / 2;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "data.items[{d}].id", .{middle_idx}) catch unreachable;

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath(path, .{});
            std.debug.assert(result != null);
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("Access middle item ({s}): {d:8} ns/op\n", .{ path, avg_ns });
    }

    // Access end of array
    {
        const last_idx = item_count - 1;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "data.items[{d}].id", .{last_idx}) catch unreachable;

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath(path, .{});
            std.debug.assert(result != null);
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("Access last item ({s}):  {d:8} ns/op\n", .{ path, avg_ns });
    }

    // Access target at end of buffer (after all items)
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath("data.target_at_end.nested.value", .{});
            std.debug.assert(result != null);
            std.debug.assert(result.?.i64 == 42);
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("Access END of buffer (target_at_end):    {d:8} ns/op\n", .{avg_ns});
    }

    // Access nested key at end
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath("data.target_at_end.nested.secret", .{});
            std.debug.assert(result != null);
            std.debug.assert(std.mem.eql(u8, result.?.bytes, "found_it!"));
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("Access END nested secret:                {d:8} ns/op\n", .{avg_ns});
    }

    // Access final_key
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath("data.final_key", .{});
            std.debug.assert(result != null);
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("Access literal last key (final_key):     {d:8} ns/op\n", .{avg_ns});
    }

    // Non-existent key (full scan)
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath("data.nonexistent", .{});
            std.debug.assert(result == null);
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("Non-existent key (full scan):            {d:8} ns/op\n", .{avg_ns});
    }

    // Benchmark with preserve_state = false
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            const result = try reader.readPath("data.target_at_end.nested.value", .{ .preserve_state = false });
            std.debug.assert(result != null);
        }
        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / iterations;
        std.debug.print("END access (preserve_state=false):       {d:8} ns/op\n", .{avg_ns});
    }

    // applyUpdates over the whole buffer
    {
        var new_value: i64 = 1234;
        var new_secret: []const u8 = "updated!";
        var new_key: []const u8 = "new_tail_value";

        var updates = [_]Writer.Update{
            Writer.Update.init("data.target_at_end.nested.value", &new_value),
            Writer.Update.init("data.target_at_end.nested.secret", &new_secret),
            Writer.Update.init("data.added_at_end", &new_key),
        };

        const out_storage = try allocator.alloc(u8, encoded.len + 256);
        defer allocator.free(out_storage);

        const update_iterations: usize = 200;

        var timer = try std.time.Timer.start();
        for (0..update_iterations) |_| {
            var out_fixed = Io.Writer.fixed(out_storage);
            var out_writer = Writer.init(&out_fixed);
            try out_writer.applyUpdates(encoded, updates[0..]);
            const out_len = out_fixed.buffered().len;
            std.mem.doNotOptimizeAway(out_len);
        }

        const elapsed_ns = timer.read();
        const avg_ns = elapsed_ns / update_iterations;
        std.debug.print("applyUpdates (3 patches, full scan):     {d:8} ns/op\n", .{avg_ns});
    }

    std.debug.print("\n", .{});
    std.debug.print("=" ** 80 ++ "\n", .{});

    // Calculate throughput
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var reader = Reader(.{}).init(encoded);
            _ = try reader.readPath("data.target_at_end.nested.value", .{});
        }
        const elapsed_ns = timer.read();
        const total_bytes_scanned = encoded.len * iterations;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const throughput_mib = @as(f64, @floatFromInt(total_bytes_scanned)) / (1024.0 * 1024.0) / elapsed_sec;

        std.debug.print("Throughput scanning to end: {d:.2} MiB/s\n", .{throughput_mib});
    }

    std.debug.print("=" ** 80 ++ "\n", .{});
}
