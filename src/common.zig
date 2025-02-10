/// Common data types

/// A tag representing the type of a value
pub const ValueType = enum (u8) {
    String,
    u64, u32, u16, u8,
    i64, i32, i16, i8,
    f64, f32,
    Bool,
    Null,
    Array,
    Object,
    ContainerEnd
};

/// A value that can be serialized
pub const Value = struct {
    type: ValueType,
    value: union {
        string: []const u8,
        u64: u64,
        u32: u32,
        u16: u16,
        u8: u8,
        i64: i64,
        i32: i32,
        i16: i16,
        i8: i8,
        f64: f64,
        f32: f32,
        bool: bool,
        depth: u32
    }
};