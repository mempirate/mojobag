from pcre2 import Regex, MatchSpan
from common import Token


@fieldwise_init
struct Pretokenizer:
    var whitespace: Bool
    var regex: Optional[String]

    @staticmethod
    def with_whitespace() -> Self:
        return Self(whitespace=True, regex=None)

    @staticmethod
    def with_regex(pattern: String) -> Self:
        return Self(whitespace=False, regex=pattern)

    def for_each[
        F: def(var List[Token])
    ](self, corpus: String, callback: F) raises:
        var corpus_utf8 = corpus.as_bytes()

        if self.regex:
            var pattern = self.regex.value()
            var re = Regex(pattern)

            # The callback cannot currently capture an origin-bound Span directly.
            # The corpus remains alive for the entire synchronous traversal.
            var corpus_ptr = corpus_utf8.unsafe_ptr().as_unsafe_any_origin()

            def on_match(m: MatchSpan) raises {imm callback, imm corpus_ptr}:
                var length = m.end - m.start
                var word = List[Token](capacity=length)
                for i in range(length):
                    word.append(Token(corpus_ptr[unsafe_offset=m.start + i]))

                callback(word^)

            re.for_each_span(corpus, on_match)
        elif self.whitespace:
            var start = 0

            for end in range(len(corpus_utf8)):
                var byte = corpus_utf8[end]
                var is_whitespace = byte == 0x20 or (
                    byte >= 0x09 and byte <= 0x0D
                )

                if is_whitespace:
                    if start < end:
                        # EMIT WORD
                        var word = List[Token](capacity=end - start)
                        for c in corpus_utf8[start:end]:
                            word.append(Token(c))

                        callback(word^)
                    start = end + 1

            var end = len(corpus_utf8)
            if start < end:
                var word = List[Token](capacity=end - start)
                for c in corpus_utf8[start:end]:
                    word.append(Token(c))

                callback(word^)

        else:
            raise "No pretokenizer set. Choose between regex or whitespace."


def gpt5_pattern() -> String:
    """The o200k pretokenization pattern used by GPT-5-family encodings."""

    return (
        "[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]*"
        "[\\p{Ll}\\p{Lm}\\p{Lo}\\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|"
        "[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]+"
        "[\\p{Ll}\\p{Lm}\\p{Lo}\\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|"
        "\\p{N}{1,3}|"
        " ?[^\\s\\p{L}\\p{N}]+[\\r\\n/]*|"
        "\\s*[\\r\\n]+|"
        "\\s+(?!\\S)|"
        "\\s+"
    )
