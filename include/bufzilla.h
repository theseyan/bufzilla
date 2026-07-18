#ifndef BUFZILLA_H
#define BUFZILLA_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

#define BUFZILLA_SIZEOF_WRITER 64
#define BUFZILLA_SIZEOF_READER 64

#if __STDC_VERSION__ >= 201112L || __cplusplus >= 201103L
typedef max_align_t bufzilla_align_t;
#else
typedef long double bufzilla_align_t;
#endif

typedef struct { bufzilla_align_t _align; uint8_t data[BUFZILLA_SIZEOF_WRITER - sizeof(bufzilla_align_t)]; } bufzilla_writer;
typedef struct { bufzilla_align_t _align; uint8_t data[BUFZILLA_SIZEOF_READER - sizeof(bufzilla_align_t)]; } bufzilla_reader;

typedef enum {
    BUFZILLA_OK = 0,
    BUFZILLA_INVALID_ARGUMENT = 1,
    BUFZILLA_BUFFER_TOO_SMALL = 2,
    BUFZILLA_UNEXPECTED_EOF = 3,
    BUFZILLA_INVALID_ENUM_TAG = 4,
    BUFZILLA_INVALID_SIGNED_MAGNITUDE = 5,
    BUFZILLA_UNEXPECTED_CONTAINER_END = 6,
    BUFZILLA_MAX_DEPTH_EXCEEDED = 7,
    BUFZILLA_BYTES_TOO_LONG = 8,
    BUFZILLA_ARRAY_TOO_LARGE = 9,
    BUFZILLA_OBJECT_TOO_LARGE = 10,
    BUFZILLA_INVALID_ROOT = 11,
    BUFZILLA_MALFORMED_PATH = 12,
    BUFZILLA_PATH_TYPE_MISMATCH = 13,
    BUFZILLA_CONFLICTING_UPDATES = 14,
    BUFZILLA_INDEX_OUT_OF_RANGE = 15,
    BUFZILLA_INVALID_UTF8 = 16,
    BUFZILLA_NON_FINITE_FLOAT = 17,
    BUFZILLA_TYPE_MISMATCH = 18,
    BUFZILLA_LENGTH_MISMATCH = 19,
    BUFZILLA_INDEX_OUT_OF_BOUNDS = 20,
    BUFZILLA_UNKNOWN_ERROR = 255,
} bufzilla_status;

typedef enum {
    BUFZILLA_VALUE_BYTES = 0,
    BUFZILLA_VALUE_VAR_INT_BYTES = 1,
    BUFZILLA_VALUE_SMALL_BYTES = 2,
    BUFZILLA_VALUE_U64 = 3,
    BUFZILLA_VALUE_U32 = 4,
    BUFZILLA_VALUE_U16 = 5,
    BUFZILLA_VALUE_U8 = 6,
    BUFZILLA_VALUE_I64 = 7,
    BUFZILLA_VALUE_I32 = 8,
    BUFZILLA_VALUE_I16 = 9,
    BUFZILLA_VALUE_I8 = 10,
    BUFZILLA_VALUE_F64 = 11,
    BUFZILLA_VALUE_F32 = 12,
    BUFZILLA_VALUE_F16 = 13,
    BUFZILLA_VALUE_BOOL = 14,
    BUFZILLA_VALUE_NULL = 15,
    BUFZILLA_VALUE_SMALL_INT_POSITIVE = 16,
    BUFZILLA_VALUE_SMALL_INT_NEGATIVE = 17,
    BUFZILLA_VALUE_SMALL_UINT = 18,
    BUFZILLA_VALUE_VAR_INT_SIGNED_POSITIVE = 19,
    BUFZILLA_VALUE_VAR_INT_SIGNED_NEGATIVE = 20,
    BUFZILLA_VALUE_VAR_INT_UNSIGNED = 21,
    BUFZILLA_VALUE_ARRAY = 22,
    BUFZILLA_VALUE_OBJECT = 23,
    BUFZILLA_VALUE_CONTAINER_END = 24,
    BUFZILLA_VALUE_TYPED_ARRAY = 25,
} bufzilla_value_tag;

typedef enum {
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
    BUFZILLA_TYPED_ARRAY_F64 = 10,
} bufzilla_typed_array_elem;

typedef struct {
    const uint8_t *ptr;
    size_t len;
} bufzilla_bytes;

typedef struct {
    uint8_t *ptr;
    size_t len;
} bufzilla_mutable_bytes;

typedef struct {
    int elem;
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
    int tag;
    bufzilla_value_payload data;
} bufzilla_value;

typedef struct {
    bufzilla_bytes path;
    bufzilla_value value;
    uint8_t found;
    uint8_t resolved;
} bufzilla_path_query;

typedef struct {
    bufzilla_bytes path;
    bufzilla_value value;
} bufzilla_update;

typedef struct {
    size_t indent_size;
    size_t float_precision;
} bufzilla_inspect_options;

int bufzilla_writer_init(bufzilla_writer *writer, bufzilla_mutable_bytes buffer);
size_t bufzilla_writer_written(bufzilla_writer *writer);
int bufzilla_writer_write_value(bufzilla_writer *writer, bufzilla_value value);
int bufzilla_writer_start_array(bufzilla_writer *writer);
int bufzilla_writer_start_object(bufzilla_writer *writer);
int bufzilla_writer_end_container(bufzilla_writer *writer);
int bufzilla_writer_write_typed_array(bufzilla_writer *writer, bufzilla_typed_array typed_array);

size_t bufzilla_apply_updates_scratch_len(size_t update_count);
int bufzilla_apply_updates(bufzilla_bytes encoded, const bufzilla_update *updates, size_t update_count, void *scratch, size_t scratch_len, bufzilla_mutable_bytes output, size_t *written);

int bufzilla_reader_init(bufzilla_reader *reader, bufzilla_bytes data);
size_t bufzilla_reader_position(bufzilla_reader *reader);
int bufzilla_reader_read(bufzilla_reader *reader, bufzilla_value *value);
int bufzilla_reader_skip_value(bufzilla_reader *reader);
int bufzilla_reader_iterate_object(bufzilla_reader *reader, bufzilla_value object, bufzilla_value *key, bufzilla_value *value, uint8_t *has_next);
int bufzilla_reader_iterate_array(bufzilla_reader *reader, bufzilla_value array, bufzilla_value *value, uint8_t *has_next);
int bufzilla_reader_read_path(bufzilla_reader *reader, bufzilla_bytes path, bufzilla_value *value, uint8_t *found);
size_t bufzilla_reader_read_paths_scratch_len(size_t query_count);
int bufzilla_reader_read_paths(bufzilla_reader *reader, bufzilla_path_query *queries, size_t query_count, void *scratch, size_t scratch_len);

int bufzilla_inspect(bufzilla_bytes data, bufzilla_mutable_bytes output, const bufzilla_inspect_options *options, size_t *written);

uint8_t bufzilla_path_validate(bufzilla_bytes path);

void bufzilla_encode_varint(uint64_t value, uint8_t output[8], size_t *written);
int bufzilla_decode_varint(bufzilla_bytes bytes, uint64_t *value);
uint8_t bufzilla_encode_tag(uint8_t tag, uint8_t data);
void bufzilla_decode_tag(uint8_t byte, uint8_t *tag, uint8_t *data);

int bufzilla_typed_array_elem_size(int elem, size_t *size);
int bufzilla_typed_array_element_to_value(bufzilla_typed_array typed_array, size_t index, bufzilla_value *value);
int bufzilla_typed_array_copy(bufzilla_typed_array typed_array, bufzilla_mutable_bytes output, size_t *written);

#ifdef __cplusplus
}
#endif

#endif
