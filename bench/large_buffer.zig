//! Path lookups and updates in a 4 MiB document: how fast bufzilla skips over data it does not need.
//!
//!     zig build bench-large -Doptimize=ReleaseFast -- [--csv] [--quick] [--filter=<text>]

const std = @import("std");
const bufzilla = @import("bufzilla");
const harness = @import("harness.zig");

const Io = std.Io;
const Writer = bufzilla.Writer;
const Reader = bufzilla.Reader(.{});

const target_size = 4 * 1024 * 1024;

/// { "data": { "items": [ ...many items... ],
///             "target_at_end": { "nested": { "value": 42, "secret": "found_it!" } },
///             "final_key": "end" } }
fn buildDocument(allocator: std.mem.Allocator) !struct { []u8, usize } {
    var aw = Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    var w = Writer.init(&aw.writer);

    try w.startObject();
    try w.writeAny("data");
    try w.startObject();
    try w.writeAny("items");
    try w.startArray();
    var item_count: usize = 0;
    while (aw.written().len < target_size - 1024) : (item_count += 1) {
        try w.writeAny(.{
            .id = @as(i64, @intCast(item_count)),
            .name = "This is a sample item with a reasonably long name string",
            .description = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
            .tags = @as([]const []const u8, &.{ "tag1", "tag2", "tag3" }),
            .metadata = .{ .created = @as(i64, 1701792000), .modified = @as(i64, 1701878400) },
        });
    }
    try w.endContainer();
    try w.writeAny("target_at_end");
    try w.writeAny(.{ .nested = .{ .value = @as(i64, 42), .secret = "found_it!" } });
    try w.writeAny("final_key");
    try w.writeAny("end");
    try w.endContainer();
    try w.endContainer();
    return .{ try aw.toOwnedSlice(), item_count };
}

const Lookup = struct {
    data: []const u8,
    path: []const u8,

    fn run(self: *Lookup) !void {
        var r = Reader.init(self.data);
        std.mem.doNotOptimizeAway(try r.readPath(self.path));
    }
};

const Update = struct {
    data: []const u8,
    out: []u8,
    value: i64 = 1234,
    secret: []const u8 = "updated!",
    tail: []const u8 = "new_tail_value",

    fn run(self: *Update) !void {
        var updates = [_]Writer.Update{
            .init("data.target_at_end.nested.value", &self.value),
            .init("data.target_at_end.nested.secret", &self.secret),
            .init("data.added_at_end", &self.tail),
        };
        var fixed = Io.Writer.fixed(self.out);
        var w = Writer.init(&fixed);
        try w.applyUpdates(self.data, &updates);
        std.mem.doNotOptimizeAway(fixed.end);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try harness.Args.parse(init);
    const options = args.options();
    const allocator = init.gpa;

    const data, const item_count = try buildDocument(allocator);
    defer allocator.free(data);
    const out = try allocator.alloc(u8, data.len + 256);
    defer allocator.free(out);

    var middle_buf: [64]u8 = undefined;
    var last_buf: [64]u8 = undefined;
    // `whole` lookups have to read past (nearly) the whole document, so their scan rate is meaningful.
    const lookups = [_]struct { name: []const u8, path: []const u8, found: bool, whole: bool }{
        .{ .name = "first key", .path = "data", .found = true, .whole = false },
        .{ .name = "first item", .path = "data.items[0].id", .found = true, .whole = false },
        .{ .name = "middle item", .path = try std.fmt.bufPrint(&middle_buf, "data.items[{d}].id", .{item_count / 2}), .found = true, .whole = false },
        .{ .name = "last item", .path = try std.fmt.bufPrint(&last_buf, "data.items[{d}].id", .{item_count - 1}), .found = true, .whole = true },
        .{ .name = "key after all items", .path = "data.target_at_end.nested.value", .found = true, .whole = true },
        .{ .name = "last key", .path = "data.final_key", .found = true, .whole = true },
        .{ .name = "missing key (full scan)", .path = "data.nonexistent", .found = false, .whole = true },
    };

    harness.warmUpCpu(init.io);
    if (args.csv) {
        std.debug.print("benchmark,median_ns,min_ns,spread,document_bytes,mib_per_s\n", .{});
    } else {
        std.debug.print("\nreadPath and applyUpdates in a {d:.2} MiB document ({d} items, {s})\n", .{ @as(f64, @floatFromInt(data.len)) / (1024 * 1024), item_count, @tagName(@import("builtin").mode) });
        std.debug.print("scan rate: document size / time, for operations that read past the whole document\n", .{});
        std.debug.print("\n  {s:<40} {s:>11} {s:>14} {s:>8}\n", .{ "", "time/op", "scan rate", "spread" });
    }

    for (lookups) |lookup| {
        if (!args.selected(lookup.name)) continue;
        var reader = Reader.init(data);
        if ((try reader.readPath(lookup.path) != null) != lookup.found) return error.UnexpectedResult;
        var state: Lookup = .{ .data = data, .path = lookup.path };
        const result = try harness.measure(init.io, &state, Lookup.run, options);
        report(args, lookup.name, result, data.len, lookup.whole);
    }

    if (args.selected("applyUpdates")) {
        var state: Update = .{ .data = data, .out = out };
        const result = try harness.measure(init.io, &state, Update.run, options);
        report(args, "applyUpdates (3 updates, whole document)", result, data.len, true);
    }
}

fn report(args: harness.Args, name: []const u8, result: harness.Result, bytes: usize, whole: bool) void {
    const rate = if (whole) result.mibPerSec(bytes) else 0;
    if (args.csv) {
        // The name is quoted: some contain commas.
        std.debug.print("\"{s}\",{d:.2},{d:.2},{d:.3},{d},{d:.1}\n", .{ name, result.median_ns, result.min_ns, result.spread, bytes, rate });
        return;
    }
    var time_buf: [32]u8 = undefined;
    const time = harness.formatTime(&time_buf, result.median_ns);
    if (whole) {
        std.debug.print("  {s:<40} {s:>11} {d:>8.0} MiB/s {d:>7.1}%\n", .{ name, time, rate, result.spread * 100 });
    } else {
        std.debug.print("  {s:<40} {s:>11} {s:>14} {d:>7.1}%\n", .{ name, time, "-", result.spread * 100 });
    }
}
