from std.collections import Counter, Set, BinaryHeap
from std.utils import Variant
from std.hashlib import hash
from std.os.path import exists, getsize

from pretokenize import Pretokenizer, gpt5_pattern
from pcre2 import MatchSpan, Regex
from mmap import MappedFile
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
    IdMap,
)
from time import Duration, Instant, Profiler

comptime CORPUS_PATH = "data/wikitext-103-raw/wiki.train.raw"


def main() raises:
    var trainer = BPETrainer(
        min_frequency=1,
        pretokenizer=Pretokenizer.with_regex(gpt5_pattern()),
    )

    trainer.train(CORPUS_PATH, 50000)


struct BPETrainer:
    var pretokenizer: Pretokenizer

    var min_frequency: int
    var compaction_factor: int

    # Shared indices
    var words: List[Word]
    var word_counts: List[int]

    var pair_counts: Dict[Pair, int]
    # Reverse index to the set of words containing the pair specified by the key.
    var pair_to_words: Dict[Pair, Set[u32]]
    var heap: BinaryHeap[PairCount]

    var profiler: Profiler

    def __init__(
        out self,
        min_frequency: int,
        var pretokenizer: Pretokenizer,
        compaction_factor: int = 2,
    ) raises:
        self.pretokenizer = pretokenizer^

        self.min_frequency = min_frequency
        self.compaction_factor = compaction_factor

        self.words = List[Word]()
        self.word_counts = List[int]()

        self.pair_counts = Dict[Pair, int]()
        # Reverse index from pairs to word IDs that contain said pair.
        self.pair_to_words = Dict[Pair, Set[u32]]()
        self.heap = BinaryHeap[PairCount]()

        self.profiler = Profiler()

    def pretokenize(mut self, corpus_path: String) raises -> Int:
        """
        Map and pretokenize a file, storing unique words and counts in self.
        Return its byte length for throughput reporting. The mapping is released
        on return; stored words own their token bytes.
        """
        var timer = Instant.now()

        # mmap the corpus file
        var mapped_corpus = MappedFile(corpus_path)

        var corpus_bytes = mapped_corpus.as_bytes()
        var ptr = corpus_bytes.unsafe_ptr().as_unsafe_any_origin()

        # NOTE: We use a custom, insert-only data structure here because it's
        # much faster than a dict.
        var hash_to_id = IdMap(4096)
        var words = List[Word]()
        var counts = List[int]()

        def on_word(
            m: MatchSpan,
        ) raises {mut hash_to_id, mut words, mut counts, imm ptr}:
            var length = m.end - m.start
            # Hash the byte span
            var h = hash(ptr.unsafe_offset(m.start), length)
            var existing = hash_to_id.get(h)

            # If this hash already exists, don't reconstruct the word,
            # just increment count
            if existing:
                # TODO: Technically not collision safe
                counts[existing.value()] += 1
                return

            var id = u32(len(hash_to_id))
            var tokens = List[Token](capacity=length)

            for i in range(length):
                tokens.append(Token(ptr[unsafe_offset=m.start + i]))

            words.append(Word(tokens))
            counts.append(1)
            hash_to_id[h] = id

        self.pretokenizer.for_each(corpus_bytes, on_word)

        self.words = words^
        self.word_counts = counts^

        self.profiler.record("pretokenize", Instant.now().since(timer))
        return len(corpus_bytes)

    def initial_count(mut self) raises:
        var timer = Instant.now()

        for id, count in enumerate(self.word_counts):
            ref word = self.words[id]

            for i in range(len(word) - 1):
                var pair = pack_pair(word[i], word[i + 1])
                self.pair_counts.setdefault(pair, 0) += count
                self.pair_to_words.setdefault(pair, Set[u32]()).add(u32(id))

        for item in self.pair_counts.items():
            # Don't push the item to the heap if frequency is not eligible
            if item.value >= self.min_frequency:
                self.heap.push(PairCount(pair=item.key, count=item.value))

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

    def train(mut self, corpus_path: String, vocab_size: int) raises:
        if not exists(corpus_path):
            raise Error("Corpus file does not exist: ", corpus_path)

        print(t"Corpus size: {f32(getsize(corpus_path)) / 1e6} MB")

        var start = Instant.now()

        # Build up the initial vocabulary. This is a mapping from token indices
        # to their values. For the initial 256 bytes, this will be byte -> byte.
        var vocab: Dict[Token, List[Byte]] = {
            id: (List([Byte(id)])) for id in range(Token(256))
        }

        self.profiler.record(
            "initialize vocabulary", Instant.now().since(start)
        )

        var corpus_size = self.pretokenize(corpus_path)

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
            var deltas = List[Tuple[Pair, int]]()

            for id in word_ids:
                ref word = self.words[id]
                ref wc = self.word_counts[id]
                word.merge(left, right, new_id, deltas)

                for pair, diff in deltas:
                    ref count = self.pair_counts.setdefault(pair, 0)
                    count += diff * wc

                    if count <= 0:
                        _ = self.pair_counts.pop(pair)
                        if pair != top:
                            _ = self.pair_to_words.pop(pair)
                    elif diff > 0:
                        self.heap.push(PairCount(pair, count))
                        self.pair_to_words.setdefault(pair, Set[u32]()).add(id)

                deltas.clear()

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
            t" {f64(corpus_size) / 1e6 / elapsed.as_secs()} MB/s"
        )

        print(t"Merges checksum: {hex(hash(merges))}")
        print(t"Vocab checksum: {hex(hash(vocab))}")


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
