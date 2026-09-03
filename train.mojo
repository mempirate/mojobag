from std.collections import Counter, Set, BinaryHeap

from pretokenize import gpt5_pattern
from pcre2 import MatchSpan, Regex
from main import (
    Pair,
    Token,
    f32,
    f64,
    int,
    pack_pair,
    u32,
    u64,
    unpack_pair,
    usize,
)
from time import Duration, Instant, Profiler


def main() raises:
    with open("corpus.md", "r") as f:
        var corpus = f.read()

        print(t"Corpus size: {f32(corpus.byte_length()) / 1e6} MB")

        var trainer = BPETrainer(min_frequency=1)
        trainer.train(corpus, 50000)


comptime TokenString = List[Token]


struct BPETrainer:
    var regex: Regex
    var min_frequency: int
    var word_counts: Counter[TokenString]

    def __init__(out self, min_frequency: int) raises:
        self.regex = Regex(gpt5_pattern())
        self.min_frequency = min_frequency
        self.word_counts = Counter[TokenString]()

    def train(mut self, corpus: String, vocab_size: int) raises:
        var profiler = Profiler()
        var start = Instant.now()

        # Build up the initial vocabulary. This is a mapping from token indices
        # to their values. For the initial 256 bytes, this will be byte -> byte.
        var vocab: Dict[Token, List[Byte]] = {
            id: (List([Byte(id)])) for id in range(Token(256))
        }
        profiler.record("initialize vocabulary", Instant.now().since(start))

        # Keep the accumulator local so the callback does not mutably capture
        # all of `self` while `self.regex` is borrowed by `for_each_span`.
        var timer = Instant.now()
        var word_counter = Counter[TokenString]()

        def count_word(m: MatchSpan) raises {mut word_counter, imm corpus}:
            var corpus_utf8 = corpus.as_bytes()
            var word = [
                Token(b)
                for b in corpus_utf8.unsafe_subspan(
                    offset=m.start, length=m.end - m.start
                )
            ]

            word_counter[word] += 1

        var words = Dict[u32, TokenString]()
        var word_counts = Dict[u32, int]()

        self.regex.for_each_span(corpus, count_word)

        for id, item in enumerate(word_counter.items()):
            words[u32(id)] = item.key.copy()
            word_counts[u32(id)] = item.value

        profiler.record("pretokenize", Instant.now().since(timer))

        var num_merges = vocab_size - len(vocab)

        timer = Instant.now()
        var pair_counts = Dict[Pair, int]()
        # Reverse index from pairs to word IDs that contain said pair.
        var pair_to_words = Dict[Pair, Set[u32]]()

        for item in word_counts.items():
            ref id = item.key
            var count = item.value

            ref word = words[id]

            for i in range(len(word) - 1):
                var pair = pack_pair(word[i], word[i + 1])
                pair_counts.setdefault(pair, 0) += count
                pair_to_words.setdefault(pair, Set[u32]()).add(id)

        var heap = BinaryHeap[PairCount]()
        for item in pair_counts.items():
            var entry = PairCount(pair=item.key, count=item.value)

            heap.push(entry^)

        profiler.record("initialize pair counts", Instant.now().since(timer))

        var merges = List[Pair]()

        var select_pair_duration = Duration(0)
        var update_vocabulary_duration = Duration(0)
        var merge_words_duration = Duration(0)

        for _ in range(num_merges):
            if not pair_counts:
                break

            # Get the most common pair
            timer = Instant.now()

            var top_pair: Optional[Pair] = None

            while len(heap) > 0:
                ref candidate = heap.peek()

                # Pop removed pairs
                if candidate.pair not in pair_counts:
                    _ = heap.pop()

                    continue

                var actual_count = pair_counts[candidate.pair]

                # Pop useless pair counts
                if actual_count < self.min_frequency:
                    _ = heap.pop()

                    continue

                if candidate.count != actual_count:
                    # Update stale candidate
                    var pair = candidate.pair

                    _ = heap.pop()
                    heap.push(PairCount(pair=pair, count=actual_count))

                    continue

                top_pair = candidate.pair
                break

            select_pair_duration += Instant.now().since(timer)

            if not top_pair:
                break

            var top = top_pair.take()
            var left, right = unpack_pair(top)

            var new_id = u32(len(vocab))

            # Create the new token, record the mapping to the original byte values.
            timer = Instant.now()
            var merged = vocab[left].copy()
            merged.extend(vocab[right].copy())
            vocab[new_id] = merged^

            merges.append(top)
            update_vocabulary_duration += Instant.now().since(timer)

            # Merge loop:
            timer = Instant.now()

            # Get the affected word IDs
            var word_ids = List(pair_to_words[top])

            for id in word_ids:
                var count = word_counts[id]
                ref word = words[id]

                # TODO: this does more work than it needs to.
                # For every pair in the word, we eagerly remove it from
                # all memory (even if the pair is unaffected). We then proceed
                # to rebuild the word and all the pair references again.
                # Another side effect of this is that we push way more heap entries
                # than we should. We could instead operate only on the pair in question and its neighbors.

                # Remove stale pair counts and index occurences
                for i in range(len(word) - 1):
                    var pair = pack_pair(word[i], word[i + 1])
                    ref pc = pair_counts[pair]
                    pc -= count

                    if pc <= 0:
                        _ = pair_counts.pop(pair)

                    pair_to_words[pair].discard(id)

                var new_word = TokenString()
                var i = 0

                while i < len(word):
                    var emitted: Token

                    if (
                        i < len(word) - 1
                        and word[i] == left
                        and word[i + 1] == right
                    ):
                        emitted = new_id
                        i += 2
                    else:
                        emitted = word[i]
                        i += 1

                    if new_word:
                        var pair = pack_pair(
                            new_word[len(new_word) - 1], emitted
                        )

                        ref pc = pair_counts.setdefault(pair, 0)
                        pc += count
                        heap.push(PairCount(pair=pair, count=pc))
                        pair_to_words.setdefault(pair, Set[u32]()).add(id)

                words[id] = new_word^

            _ = pair_to_words.pop(top)

            merge_words_duration += Instant.now().since(timer)

        # Total elapsed time
        var elapsed = Instant.now().since(start)

        profiler.record("merge words", merge_words_duration)
        profiler.record("top pair", select_pair_duration)
        profiler.record("update vocabulary", update_vocabulary_duration)

        print(profiler)
        print(t"Number of merges: {len(merges)}")
        print(t"Vocab size: {len(vocab)}")
        print(
            t"Training throughput:"
            t" {f64(corpus.byte_length()) / 1e6 / elapsed.as_secs()} MB/s"
        )


def get_pairs(word: TokenString) -> List[Pair]:
    return [pack_pair(word[i], word[i + 1]) for i in range(len(word) - 1)]


def contains_pair(word: TokenString, pair: Pair) -> Bool:
    var left, right = unpack_pair(pair)

    for i in range(len(word) - 1):
        if word[i] == left and word[i + 1] == right:
            return True

    return False


def merge_word(word: TokenString, pair: Pair, new_id: Token) -> TokenString:
    var left, right = unpack_pair(pair)
    var new_word = TokenString()
    var i = 0
    while i < len(word):
        if i < len(word) - 1 and word[i] == left and word[i + 1] == right:
            new_word.append(new_id)
            i += 2
        else:
            new_word.append(word[i])
            i += 1

    return new_word^


@fieldwise_init
struct PairCount(Comparable, Copyable, Deinitable):
    var pair: Pair
    var count: int

    def __lt__(self, rhs: Self) -> Bool:
        return self.count < rhs.count
