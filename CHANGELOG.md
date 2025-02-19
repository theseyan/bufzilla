# v0.2.0

- Upgrade to Zig 0.14 (yay)
- Simple variable length integer encoding (strictly better space efficiency) by prefixing length in the tag byte. In large integer cases, this is more space efficient than LEB128 (eg. Protobuf).
- Use ZigZag encoding for efficiently encoding negative integers.
- Rename `string` type to `bytes` because a string is just an array of bytes. Also makes it clear that the type is meant for arbitrary binary values, not just strings. We don't want multiple "bytes" types like in MessagePack.
- `bool` is now stored directly inside it's tag, saving 1 byte per bool.
- Change runtime `error.UnsupportedType`s to compile errors where possible.
- Name changed to `zibuffers` because the old one was similar to Z-buffers (term in 3-D graphics programming).

# v0.1.0

Initial Release