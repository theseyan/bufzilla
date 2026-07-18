const std = @import("std");
const bufzilla = @import("bufzilla");
const common = bufzilla.Common;
const path = bufzilla.Path;
const Writer = bufzilla.Writer;
const Reader = bufzilla.Reader(.{});
const Inspect = bufzilla.Inspect(.{});
const Io = std.Io;

pub const BUFZILLA_SIZEOF_WRITER = 64;
pub const BUFZILLA_SIZEOF_READER = 64;
pub const BUFZILLA_ALIGNOF_STATE = 16;

pub const BufzillaStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    buffer_too_small = 2,
    unexpected_eof = 3,
    invalid_enum_tag = 4,
    invalid_signed_magnitude = 5,
    unexpected_container_end = 6,
    max_depth_exceeded = 7,
    bytes_too_long = 8,
    array_too_large = 9,
    object_too_large = 10,
    invalid_root = 11,
    malformed_path = 12,
    path_type_mismatch = 13,
    conflicting_updates = 14,
    index_out_of_range = 15,
    invalid_utf8 = 16,
    non_finite_float = 17,
    type_mismatch = 18,
    length_mismatch = 19,
    index_out_of_bounds = 20,
    unknown_error = 255,
};

pub const BufzillaValueTag = enum(c_int) {
    bytes = 0,
    var_int_bytes = 1,
    small_bytes = 2,
    u64_value = 3,
    u32_value = 4,
    u16_value = 5,
    u8_value = 6,
    i64_value = 7,
    i32_value = 8,
    i16_value = 9,
    i8_value = 10,
    f64_value = 11,
    f32_value = 12,
    f16_value = 13,
    bool_value = 14,
    null_value = 15,
    small_int_positive = 16,
    small_int_negative = 17,
    small_uint = 18,
    var_int_signed_positive = 19,
    var_int_signed_negative = 20,
    var_int_unsigned = 21,
    array = 22,
    object = 23,
    container_end = 24,
    typed_array = 25,
};

pub const BufzillaTypedArrayElem = enum(c_int) {
    u8_value = 0,
    i8_value = 1,
    u16_value = 2,
    i16_value = 3,
    u32_value = 4,
    i32_value = 5,
    u64_value = 6,
    i64_value = 7,
    f16_value = 8,
    f32_value = 9,
    f64_value = 10,
};

pub const BufzillaBytes = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const BufzillaMutableBytes = extern struct {
    ptr: ?[*]u8,
    len: usize,
};

pub const BufzillaTypedArray = extern struct {
    elem: c_int,
    count: usize,
    bytes: BufzillaBytes,
};

pub const BufzillaValuePayload = extern union {
    bytes: BufzillaBytes,
    typed_array: BufzillaTypedArray,
    u64_value: u64,
    u32_value: u32,
    u16_value: u16,
    u8_value: u8,
    i64_value: i64,
    i32_value: i32,
    i16_value: i16,
    i8_value: i8,
    f64_value: f64,
    f32_value: f32,
    f16_bits: u16,
    bool_value: u8,
    small_value: u8,
    container_depth: u32,
};

pub const BufzillaValue = extern struct {
    tag: c_int,
    data: BufzillaValuePayload,
};

pub const BufzillaPathQuery = extern struct {
    path: BufzillaBytes,
    value: BufzillaValue,
    found: u8,
    resolved: u8,
};

pub const BufzillaUpdate = extern struct {
    path: BufzillaBytes,
    value: BufzillaValue,
};

pub const BufzillaInspectOptions = extern struct {
    indent_size: usize,
    float_precision: usize,
};

pub const BufzillaWriter = extern struct {
    _align: c_longdouble,
    data: [BUFZILLA_SIZEOF_WRITER - @sizeOf(c_longdouble)]u8,
};

pub const BufzillaReader = extern struct {
    _align: c_longdouble,
    data: [BUFZILLA_SIZEOF_READER - @sizeOf(c_longdouble)]u8,
};

const WriterState = struct {
    fixed: Io.Writer,
    writer: Writer,
};

const ReaderState = struct {
    reader: Reader,
};

comptime {
    std.debug.assert(@sizeOf(WriterState) <= BUFZILLA_SIZEOF_WRITER);
    std.debug.assert(@sizeOf(ReaderState) <= BUFZILLA_SIZEOF_READER);
    std.debug.assert(@alignOf(BufzillaWriter) >= @alignOf(WriterState));
    std.debug.assert(@alignOf(BufzillaReader) >= @alignOf(ReaderState));
}

fn ok() c_int {
    return @intFromEnum(BufzillaStatus.ok);
}

fn errorCode(err: anyerror) c_int {
    return @intFromEnum(switch (err) {
        error.InvalidArgument => BufzillaStatus.invalid_argument,
        error.BufferTooSmall => BufzillaStatus.buffer_too_small,
        error.WriteFailed => BufzillaStatus.buffer_too_small,
        error.NoSpaceLeft => BufzillaStatus.buffer_too_small,
        error.UnexpectedEof => BufzillaStatus.unexpected_eof,
        error.InvalidEnumTag => BufzillaStatus.invalid_enum_tag,
        error.InvalidSignedMagnitude => BufzillaStatus.invalid_signed_magnitude,
        error.UnexpectedContainerEnd => BufzillaStatus.unexpected_container_end,
        error.MaxDepthExceeded => BufzillaStatus.max_depth_exceeded,
        error.BytesTooLong => BufzillaStatus.bytes_too_long,
        error.ArrayTooLarge => BufzillaStatus.array_too_large,
        error.ObjectTooLarge => BufzillaStatus.object_too_large,
        error.InvalidRoot => BufzillaStatus.invalid_root,
        error.MalformedPath => BufzillaStatus.malformed_path,
        error.PathTypeMismatch => BufzillaStatus.path_type_mismatch,
        error.ConflictingUpdates => BufzillaStatus.conflicting_updates,
        error.IndexOutOfRange => BufzillaStatus.index_out_of_range,
        error.InvalidUtf8 => BufzillaStatus.invalid_utf8,
        error.NonFiniteFloat => BufzillaStatus.non_finite_float,
        error.TypeMismatch => BufzillaStatus.type_mismatch,
        error.LengthMismatch => BufzillaStatus.length_mismatch,
        error.IndexOutOfBounds => BufzillaStatus.index_out_of_bounds,
        else => BufzillaStatus.unknown_error,
    });
}

fn asWriter(writer: *BufzillaWriter) *WriterState {
    return @ptrCast(@alignCast(writer));
}

fn asReader(reader: *BufzillaReader) *ReaderState {
    return @ptrCast(@alignCast(reader));
}

fn constSlice(bytes: BufzillaBytes) ![]const u8 {
    if (bytes.len == 0) return &.{};
    const ptr = bytes.ptr orelse return error.InvalidArgument;
    return ptr[0..bytes.len];
}

fn mutSlice(bytes: BufzillaMutableBytes) ![]u8 {
    if (bytes.len == 0) return &.{};
    const ptr = bytes.ptr orelse return error.InvalidArgument;
    return ptr[0..bytes.len];
}

fn bytesToC(bytes: []const u8) BufzillaBytes {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

fn typedElem(elem: c_int) !common.TypedArrayElem {
    return switch (std.enums.fromInt(BufzillaTypedArrayElem, elem) orelse return error.InvalidEnumTag) {
        .u8_value => .u8,
        .i8_value => .i8,
        .u16_value => .u16,
        .i16_value => .i16,
        .u32_value => .u32,
        .i32_value => .i32,
        .u64_value => .u64,
        .i64_value => .i64,
        .f16_value => .f16,
        .f32_value => .f32,
        .f64_value => .f64,
    };
}

fn typedElemToC(elem: common.TypedArrayElem) c_int {
    const c_elem: BufzillaTypedArrayElem = switch (elem) {
        .u8 => .u8_value,
        .i8 => .i8_value,
        .u16 => .u16_value,
        .i16 => .i16_value,
        .u32 => .u32_value,
        .i32 => .i32_value,
        .u64 => .u64_value,
        .i64 => .i64_value,
        .f16 => .f16_value,
        .f32 => .f32_value,
        .f64 => .f64_value,
    };
    return @intFromEnum(c_elem);
}

fn typedArrayFromC(typed_array: BufzillaTypedArray) !common.TypedArray {
    const elem = try typedElem(typed_array.elem);
    const bytes = try constSlice(typed_array.bytes);
    const expected = std.math.mul(usize, typed_array.count, common.typedArrayElemSize(elem)) catch return error.LengthMismatch;
    if (bytes.len != expected) return error.LengthMismatch;
    return .{ .elem = elem, .count = typed_array.count, .bytes = bytes };
}

fn typedArrayToC(typed_array: common.TypedArray) BufzillaTypedArray {
    return .{
        .elem = typedElemToC(typed_array.elem),
        .count = typed_array.count,
        .bytes = bytesToC(typed_array.bytes),
    };
}

fn valueTag(value: BufzillaValue) !BufzillaValueTag {
    return std.enums.fromInt(BufzillaValueTag, value.tag) orelse error.InvalidEnumTag;
}

fn validateValue(value: BufzillaValue) !void {
    switch (try valueTag(value)) {
        .bytes, .var_int_bytes => _ = try constSlice(value.data.bytes),
        .small_bytes => {
            const bytes = try constSlice(value.data.bytes);
            if (bytes.len > 7) return error.LengthMismatch;
        },
        .small_int_positive, .small_uint => if (value.data.small_value > 7) return error.InvalidArgument,
        .small_int_negative => if (value.data.small_value == 0 or value.data.small_value > 7) return error.InvalidArgument,
        .var_int_signed_positive => if (value.data.i64_value < 0) return error.InvalidSignedMagnitude,
        .var_int_signed_negative => if (value.data.i64_value >= 0) return error.InvalidSignedMagnitude,
        .bool_value => if (value.data.bool_value > 1) return error.InvalidArgument,
        .typed_array => _ = try typedArrayFromC(value.data.typed_array),
        else => {},
    }
}

fn commonToC(value: common.Value) BufzillaValue {
    return switch (value) {
        .bytes => |v| .{ .tag = @intFromEnum(BufzillaValueTag.bytes), .data = .{ .bytes = bytesToC(v) } },
        .varIntBytes => |v| .{ .tag = @intFromEnum(BufzillaValueTag.var_int_bytes), .data = .{ .bytes = bytesToC(v) } },
        .smallBytes => |v| .{ .tag = @intFromEnum(BufzillaValueTag.small_bytes), .data = .{ .bytes = bytesToC(v) } },
        .u64 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.u64_value), .data = .{ .u64_value = v } },
        .u32 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.u32_value), .data = .{ .u32_value = v } },
        .u16 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.u16_value), .data = .{ .u16_value = v } },
        .u8 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.u8_value), .data = .{ .u8_value = v } },
        .i64 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.i64_value), .data = .{ .i64_value = v } },
        .i32 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.i32_value), .data = .{ .i32_value = v } },
        .i16 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.i16_value), .data = .{ .i16_value = v } },
        .i8 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.i8_value), .data = .{ .i8_value = v } },
        .f64 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.f64_value), .data = .{ .f64_value = v } },
        .f32 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.f32_value), .data = .{ .f32_value = v } },
        .f16 => |v| .{ .tag = @intFromEnum(BufzillaValueTag.f16_value), .data = .{ .f16_bits = @bitCast(v) } },
        .bool => |v| .{ .tag = @intFromEnum(BufzillaValueTag.bool_value), .data = .{ .bool_value = @intFromBool(v) } },
        .null => .{ .tag = @intFromEnum(BufzillaValueTag.null_value), .data = .{ .u64_value = 0 } },
        .smallIntPositive => |v| .{ .tag = @intFromEnum(BufzillaValueTag.small_int_positive), .data = .{ .small_value = v } },
        .smallIntNegative => |v| .{ .tag = @intFromEnum(BufzillaValueTag.small_int_negative), .data = .{ .small_value = v } },
        .smallUint => |v| .{ .tag = @intFromEnum(BufzillaValueTag.small_uint), .data = .{ .small_value = v } },
        .varIntSignedPositive => |v| .{ .tag = @intFromEnum(BufzillaValueTag.var_int_signed_positive), .data = .{ .i64_value = v } },
        .varIntSignedNegative => |v| .{ .tag = @intFromEnum(BufzillaValueTag.var_int_signed_negative), .data = .{ .i64_value = v } },
        .varIntUnsigned => |v| .{ .tag = @intFromEnum(BufzillaValueTag.var_int_unsigned), .data = .{ .u64_value = v } },
        .array => |v| .{ .tag = @intFromEnum(BufzillaValueTag.array), .data = .{ .container_depth = v } },
        .object => |v| .{ .tag = @intFromEnum(BufzillaValueTag.object), .data = .{ .container_depth = v } },
        .containerEnd => |v| .{ .tag = @intFromEnum(BufzillaValueTag.container_end), .data = .{ .container_depth = v } },
        .typedArray => |v| .{ .tag = @intFromEnum(BufzillaValueTag.typed_array), .data = .{ .typed_array = typedArrayToC(v) } },
    };
}

fn writeValue(writer: *Writer, value: BufzillaValue) Writer.Error!void {
    switch (valueTag(value) catch unreachable) {
        .bytes => try writer.write(.{ .bytes = constSlice(value.data.bytes) catch unreachable }, .bytes),
        .var_int_bytes => try writer.write(.{ .varIntBytes = constSlice(value.data.bytes) catch unreachable }, .varIntBytes),
        .small_bytes => try writer.write(.{ .smallBytes = constSlice(value.data.bytes) catch unreachable }, .smallBytes),
        .u64_value => try writer.write(.{ .u64 = value.data.u64_value }, .u64),
        .u32_value => try writer.write(.{ .u32 = value.data.u32_value }, .u32),
        .u16_value => try writer.write(.{ .u16 = value.data.u16_value }, .u16),
        .u8_value => try writer.write(.{ .u8 = value.data.u8_value }, .u8),
        .i64_value => try writer.write(.{ .i64 = value.data.i64_value }, .i64),
        .i32_value => try writer.write(.{ .i32 = value.data.i32_value }, .i32),
        .i16_value => try writer.write(.{ .i16 = value.data.i16_value }, .i16),
        .i8_value => try writer.write(.{ .i8 = value.data.i8_value }, .i8),
        .f64_value => try writer.write(.{ .f64 = value.data.f64_value }, .f64),
        .f32_value => try writer.write(.{ .f32 = value.data.f32_value }, .f32),
        .f16_value => try writer.write(.{ .f16 = @bitCast(value.data.f16_bits) }, .f16),
        .bool_value => try writer.write(.{ .bool = value.data.bool_value != 0 }, .bool),
        .null_value => try writer.write(.{ .null = {} }, .null),
        .small_int_positive => try writer.write(.{ .smallIntPositive = value.data.small_value }, .smallIntPositive),
        .small_int_negative => try writer.write(.{ .smallIntNegative = value.data.small_value }, .smallIntNegative),
        .small_uint => try writer.write(.{ .smallUint = value.data.small_value }, .smallUint),
        .var_int_signed_positive => try writer.write(.{ .varIntSignedPositive = value.data.i64_value }, .varIntSignedPositive),
        .var_int_signed_negative => try writer.write(.{ .varIntSignedNegative = value.data.i64_value }, .varIntSignedNegative),
        .var_int_unsigned => try writer.write(.{ .varIntUnsigned = value.data.u64_value }, .varIntUnsigned),
        .array => try writer.startArray(),
        .object => try writer.startObject(),
        .container_end => try writer.endContainer(),
        .typed_array => try writer.write(.{ .typedArray = typedArrayFromC(value.data.typed_array) catch unreachable }, .typedArray),
    }
}

fn writeUpdateValue(writer: *Writer, ctx: *const anyopaque) Writer.Error!void {
    const update: *const BufzillaUpdate = @ptrCast(@alignCast(ctx));
    try writeValue(writer, update.value);
}

fn scratchSlice(comptime T: type, ptr: ?*anyopaque, len: usize, count: usize) ![]T {
    if (count == 0) {
        const empty: [*]T = undefined;
        return empty[0..0];
    }
    const raw = ptr orelse return error.InvalidArgument;
    if (@intFromPtr(raw) % @alignOf(T) != 0) return error.InvalidArgument;
    const needed = std.math.mul(usize, @sizeOf(T), count) catch return error.LengthMismatch;
    if (len < needed) return error.BufferTooSmall;
    const typed: [*]T = @ptrCast(@alignCast(raw));
    return typed[0..count];
}

pub export fn bufzilla_writer_init(writer: *BufzillaWriter, buffer: BufzillaMutableBytes) c_int {
    const out = mutSlice(buffer) catch |err| return errorCode(err);
    const state = asWriter(writer);
    state.fixed = Io.Writer.fixed(out);
    state.writer = Writer.init(&state.fixed);
    return ok();
}

pub export fn bufzilla_writer_written(writer: *BufzillaWriter) usize {
    return asWriter(writer).fixed.buffered().len;
}

pub export fn bufzilla_writer_write_value(writer: *BufzillaWriter, value: BufzillaValue) c_int {
    validateValue(value) catch |err| return errorCode(err);
    writeValue(&asWriter(writer).writer, value) catch |err| return errorCode(err);
    return ok();
}

pub export fn bufzilla_writer_start_array(writer: *BufzillaWriter) c_int {
    asWriter(writer).writer.startArray() catch |err| return errorCode(err);
    return ok();
}

pub export fn bufzilla_writer_start_object(writer: *BufzillaWriter) c_int {
    asWriter(writer).writer.startObject() catch |err| return errorCode(err);
    return ok();
}

pub export fn bufzilla_writer_end_container(writer: *BufzillaWriter) c_int {
    asWriter(writer).writer.endContainer() catch |err| return errorCode(err);
    return ok();
}

pub export fn bufzilla_writer_write_typed_array(writer: *BufzillaWriter, typed_array: BufzillaTypedArray) c_int {
    return bufzilla_writer_write_value(writer, .{
        .tag = @intFromEnum(BufzillaValueTag.typed_array),
        .data = .{ .typed_array = typed_array },
    });
}

pub export fn bufzilla_apply_updates_scratch_len(update_count: usize) usize {
    return @sizeOf(Writer.Update) * update_count;
}

pub export fn bufzilla_apply_updates(
    encoded: BufzillaBytes,
    updates_ptr: ?[*]const BufzillaUpdate,
    update_count: usize,
    scratch_ptr: ?*anyopaque,
    scratch_len: usize,
    output: BufzillaMutableBytes,
    written: *usize,
) c_int {
    const encoded_slice = constSlice(encoded) catch |err| return errorCode(err);
    const output_slice = mutSlice(output) catch |err| return errorCode(err);
    if (update_count > 0 and updates_ptr == null) return @intFromEnum(BufzillaStatus.invalid_argument);
    const updates = if (update_count == 0) &[_]BufzillaUpdate{} else updates_ptr.?[0..update_count];
    const zig_updates = scratchSlice(Writer.Update, scratch_ptr, scratch_len, update_count) catch |err| return errorCode(err);

    for (updates, 0..) |*update, i| {
        _ = constSlice(update.path) catch |err| return errorCode(err);
        validateValue(update.value) catch |err| return errorCode(err);
        zig_updates[i] = .{
            .path = constSlice(update.path) catch unreachable,
            .ctx = @ptrCast(update),
            .writeFn = writeUpdateValue,
        };
    }

    var fixed = Io.Writer.fixed(output_slice);
    var writer = Writer.init(&fixed);
    writer.applyUpdates(encoded_slice, zig_updates) catch |err| return errorCode(err);
    written.* = fixed.buffered().len;
    return ok();
}

pub export fn bufzilla_reader_init(reader: *BufzillaReader, data: BufzillaBytes) c_int {
    const input = constSlice(data) catch |err| return errorCode(err);
    asReader(reader).* = .{ .reader = Reader.init(input) };
    return ok();
}

pub export fn bufzilla_reader_position(reader: *BufzillaReader) usize {
    return asReader(reader).reader.pos;
}

pub export fn bufzilla_reader_read(reader: *BufzillaReader, value: *BufzillaValue) c_int {
    const read_value = asReader(reader).reader.read() catch |err| return errorCode(err);
    value.* = commonToC(read_value);
    return ok();
}

pub export fn bufzilla_reader_skip_value(reader: *BufzillaReader) c_int {
    asReader(reader).reader.skipValue() catch |err| return errorCode(err);
    return ok();
}

pub export fn bufzilla_reader_iterate_object(reader: *BufzillaReader, object: BufzillaValue, key: *BufzillaValue, value: *BufzillaValue, has_next: *u8) c_int {
    if ((valueTag(object) catch |err| return errorCode(err)) != .object) return @intFromEnum(BufzillaStatus.invalid_argument);
    const next = asReader(reader).reader.iterateObject(.{ .object = object.data.container_depth }) catch |err| return errorCode(err);
    if (next) |kv| {
        key.* = commonToC(kv.key);
        value.* = commonToC(kv.value);
        has_next.* = 1;
    } else {
        has_next.* = 0;
    }
    return ok();
}

pub export fn bufzilla_reader_iterate_array(reader: *BufzillaReader, array: BufzillaValue, value: *BufzillaValue, has_next: *u8) c_int {
    if ((valueTag(array) catch |err| return errorCode(err)) != .array) return @intFromEnum(BufzillaStatus.invalid_argument);
    const next = asReader(reader).reader.iterateArray(.{ .array = array.data.container_depth }) catch |err| return errorCode(err);
    if (next) |item| {
        value.* = commonToC(item);
        has_next.* = 1;
    } else {
        has_next.* = 0;
    }
    return ok();
}

pub export fn bufzilla_reader_read_path(reader: *BufzillaReader, query_path: BufzillaBytes, value: *BufzillaValue, found: *u8) c_int {
    const path_slice = constSlice(query_path) catch |err| return errorCode(err);
    const result = asReader(reader).reader.readPath(path_slice) catch |err| return errorCode(err);
    if (result) |v| {
        value.* = commonToC(v);
        found.* = 1;
    } else {
        found.* = 0;
    }
    return ok();
}

pub export fn bufzilla_reader_read_paths_scratch_len(query_count: usize) usize {
    return @sizeOf(bufzilla.PathQuery) * query_count;
}

pub export fn bufzilla_reader_read_paths(reader: *BufzillaReader, queries_ptr: ?[*]BufzillaPathQuery, query_count: usize, scratch_ptr: ?*anyopaque, scratch_len: usize) c_int {
    if (query_count == 0) return ok();
    if (queries_ptr == null) return @intFromEnum(BufzillaStatus.invalid_argument);
    const queries = queries_ptr.?[0..query_count];
    const zig_queries = scratchSlice(bufzilla.PathQuery, scratch_ptr, scratch_len, query_count) catch |err| return errorCode(err);
    for (queries, 0..) |query, i| {
        zig_queries[i] = .{ .path = constSlice(query.path) catch |err| return errorCode(err) };
    }
    asReader(reader).reader.readPaths(zig_queries) catch |err| return errorCode(err);
    for (zig_queries, 0..) |query, i| {
        queries[i].resolved = @intFromBool(query.resolved);
        if (query.value) |v| {
            queries[i].found = 1;
            queries[i].value = commonToC(v);
        } else {
            queries[i].found = 0;
        }
    }
    return ok();
}

pub export fn bufzilla_inspect(data: BufzillaBytes, output: BufzillaMutableBytes, options: ?*const BufzillaInspectOptions, written: *usize) c_int {
    const input = constSlice(data) catch |err| return errorCode(err);
    const out = mutSlice(output) catch |err| return errorCode(err);
    const opts = if (options) |o| bufzilla.InspectOptions{ .indent_size = o.indent_size, .float_precision = o.float_precision } else bufzilla.InspectOptions{};
    var fixed = Io.Writer.fixed(out);
    var inspector = Inspect.init(input, &fixed, opts);
    inspector.inspect() catch |err| return errorCode(err);
    written.* = fixed.buffered().len;
    return ok();
}

pub export fn bufzilla_path_validate(query_path: BufzillaBytes) u8 {
    const path_slice = constSlice(query_path) catch return 0;
    return @intFromBool(path.validate(path_slice));
}

pub export fn bufzilla_encode_varint(value: u64, output: [*]u8, written: *usize) void {
    const encoded = common.encodeVarInt(value);
    const len: usize = @as(usize, encoded.size) + 1;
    @memcpy(output[0..len], encoded.bytes[0..len]);
    written.* = len;
}

pub export fn bufzilla_decode_varint(bytes: BufzillaBytes, value: *u64) c_int {
    if (bytes.len == 0 or bytes.len > 8) return @intFromEnum(BufzillaStatus.invalid_argument);
    const input = constSlice(bytes) catch |err| return errorCode(err);
    value.* = common.decodeVarInt(input);
    return ok();
}

pub export fn bufzilla_encode_tag(tag: u8, data: u8) u8 {
    return common.encodeTag(@truncate(tag), @truncate(data));
}

pub export fn bufzilla_decode_tag(byte: u8, tag: *u8, data: *u8) void {
    const decoded = common.decodeTag(byte);
    tag.* = decoded.tag;
    data.* = decoded.data;
}

pub export fn bufzilla_typed_array_elem_size(elem: c_int, size: *usize) c_int {
    const typed_elem = typedElem(elem) catch |err| return errorCode(err);
    size.* = common.typedArrayElemSize(typed_elem);
    return ok();
}

pub export fn bufzilla_typed_array_element_to_value(typed_array: BufzillaTypedArray, index: usize, value: *BufzillaValue) c_int {
    const ta = typedArrayFromC(typed_array) catch |err| return errorCode(err);
    const item = common.typedArrayElementToValue(ta, index) catch |err| return errorCode(err);
    value.* = commonToC(item);
    return ok();
}

pub export fn bufzilla_typed_array_copy(typed_array: BufzillaTypedArray, output: BufzillaMutableBytes, written: *usize) c_int {
    const ta = typedArrayFromC(typed_array) catch |err| return errorCode(err);
    const out = mutSlice(output) catch |err| return errorCode(err);
    if (out.len < ta.bytes.len) return @intFromEnum(BufzillaStatus.buffer_too_small);
    @memcpy(out[0..ta.bytes.len], ta.bytes);
    written.* = ta.bytes.len;
    return ok();
}
