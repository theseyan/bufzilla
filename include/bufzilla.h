/*
 * bufzilla C API
 *
 * Conventions
 * - Functions that can fail return a bufzilla_status: BUFZILLA_OK (0) on
 *   success, an error code otherwise. On error, out-parameters are left
 *   unchanged, but output buffers may hold partial data.
 * - Pointer parameters must not be NULL unless documented as optional; a NULL
 *   pointer returns BUFZILLA_INVALID_ARGUMENT. A byte span may have a NULL ptr
 *   only when its len is 0.
 * - The library never allocates. Callers provide all state, output buffers and
 *   scratch memory, and keep ownership of them. Output buffers and scratch
 *   memory must not overlap any input.
 * - Decoding is zero-copy: bytes and typed array payloads in a decoded
 *   bufzilla_value point into the buffer being read, and are valid as long as
 *   that buffer is.
 * - Distinct objects may be used from different threads at the same time. A
 *   single bufzilla_writer or bufzilla_reader must not be.
 */
#ifndef BUFZILLA_H
#define BUFZILLA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------ */
/* Version                                                                   */
/* ------------------------------------------------------------------------ */

#define BUFZILLA_VERSION_MAJOR 0
#define BUFZILLA_VERSION_MINOR 5
#define BUFZILLA_VERSION_PATCH 0
#define BUFZILLA_VERSION ((BUFZILLA_VERSION_MAJOR << 16) | (BUFZILLA_VERSION_MINOR << 8) | BUFZILLA_VERSION_PATCH)

/* Returns the version of the linked library, encoded like BUFZILLA_VERSION.
 * Compare the two to detect a mismatch between this header and the library. */
uint32_t bufzilla_version(void);

/* ------------------------------------------------------------------------ */
/* Status codes                                                              */
/* ------------------------------------------------------------------------ */

typedef int bufzilla_status;
enum {
    BUFZILLA_OK = 0,
    /* A NULL pointer, unknown enum value, or inconsistent value or length. */
    BUFZILLA_INVALID_ARGUMENT = 1,
    /* An output buffer or scratch memory is too small. */
    BUFZILLA_BUFFER_TOO_SMALL = 2,
    /* Malformed or hostile encoded data. */
    BUFZILLA_UNEXPECTED_EOF = 3,
    BUFZILLA_INVALID_TAG = 4,
    BUFZILLA_INVALID_SIGNED_MAGNITUDE = 5,
    BUFZILLA_UNEXPECTED_CONTAINER_END = 6,
    BUFZILLA_MAX_DEPTH_EXCEEDED = 7,
    BUFZILLA_BYTES_TOO_LONG = 8,
    BUFZILLA_ARRAY_TOO_LARGE = 9,
    BUFZILLA_OBJECT_TOO_LARGE = 10,
    /* Updates and paths. */
    BUFZILLA_INVALID_ROOT = 11,
    BUFZILLA_MALFORMED_PATH = 12,
    BUFZILLA_PATH_TYPE_MISMATCH = 13,
    BUFZILLA_CONFLICTING_UPDATES = 14,
    BUFZILLA_INDEX_OUT_OF_RANGE = 15,
    /* JSON rendering. */
    BUFZILLA_INVALID_UTF8 = 16,
    BUFZILLA_NON_FINITE_FLOAT = 17,
    /* Value conversion, or an update to a typed array element that is not a
     * number fitting the element type. */
    BUFZILLA_TYPE_MISMATCH = 18,
    BUFZILLA_OUT_OF_RANGE = 19
};

/* Returns a static, human-readable description of a status code. */
const char *bufzilla_status_string(bufzilla_status status);

/* ------------------------------------------------------------------------ */
/* Values                                                                    */
/* ------------------------------------------------------------------------ */

typedef struct {
    const uint8_t *ptr;
    size_t len;
} bufzilla_bytes;

typedef struct {
    uint8_t *ptr;
    size_t len;
} bufzilla_mutable_bytes;

static inline bufzilla_bytes bufzilla_bytes_of(const void *ptr, size_t len) {
    bufzilla_bytes bytes;
    bytes.ptr = (const uint8_t *)ptr;
    bytes.len = len;
    return bytes;
}

static inline bufzilla_mutable_bytes bufzilla_mutable_bytes_of(void *ptr, size_t len) {
    bufzilla_mutable_bytes bytes;
    bytes.ptr = (uint8_t *)ptr;
    bytes.len = len;
    return bytes;
}

/* Value tags. The reader only produces BYTES, the fixed-width numeric tags,
 * BOOL, NULL, ARRAY, OBJECT, CONTAINER_END and TYPED_ARRAY: compact integer and
 * byte encodings are decoded to I64, U64 and BYTES. The remaining tags select a
 * specific encoding when writing with bufzilla_writer_write_value. */
typedef int bufzilla_value_tag;
enum {
    BUFZILLA_VALUE_BYTES = 0,                   /* data.bytes, 8-byte length */
    BUFZILLA_VALUE_VAR_INT_BYTES = 1,           /* data.bytes, varint length */
    BUFZILLA_VALUE_SMALL_BYTES = 2,             /* data.bytes, at most 7 bytes */
    BUFZILLA_VALUE_U64 = 3,                     /* data.u64_value */
    BUFZILLA_VALUE_U32 = 4,                     /* data.u32_value */
    BUFZILLA_VALUE_U16 = 5,                     /* data.u16_value */
    BUFZILLA_VALUE_U8 = 6,                      /* data.u8_value */
    BUFZILLA_VALUE_I64 = 7,                     /* data.i64_value */
    BUFZILLA_VALUE_I32 = 8,                     /* data.i32_value */
    BUFZILLA_VALUE_I16 = 9,                     /* data.i16_value */
    BUFZILLA_VALUE_I8 = 10,                     /* data.i8_value */
    BUFZILLA_VALUE_F64 = 11,                    /* data.f64_value */
    BUFZILLA_VALUE_F32 = 12,                    /* data.f32_value */
    BUFZILLA_VALUE_F16 = 13,                    /* data.f16_bits, IEEE 754 binary16 */
    BUFZILLA_VALUE_BOOL = 14,                   /* data.bool_value, 0 or 1 */
    BUFZILLA_VALUE_NULL = 15,
    BUFZILLA_VALUE_SMALL_INT_POSITIVE = 16,     /* data.small_value, 0..7 */
    BUFZILLA_VALUE_SMALL_INT_NEGATIVE = 17,     /* data.small_value, magnitude 1..7 */
    BUFZILLA_VALUE_SMALL_UINT = 18,             /* data.small_value, 0..7 */
    BUFZILLA_VALUE_VAR_INT_SIGNED_POSITIVE = 19, /* data.i64_value, >= 0 */
    BUFZILLA_VALUE_VAR_INT_SIGNED_NEGATIVE = 20, /* data.i64_value, < 0 */
    BUFZILLA_VALUE_VAR_INT_UNSIGNED = 21,       /* data.u64_value */
    BUFZILLA_VALUE_ARRAY = 22,                  /* data.container_depth */
    BUFZILLA_VALUE_OBJECT = 23,                 /* data.container_depth */
    BUFZILLA_VALUE_CONTAINER_END = 24,          /* data.container_depth */
    BUFZILLA_VALUE_TYPED_ARRAY = 25             /* data.typed_array */
};

typedef int bufzilla_typed_array_elem;
enum {
    BUFZILLA_TYPED_ARRAY_U8 = 0,
    BUFZILLA_TYPED_ARRAY_I8 = 1,
    BUFZILLA_TYPED_ARRAY_U16 = 2,
    BUFZILLA_TYPED_ARRAY_I16 = 3,
    BUFZILLA_TYPED_ARRAY_U32 = 4,
    BUFZILLA_TYPED_ARRAY_I32 = 5,
    BUFZILLA_TYPED_ARRAY_U64 = 6,
    BUFZILLA_TYPED_ARRAY_I64 = 7,
    BUFZILLA_TYPED_ARRAY_F16 = 8,
    BUFZILLA_TYPED_ARRAY_F32 = 9,
    BUFZILLA_TYPED_ARRAY_F64 = 10
};

/* A packed numeric array as stored in the encoding: bytes holds count
 * little-endian elements, so bytes.len == count * element size. Use
 * bufzilla_typed_array_copy to get native-endian elements. */
typedef struct {
    bufzilla_typed_array_elem elem;
    size_t count;
    bufzilla_bytes bytes;
} bufzilla_typed_array;

typedef union {
    bufzilla_bytes bytes;
    bufzilla_typed_array typed_array;
    uint64_t u64_value;
    uint32_t u32_value;
    uint16_t u16_value;
    uint8_t u8_value;
    int64_t i64_value;
    int32_t i32_value;
    int16_t i16_value;
    int8_t i8_value;
    double f64_value;
    float f32_value;
    uint16_t f16_bits;
    uint8_t bool_value;
    uint8_t small_value;
    uint32_t container_depth;
} bufzilla_value_payload;

typedef struct {
    bufzilla_value_tag tag;
    bufzilla_value_payload data;
} bufzilla_value;

/* Convert a value to a C type, accepting every encoding of that type.
 * Return BUFZILLA_TYPE_MISMATCH for a value of another type, and
 * BUFZILLA_OUT_OF_RANGE for an integer that does not fit. as_f64 accepts
 * floats only, as_bytes accepts byte strings only. */
bufzilla_status bufzilla_value_as_int(const bufzilla_value *value, int64_t *out);
bufzilla_status bufzilla_value_as_uint(const bufzilla_value *value, uint64_t *out);
bufzilla_status bufzilla_value_as_f64(const bufzilla_value *value, double *out);
bufzilla_status bufzilla_value_as_bytes(const bufzilla_value *value, bufzilla_bytes *out);

/* Returns the size in bytes of one element, or 0 for an unknown elem. */
size_t bufzilla_typed_array_elem_size(bufzilla_typed_array_elem elem);

/* Reads element index of a typed array as a value with the matching
 * fixed-width tag. Returns BUFZILLA_INDEX_OUT_OF_RANGE if index >= count. */
bufzilla_status bufzilla_typed_array_get(const bufzilla_typed_array *typed_array, size_t index, bufzilla_value *value);

/* Copies all elements of a typed array to output in native byte order.
 * output.len must be at least count * element size; output need not be aligned. */
bufzilla_status bufzilla_typed_array_copy(const bufzilla_typed_array *typed_array, bufzilla_mutable_bytes output);

/* ------------------------------------------------------------------------ */
/* Writer                                                                    */
/* ------------------------------------------------------------------------ */

/* Writer and reader state. Place them anywhere (stack, heap or inside your
 * own structs) and initialize them before use. Both are plain data: copying
 * one takes a snapshot of its position, which you can restore by copying it
 * back. Copies of a writer share its output buffer. */
#define BUFZILLA_SIZEOF_WRITER 64
#define BUFZILLA_SIZEOF_READER 64
typedef struct { uint64_t _opaque[BUFZILLA_SIZEOF_WRITER / 8]; } bufzilla_writer;
typedef struct { uint64_t _opaque[BUFZILLA_SIZEOF_READER / 8]; } bufzilla_reader;

/* Prepares writer to encode into buffer. */
bufzilla_status bufzilla_writer_init(bufzilla_writer *writer, bufzilla_mutable_bytes buffer);

/* Returns the number of bytes written so far: the encoding is the first
 * bufzilla_writer_written() bytes of the buffer. Returns 0 for NULL. */
size_t bufzilla_writer_written(const bufzilla_writer *writer);

/* The functions below write one item each. A failed write leaves the writer
 * unchanged, so BUFZILLA_BUFFER_TOO_SMALL never leaves a partial item behind.
 * Integers, byte strings and typed array counts use the most compact
 * encoding. Containers are written as start_array/start_object, their
 * entries, and end_container; object entries are written as a key followed by
 * its value. */
bufzilla_status bufzilla_writer_write_null(bufzilla_writer *writer);
bufzilla_status bufzilla_writer_write_bool(bufzilla_writer *writer, bool value);
bufzilla_status bufzilla_writer_write_int(bufzilla_writer *writer, int64_t value);
bufzilla_status bufzilla_writer_write_uint(bufzilla_writer *writer, uint64_t value);
bufzilla_status bufzilla_writer_write_f64(bufzilla_writer *writer, double value);
bufzilla_status bufzilla_writer_write_f32(bufzilla_writer *writer, float value);
bufzilla_status bufzilla_writer_write_bytes(bufzilla_writer *writer, bufzilla_bytes bytes);

/* Writes count native-endian elements of type elem from values as a typed
 * array. values need not be aligned, and may be NULL when count is 0. */
bufzilla_status bufzilla_writer_write_typed_array(bufzilla_writer *writer, bufzilla_typed_array_elem elem, const void *values, size_t count);

bufzilla_status bufzilla_writer_start_array(bufzilla_writer *writer);
bufzilla_status bufzilla_writer_start_object(bufzilla_writer *writer);
bufzilla_status bufzilla_writer_end_container(bufzilla_writer *writer);

/* Writes value with exactly the encoding its tag selects. Returns
 * BUFZILLA_INVALID_ARGUMENT if the payload is out of range for the tag (see
 * the value tag list). ARRAY, OBJECT and CONTAINER_END start or end a
 * container; their payload is ignored. A typed array payload is written as-is,
 * so its bytes must already be little-endian. */
bufzilla_status bufzilla_writer_write_value(bufzilla_writer *writer, const bufzilla_value *value);

/* ------------------------------------------------------------------------ */
/* Reader                                                                    */
/* ------------------------------------------------------------------------ */

/* The reader enforces a maximum nesting depth of 2048. Lengths and counts are
 * checked against the input, so a hostile length cannot read out of bounds.
 * A failed read leaves the reader unchanged. */

/* Prepares reader to decode data, which must outlive the reader and every
 * value read from it. */
bufzilla_status bufzilla_reader_init(bufzilla_reader *reader, bufzilla_bytes data);

/* Returns the byte offset of the next item. Returns 0 for NULL. */
size_t bufzilla_reader_position(const bufzilla_reader *reader);

/* Reads the next item. For ARRAY and OBJECT, the reader moves inside the
 * container: read its entries with the iterate functions. */
bufzilla_status bufzilla_reader_read(bufzilla_reader *reader, bufzilla_value *value);

/* Skips the next item, including everything nested in it. */
bufzilla_status bufzilla_reader_skip_value(bufzilla_reader *reader);

/* Read the next entry of an object or array returned by bufzilla_reader_read
 * or by an iterate function on the same reader (not by read_path, whose
 * values come from a separate traversal). *has_next is set to true when an
 * entry was read, and to false once the container has ended. Entries the
 * caller did not read are skipped, so nested containers need not be iterated.
 * A container may only be iterated until it ends: afterwards this returns
 * BUFZILLA_INVALID_ARGUMENT, unless another container has since been opened
 * at the same depth, which cannot be told apart from it. */
bufzilla_status bufzilla_reader_iterate_object(bufzilla_reader *reader, const bufzilla_value *object, bufzilla_value *key, bufzilla_value *value, bool *has_next);
bufzilla_status bufzilla_reader_iterate_array(bufzilla_reader *reader, const bufzilla_value *array, bufzilla_value *value, bool *has_next);

/* Looks up a path such as "users[2].name" or "data['key.with.dots']" from the
 * root of the input. The reader does not move. *found is set to false if the
 * path does not exist, is malformed, or crosses a value of the wrong type. An
 * empty path returns the root value. Paths have at most BUFZILLA_MAX_PATH_SEGMENTS
 * segments; longer paths count as malformed. */
#define BUFZILLA_MAX_PATH_SEGMENTS 64
bufzilla_status bufzilla_reader_read_path(bufzilla_reader *reader, bufzilla_bytes path, bufzilla_value *value, bool *found);

typedef struct {
    bufzilla_bytes path;   /* in */
    bufzilla_value value;  /* out: set when found is 1 */
    uint8_t found;         /* out: 1 if the path was found, 0 otherwise */
} bufzilla_path_query;

/* Returns the scratch size bufzilla_reader_read_paths needs for query_count
 * queries, or SIZE_MAX if that overflows. */
size_t bufzilla_reader_read_paths_scratch_size(size_t query_count);

/* Looks up several paths in one pass over the input (per 256 queries), like
 * read_path for each.
 * scratch need not be aligned; it may be NULL when query_count is 0. On error,
 * the queries are left unchanged. */
bufzilla_status bufzilla_reader_read_paths(bufzilla_reader *reader, bufzilla_path_query *queries, size_t query_count, void *scratch, size_t scratch_size);

/* Returns true if path is well-formed and has at most
 * BUFZILLA_MAX_PATH_SEGMENTS segments. */
bool bufzilla_path_validate(bufzilla_bytes path);

/* ------------------------------------------------------------------------ */
/* Updates                                                                   */
/* ------------------------------------------------------------------------ */

typedef struct {
    bufzilla_bytes path;
    /* Any value accepted by bufzilla_writer_write_value except ARRAY, OBJECT
     * and CONTAINER_END. */
    bufzilla_value value;
} bufzilla_update;

/* The default limit on the length of arrays created or extended by updates. */
#define BUFZILLA_DEFAULT_MAX_ARRAY_LENGTH ((size_t)1 << 20)

/* Returns the scratch size bufzilla_apply_updates needs for update_count
 * updates, or SIZE_MAX if that overflows. */
size_t bufzilla_apply_updates_scratch_size(size_t update_count);

/* Writes encoded to output with updates applied, in a single pass. Updates
 * replace values at their paths and create missing keys and array elements,
 * padding new array slots with null. If several updates target the same path,
 * the last one wins. The root of encoded must be an object, unless every
 * update has the empty path, which replaces the whole document; with no
 * updates, encoded is copied unchanged. An update to an element of a typed
 * array must be a number that fits the element type, or BUFZILLA_TYPE_MISMATCH
 * is returned; typed arrays cannot be extended (BUFZILLA_INDEX_OUT_OF_RANGE).
 *
 * max_array_length caps the length of arrays created or extended by updates,
 * guarding against huge output from untrusted paths: exceeding it returns
 * BUFZILLA_ARRAY_TOO_LARGE. Arrays that are not extended are not limited.
 * Pass BUFZILLA_DEFAULT_MAX_ARRAY_LENGTH by default, 0 to forbid extending
 * arrays, or SIZE_MAX for no limit.
 *
 * scratch need not be aligned; it may be NULL when update_count is 0. On
 * success, *written is the encoding length. On error, output may hold a
 * partial encoding. */
bufzilla_status bufzilla_apply_updates(bufzilla_bytes encoded, const bufzilla_update *updates, size_t update_count, size_t max_array_length, void *scratch, size_t scratch_size, bufzilla_mutable_bytes output, size_t *written);

/* ------------------------------------------------------------------------ */
/* JSON rendering                                                            */
/* ------------------------------------------------------------------------ */

#define BUFZILLA_INSPECT_DEFAULT_INDENT_SIZE 4
#define BUFZILLA_INSPECT_DEFAULT_FLOAT_PRECISION 14

typedef struct {
    size_t indent_size;      /* spaces per nesting level */
    size_t float_precision;  /* digits after the decimal point */
} bufzilla_inspect_options;

/* Renders encoded data as pretty-printed JSON into output. options is optional
 * (NULL for the defaults). Byte strings must be valid UTF-8 and floats must be
 * finite; a float that cannot be rendered with float_precision digits is
 * rendered at full precision. Number, boolean and null object keys are
 * printed as JSON strings ("1": ...); container and typed array keys return
 * BUFZILLA_INVALID_TAG. On success, *written is the JSON
 * length; output is not NUL-terminated. On error, output may hold partial JSON. */
bufzilla_status bufzilla_inspect(bufzilla_bytes data, const bufzilla_inspect_options *options, bufzilla_mutable_bytes output, size_t *written);

#ifdef __cplusplus
}
#endif

#endif /* BUFZILLA_H */
