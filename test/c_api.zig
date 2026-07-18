const std = @import("std");
const c = @import("bufzilla_c");

fn bytes(slice: []const u8) c.BufzillaBytes {
    return .{ .ptr = slice.ptr, .len = slice.len };
}

fn mutBytes(slice: []u8) c.BufzillaMutableBytes {
    return .{ .ptr = slice.ptr, .len = slice.len };
}

test "c api: write read path inspect and updates" {
    var out: [512]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_init(&writer, mutBytes(&out)))));

    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_start_object(&writer))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_write_value(&writer, .{
        .tag = @intFromEnum(c.BufzillaValueTag.small_bytes),
        .data = .{ .bytes = bytes("name") },
    }))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_write_value(&writer, .{
        .tag = @intFromEnum(c.BufzillaValueTag.var_int_signed_positive),
        .data = .{ .i64_value = 42 },
    }))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_end_container(&writer))));

    const encoded = out[0..c.bufzilla_writer_written(&writer)];

    var reader: c.BufzillaReader = undefined;
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_reader_init(&reader, bytes(encoded)))));

    var found: u8 = 0;
    var value: c.BufzillaValue = undefined;
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_reader_read_path(&reader, bytes("name"), &value, &found))));
    try std.testing.expectEqual(@as(u8, 1), found);
    try std.testing.expectEqual(c.BufzillaValueTag.i64_value, @as(c.BufzillaValueTag, @enumFromInt(value.tag)));
    try std.testing.expectEqual(@as(i64, 42), value.data.i64_value);

    var json: [128]u8 = undefined;
    var json_len: usize = 0;
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_inspect(bytes(encoded), mutBytes(&json), null, &json_len))));
    try std.testing.expect(std.mem.indexOf(u8, json[0..json_len], "\"name\"") != null);

    var updated_out: [512]u8 = undefined;
    var scratch: [128]u8 align(8) = undefined;
    var updated_len: usize = 0;
    const updates = [_]c.BufzillaUpdate{.{
        .path = bytes("name"),
        .value = .{
            .tag = @intFromEnum(c.BufzillaValueTag.var_int_signed_positive),
            .data = .{ .i64_value = 99 },
        },
    }};
    try std.testing.expect(c.bufzilla_apply_updates_scratch_len(updates.len) <= scratch.len);
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_apply_updates(
        bytes(encoded),
        &updates,
        updates.len,
        @ptrCast(&scratch),
        scratch.len,
        mutBytes(&updated_out),
        &updated_len,
    ))));

    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_reader_init(&reader, bytes(updated_out[0..updated_len])))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_reader_read_path(&reader, bytes("name"), &value, &found))));
    try std.testing.expectEqual(@as(i64, 99), value.data.i64_value);
}

test "c api: read paths and typed arrays" {
    const numbers = [_]u16{ 10, 20, 30 };
    var out: [128]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_init(&writer, mutBytes(&out)))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_start_object(&writer))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_write_value(&writer, .{
        .tag = @intFromEnum(c.BufzillaValueTag.small_bytes),
        .data = .{ .bytes = bytes("nums") },
    }))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_write_typed_array(&writer, .{
        .elem = @intFromEnum(c.BufzillaTypedArrayElem.u16_value),
        .count = numbers.len,
        .bytes = bytes(std.mem.sliceAsBytes(&numbers)),
    }))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_writer_end_container(&writer))));

    const encoded = out[0..c.bufzilla_writer_written(&writer)];
    var reader: c.BufzillaReader = undefined;
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_reader_init(&reader, bytes(encoded)))));

    var queries = [_]c.BufzillaPathQuery{
        .{ .path = bytes("nums[1]"), .value = undefined, .found = 0, .resolved = 0 },
    };
    var scratch: [128]u8 align(8) = undefined;
    try std.testing.expect(c.bufzilla_reader_read_paths_scratch_len(queries.len) <= scratch.len);
    try std.testing.expectEqual(c.BufzillaStatus.buffer_too_small, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_reader_read_paths(&reader, &queries, queries.len, @ptrCast(&scratch), 0))));

    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_reader_init(&reader, bytes(encoded)))));
    try std.testing.expectEqual(c.BufzillaStatus.ok, @as(c.BufzillaStatus, @enumFromInt(c.bufzilla_reader_read_paths(&reader, &queries, queries.len, @ptrCast(&scratch), scratch.len))));
    try std.testing.expectEqual(@as(u8, 1), queries[0].found);
    try std.testing.expectEqual(c.BufzillaValueTag.u16_value, @as(c.BufzillaValueTag, @enumFromInt(queries[0].value.tag)));
    try std.testing.expectEqual(@as(u16, 20), queries[0].value.data.u16_value);
}
