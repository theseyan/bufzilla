# ⚡ bufzilla

_buffer • zilla_

A compact and fast **binary encoding format** in pure Zig.
Originally based on rxi's article - ["A Simple Serialization System"](https://rxi.github.io/a_simple_serialization_system.html).

bufzilla is ideal for serializing JSON-like objects and arrays, and has the following qualities:

- **Portable** across endianness and architectures.
- **Schemaless**, fully self-describing format; no "pre-compilation" step is necessary.
- **Zero-copy** reads directly from the encoded bytes.
- **Zero internal allocations** while encoding/decoding.
- **Variable length integer encoding** enabled by default, no wasted bytes.
- **Safety** against untrusted inputs with configurable, zero-overhead parsing limits.
- Data can be read _linearly_ without any intermediate representation (eg. trees).
- Format encoded objects as JSON via `Inspect` API.
- Serialize Zig structs and data types recursively.

## Installation

- Zig version: `0.17.1`

```sh
zig fetch https://github.com/theseyan/bufzilla/archive/refs/tags/{VERSION}.tar.gz
```

Copy the hash generated and add `bufzilla` to your `build.zig.zon`:

```zig
.{
    .dependencies = .{
        .bufzilla = .{
            .url = "https://github.com/theseyan/bufzilla/archive/refs/tags/{VERSION}.tar.gz",
            .hash = "{HASH}",
        },
    },
}
```

## Usage

bufzilla simply takes a `std.Io.Writer` interface, and writes encoded data to it. Such a writer can be backed by a growing buffer, a fixed array, a file, or a network socket, etc.

### Writing to a dynamic buffer

Use `std.Io.Writer.Allocating` when you need a dynamically growing buffer:

```zig
const std = @import("std");
const Io = std.Io;
const Writer = @import("bufzilla").Writer;

// Create an allocating writer
var aw = Io.Writer.Allocating.init(allocator);
defer aw.deinit();

// Initialize bufzilla writer
var writer = Writer.init(&aw.writer);

const DataType = struct {
    a: i64,
    b: struct {
        c: bool,
    },
    d: []const union(enum) {
        null: ?void,
        f64: f64,
        string: []const u8,
    },
};

const data = DataType{
    .a = 123,
    .b = .{ .c = true },
    .d = &.{ .{ .f64 = 123.123 }, .{ .null = null }, .{ .string = "value" } },
};

try writer.writeAny(data);

// Get the encoded bytes
const encoded = aw.written();
std.debug.print("Encoded {d} bytes\n", .{encoded.len});
```

### Writing to a fixed buffer

Use `std.Io.Writer.fixed` to prevent dynamic allocations when you know the maximum size upfront:

```zig
var buffer: [1024]u8 = undefined;
var fixed = Io.Writer.fixed(&buffer);

var writer = Writer.init(&fixed);
try writer.writeAny("hello");
try writer.writeAny(@as(i64, 42));

const encoded = fixed.buffered();
```

### Incremental writing

You can also build messages incrementally:

```zig
var writer = Writer.init(&aw.writer);

try writer.startObject();
try writer.writeAny("name");
try writer.writeAny("Alice");
try writer.writeAny("scores");
try writer.startArray();
try writer.writeAny(@as(i64, 100));
try writer.writeAny(@as(i64, 95));
try writer.endContainer(); // end array
try writer.endContainer(); // end object
```

### Typed arrays

When all elements of an array have the same numeric type, and the length is known upfront, you can use a packed typed array which is much more space-efficient:

```zig
const vec: [768]f32 = @splat(1.0);
try writer.writeTypedArray(&vec);
```

### Streaming updates

If you already have an encoded object buffer and want to update a few fields, `Writer.applyUpdates` can stream a new encoding efficiently in a single pass.
Unchanged parts of the buffer are copied directly while only the changed fields are modified.

```zig
const bufzilla = @import("bufzilla");
const Writer = bufzilla.Writer;

// `encoded_bytes` is an existing encoded object

var new_age: i64 = 31;
var new_city: []const u8 = "Berlin";

var updates = [_]Writer.Update{
    Writer.Update.init("age", &new_age),
    Writer.Update.init("profile.address.city", &new_city),
    Writer.Update.init("new_key", &true), // upsert missing keys
    Writer.Update.init("scores[5]", &@as(i64, 100)), // extend arrays, fills gaps with null
};

var out_writer = Writer.init(&aw.writer);
try out_writer.applyUpdates(encoded_bytes, updates[0..]);
```

Note:
- Paths follow the same syntax as `Reader.readPath`.
- `Update.init` takes a pointer; the pointed-to value must stay alive for the duration of `applyUpdates`.
- Missing keys/indices are inserted in the output encoding.
- If several updates target the same path, the last one wins.
- Array-extension updates (e.g. `arr[5]` on a shorter or missing array) fill gaps with nulls, and are capped at `max_array_length` elements to guard against unbounded output from untrusted paths. The default cap is 1,048,576; use `applyUpdatesWithLimits` with `.max_array_length = null` for unlimited extension.
- The cap applies to arrays created or extended by paths, including nested arrays. Existing arrays that are not extended and values supplied as whole-array replacements are not subject to this cap.
- Errors are returned as `Writer.Error || ReadError || ApplyUpdatesError`.
- Updates stream output as they run. On error, discard the partial encoding; limit checks occur before padding the rejected array, but earlier output may already have been written.

```zig
var out_writer = Writer.init(&aw.writer);
try out_writer.applyUpdatesWithLimits(encoded_bytes, updates[0..], .{
    .max_array_length = 10_000,
});
```

### Inspecting encoded data as JSON

The `Inspect` API renders encoded bufzilla data as pretty-printed JSON:

```zig
const Inspect = @import("bufzilla").Inspect;

// Output to an allocating writer
var aw = Io.Writer.Allocating.init(allocator);
defer aw.deinit();

var inspector = Inspect(.{}).init(encoded_bytes, &aw.writer, .{});
try inspector.inspect();

std.debug.print("{s}\n", .{aw.written()});
```

Or output directly to a fixed buffer:

```zig
var buffer: [4096]u8 = undefined;
var fixed = Io.Writer.fixed(&buffer);

var inspector = Inspect(.{}).init(encoded_bytes, &fixed, .{});
try inspector.inspect();

std.debug.print("{s}\n", .{fixed.buffered()});
```

Output:

```json
{
    "a": 123,
    "b": {
        "c": true
    },
    "d": [
        123.12300000000000,
        null,
        "value"
    ]
}
```

### Reading encoded data

The `Reader` provides zero-copy access to encoded data:

```zig
const Reader = @import("bufzilla").Reader;

var reader = Reader(.{}).init(encoded_bytes);

// Read values sequentially
const val = try reader.read();
switch (val) {
    .object => { /* iterate object */ },
    .array => { /* iterate array */ },
    .i64 => |n| std.debug.print("int: {d}\n", .{n}),
    .bytes => |s| std.debug.print("string: {s}\n", .{s}),
    // ... other types
}

// Or iterate containers
while (try reader.iterateObject(obj)) |kv| {
    // kv.key and kv.value
}
```

### Path-based queries

The `readPath` method provides fast access to nested values using Javascript-style property paths:

```zig
const Reader = @import("bufzilla").Reader;

var reader = Reader(.{}).init(encoded_bytes);

// Simple property access
const name = try reader.readPath("name");

// Nested properties
const city = try reader.readPath("address.city");

// Array indexing
const first = try reader.readPath("items[0]");

// Mixed paths
const score = try reader.readPath("users[5].scores[0]");

// Quoted keys
const value = try reader.readPath("data['key.with.dots']");

// Returns null if path doesn't exist
const missing = try reader.readPath("nonexistent.path"); // null
```

Paths have at most 64 segments (`bufzilla.Path.max_segments`); longer paths are treated as malformed. This bounds the stack used by path lookups and updates, which recurse once per segment.

For reading many paths efficiently, use `readPaths` to scan the buffer once (per 256 queries):

```zig
var queries = [_]bufzilla.PathQuery{
    .{ .path = "name" },
    .{ .path = "address.city" },
    .{ .path = "items[0]" },
};

try reader.readPaths(queries[0..]);

const name = queries[0].value;
const city = queries[1].value;
const first_item = queries[2].value;
```

You can find more examples in the [unit tests](https://github.com/theseyan/bufzilla/tree/main/test).

### Safety against untrusted inputs

When reading untrusted data, bufzilla provides configurable limits at compile time to prevent infinite recursion/stack overflow errors, with negligible performance loss.

```zig
const Reader = @import("bufzilla").Reader;

// Default limits
var reader = Reader(.{}).init(data);

// Custom limits
var reader = Reader(.{
    .max_depth = 50,                    // Max nesting depth
    .max_bytes_length = 1024 * 1024,    // Max string/binary blob size
    .max_array_length = 10_000,         // Max array elements
    .max_object_size = 10_000,          // Max object key-value pairs
}).init(data);

// Unlimited depth
var reader = Reader(.{ .max_depth = null }).init(data);
```

| Limit | Default | Error |
|-------|---------|-------|
| `max_depth` | 2048 | `MaxDepthExceeded` |
| `max_bytes_length` | unlimited | `BytesTooLong` |
| `max_array_length` | unlimited | `ArrayTooLarge` |
| `max_object_size` | unlimited | `ObjectTooLarge` |

**Notes:**
- `max_array_length` and `max_object_size` require `max_depth` to be set. Setting them with `max_depth = null` is a compile error.
- Reader internally allocates a stack buffer of size `max_depth` for iteration counters when array/object limits are enabled. Keep `max_depth` reasonable (default 2048 uses ~16KB).

The `Inspect` API also accepts limits as a parameter:

```zig
var inspector = Inspect(.{ .max_depth = 100 }).init(data, &writer, .{});
```

## Gotchas

- As a self-describing format, field names (keys) are present in the encoded result which can inflate the encoded size compared to other schemaful encoding formats.

## Testing

Comprehensive unit tests are present in the `test/` directory.

```bash
zig build test
```

## C API

`zig build` installs static and dynamic C libraries plus [`bufzilla.h`](include/bufzilla.h), which documents every function:

```bash
zig build -Doptimize=fast
```

The C API never allocates: callers own the writer and reader state, output buffers and scratch memory. Every function that can fail returns a `bufzilla_status`, and `bufzilla_status_string` describes it.

```c
#include <bufzilla.h>

uint8_t buf[256];
bufzilla_writer w;
bufzilla_writer_init(&w, bufzilla_mutable_bytes_of(buf, sizeof buf));
bufzilla_writer_start_object(&w);
bufzilla_writer_write_bytes(&w, bufzilla_bytes_of("age", 3));
bufzilla_writer_write_int(&w, 30);
bufzilla_writer_end_container(&w);

bufzilla_reader r;
bufzilla_value value;
bool found;
int64_t age;
bufzilla_reader_init(&r, bufzilla_bytes_of(buf, bufzilla_writer_written(&w)));
if (bufzilla_reader_read_path(&r, bufzilla_bytes_of("age", 3), &value, &found) == BUFZILLA_OK && found &&
    bufzilla_value_as_int(&value, &age) == BUFZILLA_OK) {
    printf("age = %lld\n", (long long)age);
}
```

A failed write leaves the writer unchanged, and a failed read leaves the reader unchanged. See [`test/c_api_smoke.c`](test/c_api_smoke.c) for a complete program covering iteration, path queries, updates, typed arrays and JSON rendering.

## Benchmarks

There are three benchmark programs. Each accepts `--csv` (for charts), `--quick` and `--filter=<text>`:

```bash
zig build bench -Doptimize=fast        # bufzilla operations: scalars to structs, paths, updates
zig build bench-large -Doptimize=fast  # path lookups and updates in a 4 MiB document

cd bench/compare && zig build run -Doptimize=fast   # bufzilla vs other Zig serialization libraries
```

They time each operation in calibrated batches and report the median of 15 samples, with the spread (interquartile range) to show how stable a result is. Setup, such as building inputs and encoding data to decode, happens outside the timed region. Results go to stdout.

The comparison ([`bench/compare`](bench/compare)) encodes the same datasets (a record, 1000 records, a 768-float vector) with bufzilla, [zbor](https://github.com/r4gus/zbor) (CBOR), [zig-msgpack](https://github.com/zigcc/zig-msgpack) (MessagePack), [zig-protobuf](https://github.com/Arwalk/zig-protobuf) (Protobuf) and `std.json`. It measures encoded size, encoding, decoding every value, and reading a single field. Before timing, each library's decode must reproduce a checksum of the whole dataset, so every library does the same, complete work. It is a separate package, so bufzilla does not depend on these libraries. The chart and tables below are generated from its results (`zig build chart` writes the chart's light and dark versions and prints the tables):

```bash
cd bench/compare
zig build run -Doptimize=fast -- --csv > results.csv
zig build chart -- results.csv ../../misc --machine="Apple M4, macOS, Zig 0.17.1"
```

**bufzilla is competitive in performance with similar self-describing binary formats, and in most cases, much faster.**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="misc/bench-dark.svg">
  <img alt="Bar charts of the time per operation of bufzilla, zbor, zig-msgpack, zig-protobuf, std.json and simdjzon: encoding, decoding every value and reading one field, for one record, 1000 records and a 768-float vector. The same numbers are in the tables below." src="misc/bench-light.svg">
</picture>

Results on an Apple M4 (macOS, `-Doptimize=fast`, Zig 0.17.1). Times are medians of 15 samples, and the middle of three runs; in parentheses, the time relative to bufzilla.

**One record** (strings, integers, a float, a nested object and arrays)

| Library | Format | Size | Encode | Decode (all values) | Read `address.city` |
|---|---|---:|---:|---:|---:|
| bufzilla | bufzilla | 208 B | 65 ns | 119 ns | 51 ns |
| zbor | CBOR | 206 B | 159 ns (2.4×) | 499 ns (4.2×) | 214 ns (4.2×) |
| zig-msgpack | MessagePack | 200 B | 138 ns (2.1×) | 475 ns (4.0×) | 450 ns (8.8×) |
| zig-protobuf | Protobuf | 127 B | 82 ns (1.3×) | 151 ns (1.3×) | 108 ns (2.1×) |
| std.json | JSON | 265 B | 311 ns (4.8×) | 641 ns (5.4×) | 621 ns (12×) |
| simdjzon¹ | JSON | 265 B | - | 328 ns (2.8×) | 267 ns (5.2×) |

**1000 records**

| Library | Format | Size | Encode | Decode (all values) | Read `[500].username` |
|---|---|---:|---:|---:|---:|
| bufzilla | bufzilla | 204,407 B | 63.6 µs | 165.2 µs | 35.0 µs |
| zbor | CBOR | 203,331 B | 180.4 µs (2.8×) | 656.0 µs (4.0×) | 156.4 µs (4.5×) |
| zig-msgpack | MessagePack | 202,284 B | 172.4 µs (2.7×) | 491.6 µs (3.0×) | 431.5 µs (12×) |
| zig-protobuf | Protobuf | 126,556 B | 98.8 µs (1.6×) | 168.2 µs (1.0×) | 5.64 µs (0.16×) |
| std.json | JSON | 266,738 B | 316.0 µs (5.0×) | 626.7 µs (3.8×) | 637.5 µs (18×) |
| simdjzon¹ | JSON | 266,738 B | - | 319.9 µs (1.9×) | 221.6 µs (6.3×) |

**A 768-float vector embedding**

| Library | Format | Size | Encode | Decode (all values) | Read `values[700]` |
|---|---|---:|---:|---:|---:|
| bufzilla | bufzilla | 3,118 B | 70 ns | 378 ns | 24 ns |
| zbor | CBOR | 3,885 B | 1.60 µs (23×) | 13.2 µs (35×) | 10.6 µs (446×) |
| zig-msgpack | MessagePack | 3,884 B | 3.06 µs (44×) | 6.67 µs (18×) | 5.42 µs (229×) |
| zig-protobuf | Protobuf | 3,101 B | 2.17 µs (31×) | 3.09 µs (8.2×) | 2.41 µs (102×) |
| std.json | JSON | 15,220 B | 17.1 µs (243×) | 26.8 µs (71×) | 26.2 µs (1105×) |
| simdjzon¹ | JSON | 15,220 B | - | 21.2 µs (56×) | 19.3 µs (815×) |

Notes:
- Decoding reads every value. bufzilla reads them in place, without copying; the others build structs or a tree of values (in an arena). bufzilla, zbor and zig-protobuf read a single field lazily; the others decode the whole document first.
- Integers from -32 to 63 and byte strings up to 31 bytes long fit in a single header byte (MessagePack: -32 to 127 and 31 bytes; CBOR: -24 to 23 and 23 bytes). bufzilla is still slightly larger than both, by at most 1% on the 1000 records and 4% on the single record. Each container ends with an end marker instead of starting with a count, which lets a container be written incrementally without knowing its length in advance; and MessagePack also fits integers up to 127 in one byte.
- Protobuf is schema-based: field names are not in the encoding, so it is the smallest. It also prefixes each nested message with its length, so reading record 500 skips the records before it without reading them; bufzilla, like the other self-describing formats, has to walk them.
- bufzilla stores the vector as a typed array: encoding it is one copy, and reading any element takes constant time. The others encode and decode each float separately.
- ¹ simdjzon only parses; its input is `std.json`'s output. It is not part of `bench/compare`: its build script does not support Zig 0.17.1, and it needed two fixes, for integer literals in float fields and for empty arrays. These numbers come from a local build with those fixes.
