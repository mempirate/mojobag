from std.collections import Counter

from pretokenize import gpt5_pattern
from pcre2 import MatchSpan, Regex
from main import f32, f64, u32, u64, usize, int, Token
from time import Instant, Duration


def main() raises:
    with open("corpus.md", "r") as f:
        var corpus = f.read()

        print(t"Corpus size: {f32(corpus.byte_length()) / 1e6} MB")

        var trainer = BPETrainer()
        trainer.train(corpus, 50000)


comptime TokenString = List[Token]


struct BPETrainer:
    var regex: Regex
    var word_counts: Counter[TokenString]

    def __init__(out self) raises:
        self.regex = Regex(gpt5_pattern())
        self.word_counts = Counter[TokenString]()

    def train(mut self, corpus: String, vocab_size: int) raises:
        var start = Instant.now()
        # Build up the initial vocabulary. This is a mapping from token indices
        # to their values. For the initial 256 bytes, this will be byte -> byte.
        var vocab: Dict[Token, List[Byte]] = {
            id: (List([Byte(id)])) for id in range(Token(256))
        }

        # Keep the accumulator local so the callback does not mutably capture
        # all of `self` while `self.regex` is borrowed by `for_each_span`.
        var word_counts = Counter[TokenString]()

        def count_word(m: MatchSpan) raises {mut word_counts, imm corpus}:
            var corpus_utf8 = corpus.as_bytes()
            var word = [
                Token(b)
                for b in corpus_utf8.unsafe_subspan(
                    offset=m.start, length=m.end - m.start
                )
            ]

            word_counts[word] += 1

        self.regex.for_each_span(corpus, count_word)
        self.word_counts = word_counts^

        print(
            t"Pretokenization took {Instant.now().since(start).as_millis()} ms"
        )

        print("Most common words in corpus:")
        for item in self.word_counts.most_common(5):
            var word_bytes = List[Byte](capacity=len(item._value))
            for token in item._value:
                word_bytes.append(Byte(token))

            print(String(from_utf8=word_bytes), "\t=>", item._count)

        var num_merges = vocab_size - len(vocab)

        var merges = List[Tuple[u32, u32]]()

        var pair_counts = Counter[Tuple[Token, Token]]()

        for item in self.word_counts.items():
            ref word = item.key
            var count = item.value

            for i in range(len(word) - 1):
                var pair = (Token(word[i]), Token(word[i + 1]))
                pair_counts[pair] += count

        for _ in range(num_merges):
            if not pair_counts:
                break

            # Get the most common pair
            var top_pair = pair_counts.most_common(1)[0]._value
            var new_id = u32(len(vocab))

            # Create the new token, record the mapping to the original byte values.
            var merged = vocab[top_pair[0]].copy()
            merged.extend(vocab[top_pair[1]].copy())
            vocab[new_id] = merged^

            merges.append(top_pair)

            var word_counts = Counter[TokenString]()

            for item in self.word_counts.items():
                ref word = item.key
                var count = item.value

                if top_pair not in get_pairs(word):
                    word_counts[word] = count
                else:
                    for pair in get_pairs(word):
                        pair_counts[pair] -= count

                        if pair_counts[pair] == 0:
                            _ = pair_counts.pop(pair)

                    var new_word = merge_word(word, top_pair, new_id)
                    word_counts[new_word] = count

                    for pair in get_pairs(new_word):
                        pair_counts[pair] += count

            self.word_counts = word_counts^

        print(t"Done in {Instant.now().since(start).as_millis()} ms")
        print(t"Number of merges: {len(merges)}")
        print(t"Vocab size: {len(vocab)}")


def get_pairs(word: TokenString) -> List[Tuple[Token, Token]]:
    return [(Token(word[i]), Token(word[i + 1])) for i in range(len(word) - 1)]


def merge_word(
    word: TokenString, pair: Tuple[Token, Token], new_id: Token
) -> TokenString:
    var new_word = TokenString()
    var i = 0
    while i < len(word):
        if i < len(word) - 1 and word[i] == pair[0] and word[i + 1] == pair[1]:
            new_word.append(new_id)
            i += 2
        else:
            new_word.append(word[i])
            i += 1

    return new_word^
