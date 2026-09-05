from std.collections import Span
from std.hashlib import Hasher, hash


struct NilHasher(Hasher):
    var _value: UInt64

    def __init__(out self):
        self._value = 0

    def update(mut self, value: Some[Hashable]):
        comptime assert type_of(value) == UInt64, "Expected a prehashed UInt64"
        value.__hash__(self)

    def _update_with_simd(mut self, value: SIMD[_, _]):
        comptime assert value.dtype == DType.uint64 and value.length == 1
        self._value = UInt64(value[0])

    def _update_with_bytes(mut self, data: Span[Byte, _]):
        # Required by Hasher; unused for UInt64 dictionary keys.
        self._value = hash(data.unsafe_ptr(), len(data))

    def finish(var self) -> UInt64:
        return self._value
