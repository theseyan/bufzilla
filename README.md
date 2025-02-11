# ⚡ zBuffers - A Simple Serialization format

A simple and fast binary encoding scheme in pure Zig.
Based on rxi's article - ["A Simple Serialization System"](https://rxi.github.io/a_simple_serialization_system.html).

zBuffers is ideal for serializing JSON-like objects and arrays, and has the following qualities:

- Independent of byte order and architecture.
- **Schemaless**, fully self-describing format; no "pre-compilation" is necessary.
- **Zero-copy** reads directly from the encoded bytes.
- Data is laid out linearly in memory and can be read without any intermediate representation (eg. trees).
- Printing encoded objects as JSON via `Inspect` API.
- Serialize Zig structs and data types recursively.

### Caveats

- zBuffers makes no effort in optimizing for size, in favor of simplicity and performance. Variable length integer encoding is one such technique which can be added for a small performance penalty.
- As a self-describing format, field names are present in the encoded result which affects the encoded size.