# Type aliases for common numeric types.
comptime u32 = UInt32
comptime u64 = UInt64
comptime f32 = Float32
comptime f64 = Float64
comptime int = Int
comptime i32 = Int32
comptime usize = UInt


# Type alias for a token, represented by a UInt32. The range of values
# here is quite a lot higher than what we'll need, but UInt16 is too small
# (only 65536).
comptime Token = u32
# Type alias for a pair of tokens.
comptime Pair = u64


@always_inline
def pack_pair(first: Token, second: Token) -> Pair:
    return (u64(first) << 32) | u64(second)


@always_inline
def unpack_pair(pair: Pair) -> Tuple[Token, Token]:
    # Shift right by 32 bits
    var first = Token(pair >> 32)
    # Mask to keep only lower 32 bits
    var second = Token(pair & 0xFFFF_FFFF)

    return (first, second)
