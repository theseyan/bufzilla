const std = @import("std");
const bufzilla = @import("bufzilla");
pub const Common = bufzilla.Common;

test "varint encoding" {
    const varint = Common.encodeVarInt(512);

    const expected = &.{ 0, 2 };
    try std.testing.expect(std.mem.eql(u8, expected, varint.bytes[0 .. varint.size + 1]));

    const decoded = Common.decodeVarInt(varint.bytes[0 .. varint.size + 1]);
    try std.testing.expectEqual(512, decoded);
}

test "zigzag encoding" {
    const zenc = Common.encodeZigZag(-100);
    const zdec = Common.decodeZigZag(zenc);

    try std.testing.expectEqual(199, zenc);
    try std.testing.expectEqual(-100, zdec);
}
