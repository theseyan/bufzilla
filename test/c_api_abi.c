/* Reports the C compiler's view of bufzilla.h, so the Zig tests can check that
 * the ABI types in src/c_api.zig match the header. Keep the lists in the
 * header's declaration order. */
#include "bufzilla.h"

#define LIST(name, type, ...)                                \
    const type *name(size_t *len) {                          \
        static const type items[] = {__VA_ARGS__};           \
        *len = sizeof(items) / sizeof(items[0]);             \
        return items;                                        \
    }

/* Each struct contributes its size and alignment, then the offset and size of
 * each of its fields. */
#define STRUCT(T) sizeof(T), _Alignof(T)
#define FIELD(T, f) offsetof(T, f), sizeof(((T *)0)->f)

/* Prototypes keep -Wmissing-prototypes quiet; these are only for the tests. */
const size_t *bufzilla_test_abi_layout(size_t *len);
const int *bufzilla_test_abi_statuses(size_t *len);
const int *bufzilla_test_abi_value_tags(size_t *len);
const int *bufzilla_test_abi_typed_array_elems(size_t *len);
const size_t *bufzilla_test_abi_constants(size_t *len);

LIST(bufzilla_test_abi_layout, size_t,
     STRUCT(bufzilla_bytes),
     FIELD(bufzilla_bytes, ptr),
     FIELD(bufzilla_bytes, len),
     STRUCT(bufzilla_mutable_bytes),
     FIELD(bufzilla_mutable_bytes, ptr),
     FIELD(bufzilla_mutable_bytes, len),
     STRUCT(bufzilla_typed_array),
     FIELD(bufzilla_typed_array, elem),
     FIELD(bufzilla_typed_array, count),
     FIELD(bufzilla_typed_array, bytes),
     STRUCT(bufzilla_value_payload),
     FIELD(bufzilla_value_payload, bytes),
     FIELD(bufzilla_value_payload, typed_array),
     FIELD(bufzilla_value_payload, u64_value),
     FIELD(bufzilla_value_payload, u32_value),
     FIELD(bufzilla_value_payload, u16_value),
     FIELD(bufzilla_value_payload, u8_value),
     FIELD(bufzilla_value_payload, i64_value),
     FIELD(bufzilla_value_payload, i32_value),
     FIELD(bufzilla_value_payload, i16_value),
     FIELD(bufzilla_value_payload, i8_value),
     FIELD(bufzilla_value_payload, f64_value),
     FIELD(bufzilla_value_payload, f32_value),
     FIELD(bufzilla_value_payload, f16_bits),
     FIELD(bufzilla_value_payload, bool_value),
     FIELD(bufzilla_value_payload, small_value),
     FIELD(bufzilla_value_payload, container_depth),
     STRUCT(bufzilla_value),
     FIELD(bufzilla_value, tag),
     FIELD(bufzilla_value, data),
     STRUCT(bufzilla_path_query),
     FIELD(bufzilla_path_query, path),
     FIELD(bufzilla_path_query, value),
     FIELD(bufzilla_path_query, found),
     STRUCT(bufzilla_update),
     FIELD(bufzilla_update, path),
     FIELD(bufzilla_update, value),
     STRUCT(bufzilla_inspect_options),
     FIELD(bufzilla_inspect_options, indent_size),
     FIELD(bufzilla_inspect_options, float_precision),
     STRUCT(bufzilla_writer),
     FIELD(bufzilla_writer, _opaque),
     STRUCT(bufzilla_reader),
     FIELD(bufzilla_reader, _opaque))

LIST(bufzilla_test_abi_statuses, int,
     BUFZILLA_OK,
     BUFZILLA_INVALID_ARGUMENT,
     BUFZILLA_BUFFER_TOO_SMALL,
     BUFZILLA_UNEXPECTED_EOF,
     BUFZILLA_INVALID_TAG,
     BUFZILLA_INVALID_SIGNED_MAGNITUDE,
     BUFZILLA_UNEXPECTED_CONTAINER_END,
     BUFZILLA_MAX_DEPTH_EXCEEDED,
     BUFZILLA_BYTES_TOO_LONG,
     BUFZILLA_ARRAY_TOO_LARGE,
     BUFZILLA_OBJECT_TOO_LARGE,
     BUFZILLA_INVALID_ROOT,
     BUFZILLA_MALFORMED_PATH,
     BUFZILLA_PATH_TYPE_MISMATCH,
     BUFZILLA_CONFLICTING_UPDATES,
     BUFZILLA_INDEX_OUT_OF_RANGE,
     BUFZILLA_INVALID_UTF8,
     BUFZILLA_NON_FINITE_FLOAT,
     BUFZILLA_TYPE_MISMATCH,
     BUFZILLA_OUT_OF_RANGE)

LIST(bufzilla_test_abi_value_tags, int,
     BUFZILLA_VALUE_BYTES,
     BUFZILLA_VALUE_VAR_INT_BYTES,
     BUFZILLA_VALUE_SMALL_BYTES,
     BUFZILLA_VALUE_U64,
     BUFZILLA_VALUE_U32,
     BUFZILLA_VALUE_U16,
     BUFZILLA_VALUE_U8,
     BUFZILLA_VALUE_I64,
     BUFZILLA_VALUE_I32,
     BUFZILLA_VALUE_I16,
     BUFZILLA_VALUE_I8,
     BUFZILLA_VALUE_F64,
     BUFZILLA_VALUE_F32,
     BUFZILLA_VALUE_F16,
     BUFZILLA_VALUE_BOOL,
     BUFZILLA_VALUE_NULL,
     BUFZILLA_VALUE_SMALL_INT_POSITIVE,
     BUFZILLA_VALUE_SMALL_INT_NEGATIVE,
     BUFZILLA_VALUE_SMALL_UINT,
     BUFZILLA_VALUE_VAR_INT_SIGNED_POSITIVE,
     BUFZILLA_VALUE_VAR_INT_SIGNED_NEGATIVE,
     BUFZILLA_VALUE_VAR_INT_UNSIGNED,
     BUFZILLA_VALUE_ARRAY,
     BUFZILLA_VALUE_OBJECT,
     BUFZILLA_VALUE_CONTAINER_END,
     BUFZILLA_VALUE_TYPED_ARRAY)

LIST(bufzilla_test_abi_typed_array_elems, int,
     BUFZILLA_TYPED_ARRAY_U8,
     BUFZILLA_TYPED_ARRAY_I8,
     BUFZILLA_TYPED_ARRAY_U16,
     BUFZILLA_TYPED_ARRAY_I16,
     BUFZILLA_TYPED_ARRAY_U32,
     BUFZILLA_TYPED_ARRAY_I32,
     BUFZILLA_TYPED_ARRAY_U64,
     BUFZILLA_TYPED_ARRAY_I64,
     BUFZILLA_TYPED_ARRAY_F16,
     BUFZILLA_TYPED_ARRAY_F32,
     BUFZILLA_TYPED_ARRAY_F64)

LIST(bufzilla_test_abi_constants, size_t,
     BUFZILLA_SIZEOF_WRITER,
     BUFZILLA_SIZEOF_READER,
     BUFZILLA_VERSION,
     BUFZILLA_DEFAULT_MAX_ARRAY_LENGTH,
     BUFZILLA_INSPECT_DEFAULT_INDENT_SIZE,
     BUFZILLA_INSPECT_DEFAULT_FLOAT_PRECISION,
     BUFZILLA_MAX_PATH_SEGMENTS)
