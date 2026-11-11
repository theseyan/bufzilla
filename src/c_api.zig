//! C API, exported by the static and dynamic libraries.
//!
//! `include/bufzilla.h` documents the contract. The extern types below mirror it and must stay in
//! sync with it: `test/c_api_abi.c` checks their layout and constants against the header.
//!
//! Every export is a thin wrapper that converts the error of an internal function to a status code.
//! Values coming from C are read once and converted to Zig types up front, so nothing caller-owned
//! is trusted after it has been validated.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const bufzilla = @import("bufzilla");

const common = bufzilla.Common;
const Writer = bufzilla.Writer;
const Reader = bufzilla.Reader(.{});
const Inspect = bufzilla.Inspect(.{});
const Io = std.Io;

// =============================================================================
// ABI types and constants
// =============================================================================

pub const BufzillaStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    buffer_too_small = 2,
    unexpected_eof = 3,
    invalid_tag = 4,
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
    out_of_range = 19,
};

/// `BUFZILLA_VALUE_*` are the tags of the encoding itself.
pub const ValueTag = std.meta.Tag(common.Value);
/// `BUFZILLA_TYPED_ARRAY_*` are the element types of the encoding itself.
pub const TypedArrayElem = common.TypedArrayElem;

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
};

pub const BufzillaUpdate = extern struct {
    path: BufzillaBytes,
    value: BufzillaValue,
};

pub const BufzillaInspectOptions = extern struct {
    indent_size: usize,
    float_precision: usize,
};

pub const sizeof_writer = 64;
pub const sizeof_reader = 64;
pub const BufzillaWriter = extern struct { _opaque: [sizeof_writer / 8]u64 };
pub const BufzillaReader = extern struct { _opaque: [sizeof_reader / 8]u64 };

pub const default_max_array_length = (bufzilla.ApplyUpdatesLimits{}).max_array_length.?;
pub const inspect_defaults: bufzilla.InspectOptions = .{};
pub const version = std.SemanticVersion.parse(build_options.version) catch @compileError("invalid package version");

/// State behind a `bufzilla_writer`. Plain data without interior pointers, so C code may copy it.
const WriterState = extern struct {
    buffer: ?[*]u8,
    capacity: usize,
    written: usize,
};

/// State behind a `bufzilla_reader`. `Reader` holds no interior pointers, so C code may copy it.
const ReaderState = Reader;

comptime {
    std.debug.assert(@sizeOf(WriterState) <= @sizeOf(BufzillaWriter));
    std.debug.assert(@alignOf(WriterState) <= @alignOf(BufzillaWriter));
    std.debug.assert(@sizeOf(ReaderState) <= @sizeOf(BufzillaReader));
    std.debug.assert(@alignOf(ReaderState) <= @alignOf(BufzillaReader));
}

// =============================================================================
// Errors
// =============================================================================

const Error = error{ InvalidArgument, BufferTooSmall, TypeMismatch, OutOfRange } || bufzilla.InspectError || bufzilla.ApplyUpdatesError;

/// Exhaustive, so a new library error fails to compile until it has a status code.
fn statusOf(err: Error) BufzillaStatus {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.BufferTooSmall, error.WriteFailed => .buffer_too_small,
        error.UnexpectedEof => .unexpected_eof,
        error.InvalidEnumTag => .invalid_tag,
        error.InvalidSignedMagnitude => .invalid_signed_magnitude,
        error.UnexpectedContainerEnd => .unexpected_container_end,
        error.MaxDepthExceeded => .max_depth_exceeded,
        error.BytesTooLong => .bytes_too_long,
        error.ArrayTooLarge => .array_too_large,
        error.ObjectTooLarge => .object_too_large,
        error.InvalidRoot => .invalid_root,
        error.MalformedPath => .malformed_path,
        error.PathTypeMismatch => .path_type_mismatch,
        error.ConflictingUpdates => .conflicting_updates,
        error.IndexOutOfRange => .index_out_of_range,
        error.InvalidUtf8 => .invalid_utf8,
        error.NonFiniteFloat => .non_finite_float,
        error.TypeMismatch => .type_mismatch,
        error.OutOfRange => .out_of_range,
    };
}

fn status(result: Error!void) c_int {
    result catch |err| return @backingInt(statusOf(err));
    return @backingInt(BufzillaStatus.ok);
}

// =============================================================================
// Conversions between C and Zig values
// =============================================================================

fn constSlice(bytes: BufzillaBytes) Error![]const u8 {
    if (bytes.len == 0) return &.{};
    const ptr = bytes.ptr orelse return error.InvalidArgument;
    return ptr[0..bytes.len];
}

fn mutSlice(bytes: BufzillaMutableBytes) Error![]u8 {
    if (bytes.len == 0) return &.{};
    const ptr = bytes.ptr orelse return error.InvalidArgument;
    return ptr[0..bytes.len];
}

fn bytesToC(bytes: []const u8) BufzillaBytes {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

fn parseTypedArray(typed_array: BufzillaTypedArray) Error!common.TypedArray {
    const elem = std.enums.fromInt(TypedArrayElem, typed_array.elem) orelse return error.InvalidArgument;
    const bytes = try constSlice(typed_array.bytes);
    const expected = std.math.mul(usize, typed_array.count, common.typedArrayElemSize(elem)) catch return error.InvalidArgument;
    if (bytes.len != expected) return error.InvalidArgument;
    return .{ .elem = elem, .count = typed_array.count, .bytes = bytes };
}

/// Validates a C value against the constraints of its tag and converts it.
fn parseValue(value: BufzillaValue) Error!common.Value {
    const tag = std.enums.fromInt(ValueTag, value.tag) orelse return error.InvalidArgument;
    const data = value.data;
    return switch (tag) {
        .bytes => .{ .bytes = try constSlice(data.bytes) },
        .varIntBytes => .{ .varIntBytes = try constSlice(data.bytes) },
        .smallBytes => blk: {
            const bytes = try constSlice(data.bytes);
            if (bytes.len > 7) return error.InvalidArgument;
            break :blk .{ .smallBytes = bytes };
        },
        .u64 => .{ .u64 = data.u64_value },
        .u32 => .{ .u32 = data.u32_value },
        .u16 => .{ .u16 = data.u16_value },
        .u8 => .{ .u8 = data.u8_value },
        .i64 => .{ .i64 = data.i64_value },
        .i32 => .{ .i32 = data.i32_value },
        .i16 => .{ .i16 = data.i16_value },
        .i8 => .{ .i8 = data.i8_value },
        .f64 => .{ .f64 = data.f64_value },
        .f32 => .{ .f32 = data.f32_value },
        .f16 => .{ .f16 = @bitCast(data.f16_bits) },
        .bool => .{ .bool = switch (data.bool_value) {
            0 => false,
            1 => true,
            else => return error.InvalidArgument,
        } },
        .null => .{ .null = {} },
        .smallIntPositive => if (data.small_value <= 7) .{ .smallIntPositive = data.small_value } else error.InvalidArgument,
        .smallIntNegative => if (data.small_value >= 1 and data.small_value <= 7) .{ .smallIntNegative = data.small_value } else error.InvalidArgument,
        .smallUint => if (data.small_value <= 7) .{ .smallUint = data.small_value } else error.InvalidArgument,
        .varIntSignedPositive => if (data.i64_value >= 0) .{ .varIntSignedPositive = data.i64_value } else error.InvalidArgument,
        .varIntSignedNegative => if (data.i64_value < 0) .{ .varIntSignedNegative = data.i64_value } else error.InvalidArgument,
        .varIntUnsigned => .{ .varIntUnsigned = data.u64_value },
        .array => .{ .array = 0 },
        .object => .{ .object = 0 },
        .containerEnd => .{ .containerEnd = 0 },
        .typedArray => .{ .typedArray = try parseTypedArray(data.typed_array) },
    };
}

fn valueToC(value: common.Value) BufzillaValue {
    var data = std.mem.zeroes(BufzillaValuePayload);
    switch (value) {
        .bytes, .varIntBytes, .smallBytes => |bytes| data.bytes = bytesToC(bytes),
        .u64, .varIntUnsigned => |v| data.u64_value = v,
        .u32 => |v| data.u32_value = v,
        .u16 => |v| data.u16_value = v,
        .u8 => |v| data.u8_value = v,
        .i64, .varIntSignedPositive, .varIntSignedNegative => |v| data.i64_value = v,
        .i32 => |v| data.i32_value = v,
        .i16 => |v| data.i16_value = v,
        .i8 => |v| data.i8_value = v,
        .f64 => |v| data.f64_value = v,
        .f32 => |v| data.f32_value = v,
        .f16 => |v| data.f16_bits = @bitCast(v),
        .bool => |v| data.bool_value = @intFromBool(v),
        .null => {},
        .smallIntPositive, .smallIntNegative, .smallUint => |v| data.small_value = v,
        .array, .object, .containerEnd => |depth| data.container_depth = depth,
        .typedArray => |ta| data.typed_array = .{ .elem = @backingInt(ta.elem), .count = ta.count, .bytes = bytesToC(ta.bytes) },
    }
    return .{ .tag = @backingInt(std.meta.activeTag(value)), .data = data };
}

fn writeValue(writer: *Writer, value: common.Value) Writer.Error!void {
    switch (value) {
        inline else => |_, tag| try writer.write(value, tag),
    }
}

// =============================================================================
// Version and status
// =============================================================================

pub export fn bufzilla_version() u32 {
    return comptime @intCast((version.major << 16) | (version.minor << 8) | version.patch);
}

pub export fn bufzilla_status_string(code: c_int) [*:0]const u8 {
    const s = std.enums.fromInt(BufzillaStatus, code) orelse return "unknown status";
    return switch (s) {
        .ok => "ok",
        .invalid_argument => "invalid argument",
        .buffer_too_small => "buffer too small",
        .unexpected_eof => "unexpected end of input",
        .invalid_tag => "invalid tag",
        .invalid_signed_magnitude => "invalid signed integer magnitude",
        .unexpected_container_end => "unexpected container end",
        .max_depth_exceeded => "maximum nesting depth exceeded",
        .bytes_too_long => "byte string too long",
        .array_too_large => "array too large",
        .object_too_large => "object too large",
        .invalid_root => "root value is not an object",
        .malformed_path => "malformed path",
        .path_type_mismatch => "path does not match the container types in the data",
        .conflicting_updates => "conflicting updates",
        .index_out_of_range => "index out of range",
        .invalid_utf8 => "invalid UTF-8",
        .non_finite_float => "non-finite float",
        .type_mismatch => "type mismatch",
        .out_of_range => "value out of range",
    };
}

// =============================================================================
// Values and typed arrays
// =============================================================================

pub export fn bufzilla_value_as_int(value: ?*const BufzillaValue, out: ?*i64) c_int {
    return status(valueAsInt(value, out));
}

fn valueAsInt(value: ?*const BufzillaValue, out: ?*i64) Error!void {
    const parsed = try parseValue((value orelse return error.InvalidArgument).*);
    const result = out orelse return error.InvalidArgument;
    const wide = common.integerValue(parsed) orelse return error.TypeMismatch;
    result.* = std.math.cast(i64, wide) orelse return error.OutOfRange;
}

pub export fn bufzilla_value_as_uint(value: ?*const BufzillaValue, out: ?*u64) c_int {
    return status(valueAsUint(value, out));
}

fn valueAsUint(value: ?*const BufzillaValue, out: ?*u64) Error!void {
    const parsed = try parseValue((value orelse return error.InvalidArgument).*);
    const result = out orelse return error.InvalidArgument;
    const wide = common.integerValue(parsed) orelse return error.TypeMismatch;
    result.* = std.math.cast(u64, wide) orelse return error.OutOfRange;
}

pub export fn bufzilla_value_as_f64(value: ?*const BufzillaValue, out: ?*f64) c_int {
    return status(valueAsF64(value, out));
}

fn valueAsF64(value: ?*const BufzillaValue, out: ?*f64) Error!void {
    const parsed = try parseValue((value orelse return error.InvalidArgument).*);
    const result = out orelse return error.InvalidArgument;
    result.* = switch (parsed) {
        .f64 => |v| v,
        .f32 => |v| v,
        .f16 => |v| v,
        else => return error.TypeMismatch,
    };
}

pub export fn bufzilla_value_as_bytes(value: ?*const BufzillaValue, out: ?*BufzillaBytes) c_int {
    return status(valueAsBytes(value, out));
}

fn valueAsBytes(value: ?*const BufzillaValue, out: ?*BufzillaBytes) Error!void {
    const parsed = try parseValue((value orelse return error.InvalidArgument).*);
    const result = out orelse return error.InvalidArgument;
    result.* = switch (parsed) {
        .bytes, .varIntBytes, .smallBytes => |bytes| bytesToC(bytes),
        else => return error.TypeMismatch,
    };
}

pub export fn bufzilla_typed_array_elem_size(elem: c_int) usize {
    return common.typedArrayElemSize(std.enums.fromInt(TypedArrayElem, elem) orelse return 0);
}

pub export fn bufzilla_typed_array_get(typed_array: ?*const BufzillaTypedArray, index: usize, value: ?*BufzillaValue) c_int {
    return status(typedArrayGet(typed_array, index, value));
}

fn typedArrayGet(typed_array: ?*const BufzillaTypedArray, index: usize, value: ?*BufzillaValue) Error!void {
    const ta = try parseTypedArray((typed_array orelse return error.InvalidArgument).*);
    const result = value orelse return error.InvalidArgument;
    const element = common.typedArrayElementToValue(ta, index) catch |err| return switch (err) {
        error.IndexOutOfBounds => error.IndexOutOfRange,
        error.LengthMismatch => error.InvalidArgument,
    };
    result.* = valueToC(element);
}

pub export fn bufzilla_typed_array_copy(typed_array: ?*const BufzillaTypedArray, output: BufzillaMutableBytes) c_int {
    return status(typedArrayCopy(typed_array, output));
}

fn typedArrayCopy(typed_array: ?*const BufzillaTypedArray, output: BufzillaMutableBytes) Error!void {
    const ta = try parseTypedArray((typed_array orelse return error.InvalidArgument).*);
    const out = try mutSlice(output);
    if (out.len < ta.bytes.len) return error.BufferTooSmall;
    const dest = out[0..ta.bytes.len];
    @memmove(dest, ta.bytes);
    // The payload is little-endian.
    if (builtin.cpu.arch.endian() == .big) {
        const size = common.typedArrayElemSize(ta.elem);
        var offset: usize = 0;
        while (offset < dest.len) : (offset += size) std.mem.reverse(u8, dest[offset..][0..size]);
    }
}

// =============================================================================
// Writer
// =============================================================================

fn writerState(writer: ?*BufzillaWriter) Error!*WriterState {
    return @ptrCast(@alignCast(writer orelse return error.InvalidArgument));
}

/// Calls `op(&writer, args...)` with a writer over the state's buffer. The output is committed only
/// if `op` succeeds, so a failed write leaves the state unchanged.
fn writeWith(handle: ?*BufzillaWriter, comptime op: anytype, args: anytype) Error!void {
    const state = try writerState(handle);
    // Catches some uses of a writer that was never initialized.
    if (state.written > state.capacity or (state.buffer == null and state.capacity != 0)) return error.InvalidArgument;
    const buffer: []u8 = if (state.buffer) |ptr| ptr[0..state.capacity] else &.{};
    var io: Io.Writer = .fixed(buffer);
    io.end = state.written;
    var writer = Writer.init(&io);
    try @call(.auto, op, .{&writer} ++ args);
    state.written = io.end;
}

pub export fn bufzilla_writer_init(writer: ?*BufzillaWriter, buffer: BufzillaMutableBytes) c_int {
    return status(writerInit(writer, buffer));
}

fn writerInit(writer: ?*BufzillaWriter, buffer: BufzillaMutableBytes) Error!void {
    const state = try writerState(writer);
    const out = try mutSlice(buffer);
    state.* = .{ .buffer = out.ptr, .capacity = out.len, .written = 0 };
}

pub export fn bufzilla_writer_written(writer: ?*const BufzillaWriter) usize {
    const state: *const WriterState = @ptrCast(@alignCast(writer orelse return 0));
    return state.written;
}

pub export fn bufzilla_writer_write_null(writer: ?*BufzillaWriter) c_int {
    return status(writeWith(writer, Writer.writeAny, .{null}));
}

pub export fn bufzilla_writer_write_bool(writer: ?*BufzillaWriter, value: bool) c_int {
    return status(writeWith(writer, Writer.writeAny, .{value}));
}

pub export fn bufzilla_writer_write_int(writer: ?*BufzillaWriter, value: i64) c_int {
    return status(writeWith(writer, Writer.writeAny, .{value}));
}

pub export fn bufzilla_writer_write_uint(writer: ?*BufzillaWriter, value: u64) c_int {
    return status(writeWith(writer, Writer.writeAny, .{value}));
}

pub export fn bufzilla_writer_write_f64(writer: ?*BufzillaWriter, value: f64) c_int {
    return status(writeWith(writer, Writer.writeAny, .{value}));
}

pub export fn bufzilla_writer_write_f32(writer: ?*BufzillaWriter, value: f32) c_int {
    return status(writeWith(writer, Writer.writeAny, .{value}));
}

pub export fn bufzilla_writer_write_bytes(writer: ?*BufzillaWriter, bytes: BufzillaBytes) c_int {
    return status(writeBytes(writer, bytes));
}

fn writeBytes(writer: ?*BufzillaWriter, bytes: BufzillaBytes) Error!void {
    try writeWith(writer, Writer.writeAny, .{try constSlice(bytes)});
}

pub export fn bufzilla_writer_write_typed_array(writer: ?*BufzillaWriter, elem: c_int, values: ?*const anyopaque, count: usize) c_int {
    return status(writeTypedArray(writer, elem, values, count));
}

fn writeTypedArray(writer: ?*BufzillaWriter, elem: c_int, values: ?*const anyopaque, count: usize) Error!void {
    const typed_elem = std.enums.fromInt(TypedArrayElem, elem) orelse return error.InvalidArgument;
    _ = std.math.mul(usize, count, common.typedArrayElemSize(typed_elem)) catch return error.InvalidArgument;
    switch (typed_elem) {
        inline else => |e| {
            const T = common.TypedArrayElemType(e);
            const items: []align(1) const T = if (count == 0) &.{} else blk: {
                const ptr: [*]align(1) const T = @ptrCast(values orelse return error.InvalidArgument);
                break :blk ptr[0..count];
            };
            try writeWith(writer, Writer.writeTypedArray, .{items});
        },
    }
}

pub export fn bufzilla_writer_start_array(writer: ?*BufzillaWriter) c_int {
    return status(writeWith(writer, Writer.startArray, .{}));
}

pub export fn bufzilla_writer_start_object(writer: ?*BufzillaWriter) c_int {
    return status(writeWith(writer, Writer.startObject, .{}));
}

pub export fn bufzilla_writer_end_container(writer: ?*BufzillaWriter) c_int {
    return status(writeWith(writer, Writer.endContainer, .{}));
}

pub export fn bufzilla_writer_write_value(writer: ?*BufzillaWriter, value: ?*const BufzillaValue) c_int {
    return status(writeValueC(writer, value));
}

fn writeValueC(writer: ?*BufzillaWriter, value: ?*const BufzillaValue) Error!void {
    const parsed = try parseValue((value orelse return error.InvalidArgument).*);
    try writeWith(writer, writeValue, .{parsed});
}

// =============================================================================
// Reader
// =============================================================================

fn readerState(reader: ?*BufzillaReader) Error!*ReaderState {
    return @ptrCast(@alignCast(reader orelse return error.InvalidArgument));
}

/// The state of a reader that must already be initialized.
fn initializedReader(reader: ?*BufzillaReader) Error!*ReaderState {
    const state = try readerState(reader);
    // Catches some uses of a reader that was never initialized.
    if (state.pos > state.bytes.len) return error.InvalidArgument;
    return state;
}

/// Returns the depth of a container value the reader can iterate, which must still be open.
fn openContainerDepth(reader: *const ReaderState, container: BufzillaValue, tag: ValueTag) Error!u32 {
    if (container.tag != @backingInt(tag)) return error.InvalidArgument;
    const depth = container.data.container_depth;
    if (depth == 0 or depth > reader.depth) return error.InvalidArgument;
    return depth;
}

pub export fn bufzilla_reader_init(reader: ?*BufzillaReader, data: BufzillaBytes) c_int {
    return status(readerInit(reader, data));
}

fn readerInit(reader: ?*BufzillaReader, data: BufzillaBytes) Error!void {
    const state = try readerState(reader);
    state.* = .init(try constSlice(data));
}

pub export fn bufzilla_reader_position(reader: ?*const BufzillaReader) usize {
    const state: *const ReaderState = @ptrCast(@alignCast(reader orelse return 0));
    return state.pos;
}

pub export fn bufzilla_reader_read(reader: ?*BufzillaReader, value: ?*BufzillaValue) c_int {
    return status(readerRead(reader, value));
}

fn readerRead(reader: ?*BufzillaReader, value: ?*BufzillaValue) Error!void {
    const state = try initializedReader(reader);
    const result = value orelse return error.InvalidArgument;
    const saved = state.*;
    errdefer state.* = saved;
    result.* = valueToC(try state.read());
}

pub export fn bufzilla_reader_skip_value(reader: ?*BufzillaReader) c_int {
    return status(readerSkipValue(reader));
}

fn readerSkipValue(reader: ?*BufzillaReader) Error!void {
    const state = try initializedReader(reader);
    const saved = state.*;
    errdefer state.* = saved;
    try state.skipValue();
}

pub export fn bufzilla_reader_iterate_object(reader: ?*BufzillaReader, object: ?*const BufzillaValue, key: ?*BufzillaValue, value: ?*BufzillaValue, has_next: ?*bool) c_int {
    return status(readerIterateObject(reader, object, key, value, has_next));
}

fn readerIterateObject(reader: ?*BufzillaReader, object: ?*const BufzillaValue, key: ?*BufzillaValue, value: ?*BufzillaValue, has_next: ?*bool) Error!void {
    const state = try initializedReader(reader);
    const depth = try openContainerDepth(state, (object orelse return error.InvalidArgument).*, .object);
    const key_out = key orelse return error.InvalidArgument;
    const value_out = value orelse return error.InvalidArgument;
    const has_next_out = has_next orelse return error.InvalidArgument;

    const saved = state.*;
    errdefer state.* = saved;
    if (try state.iterateObject(.{ .object = depth })) |entry| {
        key_out.* = valueToC(entry.key);
        value_out.* = valueToC(entry.value);
        has_next_out.* = true;
    } else {
        has_next_out.* = false;
    }
}

pub export fn bufzilla_reader_iterate_array(reader: ?*BufzillaReader, array: ?*const BufzillaValue, value: ?*BufzillaValue, has_next: ?*bool) c_int {
    return status(readerIterateArray(reader, array, value, has_next));
}

fn readerIterateArray(reader: ?*BufzillaReader, array: ?*const BufzillaValue, value: ?*BufzillaValue, has_next: ?*bool) Error!void {
    const state = try initializedReader(reader);
    const depth = try openContainerDepth(state, (array orelse return error.InvalidArgument).*, .array);
    const value_out = value orelse return error.InvalidArgument;
    const has_next_out = has_next orelse return error.InvalidArgument;

    const saved = state.*;
    errdefer state.* = saved;
    if (try state.iterateArray(.{ .array = depth })) |item| {
        value_out.* = valueToC(item);
        has_next_out.* = true;
    } else {
        has_next_out.* = false;
    }
}

pub export fn bufzilla_reader_read_path(reader: ?*BufzillaReader, path: BufzillaBytes, value: ?*BufzillaValue, found: ?*bool) c_int {
    return status(readerReadPath(reader, path, value, found));
}

fn readerReadPath(reader: ?*BufzillaReader, path: BufzillaBytes, value: ?*BufzillaValue, found: ?*bool) Error!void {
    const state = try initializedReader(reader);
    const path_slice = try constSlice(path);
    const value_out = value orelse return error.InvalidArgument;
    const found_out = found orelse return error.InvalidArgument;
    // `readPath` restores the reader's position itself.
    if (try state.readPath(path_slice)) |result| {
        value_out.* = valueToC(result);
        found_out.* = true;
    } else {
        found_out.* = false;
    }
}

pub export fn bufzilla_reader_read_paths_scratch_size(query_count: usize) usize {
    return scratchSize(&.{bufzilla.PathQuery}, query_count);
}

pub export fn bufzilla_reader_read_paths(reader: ?*BufzillaReader, queries: ?[*]BufzillaPathQuery, query_count: usize, scratch: ?*anyopaque, scratch_size: usize) c_int {
    return status(readerReadPaths(reader, queries, query_count, scratch, scratch_size));
}

fn readerReadPaths(reader: ?*BufzillaReader, queries_ptr: ?[*]BufzillaPathQuery, query_count: usize, scratch_ptr: ?*anyopaque, scratch_size: usize) Error!void {
    const state = try initializedReader(reader);
    if (query_count == 0) return;
    const queries = (queries_ptr orelse return error.InvalidArgument)[0..query_count];
    var scratch = try scratchSlice(scratch_ptr, scratch_size);
    const zig_queries = try carve(bufzilla.PathQuery, &scratch, query_count);

    for (queries, zig_queries) |*query, *zig_query| zig_query.* = .{ .path = try constSlice(query.path) };
    // `readPaths` restores the reader's position itself.
    try state.readPaths(zig_queries);
    for (queries, zig_queries) |*query, zig_query| {
        if (zig_query.value) |result| {
            query.value = valueToC(result);
            query.found = 1;
        } else {
            query.found = 0;
        }
    }
}

pub export fn bufzilla_path_validate(path: BufzillaBytes) bool {
    return bufzilla.Path.validate(constSlice(path) catch return false);
}

// =============================================================================
// Scratch memory
// =============================================================================

fn scratchSlice(ptr: ?*anyopaque, len: usize) Error![]u8 {
    if (len == 0) return &.{};
    const bytes: [*]u8 = @ptrCast(ptr orelse return error.InvalidArgument);
    return bytes[0..len];
}

/// The scratch size needed for `count` items of each type, including slack to align each array,
/// so callers can pass any buffer. Saturates at `maxInt(usize)`.
fn scratchSize(comptime types: []const type, count: usize) usize {
    var total: usize = 0;
    inline for (types) |T| {
        const bytes = std.math.mul(usize, @sizeOf(T), count) catch return std.math.maxInt(usize);
        total = std.math.add(usize, total, bytes) catch return std.math.maxInt(usize);
        total = std.math.add(usize, total, @alignOf(T) - 1) catch return std.math.maxInt(usize);
    }
    return total;
}

/// Takes an aligned array of `count` items of `T` from the front of `scratch`.
fn carve(comptime T: type, scratch: *[]u8, count: usize) Error![]T {
    if (count == 0) return &.{};
    const padding = std.mem.alignPointerOffset(scratch.ptr, @alignOf(T)) orelse return error.BufferTooSmall;
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.BufferTooSmall;
    if (padding > scratch.len or bytes > scratch.len - padding) return error.BufferTooSmall;
    const items: [*]T = @ptrCast(@alignCast(scratch.ptr + padding));
    scratch.* = scratch.*[padding + bytes ..];
    return items[0..count];
}

// =============================================================================
// Updates
// =============================================================================

pub export fn bufzilla_apply_updates_scratch_size(update_count: usize) usize {
    return scratchSize(&.{ common.Value, Writer.Update }, update_count);
}

pub export fn bufzilla_apply_updates(
    encoded: BufzillaBytes,
    updates: ?[*]const BufzillaUpdate,
    update_count: usize,
    max_array_length: usize,
    scratch: ?*anyopaque,
    scratch_size: usize,
    output: BufzillaMutableBytes,
    written: ?*usize,
) c_int {
    return status(applyUpdates(encoded, updates, update_count, max_array_length, scratch, scratch_size, output, written));
}

fn applyUpdates(
    encoded: BufzillaBytes,
    updates_ptr: ?[*]const BufzillaUpdate,
    update_count: usize,
    max_array_length: usize,
    scratch_ptr: ?*anyopaque,
    scratch_size: usize,
    output: BufzillaMutableBytes,
    written: ?*usize,
) Error!void {
    const encoded_slice = try constSlice(encoded);
    const out = try mutSlice(output);
    const written_out = written orelse return error.InvalidArgument;
    const updates: []const BufzillaUpdate = if (update_count == 0) &.{} else (updates_ptr orelse return error.InvalidArgument)[0..update_count];

    // Updates are converted into scratch memory: the values first, then the updates that refer to them.
    var scratch = try scratchSlice(scratch_ptr, scratch_size);
    const values = try carve(common.Value, &scratch, update_count);
    const zig_updates = try carve(Writer.Update, &scratch, update_count);
    for (updates, values, zig_updates) |*update_ptr, *value, *zig_update| {
        const update = update_ptr.*;
        value.* = try parseValue(update.value);
        // A lone container tag would leave the output unbalanced.
        switch (value.*) {
            .array, .object, .containerEnd => return error.InvalidArgument,
            else => {},
        }
        zig_update.* = .{ .path = try constSlice(update.path), .ctx = value, .writeFn = writeUpdateValue };
    }

    var io: Io.Writer = .fixed(out);
    var writer = Writer.init(&io);
    try writer.applyUpdatesWithLimits(encoded_slice, zig_updates, .{ .max_array_length = max_array_length });
    written_out.* = io.end;
}

fn writeUpdateValue(writer: *Writer, ctx: *const anyopaque) Writer.Error!void {
    const value: *const common.Value = @ptrCast(@alignCast(ctx));
    try writeValue(writer, value.*);
}

// =============================================================================
// JSON rendering
// =============================================================================

pub export fn bufzilla_inspect(data: BufzillaBytes, options: ?*const BufzillaInspectOptions, output: BufzillaMutableBytes, written: ?*usize) c_int {
    return status(inspect(data, options, output, written));
}

fn inspect(data: BufzillaBytes, options: ?*const BufzillaInspectOptions, output: BufzillaMutableBytes, written: ?*usize) Error!void {
    const input = try constSlice(data);
    const out = try mutSlice(output);
    const written_out = written orelse return error.InvalidArgument;
    const inspect_options: bufzilla.InspectOptions = if (options) |o| .{
        .indent_size = o.indent_size,
        .float_precision = o.float_precision,
    } else .{};

    var io: Io.Writer = .fixed(out);
    var inspector = Inspect.init(input, &io, inspect_options);
    try inspector.inspect();
    written_out.* = io.end;
}
