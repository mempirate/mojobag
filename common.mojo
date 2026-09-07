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


@fieldwise_init
struct MatchSpan(ImplicitlyCopyable):
    """A half-open byte range in the matched UTF-8 subject."""

    var start: Int
    var end: Int


struct IdMap(Movable, Sized):
    """Insert-only map for prehashed UInt64 keys."""

    # Keys: the word hashes
    var _keys: List[UInt64]
    # Values: the word IDs
    var _ids: List[UInt32]  # 0 = empty; otherwise value + 1.
    var _count: Int

    def __init__(out self, capacity: int = 4096):
        self._keys = List[UInt64](length=capacity, fill=0)
        self._ids = List[UInt32](length=capacity, fill=0)
        self._count = 0

    def __len__(self) -> Int:
        return self._count

    @always_inline
    def _slot(self, key: UInt64) -> Int:
        """
        Returns either the slot (index) containing this key,
        or an empty slot where it can be inserted.
        """
        var mask = len(self._keys) - 1
        var slot = Int(key & UInt64(mask))
        while self._ids[slot] != 0:
            if self._keys[slot] == key:
                break
            slot = (slot + 1) & mask
        return slot

    def get(self, key: UInt64) -> Optional[UInt32]:
        var encoded = self._ids[self._slot(key)]
        if encoded == 0:
            return None
        return encoded - 1

    def __getitem__(self, key: UInt64) raises -> UInt32:
        var value = self.get(key)
        if not value:
            raise Error("Key not found")
        return value.value()

    def __setitem__(mut self, key: UInt64, value: UInt32) raises:
        if value == UInt32.MAX:
            raise Error("UInt32.MAX is reserved")

        var slot = self._slot(key)
        if self._ids[slot] == 0:
            var capacity = len(self._keys)
            if self._count >= capacity - capacity // 4:
                self._grow()
                slot = self._slot(key)
            self._keys[slot] = key
            self._count += 1

        self._ids[slot] = value + 1

    def _grow(mut self):
        var capacity = len(self._keys) * 2
        var mask = capacity - 1
        var keys = List[UInt64](length=capacity, fill=0)
        var ids = List[UInt32](length=capacity, fill=0)

        for i in range(len(self._keys)):
            var encoded = self._ids[i]
            if encoded == 0:
                continue
            var key = self._keys[i]
            var slot = Int(key & UInt64(mask))
            while ids[slot] != 0:
                slot = (slot + 1) & mask
            keys[slot] = key
            ids[slot] = encoded

        self._keys = keys^
        self._ids = ids^
