/* Uses the C API the way a C program would: through bufzilla.h and the static
 * library. Built with -std=c99 -Wall -Wextra -Wpedantic -Werror. */
#include "bufzilla.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr)                                                                          \
    do {                                                                                     \
        bufzilla_status status_ = (expr);                                                    \
        if (status_ != BUFZILLA_OK) {                                                        \
            fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, #expr,                    \
                    bufzilla_status_string(status_));                                        \
            return 1;                                                                        \
        }                                                                                    \
    } while (0)

#define EXPECT(cond)                                                                         \
    do {                                                                                     \
        if (!(cond)) {                                                                       \
            fprintf(stderr, "%s:%d: expected %s\n", __FILE__, __LINE__, #cond);              \
            return 1;                                                                        \
        }                                                                                    \
    } while (0)

static bufzilla_bytes str(const char *s) {
    return bufzilla_bytes_of(s, strlen(s));
}

/* {"name": "Alice", "scores": [100, -5], "embedding": <f32 typed array>} */
static int encode_sample(uint8_t *buffer, size_t size, size_t *len) {
    const float embedding[3] = {0.5f, -1.0f, 2.0f};
    bufzilla_writer writer;
    CHECK(bufzilla_writer_init(&writer, bufzilla_mutable_bytes_of(buffer, size)));
    CHECK(bufzilla_writer_start_object(&writer));
    CHECK(bufzilla_writer_write_bytes(&writer, str("name")));
    CHECK(bufzilla_writer_write_bytes(&writer, str("Alice")));
    CHECK(bufzilla_writer_write_bytes(&writer, str("scores")));
    CHECK(bufzilla_writer_start_array(&writer));
    CHECK(bufzilla_writer_write_int(&writer, 100));
    CHECK(bufzilla_writer_write_int(&writer, -5));
    CHECK(bufzilla_writer_end_container(&writer));
    CHECK(bufzilla_writer_write_bytes(&writer, str("embedding")));
    CHECK(bufzilla_writer_write_typed_array(&writer, BUFZILLA_TYPED_ARRAY_F32, embedding, 3));
    CHECK(bufzilla_writer_end_container(&writer));
    *len = bufzilla_writer_written(&writer);
    return 0;
}

static int test_iteration(bufzilla_bytes encoded) {
    bufzilla_reader reader;
    bufzilla_value root, key, value, item;
    bool has_next;
    int64_t sum = 0;

    CHECK(bufzilla_reader_init(&reader, encoded));
    CHECK(bufzilla_reader_read(&reader, &root));
    EXPECT(root.tag == BUFZILLA_VALUE_OBJECT);
    for (;;) {
        CHECK(bufzilla_reader_iterate_object(&reader, &root, &key, &value, &has_next));
        if (!has_next) break;
        if (value.tag != BUFZILLA_VALUE_ARRAY) continue;
        for (;;) {
            int64_t n;
            CHECK(bufzilla_reader_iterate_array(&reader, &value, &item, &has_next));
            if (!has_next) break;
            CHECK(bufzilla_value_as_int(&item, &n));
            sum += n;
        }
    }
    EXPECT(sum == 95);
    EXPECT(bufzilla_reader_position(&reader) == encoded.len);
    return 0;
}

static int test_paths(bufzilla_bytes encoded) {
    bufzilla_reader reader;
    bufzilla_value value;
    bufzilla_bytes name;
    bool found;
    float embedding[3];
    bufzilla_path_query queries[2];
    size_t scratch_size;
    void *scratch;
    int64_t score;

    CHECK(bufzilla_reader_init(&reader, encoded));
    CHECK(bufzilla_reader_read_path(&reader, str("name"), &value, &found));
    EXPECT(found);
    CHECK(bufzilla_value_as_bytes(&value, &name));
    EXPECT(name.len == 5 && memcmp(name.ptr, "Alice", 5) == 0);

    CHECK(bufzilla_reader_read_path(&reader, str("embedding"), &value, &found));
    EXPECT(found && value.tag == BUFZILLA_VALUE_TYPED_ARRAY);
    CHECK(bufzilla_typed_array_copy(&value.data.typed_array, bufzilla_mutable_bytes_of(embedding, sizeof(embedding))));
    EXPECT(embedding[0] == 0.5f && embedding[1] == -1.0f && embedding[2] == 2.0f);

    CHECK(bufzilla_reader_read_path(&reader, str("missing"), &value, &found));
    EXPECT(!found);

    memset(queries, 0, sizeof(queries));
    queries[0].path = str("scores[1]");
    queries[1].path = str("scores[7]");
    scratch_size = bufzilla_reader_read_paths_scratch_size(2);
    scratch = malloc(scratch_size);
    EXPECT(scratch != NULL);
    CHECK(bufzilla_reader_read_paths(&reader, queries, 2, scratch, scratch_size));
    free(scratch);
    EXPECT(queries[0].found == 1 && queries[1].found == 0);
    CHECK(bufzilla_value_as_int(&queries[0].value, &score));
    EXPECT(score == -5);
    return 0;
}

static int test_updates(bufzilla_bytes encoded) {
    bufzilla_update updates[2];
    uint8_t scratch[1024];
    uint8_t output[256];
    size_t written = 0;
    bufzilla_reader reader;
    bufzilla_value value;
    bool found;
    int64_t score;

    memset(updates, 0, sizeof(updates));
    updates[0].path = str("scores[0]");
    updates[0].value.tag = BUFZILLA_VALUE_VAR_INT_SIGNED_POSITIVE;
    updates[0].value.data.i64_value = 250;
    updates[1].path = str("scores[3]");
    updates[1].value.tag = BUFZILLA_VALUE_BOOL;
    updates[1].value.data.bool_value = 1;

    EXPECT(bufzilla_apply_updates_scratch_size(2) <= sizeof(scratch));
    EXPECT(bufzilla_apply_updates(encoded, updates, 2, 0, scratch, sizeof(scratch),
                                  bufzilla_mutable_bytes_of(output, sizeof(output)), &written) == BUFZILLA_ARRAY_TOO_LARGE);
    CHECK(bufzilla_apply_updates(encoded, updates, 2, BUFZILLA_DEFAULT_MAX_ARRAY_LENGTH, scratch, sizeof(scratch),
                                 bufzilla_mutable_bytes_of(output, sizeof(output)), &written));

    CHECK(bufzilla_reader_init(&reader, bufzilla_bytes_of(output, written)));
    CHECK(bufzilla_reader_read_path(&reader, str("scores[0]"), &value, &found));
    EXPECT(found);
    CHECK(bufzilla_value_as_int(&value, &score));
    EXPECT(score == 250);
    CHECK(bufzilla_reader_read_path(&reader, str("scores[2]"), &value, &found));
    EXPECT(found && value.tag == BUFZILLA_VALUE_NULL);
    return 0;
}

static int test_inspect(bufzilla_bytes encoded) {
    static const char expected[] =
        "{\n"
        "\"name\": \"Alice\",\n"
        "\"scores\": [\n100,\n-5\n],\n"
        "\"embedding\": [\n0.5,\n-1.0,\n2.0\n]\n"
        "}";
    char json[256];
    size_t written = 0;
    bufzilla_inspect_options options;

    options.indent_size = 0;
    options.float_precision = 1;
    CHECK(bufzilla_inspect(encoded, &options, bufzilla_mutable_bytes_of(json, sizeof(json)), &written));
    EXPECT(written == strlen(expected) && memcmp(json, expected, written) == 0);
    EXPECT(bufzilla_inspect(encoded, NULL, bufzilla_mutable_bytes_of(json, 8), &written) == BUFZILLA_BUFFER_TOO_SMALL);
    return 0;
}

int main(void) {
    uint8_t buffer[256];
    size_t len = 0;
    bufzilla_bytes encoded;

    EXPECT(bufzilla_version() == BUFZILLA_VERSION);
    EXPECT(strcmp(bufzilla_status_string(BUFZILLA_BUFFER_TOO_SMALL), "buffer too small") == 0);

    if (encode_sample(buffer, sizeof(buffer), &len) != 0) return 1;
    encoded = bufzilla_bytes_of(buffer, len);
    if (test_iteration(encoded) != 0) return 1;
    if (test_paths(encoded) != 0) return 1;
    if (test_updates(encoded) != 0) return 1;
    if (test_inspect(encoded) != 0) return 1;
    return 0;
}
