# ⚡ bufzilla

_buffer • zilla_

A simple and fast **binary encoding format** in pure Zig.
Originally based on rxi's article - ["A Simple Serialization System"](https://rxi.github.io/a_simple_serialization_system.html).

bufzilla is ideal for serializing JSON-like objects and arrays, and has the following qualities:

- **Portable** across endianness and architectures.
- **Schemaless**, fully self-describing format; no "pre-compilation" step is necessary.
- **Zero-copy** reads directly from the encoded bytes.
- **Variable length integer encoding** enabled by default, no wasted bytes.
- Data can be read _linearly_ without any intermediate representation (eg. trees).
- Printing encoded objects as JSON via `Inspect` API.
- Serialize Zig structs and data types recursively.

## Installation

- Zig version: `0.15.2`

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

### Inspecting encoded data as JSON

The `Inspect` API renders encoded bufzilla data as pretty-printed JSON:

```zig
const Inspect = @import("bufzilla").Inspect;

// Output to an allocating writer
var aw = Io.Writer.Allocating.init(allocator);
defer aw.deinit();

var inspector = Inspect.init(encoded_bytes, &aw.writer, .{});
try inspector.inspect();

std.debug.print("{s}\n", .{aw.written()});
```

Or output directly to a fixed buffer:

```zig
var buffer: [4096]u8 = undefined;
var fixed = Io.Writer.fixed(&buffer);

var inspector = Inspect.init(encoded_bytes, &fixed, .{});
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

var reader = Reader.init(encoded_bytes);

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

You can find more examples in the [unit tests](https://github.com/theseyan/bufzilla/tree/main/test).

### Caveats

- As a self-describing format, field names (keys) are present in the encoded result which can inflate the encoded size.

## Testing

Unit tests are present in the `test/` directory.

```bash
zig build test
```

## Benchmarks

TODO
