# zBuffers - Simple Serialization in Zig

A simple and fast binary encoding scheme in pure Zig.
Based on rxi's article - ["A Simple Serialization System"](https://rxi.github.io/a_simple_serialization_system.html).

zBuffers is ideal for serializing JSON-like objects and arrays, and has the following qualities:
- Supports upto 64-bit integers and floats.
- Schemaless, fully self-describing format; no "pre-compilation" is necessary.
- Zero-copy reads directly from the encoded bytes.
- Printing encoded objects as JSON via `Inspect` API.
- Serialize Zig structs and data types recursively.

### Caveats

- zBuffers makes no effort in reducing the size of encoded bytes in favor of simplicity and performance. Variable length integer encoding is one such technique which can be added later on.
- As a self-describing format, field names are present in the encoded result increasing the size even more.