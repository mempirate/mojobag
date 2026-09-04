from std.collections import Counter, Set, BinaryHeap

from pretokenize import gpt5_pattern
from pcre2 import MatchSpan, Regex
from word import Word
from common import (
    Pair,
    Token,
    f32,
    f64,
    int,
    pack_pair,
    u32,
    u64,
    i32,
    unpack_pair,
    usize,
)
from time import Duration, Instant, Profiler

# comptime CORPUS = "corpus.md"
comptime CORPUS = "data/wikitext-103-raw/wiki.train.raw"


def main() raises:
    with open(CORPUS, "r") as f:
        var corpus = f.read()

        print(t"Corpus size: {f32(corpus.byte_length()) / 1e6} MB")

        var trainer = BPETrainer(min_frequency=1)
        trainer.train(corpus, 50000)


struct BPETrainer:
    var regex: Regex

    var min_frequency: int
    var compaction_factor: int

    var words: Dict[u32, Word]
    var word_counts: Dict[u32, int]
    var pair_counts: Dict[Pair, int]
    # Reverse index to the set of words containing the pair specified by the key.
    var pair_to_words: Dict[Pair, Set[u32]]
    var heap: BinaryHeap[PairCount]

    var profiler: Profiler

    def __init__(
        out self,
        min_frequency: int,
        compaction_factor: int = 2,
    ) raises:
        self.regex = Regex(gpt5_pattern())

        self.min_frequency = min_frequency
        self.compaction_factor = compaction_factor

        self.words = Dict[u32, Word]()
        self.word_counts = Dict[u32, int]()
        self.pair_counts = Dict[Pair, int]()
        # Reverse index from pairs to word IDs that contain said pair.
        self.pair_to_words = Dict[Pair, Set[u32]]()
        self.heap = BinaryHeap[PairCount]()

        self.profiler = Profiler()

    def pretokenize(mut self, corpus: String) raises:
        """
        Pretokenizes the corpus according to the specified regex pattern (self.regex), and
        stores the resulting words and word counts in self.
        """
        # Keep the accumulator local so the callback does not mutably capture
        # all of `self` while `self.regex` is borrowed by `for_each_span`.
        var timer = Instant.now()

        var word_counter = Dict[List[Token], int]()

        var corpus_utf8 = corpus.as_bytes()
        # The callback cannot currently capture an origin-bound Span directly.
        # The corpus remains alive for the entire synchronous traversal.
        var corpus_ptr = corpus_utf8.unsafe_ptr().as_unsafe_any_origin()

        def count_word(m: MatchSpan) raises {mut word_counter, imm corpus_ptr}:
            var length = m.end - m.start
            var word = List[Token](capacity=length)
            for i in range(length):
                word.append(Token(corpus_ptr[unsafe_offset=m.start + i]))

            word_counter.setdefault(word^, 0) += 1

        self.regex.for_each_span(corpus, count_word)

        var id = u32(0)
        for item in word_counter.items():
            self.word_counts[id] = item.value
            self.words[id] = Word(item.key)
            id += 1

        self.profiler.record("pretokenize", Instant.now().since(timer))

    def initial_count(mut self) raises:
        var timer = Instant.now()

        for item in self.word_counts.items():
            ref id = item.key
            var count = item.value

            ref word = self.words[id]

            for i in range(len(word) - 1):
                var pair = pack_pair(word[i], word[i + 1])
                self.pair_counts.setdefault(pair, 0) += count
                self.pair_to_words.setdefault(pair, Set[u32]()).add(id)

        for item in self.pair_counts.items():
            var entry = PairCount(pair=item.key, count=item.value)

            self.heap.push(entry^)

        self.profiler.record(
            "initialize pair counts", Instant.now().since(timer)
        )

    def find_top_pair(mut self) raises -> Optional[Pair]:
        var top_pair: Optional[Pair] = None

        while len(self.heap) > 0:
            ref candidate = self.heap.peek()

            # Pop removed pairs
            if candidate.pair not in self.pair_counts:
                _ = self.heap.pop()

                continue

            var actual_count = self.pair_counts[candidate.pair]

            # Pop useless pair counts
            if actual_count < self.min_frequency:
                _ = self.heap.pop()

                continue

            if candidate.count != actual_count:
                # Update stale candidate
                var pair = candidate.pair

                _ = self.heap.pop()
                self.heap.push(PairCount(pair=pair, count=actual_count))

                continue

            top_pair = candidate.pair
            break

        # Heap compaction if the heap exceeds active pairs * compaction_factor.
        if len(self.heap) > len(self.pair_counts) * self.compaction_factor:
            self.heap.clear()

            for item in self.pair_counts.items():
                var entry = PairCount(pair=item.key, count=item.value)

                self.heap.push(entry^)

        return top_pair

    def train(mut self, corpus: String, vocab_size: int) raises:
        var start = Instant.now()

        # Build up the initial vocabulary. This is a mapping from token indices
        # to their values. For the initial 256 bytes, this will be byte -> byte.
        var vocab: Dict[Token, List[Byte]] = {
            id: (List([Byte(id)])) for id in range(Token(256))
        }

        self.profiler.record(
            "initialize vocabulary", Instant.now().since(start)
        )

        self.pretokenize(corpus)

        self.initial_count()

        var num_merges = vocab_size - len(vocab)

        var merges = List[Pair]()

        var select_pair_duration = Duration(0)
        var update_vocabulary_duration = Duration(0)
        var merge_words_duration = Duration(0)

        for _ in range(num_merges):
            if not self.pair_counts:
                break

            var timer = Instant.now()

            # Get the most common pair
            var top_pair = self.find_top_pair()

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
            var word_ids = List(self.pair_to_words[top])

            for id in word_ids:
                ref word = self.words[id]
                var deltas = word.merge(left, right, new_id)

                for pair, diff in deltas:
                    ref count = self.pair_counts.setdefault(pair, 0)
                    count += diff * self.word_counts[id]

                    if count <= 0:
                        _ = self.pair_counts.pop(pair)
                    elif diff > 0:
                        self.heap.push(PairCount(pair, count))
                        self.pair_to_words.setdefault(pair, Set[u32]()).add(id)

            # The selected pair has been merged in every indexed word.
            _ = self.pair_to_words.pop(top)

            merge_words_duration += Instant.now().since(timer)

        # Total elapsed time
        var elapsed = Instant.now().since(start)

        self.profiler.record("merge words", merge_words_duration)
        self.profiler.record("top pair", select_pair_duration)
        self.profiler.record("update vocabulary", update_vocabulary_duration)

        print(self.profiler)
        print(t"Number of merges: {len(merges)}")
        print(t"Vocab size: {len(vocab)}")
        print(
            t"Training throughput:"
            t" {f64(corpus.byte_length()) / 1e6 / elapsed.as_secs()} MB/s"
        )


def get_pairs(word: Word) -> List[Pair]:
    return [pack_pair(word[i], word[i + 1]) for i in range(len(word) - 1)]


def contains_pair(word: Word, pair: Pair) -> Bool:
    var left, right = unpack_pair(pair)

    for i in range(len(word) - 1):
        if word[i] == left and word[i + 1] == right:
            return True

    return False


@fieldwise_init
struct PairCount(Comparable, Copyable, Deinitable):
    var pair: Pair
    var count: int

    def __lt__(self, rhs: Self) -> Bool:
        return self.count < rhs.count
