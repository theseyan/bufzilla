# ⚡ zBuffers

A simple and fast binary encoding format in pure Zig.
Based on rxi's article - ["A Simple Serialization System"](https://rxi.github.io/a_simple_serialization_system.html).

zBuffers is ideal for serializing JSON-like objects and arrays, and has the following qualities:

- **Portable** across endianness and architectures.
- **Schemaless**, fully self-describing format; no "pre-compilation" is necessary.
- **Zero-copy** reads directly from the encoded bytes.
- **Variable length integer encoding** for space efficiency.
- Data can be read _linearly_ without any intermediate representation (eg. trees).
- Printing encoded objects as JSON via `Inspect` API.
- Serialize Zig structs and data types recursively.

## Installation

```sh
zig fetch https://github.com/theseyan/zbuffers/archive/refs/tags/{VERSION}.tar.gz
```

Copy the hash generated and add `zbuffers` to your `build.zig.zon`:

```zig
.{
    .dependencies = .{
        .zbuffers = .{
            .url = "https://github.com/theseyan/zbuffers/archive/refs/tags/{VERSION}.tar.gz",
            .hash = "{HASH}",
        },
    },
}
```

## Usage

The `Writer.writeAny` function can serialize primitive data types as well as Zig structs and tuples. Coupled with the `Writer.startObject`, `Writer.startArray` and `Writer.endContainer` functions, it can be used to incrementally build a message as well.
```zig
const Writer = @import("zbuffers").Writer;

var writer = Writer.init(std.heap.c_allocator);
defer writer.deinit();

const DataType = struct {
    a: i64,
    b: struct {
        c: bool,
    },
    d: []const union (enum) {
        null: ?void,
        f64: f64,
        string: []const u8,
    }
};

const data = DataType{
    .a = 123,
    .b = .{ .c = true },
    .d = &.{ .{ .f64 = 123.123 }, .{ .null = null }, .{ .string = "value" } },
};

try writer.writeAny(data);
try std.debug.print("{}", .{ writer.bytes() });
```

Let's print out the object as a JSON string via `Inspect` API.

```zig
const Inspect = @import("zbuffers").Inspect;

var buf = std.ArrayList(u8).init(std.testing.allocator);
defer buf.deinit();
var writer = buf.writer();

var inspector = Inspect.init(&encoded_bytes, &writer, .{});
try inspector.inspect(); // Writes the JSON string to `buf`

std.debug.print("{s}", .{ buf.items });
```

which prints the following JSON:

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

You can find more examples of usage in the [unit tests](https://github.com/theseyan/zbuffers/tree/main/test).

### Caveats

NOTE: Post `v0.2.0` VLE has been implemented which alleviates most of these caveats.

- zBuffers favors simplicity and performance over output size. Optional **variable length integer encoding** is a technique which can be added later, for a small performance penalty.
- As a self-describing format, field names are present in the encoded result which affects the encoded size.

## Testing

Unit tests are present in the `test/` directory.

```bash
zig build test
```

## Benchmarks

TODO