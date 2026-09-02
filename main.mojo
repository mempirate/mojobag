from std.collections import Counter, BinaryHeap
from time import Duration, Instant

# Type aliases for common numeric types.
comptime u32 = UInt32
comptime u64 = UInt64
comptime f32 = Float32
comptime f64 = Float64
comptime int = Int
comptime usize = UInt


# Type alias for a token, represented by a UInt32. The range of values
# here is quite a lot higher than what we'll need, but UInt16 is too small
# (only 65536).
comptime Token = u32
# Type alias for a pair of tokens.
comptime Pair = u64

comptime TARGET_VOCABULARY_SIZE = 50000


def main() raises:
    with open("corpus.md", "r") as f:
        var corpus = f.read()

        print(t"Text bytes: {f32(corpus.byte_length()) / 1e6} MB")

        var tokenizer = Tokenizer()

        tokenizer.train(corpus, TARGET_VOCABULARY_SIZE)


@fieldwise_init
struct PairCount(Comparable, Copyable, Deinitable):
    var pair: Pair
    var count: int

    def __lt__(self, rhs: Self) -> Bool:
        return self.count < rhs.count

    def __le__(self, rhs: Self) -> Bool:
        return self.count <= rhs.count

    def __eq__(self, rhs: Self) -> Bool:
        return self.count == rhs.count

    def __ne__(self, rhs: Self) -> Bool:
        return self.count != rhs.count

    def __gt__(self, rhs: Self) -> Bool:
        return self.count > rhs.count

    def __ge__(self, rhs: Self) -> Bool:
        return self.count >= rhs.count


struct Tokenizer:
    var merges: Dict[Pair, Token]

    var counts: Counter[Pair]
    var pair_to_tokens: Dict[Pair, List[int]]
    # List of dirty edge indices in the list of tokens. These are
    # the indices whose pairs need to be recounted (int represents the
    # left index of the pair).
    var dirty: Optional[List[int]]
    var top_candidates: BinaryHeap[PairCount]

    var count_duration: Duration
    var most_common_duration: Duration
    var merge_duration: Duration

    def __init__(out self):
        self.merges = Dict[Pair, Token]()

        self.counts = Counter[Pair]()
        self.pair_to_tokens = Dict[Pair, List[int]]()
        self.dirty = None
        self.top_candidates = BinaryHeap[PairCount]()

        self.count_duration = Duration(0)
        self.most_common_duration = Duration(0)
        self.merge_duration = Duration(0)

    def decrement_count(mut self, pair: Pair):
        """
        Decrements the count for `pair`, removing it from the `self.counts` Counter
        if the count hits zero.
        """
        self.counts[pair] -= 1

        if not self.counts[pair]:
            var _ = self.counts.pop(pair, 0)

    def increment_count(mut self, pair: Pair):
        self.counts[pair] += 1

        self.top_candidates.push(PairCount(pair, self.counts[pair]))

    def count_pairs(mut self, tokens: List[Token]) raises:
        if len(tokens) < 2:
            return

        if not self.dirty:
            # If we have no dirty indices yet, build up the full count for the first time.
            for i, (first, second) in enumerate(zip(tokens, tokens[1:])):
                var pair = pack_pair(first, second)

                self.counts[pair] += 1
                self.pair_to_tokens[pair].append(i)

            # Populate the initial top candidates heap.
            for item in self.counts.items():
                self.top_candidates.push(
                    PairCount(pair=item.key, count=item.value)
                )

        else:
            # Else, only recount neighbours of dirty indices (newly inserted tokens)
            ref dirty = self.dirty.value()
            for i in dirty:
                if i < len(tokens) - 1:
                    var pair = pack_pair(tokens[i], tokens[i + 1])

                    self.increment_count(pair)
                    self.pair_to_tokens[pair].append(i)

            dirty.clear()

    def most_common(mut self) -> Optional[Pair]:
        if self.counts and len(self.top_candidates) > 0:
            # Iterate over the top candidates
            while len(self.top_candidates) > 0:
                ref candidate = self.top_candidates.peek()

                var actual_count = self.counts[candidate.pair]

                if actual_count < 2:
                    # Remove the candidate
                    _ = self.top_candidates.pop()

                    continue

                if candidate.count != actual_count:
                    # Update the stale candidate
                    var pair = candidate.pair

                    _ = self.top_candidates.pop()
                    self.top_candidates.push(PairCount(pair, actual_count))

                    continue

                return candidate.pair

            return None
        elif self.counts:
            var pair = self.counts.most_common(1)[0].copy()
            return pair._value if pair._count > 1 else None
        else:
            return None

    def merge(mut self, mut tokens: List[Token], pair: Pair, new: Token):
        """
        Merges the sequence of `tokens` in place, replacing each `pair`, with a new
        `token`.
        """
        # Read cursor
        var read = 0
        # Write cursor
        var write = 0

        var first, second = unpack_pair(pair)

        # Cache the right pair's edge of the previous iteration, to make
        # sure we don't decrement it twice. We start at -1 to ensure
        # the first iteration passes correctly (could also start at 0
        # and add another condition, but branching in this loop is expensive).
        var prev_right_edge: int = -1

        var indices = self.pair_to_tokens.get(pair, [])

        for i in indices:
            _ = i

        while read < len(tokens):
            if (
                read < len(tokens) - 1
                and tokens[read] == first
                and tokens[read + 1] == second
            ):
                # If there is a match, we write the new pair at the `write` cursor.
                # Then, increment the `write` by 1, and `read` by 2 (to skip over the
                # old, second element of the pair, which will be overwritten in the next
                # iteration).

                # For every merged pair, decrement the count.
                self.decrement_count(pair)

                # Fix counts of stale neighboring pairs.
                # First, the left pair.
                if read > 0 and read - 1 > prev_right_edge:
                    var pair_left = pack_pair(tokens[read - 1], tokens[read])
                    self.decrement_count(pair_left)

                # Then the right pair.
                if read + 2 < len(tokens):
                    var pair_right = pack_pair(
                        tokens[read + 1], tokens[read + 2]
                    )
                    self.decrement_count(pair_right)
                    prev_right_edge = read + 1

                tokens[write] = new

                # Record dirty indices
                if self.dirty:
                    ref dirty = self.dirty.value()
                    # Record potential new left pair as dirty:
                    if write > 0 and (
                        len(dirty) == 0 or dirty[len(dirty) - 1] != write - 1
                    ):
                        dirty.append(write - 1)

                    # Also record potential right pair as dirty:
                    if write < len(tokens):
                        dirty.append(write)

                else:
                    # Initialize a new dirty list
                    self.dirty = List[int]()

                    ref dirty = self.dirty.value()

                    # Record potential new left pair as dirty:
                    if write > 0:
                        dirty.append(write - 1)

                    # Also record potential right pair as dirty:
                    if write < len(tokens):
                        dirty.append(write)

                write += 1
                read += 2

            else:
                # If there's no match, we just shift the remaining elements forward.

                tokens[write] = tokens[read]
                read += 1
                write += 1

        tokens.shrink(write)

    def train(mut self, text: String, target_vocab_size: u32) raises:
        var text_len = text.byte_length()
        if text_len == 0:
            raise "Empty string"

        # The new tokens will start at 256 (max byte value + 1).
        var new = Token(2**8)

        if target_vocab_size < new:
            raise "Target vocabulary size too small"

        # Convert the text into UTF-8 bytes (casted to Token). This sets
        # the initial vocabulary before any merging.
        var tokens = to_tokens(text)

        # Create a copy of the original tokens to work with.
        var merged = tokens.copy()

        var iters = target_vocab_size - new

        var train_start = Instant.now()

        # Loop until we've reached our target vocabulary.
        for _ in range(iters):
            var timer = Instant.now()
            self.count_pairs(merged)

            self.count_duration += Instant.now().since(timer)

            timer = Instant.now()
            var most_common = self.most_common()
            self.most_common_duration += Instant.now().since(timer)

            if most_common:
                var most_common = most_common.take()

                timer = Instant.now()
                self.merge(merged, most_common, new)

                self.merge_duration += Instant.now().since(timer)

                # Record the merge.
                self.merges[most_common] = new

                new += 1
            else:
                break

        var elapsed = Instant.now().since(train_start)
        var elapsed_secs = elapsed.as_secs()

        print(
            t"Total merges: {len(self.merges)}, vocabulary size:"
            t" {256 + len(self.merges)}"
        )
        print(t"Tokens length: {len(tokens)}")
        print(t"Merged length: {len(merged)}")
        print(t"Compression ratio: {f32(len(tokens)) / f32(len(merged))}x")

        print(t"Done in {elapsed_secs * 1000} ms")
        print()
        print(
            t"Count\tTop\tMerge\n"
            t"{self.count_duration.as_millis()}\t{self.most_common_duration.as_millis()}\t{self.merge_duration.as_millis()}"
        )
        print()

        print(
            "Training throughput:",
            (f64(text_len) / elapsed_secs) / 1e6,
            "MB/s",
        )

    def encode(self, text: String) -> List[Int]:
        return []

    def decode(self, tokens: List[Int]) -> String:
        return ""


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


def to_tokens(str: String) -> List[Token]:
    return [Token(b) for b in str.bytes()]
