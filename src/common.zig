/// Common data types

/// A value/type that can be serialized
pub const Value = union (enum) {
    // Primitive types
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
    null: void,

    // Container tags
    array: u32,
    object: u32,

    // Container ending tag
    containerEnd: u32
};