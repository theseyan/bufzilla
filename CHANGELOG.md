# v0.5.0

- Upgrade to Zig 0.17 (minimum Zig version is now `0.17.0`).

### Breaking Changes
- Requires Zig 0.17.
- Removed `Common.encodeZigZag` / `Common.decodeZigZag` (unused since signed-magnitude varints replaced ZigZag encoding in v0.3.2).
- Paths have at most `Path.max_segments` (64) segments; longer paths are malformed. `readPath` returns null for them and `applyUpdates` returns `MalformedPath`.
- `ApplyUpdatesError` has a new `TypeMismatch` error, returned when an update to a typed array element is not a number that fits the element type.
- Removed `Path.segmentAtDepth`, which re-parsed a path from its start; traversals now track their position with `Path.currentSegment`, `Path.descend` and `Path.ascend`.
- `Reader.readPaths` resolves every query exactly as `readPath` would: with duplicate keys in the data only the first occurrence is searched, and a typed array root can be indexed.
- `Inspect` prints number, boolean and null object keys as JSON strings, and returns `InvalidEnumTag` for a typed array key.
- Removed the internal `PathQuery.orig_index` and `offset` fields: `readPaths` no longer reorders the caller's queries. It resolves up to `read_paths_batch` (256) queries per pass over the data.

### C API
- Added a C API: `zig build` installs static and dynamic libraries plus `include/bufzilla.h`, which documents every function. The C API never allocates; callers provide writer/reader state, output buffers and scratch memory.
- Writing: compact `bufzilla_writer_write_{null,bool,int,uint,f64,f32,bytes}`, native-endian `bufzilla_writer_write_typed_array`, and `bufzilla_writer_write_value` for a specific encoding. A failed write leaves the writer unchanged.
- Reading: `bufzilla_reader_*` for sequential reads, iteration and path queries; a failed read leaves the reader unchanged. `bufzilla_value_as_{int,uint,f64,bytes}` convert a value regardless of its encoding.
- Writer and reader state are plain data that can be copied to save and restore a position. NULL pointers return `BUFZILLA_INVALID_ARGUMENT`, and scratch memory needs no particular alignment.
- `bufzilla_version` and `bufzilla_status_string`.

### Safety
- Fix unbounded output amplification in `Writer.applyUpdates` when extending arrays from untrusted paths: added `ApplyUpdatesLimits` (default `max_array_length` of 1,048,576) and `Writer.applyUpdatesWithLimits`. Exceeding the limit returns `ArrayTooLarge` before padding the rejected array; partial output may already have been written. In the C API, `bufzilla_apply_updates` takes the limit as a parameter.
- Fix `Writer.applyUpdates` CPU time growing with (array length × number of updates), and (object size × number of updates): a few thousand short paths could take tens of seconds. Updates are now matched to the encoded data in a single sorted pass.
- Fix `Reader.readPaths` CPU time growing with (entries × queries × path length): every entry rescanned every query and re-parsed each path from its start. It now matches queries to the data in a single sorted pass, like `applyUpdates`, and stops scanning a container once its queries are resolved.
- Fix `Inspect` stack overflow on deeply nested input: it recursed once per nesting level, so input nested a few hundred levels deep could crash a thread with a small stack. Inspect is now iterative, and supports nesting up to `max_nesting` (65,536) levels.
- Fix `Inspect` integer overflow with a very large `indent_size`, and a crash with a `float_precision` near `maxInt(usize)`.
- Fix stack overflow from long paths: path lookups and updates recurse once per path segment, so a path of a few thousand segments could crash a thread. Paths are now limited to 64 segments.
- Fix `Writer.applyUpdates` silently truncating an update value that does not fit the element type of a typed array (undefined behavior in ReleaseFast). Typed array elements now accept any integer encoding that fits (or, for float elements, any float that does not overflow), and return `TypeMismatch` otherwise, instead of `InvalidEnumTag` or, for values longer than 64 bytes, `WriteFailed`.
- Harden bounds checks for typed array payload sizes and for fixed-width values in `Reader.skipValue`.
- `Reader` returns `BytesTooLong` for byte lengths that do not fit in `usize` (e.g. on 32-bit targets).

### Bugfixes
- Fix `Inspect` emitting nothing for `varIntUnsigned` / `varIntSignedPositive` / `varIntSignedNegative` values.
- `Writer.applyUpdates`: when several updates target the same path, the last one now always wins. Previously this depended on the number of updates, and several root replacements returned `ConflictingUpdates`.
- `Reader.readPaths`: a malformed path among the queries could make another query resolve inside the wrong key's value.
- `Reader.iterateObject`, `readPath` and `readPaths` return `UnexpectedContainerEnd` for an object entry that has a key but no value, instead of returning the container end as its value.
- The empty path always means the root: an update or query with the empty path was treated as the key `['']` when sorted next to one.
- `Reader.readPaths` now leaves the reader and the query order unchanged on error, like `readPath`.
- `Inspect` falls back to full precision for floats that cannot be rendered with `float_precision` digits, instead of printing `(float)`, and returns `InvalidEnumTag` for an object key that is a container.
- `Writer.writeTypedArray` accepts slices with any alignment.

### Performance
Measured with A/B benchmarks against the previous code, Apple Silicon, ReleaseFast unless noted:
- Varints (integers, byte string lengths) are written with one fixed-size store when the buffer has room, instead of two copies: writing integers is about 34% faster, and serializing a typical struct about 22% faster.
- `Reader.readPaths` sorts an index array instead of the queries themselves, and caches each query's current path segment instead of re-parsing paths: 3.2x faster for 3 queries and 4.2x faster for 8 (5x in ReleaseSafe). It also no longer needs a 45 KB stack buffer.
- `Writer.applyUpdates` sorts up to 16 updates with insertion sort instead of block sort, avoiding a 24 KB stack buffer: about 2x faster for a few updates in ReleaseSafe and Debug builds, where that buffer was filled on every call; unchanged in ReleaseFast.
- Optimize reader hot paths: fast path for single-byte reads and single-query `Reader.readPaths`, and `Reader.readPath` no longer runs a separate path validation pass.

### Benchmarks
- Rewrote the benchmark suite: each operation is timed in calibrated batches and reported as the median of 15 samples with its spread, and setup is no longer timed (the object benchmarks used to format keys inside the timed loop). The benchmark programs accept `--csv`, `--quick` and `--filter=<text>`.
- Added `bench/compare`, comparing bufzilla with zbor, zig-msgpack, zig-protobuf and `std.json` on the same datasets. Checksums verify that every library decodes the complete data.

### Build
- `-Dno-llvm` is ignored on aarch64 targets, where Zig's self-hosted backend is not ready yet; LLVM is always used there.

# v0.3.2

### Format Improvements
- Change signed varint encoding to signed-magnitude via `varIntSignedPositive` / `varIntSignedNegative` tags (replaces the need for ZigZag encoding).
- Add compact tags for very small values:
  - `smallIntPositive` / `smallIntNegative` (inline magnitude 0..7 in tag byte)
  - `smallUint` (inline unsigned 0..7 in tag byte)
  - `smallBytes` (inline length 0..7 in tag byte)
- Add `typedArray` for packed numeric vectors.
- Add native `f16` float value encoding.

### Safety
- Fix `Reader.readPath` / `Reader.readPaths` object size limit enforcement when encountering non-byte keys.
- Refactor code to reduce duplication.

# v0.3.1

- Added `Reader.readPath` for fast path-based queries on encoded data using Javascript-style property access: `"name"`, `"address.city"`, `"items[0]"`, `"users[5].scores[0]"`.
- Added `Reader.readPaths` for efficiently reading a list of paths in a single pass.
- Added `Writer.applyUpdates` for efficiently applying a changeset of updates to an existing encoded buffer in a single pass.

### Improvements
- Refactored and simplified logic in `Reader.zig`

# v0.3.0

- Upgrade to Zig 0.15.2
- `Writer` now accepts a `*std.Io.Writer` instead of an allocator. This enables:
  - Writing to dynamically growing buffers via `std.Io.Writer.Allocating`
  - Writing to fixed buffers via `std.Io.Writer.fixed()` (zero allocation)
  - Streaming directly to files, sockets, or any custom writer
- `Inspect` now accepts a `*std.Io.Writer` instead of the deprecated `std.io.AnyWriter`.
- Removed `Writer.deinit()`, `Writer.bytes()`, `Writer.len()`, `Writer.toOwnedSlice()` in favor of `std.Io.Writer`.

### Safety
- Added configurable `ReadLimits` with the following options:
  - `max_depth`: maximum nesting depth for containers
  - `max_bytes_length`: maximum string/binary blob size
  - `max_array_length`: maximum array element count
  - `max_object_size`: maximum object key-value pair count
- New errors: `MaxDepthExceeded`, `BytesTooLong`, `ArrayTooLarge`, `ObjectTooLarge`.
- `Inspect.printValue` now returns `NonFiniteFloat` error for NaN and Infinity float value.

### Benchmarks
- A benchmark suite has been added (mostly ported from [zig-msgpack](https://github.com/zigcc/zig-msgpack)).

### Bugfixes and Optimizations
- Fix integer overflow in `Reader` bounds checks that could bypass validation with malicious length values.
- Fix `Reader` depth underflow when encountering `containerEnd` at depth 0.
- Fix `Reader` float decoding to use little-endian byte order always.
- Fix `Inspect` JSON output to escape all control characters (0x00-0x1F).
- Fix `encodeVarInt` computing wrong size on big-endian machines.
- `Inspect` now returns `error.InvalidUtf8` for non-UTF-8 byte sequences instead of producing invalid JSON.
- Fix integer overflow in `Writer.write` when writing extremely large integers.
- Fix `Writer.writeAny` silently dropping pointer-to-array values like `&[_]u8{1,2,3}` (data loss).
- Optimize: pre-compute key field for struct serialization. 

# v0.2.1
- Compatible with Zig 0.14.1
- Fix an issue in `build.zig` preventing compilation in macOS hosts.

# v0.2.0

- Upgrade to Zig 0.14
- Simple variable length integer encoding (strictly better space efficiency) by prefixing length in the tag byte.
- Use ZigZag algorithm for efficiently encoding negative variable integers.
- Rename `string` type to `bytes` because a string is just an array of bytes. Also makes it clear that the type is meant for arbitrary binary values, not just strings. We don't want multiple "bytes" types like in MessagePack.
- `bool` is now stored directly inside it's tag, saving 1 byte per bool.
- Change runtime `error.UnsupportedType`s to compile errors where possible.
- Rename to `bufzilla` because the old name was similar to Z-buffers (term in 3-D graphics programming).

# v0.1.0

Initial Release
