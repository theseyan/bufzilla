# v0.3.0

- Upgrade to Zig 0.15.2
- `Writer` now accepts a `*std.Io.Writer` instead of an allocator. This enables:
  - Writing to dynamically growing buffers via `std.Io.Writer.Allocating`
  - Writing to fixed buffers via `std.Io.Writer.fixed()` (zero allocation)
  - Streaming directly to files, sockets, or any custom writer
- `Inspect` now accepts a `*std.Io.Writer` instead of the deprecated `std.io.AnyWriter`.
- Removed `Writer.deinit()`, `Writer.bytes()`, `Writer.len()`, `Writer.toOwnedSlice()` — buffer management is now the caller's responsibility.

### Benchmarks
- A benchmark suite has been added (mostly ported from [zig-msgpack](https://github.com/zigcc/zig-msgpack)).

### Bug Fixes
- Fix integer overflow in `Reader` bounds checks that could bypass validation with malicious length values.
- Fix `Reader` depth underflow when encountering `containerEnd` at depth 0.
- Fix `Reader` float decoding to use little-endian byte order always.
- Fix `Inspect` JSON output to escape all control characters (0x00-0x1F).
- Fix `encodeVarInt` computing wrong size on big-endian machines.
- `Inspect` now returns `error.InvalidUtf8` for non-UTF-8 byte sequences instead of producing invalid JSON.
- Fix integer overflow in `Writer.write` when writing extremely large integers.

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