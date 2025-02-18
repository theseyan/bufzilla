# v0.2.0

- Upgrade to Zig 0.14 (yay!)
- Custom variable length integer encoding (strictly better space efficiency, even in the worst case) by prefixing length in the tag byte. In large integer cases, this is more space efficient than LEB128 (Protobuf). Faster in almost all cases.
- Rename `string` type to `bytes` because a string is just an array of bytes. Also makes it clear that the type is meant for arbitrary binary values, not just strings. We don't want multiple "bytes" types like in MessagePack.
- `bool` is now stored directly inside it's tag, saving 1 byte per bool.
- Name changed to `zibuffers` because the old one was similar to Z-buffers (term in 3-D graphics programming).

# v0.1.0

Initial Release