//! Tests for the C API, called from Zig.
const std = @import("std");
const bufzilla = @import("bufzilla");
const c = @import("bufzilla_c");

const Io = std.Io;
const Writer = bufzilla.Writer;
const Status = c.BufzillaStatus;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectStatus(expected: Status, code: c_int) !void {
    try expectEqual(expected, std.enums.fromInt(Status, code) orelse return error.UnknownStatus);
}

fn ok(code: c_int) !void {
    try expectStatus(.ok, code);
}

fn bytes(slice: []const u8) c.BufzillaBytes {
    return .{ .ptr = slice.ptr, .len = slice.len };
}

fn mutBytes(slice: []u8) c.BufzillaMutableBytes {
    return .{ .ptr = slice.ptr, .len = slice.len };
}

fn sliceOf(b: c.BufzillaBytes) []const u8 {
    return if (b.len == 0) &.{} else b.ptr.?[0..b.len];
}

fn tagOf(tag: c.ValueTag) c_int {
    return @backingInt(tag);
}

fn elemOf(elem: c.TypedArrayElem) c_int {
    return @backingInt(elem);
}

fn initWriter(writer: *c.BufzillaWriter, buffer: []u8) !void {
    try ok(c.bufzilla_writer_init(writer, mutBytes(buffer)));
}

fn writtenBytes(writer: *const c.BufzillaWriter, buffer: []const u8) []const u8 {
    return buffer[0..c.bufzilla_writer_written(writer)];
}

fn readAt(encoded: []const u8, path: []const u8) !c.BufzillaValue {
    var reader: c.BufzillaReader = undefined;
    try ok(c.bufzilla_reader_init(&reader, bytes(encoded)));
    var value: c.BufzillaValue = undefined;
    var found = false;
    try ok(c.bufzilla_reader_read_path(&reader, bytes(path), &value, &found));
    if (!found) return error.PathNotFound;
    return value;
}

fn intAt(encoded: []const u8, path: []const u8) !i64 {
    const value = try readAt(encoded, path);
    var result: i64 = undefined;
    try ok(c.bufzilla_value_as_int(&value, &result));
    return result;
}

// =============================================================================
// ABI
// =============================================================================

extern fn bufzilla_test_abi_layout(len: *usize) [*]const usize;
extern fn bufzilla_test_abi_statuses(len: *usize) [*]const c_int;
extern fn bufzilla_test_abi_value_tags(len: *usize) [*]const c_int;
extern fn bufzilla_test_abi_typed_array_elems(len: *usize) [*]const c_int;
extern fn bufzilla_test_abi_constants(len: *usize) [*]const usize;

/// The layout the C compiler sees, in the order `test/c_api_abi.c` lists it.
const abi_types = [_]type{
    c.BufzillaBytes,
    c.BufzillaMutableBytes,
    c.BufzillaTypedArray,
    c.BufzillaValuePayload,
    c.BufzillaValue,
    c.BufzillaPathQuery,
    c.BufzillaUpdate,
    c.BufzillaInspectOptions,
    c.BufzillaWriter,
    c.BufzillaReader,
};

fn zigLayout() []const usize {
    comptime var items: []const usize = &.{};
    inline for (abi_types) |T| {
        items = items ++ &[_]usize{ @sizeOf(T), @alignOf(T) };
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (info.field_names) |name| {
                items = items ++ &[_]usize{ @offsetOf(T, name), @sizeOf(@FieldType(T, name)) };
            },
            .@"union" => |info| inline for (info.field_names) |name| {
                items = items ++ &[_]usize{ 0, @sizeOf(@FieldType(T, name)) };
            },
            else => comptime unreachable,
        }
    }
    return items;
}

fn expectEnumMatches(comptime E: type, c_values: [*]const c_int, len: usize) !void {
    const values = comptime std.enums.values(E);
    try expectEqual(values.len, len);
    for (values, c_values[0..len]) |value, c_value| try expectEqual(@as(c_int, @backingInt(value)), c_value);
}

test "c api: ABI types and constants match bufzilla.h" {
    var len: usize = 0;
    const layout = bufzilla_test_abi_layout(&len);
    try expectEqualSlices(usize, comptime zigLayout(), layout[0..len]);

    try expectEnumMatches(Status, bufzilla_test_abi_statuses(&len), len);
    try expectEnumMatches(c.ValueTag, bufzilla_test_abi_value_tags(&len), len);
    try expectEnumMatches(c.TypedArrayElem, bufzilla_test_abi_typed_array_elems(&len), len);

    const constants = bufzilla_test_abi_constants(&len);
    try expectEqualSlices(usize, &.{
        c.sizeof_writer,
        c.sizeof_reader,
        c.bufzilla_version(),
        c.default_max_array_length,
        c.inspect_defaults.indent_size,
        c.inspect_defaults.float_precision,
        bufzilla.Path.max_segments,
    }, constants[0..len]);
}

test "c api: version and status strings" {
    const expected: u32 = @intCast((c.version.major << 16) | (c.version.minor << 8) | c.version.patch);
    try expectEqual(expected, c.bufzilla_version());

    for (std.enums.values(Status)) |s| {
        const text = std.mem.span(c.bufzilla_status_string(@backingInt(s)));
        try expect(text.len > 0);
        try expect(!std.mem.eql(u8, text, "unknown status"));
    }
    try expectEqualStrings("unknown status", std.mem.span(c.bufzilla_status_string(-1)));
    try expectEqualStrings("unknown status", std.mem.span(c.bufzilla_status_string(1000)));
}

// =============================================================================
// Writer
// =============================================================================

test "c api: writer encodes like writeAny" {
    var out: [128]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    try initWriter(&writer, &out);
    try ok(c.bufzilla_writer_start_object(&writer));
    try ok(c.bufzilla_writer_write_bytes(&writer, bytes("small")));
    try ok(c.bufzilla_writer_write_int(&writer, -3));
    try ok(c.bufzilla_writer_write_bytes(&writer, bytes("large")));
    try ok(c.bufzilla_writer_write_uint(&writer, std.math.maxInt(u64)));
    try ok(c.bufzilla_writer_write_bytes(&writer, bytes("float")));
    try ok(c.bufzilla_writer_write_f64(&writer, 1.25));
    try ok(c.bufzilla_writer_write_bytes(&writer, bytes("single")));
    try ok(c.bufzilla_writer_write_f32(&writer, 0.5));
    try ok(c.bufzilla_writer_write_bytes(&writer, bytes("flag")));
    try ok(c.bufzilla_writer_write_bool(&writer, true));
    try ok(c.bufzilla_writer_write_bytes(&writer, bytes("nothing")));
    try ok(c.bufzilla_writer_write_null(&writer));
    try ok(c.bufzilla_writer_write_bytes(&writer, bytes("list")));
    try ok(c.bufzilla_writer_start_array(&writer));
    try ok(c.bufzilla_writer_write_bytes(&writer, bytes("a string longer than seven bytes")));
    try ok(c.bufzilla_writer_end_container(&writer));
    try ok(c.bufzilla_writer_end_container(&writer));

    var expected_buf: [128]u8 = undefined;
    var expected = Io.Writer.fixed(&expected_buf);
    var zig_writer = Writer.init(&expected);
    try zig_writer.writeAny(.{
        .small = @as(i64, -3),
        .large = @as(u64, std.math.maxInt(u64)),
        .float = @as(f64, 1.25),
        .single = @as(f32, 0.5),
        .flag = true,
        .nothing = null,
        .list = @as([]const []const u8, &.{"a string longer than seven bytes"}),
    });
    try expectEqualSlices(u8, expected.buffered(), writtenBytes(&writer, &out));
}

test "c api: a failed write leaves the writer unchanged" {
    var out: [4]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    try initWriter(&writer, &out);
    try ok(c.bufzilla_writer_start_array(&writer));
    try ok(c.bufzilla_writer_write_int(&writer, 1));

    // Only part of this would fit; none of it may be kept.
    try expectStatus(.buffer_too_small, c.bufzilla_writer_write_bytes(&writer, bytes("too long")));
    try expectEqual(@as(usize, 2), c.bufzilla_writer_written(&writer));

    try ok(c.bufzilla_writer_write_int(&writer, 2));
    try ok(c.bufzilla_writer_end_container(&writer));
    try expectEqual(@as(i64, 2), try intAt(writtenBytes(&writer, &out), "[1]"));
}

test "c api: copying a writer snapshots its position" {
    var out: [16]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    try initWriter(&writer, &out);
    try ok(c.bufzilla_writer_start_array(&writer));
    try ok(c.bufzilla_writer_write_int(&writer, 1));

    // Writing through a copy must not move the original.
    var copy = writer;
    try ok(c.bufzilla_writer_write_int(&copy, 2));
    try expectEqual(@as(usize, 3), c.bufzilla_writer_written(&copy));
    try expectEqual(@as(usize, 2), c.bufzilla_writer_written(&writer));

    // Continuing from the original overwrites what the copy wrote.
    try ok(c.bufzilla_writer_write_int(&writer, 3));
    try ok(c.bufzilla_writer_end_container(&writer));
    try expectEqual(@as(i64, 3), try intAt(writtenBytes(&writer, &out), "[1]"));
}

test "c api: write_value writes exactly the encoding its tag selects" {
    var out: [64]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    try initWriter(&writer, &out);

    const fixed_i64: c.BufzillaValue = .{ .tag = tagOf(.i64), .data = .{ .i64_value = 1 } };
    try ok(c.bufzilla_writer_write_value(&writer, &fixed_i64));
    try expectEqual(@as(usize, 9), c.bufzilla_writer_written(&writer));

    const negative: c.BufzillaValue = .{ .tag = tagOf(.varIntSignedNegative), .data = .{ .i64_value = std.math.minInt(i64) } };
    try ok(c.bufzilla_writer_write_value(&writer, &negative));

    var reader: c.BufzillaReader = undefined;
    try ok(c.bufzilla_reader_init(&reader, bytes(writtenBytes(&writer, &out))));
    var value: c.BufzillaValue = undefined;
    try ok(c.bufzilla_reader_read(&reader, &value));
    try expectEqual(tagOf(.i64), value.tag);
    try ok(c.bufzilla_reader_read(&reader, &value));
    try expectEqual(std.math.minInt(i64), value.data.i64_value);
}

test "c api: write_value rejects payloads out of range for their tag" {
    const invalid = [_]c.BufzillaValue{
        .{ .tag = tagOf(.smallBytes), .data = .{ .bytes = bytes("8 bytes!") } },
        .{ .tag = tagOf(.smallIntPositive), .data = .{ .small_value = 8 } },
        .{ .tag = tagOf(.smallIntNegative), .data = .{ .small_value = 0 } },
        .{ .tag = tagOf(.smallUint), .data = .{ .small_value = 8 } },
        .{ .tag = tagOf(.varIntSignedPositive), .data = .{ .i64_value = -1 } },
        .{ .tag = tagOf(.varIntSignedNegative), .data = .{ .i64_value = 0 } },
        .{ .tag = tagOf(.bool), .data = .{ .bool_value = 2 } },
        .{ .tag = tagOf(.bytes), .data = .{ .bytes = .{ .ptr = null, .len = 1 } } },
        .{ .tag = 26, .data = .{ .u64_value = 0 } },
        .{ .tag = -1, .data = .{ .u64_value = 0 } },
        .{ .tag = tagOf(.typedArray), .data = .{ .typed_array = .{ .elem = elemOf(.u16), .count = 2, .bytes = bytes("abc") } } },
        .{ .tag = tagOf(.typedArray), .data = .{ .typed_array = .{ .elem = 11, .count = 0, .bytes = bytes("") } } },
        .{ .tag = tagOf(.typedArray), .data = .{ .typed_array = .{ .elem = elemOf(.u64), .count = std.math.maxInt(usize), .bytes = bytes("") } } },
    };

    var out: [64]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    try initWriter(&writer, &out);
    for (&invalid) |*value| {
        try expectStatus(.invalid_argument, c.bufzilla_writer_write_value(&writer, value));
    }
    try expectEqual(@as(usize, 0), c.bufzilla_writer_written(&writer));
}

test "c api: NULL pointers return invalid_argument" {
    var out: [16]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    var reader: c.BufzillaReader = undefined;
    var value: c.BufzillaValue = undefined;
    var flag = false;
    var written: usize = 0;

    try expectStatus(.invalid_argument, c.bufzilla_writer_init(null, mutBytes(&out)));
    try expectStatus(.invalid_argument, c.bufzilla_writer_init(&writer, .{ .ptr = null, .len = 1 }));
    try initWriter(&writer, &out);
    try expectStatus(.invalid_argument, c.bufzilla_writer_write_int(null, 1));
    try expectStatus(.invalid_argument, c.bufzilla_writer_write_value(&writer, null));
    try expectStatus(.invalid_argument, c.bufzilla_writer_write_bytes(&writer, .{ .ptr = null, .len = 3 }));
    try ok(c.bufzilla_writer_write_bytes(&writer, .{ .ptr = null, .len = 0 }));
    try expectEqual(@as(usize, 0), c.bufzilla_writer_written(null));

    try expectStatus(.invalid_argument, c.bufzilla_reader_init(null, bytes(writtenBytes(&writer, &out))));
    try ok(c.bufzilla_reader_init(&reader, bytes(writtenBytes(&writer, &out))));
    try expectStatus(.invalid_argument, c.bufzilla_reader_read(&reader, null));
    try expectStatus(.invalid_argument, c.bufzilla_reader_read_path(&reader, bytes(""), null, &flag));
    try expectStatus(.invalid_argument, c.bufzilla_reader_read_path(&reader, bytes(""), &value, null));
    try expectStatus(.invalid_argument, c.bufzilla_reader_iterate_array(&reader, null, &value, &flag));
    try expectStatus(.invalid_argument, c.bufzilla_reader_read_paths(&reader, null, 1, null, 0));
    try expectEqual(@as(usize, 0), c.bufzilla_reader_position(null));
    // Nothing above moved the reader.
    try expectEqual(@as(usize, 0), c.bufzilla_reader_position(&reader));

    try expectStatus(.invalid_argument, c.bufzilla_inspect(bytes(writtenBytes(&writer, &out)), null, mutBytes(&out), null));
    try expectStatus(.invalid_argument, c.bufzilla_apply_updates(bytes(""), null, 1, 0, null, 0, mutBytes(&out), &written));
    try expectStatus(.invalid_argument, c.bufzilla_value_as_int(null, null));
}

// =============================================================================
// Typed arrays
// =============================================================================

test "c api: typed arrays round-trip native values through unaligned memory" {
    const values = [_]u32{ 1, 0x01020304, 0xFFFF_FFFF };
    var input: [1 + @sizeOf(@TypeOf(values))]u8 align(4) = undefined;
    @memcpy(input[1..], std.mem.sliceAsBytes(&values));

    var out: [64]u8 = undefined;
    var writer: c.BufzillaWriter = undefined;
    try initWriter(&writer, &out);
    try ok(c.bufzilla_writer_write_typed_array(&writer, elemOf(.u32), &input[1], values.len));

    // The payload is little-endian regardless of the host.
    var expected_buf: [64]u8 = undefined;
    var expected = Io.Writer.fixed(&expected_buf);
    var zig_writer = Writer.init(&expected);
    try zig_writer.writeTypedArray(&values);
    try expectEqualSlices(u8, expected.buffered(), writtenBytes(&writer, &out));

    var reader: c.BufzillaReader = undefined;
    try ok(c.bufzilla_reader_init(&reader, bytes(writtenBytes(&writer, &out))));
    var value: c.BufzillaValue = undefined;
    try ok(c.bufzilla_reader_read(&reader, &value));
    try expectEqual(tagOf(.typedArray), value.tag);
    const ta = value.data.typed_array;
    try expectEqual(@as(usize, 3), ta.count);

    var element: c.BufzillaValue = undefined;
    try ok(c.bufzilla_typed_array_get(&ta, 1, &element));
    try expectEqual(tagOf(.u32), element.tag);
    try expectEqual(@as(u32, 0x01020304), element.data.u32_value);
    try expectStatus(.index_out_of_range, c.bufzilla_typed_array_get(&ta, 3, &element));

    var copied: [1 + @sizeOf(@TypeOf(values))]u8 = undefined;
    try ok(c.bufzilla_typed_array_copy(&ta, mutBytes(copied[1..])));
    try expectEqualSlices(u8, std.mem.sliceAsBytes(&values), copied[1..]);
    try expectStatus(.buffer_too_small, c.bufzilla_typed_array_copy(&ta, mutBytes(copied[1 .. copied.len - 1])));

    try expectEqual(@as(usize, 4), c.bufzilla_typed_array_elem_size(elemOf(.u32)));
    try expectEqual(@as(usize, 2), c.bufzilla_typed_array_elem_size(elemOf(.f16)));
    try expectEqual(@as(usize, 0), c.bufzilla_typed_array_elem_size(11));
}

test "c api: write_typed_array validates its arguments" {
    var out: [16]u8 = undefined;
    const input: [16]u8 = @splat(0);
    var writer: c.BufzillaWriter = undefined;
    try initWriter(&writer, &out);
    try ok(c.bufzilla_writer_write_typed_array(&writer, elemOf(.f64), null, 0));
    try expectStatus(.invalid_argument, c.bufzilla_writer_write_typed_array(&writer, elemOf(.f64), null, 1));
    try expectStatus(.invalid_argument, c.bufzilla_writer_write_typed_array(&writer, 11, &input, 1));
    try expectStatus(.invalid_argument, c.bufzilla_writer_write_typed_array(&writer, elemOf(.u64), &input, std.math.maxInt(usize) / 4));
    try expectStatus(.buffer_too_small, c.bufzilla_writer_write_typed_array(&writer, elemOf(.u8), &input, input.len));
}

// =============================================================================
// Reader
// =============================================================================

fn encodeSample(buffer: []u8) ![]const u8 {
    var fixed = Io.Writer.fixed(buffer);
    var writer = Writer.init(&fixed);
    try writer.writeAny(.{ .a = @as([]const i64, &.{ 1, 2 }), .b = true });
    return fixed.buffered();
}

test "c api: reader iterates containers and rejects ones that are not open" {
    var buffer: [64]u8 = undefined;
    const encoded = try encodeSample(&buffer);

    var reader: c.BufzillaReader = undefined;
    try ok(c.bufzilla_reader_init(&reader, bytes(encoded)));
    var root: c.BufzillaValue = undefined;
    try ok(c.bufzilla_reader_read(&reader, &root));
    try expectEqual(tagOf(.object), root.tag);

    var key: c.BufzillaValue = undefined;
    var value: c.BufzillaValue = undefined;
    var has_next = false;
    try ok(c.bufzilla_reader_iterate_object(&reader, &root, &key, &value, &has_next));
    try expect(has_next);
    try expectEqualStrings("a", sliceOf(key.data.bytes));
    const array = value;
    try expectEqual(tagOf(.array), array.tag);

    // Passing a container to the wrong iterator, or a forged depth, is rejected.
    try expectStatus(.invalid_argument, c.bufzilla_reader_iterate_object(&reader, &array, &key, &value, &has_next));
    var forged = array;
    forged.data.container_depth = 0;
    try expectStatus(.invalid_argument, c.bufzilla_reader_iterate_array(&reader, &forged, &value, &has_next));
    forged.data.container_depth = 99;
    try expectStatus(.invalid_argument, c.bufzilla_reader_iterate_array(&reader, &forged, &value, &has_next));

    var item: c.BufzillaValue = undefined;
    var sum: i64 = 0;
    while (true) {
        try ok(c.bufzilla_reader_iterate_array(&reader, &array, &item, &has_next));
        if (!has_next) break;
        var n: i64 = undefined;
        try ok(c.bufzilla_value_as_int(&item, &n));
        sum += n;
    }
    try expectEqual(@as(i64, 3), sum);
    // The array has ended.
    try expectStatus(.invalid_argument, c.bufzilla_reader_iterate_array(&reader, &array, &item, &has_next));

    try ok(c.bufzilla_reader_iterate_object(&reader, &root, &key, &value, &has_next));
    try expect(has_next);
    try expectEqual(tagOf(.bool), value.tag);
    try ok(c.bufzilla_reader_iterate_object(&reader, &root, &key, &value, &has_next));
    try expect(!has_next);
    try expectEqual(encoded.len, c.bufzilla_reader_position(&reader));
    try expectStatus(.invalid_argument, c.bufzilla_reader_iterate_object(&reader, &root, &key, &value, &has_next));
}

test "c api: a failed read leaves the reader unchanged" {
    var buffer: [64]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var writer = Writer.init(&fixed);
    try writer.writeAny(.{ .a = "a string long enough to truncate" });
    const truncated = fixed.buffered()[0 .. fixed.buffered().len - 4];

    var reader: c.BufzillaReader = undefined;
    try ok(c.bufzilla_reader_init(&reader, bytes(truncated)));
    var root: c.BufzillaValue = undefined;
    try ok(c.bufzilla_reader_read(&reader, &root));
    const position = c.bufzilla_reader_position(&reader);

    var key: c.BufzillaValue = undefined;
    var value: c.BufzillaValue = undefined;
    var has_next = false;
    try expectStatus(.unexpected_eof, c.bufzilla_reader_iterate_object(&reader, &root, &key, &value, &has_next));
    try expectEqual(position, c.bufzilla_reader_position(&reader));

    try ok(c.bufzilla_reader_init(&reader, bytes(truncated)));
    try expectStatus(.unexpected_eof, c.bufzilla_reader_skip_value(&reader));
    try expectEqual(@as(usize, 0), c.bufzilla_reader_position(&reader));
}

test "c api: path lookups" {
    var buffer: [64]u8 = undefined;
    const encoded = try encodeSample(&buffer);
    try expectEqual(@as(i64, 2), try intAt(encoded, "a[1]"));
    try std.testing.expectError(error.PathNotFound, readAt(encoded, "missing"));
    try std.testing.expectError(error.PathNotFound, readAt(encoded, "a["));
    try expectEqual(tagOf(.object), (try readAt(encoded, "")).tag);

    try expect(c.bufzilla_path_validate(bytes("users[2]['key.with.dots']")));
    try expect(!c.bufzilla_path_validate(bytes("a[")));
    try expect(!c.bufzilla_path_validate(.{ .ptr = null, .len = 1 }));
}

test "c api: read_paths with unaligned and undersized scratch" {
    var buffer: [64]u8 = undefined;
    const encoded = try encodeSample(&buffer);
    var reader: c.BufzillaReader = undefined;
    try ok(c.bufzilla_reader_init(&reader, bytes(encoded)));

    const unset: c.BufzillaValue = .{ .tag = -1, .data = .{ .u64_value = 0 } };
    var queries = [_]c.BufzillaPathQuery{
        .{ .path = bytes("a[0]"), .value = unset, .found = 7 },
        .{ .path = bytes("missing"), .value = unset, .found = 7 },
        .{ .path = bytes("b"), .value = unset, .found = 7 },
    };

    var tiny: [8]u8 = undefined;
    try expectStatus(.buffer_too_small, c.bufzilla_reader_read_paths(&reader, &queries, queries.len, &tiny, tiny.len));
    for (queries) |query| try expectEqual(@as(u8, 7), query.found);

    const size = c.bufzilla_reader_read_paths_scratch_size(queries.len);
    const scratch = try std.testing.allocator.alloc(u8, size + 1);
    defer std.testing.allocator.free(scratch);
    // Offset by one byte so the scratch is misaligned.
    try ok(c.bufzilla_reader_read_paths(&reader, &queries, queries.len, scratch[1..].ptr, size));
    try expectEqual(@as(u8, 1), queries[0].found);
    try expectEqual(@as(u8, 0), queries[1].found);
    try expectEqual(@as(u8, 1), queries[2].found);
    var first: i64 = undefined;
    try ok(c.bufzilla_value_as_int(&queries[0].value, &first));
    try expectEqual(@as(i64, 1), first);

    try ok(c.bufzilla_reader_read_paths(&reader, &queries, 0, null, 0));
    try expectEqual(@as(usize, std.math.maxInt(usize)), c.bufzilla_reader_read_paths_scratch_size(std.math.maxInt(usize)));
    try expectEqual(@as(usize, std.math.maxInt(usize)), c.bufzilla_apply_updates_scratch_size(std.math.maxInt(usize) / 8));
}

// =============================================================================
// Updates
// =============================================================================

fn applyUpdates(encoded: []const u8, updates: []const c.BufzillaUpdate, max_array_length: usize, output: []u8, written: *usize) c_int {
    var scratch: [1024]u8 = undefined;
    std.debug.assert(c.bufzilla_apply_updates_scratch_size(updates.len) <= scratch.len - 1);
    // Offset by one byte so the scratch is misaligned.
    return c.bufzilla_apply_updates(bytes(encoded), updates.ptr, updates.len, max_array_length, &scratch[1], scratch.len - 1, mutBytes(output), written);
}

test "c api: apply updates replaces, extends and inserts" {
    var buffer: [64]u8 = undefined;
    const encoded = try encodeSample(&buffer);
    const updates = [_]c.BufzillaUpdate{
        .{ .path = bytes("b"), .value = .{ .tag = tagOf(.varIntSignedPositive), .data = .{ .i64_value = 99 } } },
        .{ .path = bytes("a[3]"), .value = .{ .tag = tagOf(.bool), .data = .{ .bool_value = 1 } } },
        .{ .path = bytes("new.key"), .value = .{ .tag = tagOf(.smallBytes), .data = .{ .bytes = bytes("v") } } },
    };

    var out: [128]u8 = undefined;
    var written: usize = 0;
    try ok(applyUpdates(encoded, &updates, c.default_max_array_length, &out, &written));
    const updated = out[0..written];
    try expectEqual(@as(i64, 99), try intAt(updated, "b"));
    try expectEqual(@as(i64, 2), try intAt(updated, "a[1]"));
    try expectEqual(tagOf(.null), (try readAt(updated, "a[2]")).tag);
    try expectEqual(tagOf(.bool), (try readAt(updated, "a[3]")).tag);
    try expectEqualStrings("v", sliceOf((try readAt(updated, "new.key")).data.bytes));
}

test "c api: apply updates limits, validation and errors" {
    var buffer: [64]u8 = undefined;
    const encoded = try encodeSample(&buffer);
    var out: [128]u8 = undefined;
    var written: usize = 123;

    // A limit of zero forbids extending arrays but still allows replacing elements.
    const extend = [_]c.BufzillaUpdate{.{ .path = bytes("a[2]"), .value = .{ .tag = tagOf(.null), .data = .{ .u64_value = 0 } } }};
    try expectStatus(.array_too_large, applyUpdates(encoded, &extend, 0, &out, &written));
    try expectEqual(@as(usize, 123), written);
    const replace = [_]c.BufzillaUpdate{.{ .path = bytes("a[1]"), .value = .{ .tag = tagOf(.null), .data = .{ .u64_value = 0 } } }};
    try ok(applyUpdates(encoded, &replace, 0, &out, &written));
    try ok(applyUpdates(encoded, &extend, std.math.maxInt(usize), &out, &written));

    // A lone container tag would unbalance the output.
    const container = [_]c.BufzillaUpdate{.{ .path = bytes("b"), .value = .{ .tag = tagOf(.array), .data = .{ .u64_value = 0 } } }};
    try expectStatus(.invalid_argument, applyUpdates(encoded, &container, 0, &out, &written));

    // The last of several updates to the same path wins.
    const repeated = [_]c.BufzillaUpdate{
        .{ .path = bytes("b"), .value = .{ .tag = tagOf(.smallUint), .data = .{ .small_value = 1 } } },
        .{ .path = bytes("b"), .value = .{ .tag = tagOf(.smallUint), .data = .{ .small_value = 2 } } },
    };
    try ok(applyUpdates(encoded, &repeated, 0, &out, &written));
    try expectEqual(@as(i64, 2), try intAt(out[0..written], "b"));

    var tiny: [8]u8 = undefined;
    try expectStatus(.buffer_too_small, c.bufzilla_apply_updates(bytes(encoded), &repeated, repeated.len, 0, &tiny, tiny.len, mutBytes(&out), &written));
    try expectStatus(.buffer_too_small, applyUpdates(encoded, &repeated, 0, out[0..4], &written));
    try expectStatus(.malformed_path, applyUpdates(encoded, &.{.{ .path = bytes("a["), .value = replace[0].value }}, 0, &out, &written));
}

test "c api: typed array element updates must be numbers that fit" {
    var buffer: [64]u8 = undefined;
    var fixed = Io.Writer.fixed(&buffer);
    var zig_writer = Writer.init(&fixed);
    try zig_writer.startObject();
    try zig_writer.writeAny("ta");
    try zig_writer.writeTypedArray(&[_]u8{ 1, 2 });
    try zig_writer.endContainer();
    const encoded = fixed.buffered();

    var out: [64]u8 = undefined;
    var written: usize = 0;
    const too_big = [_]c.BufzillaUpdate{.{ .path = bytes("ta[0]"), .value = .{ .tag = tagOf(.u64), .data = .{ .u64_value = 1000 } } }};
    try expectStatus(.type_mismatch, applyUpdates(encoded, &too_big, 0, &out, &written));
    const long_string = [_]c.BufzillaUpdate{.{ .path = bytes("ta[0]"), .value = .{ .tag = tagOf(.bytes), .data = .{ .bytes = bytes("a string far longer than any number") } } }};
    try expectStatus(.type_mismatch, applyUpdates(encoded, &long_string, 0, &out, &written));
    const fits = [_]c.BufzillaUpdate{.{ .path = bytes("ta[1]"), .value = .{ .tag = tagOf(.varIntSignedPositive), .data = .{ .i64_value = 200 } } }};
    try ok(applyUpdates(encoded, &fits, 0, &out, &written));
    try expectEqual(@as(i64, 200), try intAt(out[0..written], "ta[1]"));
    const extend = [_]c.BufzillaUpdate{.{ .path = bytes("ta[2]"), .value = fits[0].value }};
    try expectStatus(.index_out_of_range, applyUpdates(encoded, &extend, std.math.maxInt(usize), &out, &written));
}

test "c api: paths are limited to BUFZILLA_MAX_PATH_SEGMENTS segments" {
    var path_buf: [2 * (bufzilla.Path.max_segments + 1)]u8 = undefined;
    for (0..bufzilla.Path.max_segments + 1) |i| {
        path_buf[2 * i] = 'z';
        path_buf[2 * i + 1] = '.';
    }
    const longest = path_buf[0 .. 2 * bufzilla.Path.max_segments - 1];
    const too_long = path_buf[0 .. 2 * bufzilla.Path.max_segments + 1];
    try expect(c.bufzilla_path_validate(bytes(longest)));
    try expect(!c.bufzilla_path_validate(bytes(too_long)));

    var buffer: [64]u8 = undefined;
    const encoded = try encodeSample(&buffer);
    var out: [1024]u8 = undefined;
    var written: usize = 0;
    const null_value: c.BufzillaValue = .{ .tag = tagOf(.null), .data = .{ .u64_value = 0 } };
    try ok(applyUpdates(encoded, &.{.{ .path = bytes(longest), .value = null_value }}, 0, &out, &written));
    try expectEqual(tagOf(.null), (try readAt(out[0..written], longest)).tag);
    try expectStatus(.malformed_path, applyUpdates(encoded, &.{.{ .path = bytes(too_long), .value = null_value }}, 0, &out, &written));
}

test "c api: zero-initialized state fails safely" {
    var writer = std.mem.zeroes(c.BufzillaWriter);
    try expectStatus(.buffer_too_small, c.bufzilla_writer_write_int(&writer, 1));
    try expectEqual(@as(usize, 0), c.bufzilla_writer_written(&writer));
    var reader = std.mem.zeroes(c.BufzillaReader);
    var value: c.BufzillaValue = undefined;
    try expectStatus(.unexpected_eof, c.bufzilla_reader_read(&reader, &value));
}

// =============================================================================
// Values and JSON
// =============================================================================

test "c api: value accessors accept every encoding of a type" {
    var int: i64 = undefined;
    var uint: u64 = undefined;
    var float: f64 = undefined;
    var span: c.BufzillaBytes = undefined;

    try ok(c.bufzilla_value_as_int(&.{ .tag = tagOf(.smallIntNegative), .data = .{ .small_value = 3 } }, &int));
    try expectEqual(@as(i64, -3), int);
    try ok(c.bufzilla_value_as_int(&.{ .tag = tagOf(.u8), .data = .{ .u8_value = 200 } }, &int));
    try expectEqual(@as(i64, 200), int);
    try expectStatus(.out_of_range, c.bufzilla_value_as_int(&.{ .tag = tagOf(.u64), .data = .{ .u64_value = std.math.maxInt(u64) } }, &int));
    try expectStatus(.type_mismatch, c.bufzilla_value_as_int(&.{ .tag = tagOf(.f64), .data = .{ .f64_value = 1 } }, &int));
    try expectStatus(.invalid_argument, c.bufzilla_value_as_int(&.{ .tag = tagOf(.smallUint), .data = .{ .small_value = 9 } }, &int));

    try ok(c.bufzilla_value_as_uint(&.{ .tag = tagOf(.varIntUnsigned), .data = .{ .u64_value = std.math.maxInt(u64) } }, &uint));
    try expectEqual(@as(u64, std.math.maxInt(u64)), uint);
    try expectStatus(.out_of_range, c.bufzilla_value_as_uint(&.{ .tag = tagOf(.i8), .data = .{ .i8_value = -1 } }, &uint));

    try ok(c.bufzilla_value_as_f64(&.{ .tag = tagOf(.f16), .data = .{ .f16_bits = @bitCast(@as(f16, 1.5)) } }, &float));
    try expectEqual(@as(f64, 1.5), float);
    try expectStatus(.type_mismatch, c.bufzilla_value_as_f64(&.{ .tag = tagOf(.i64), .data = .{ .i64_value = 1 } }, &float));

    try ok(c.bufzilla_value_as_bytes(&.{ .tag = tagOf(.smallBytes), .data = .{ .bytes = bytes("abc") } }, &span));
    try expectEqualStrings("abc", sliceOf(span));
    try expectStatus(.type_mismatch, c.bufzilla_value_as_bytes(&.{ .tag = tagOf(.null), .data = .{ .u64_value = 0 } }, &span));
}

test "c api: inspect" {
    var buffer: [64]u8 = undefined;
    const encoded = try encodeSample(&buffer);
    var json: [128]u8 = undefined;
    var written: usize = 0;

    const compact: c.BufzillaInspectOptions = .{ .indent_size = 0, .float_precision = 2 };
    try ok(c.bufzilla_inspect(bytes(encoded), &compact, mutBytes(&json), &written));
    try expectEqualStrings("{\n\"a\": [\n1,\n2\n],\n\"b\": true\n}", json[0..written]);

    try ok(c.bufzilla_inspect(bytes(encoded), null, mutBytes(&json), &written));
    try expect(std.mem.find(u8, json[0..written], "    \"b\": true") != null);

    // Oversized options and output buffers fail cleanly.
    written = 123;
    const huge: c.BufzillaInspectOptions = .{ .indent_size = std.math.maxInt(usize), .float_precision = std.math.maxInt(usize) };
    try expectStatus(.buffer_too_small, c.bufzilla_inspect(bytes(encoded), &huge, mutBytes(&json), &written));
    try expectStatus(.buffer_too_small, c.bufzilla_inspect(bytes(encoded), null, mutBytes(json[0..4]), &written));
    try expectEqual(@as(usize, 123), written);
    try expectStatus(.unexpected_eof, c.bufzilla_inspect(bytes(encoded[0..3]), null, mutBytes(&json), &written));
}
