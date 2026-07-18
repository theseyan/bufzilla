#include "bufzilla.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    bufzilla_align_t align;
    uint8_t bytes[256];
} aligned_scratch;

static bufzilla_bytes bytes(const void *ptr, size_t len) {
    bufzilla_bytes b = { (const uint8_t *)ptr, len };
    return b;
}

static bufzilla_mutable_bytes mutable_bytes(void *ptr, size_t len) {
    bufzilla_mutable_bytes b = { (uint8_t *)ptr, len };
    return b;
}

int main(void) {
    uint8_t encoded[256];
    bufzilla_writer writer;
    if (bufzilla_writer_init(&writer, mutable_bytes(encoded, sizeof(encoded))) != BUFZILLA_OK) return 1;
    if (bufzilla_writer_start_object(&writer) != BUFZILLA_OK) return 2;

    const char key[] = "name";
    bufzilla_value key_value;
    memset(&key_value, 0, sizeof(key_value));
    key_value.tag = BUFZILLA_VALUE_SMALL_BYTES;
    key_value.data.bytes = bytes(key, 4);
    if (bufzilla_writer_write_value(&writer, key_value) != BUFZILLA_OK) return 3;

    bufzilla_value int_value;
    memset(&int_value, 0, sizeof(int_value));
    int_value.tag = BUFZILLA_VALUE_VAR_INT_SIGNED_POSITIVE;
    int_value.data.i64_value = 42;
    if (bufzilla_writer_write_value(&writer, int_value) != BUFZILLA_OK) return 4;
    if (bufzilla_writer_end_container(&writer) != BUFZILLA_OK) return 5;

    size_t encoded_len = bufzilla_writer_written(&writer);
    bufzilla_reader reader;
    if (bufzilla_reader_init(&reader, bytes(encoded, encoded_len)) != BUFZILLA_OK) return 6;

    uint8_t found = 0;
    bufzilla_value found_value;
    if (bufzilla_reader_read_path(&reader, bytes(key, 4), &found_value, &found) != BUFZILLA_OK) return 7;
    if (!found || found_value.tag != BUFZILLA_VALUE_I64 || found_value.data.i64_value != 42) return 8;

    bufzilla_update update;
    memset(&update, 0, sizeof(update));
    update.path = bytes(key, 4);
    update.value.tag = BUFZILLA_VALUE_VAR_INT_SIGNED_POSITIVE;
    update.value.data.i64_value = 99;

    uint8_t updated[256];
    size_t updated_len = 0;
    aligned_scratch scratch;
    if (bufzilla_apply_updates(bytes(encoded, encoded_len), &update, 1, &scratch, sizeof(scratch), mutable_bytes(updated, sizeof(updated)), &updated_len) != BUFZILLA_OK) return 9;

    if (bufzilla_reader_init(&reader, bytes(updated, updated_len)) != BUFZILLA_OK) return 10;
    if (bufzilla_reader_read_path(&reader, bytes(key, 4), &found_value, &found) != BUFZILLA_OK) return 11;
    if (!found || found_value.data.i64_value != 99) return 12;

    return 0;
}
