# v0.3.0

- Upgrade to Zig 0.15.2
- `Writer` now accepts a `*std.Io.Writer` instead of an allocator. This enables:
  - Writing to dynamically growing buffers via `std.Io.Writer.Allocating`
  - Writing to fixed buffers via `std.Io.Writer.fixed()` (zero allocation)
  - Streaming directly to files, sockets, or any custom writer
- `Inspect` now accepts a `*std.Io.Writer` instead of the deprecated `std.io.AnyWriter`.
- Removed `Writer.deinit()`, `Writer.bytes()`, `Writer.len()`, `Writer.toOwnedSlice()` — buffer management is now the caller's responsibility.

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