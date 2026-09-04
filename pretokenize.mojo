from pcre2 import Regex, MatchSpan
from common import Token, int


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
        F: def(MatchSpan) raises
    ](self, corpus: String, callback: F) raises:
        var corpus_utf8 = corpus.as_bytes()

        # Split with regex
        if self.regex:
            var pattern = self.regex.value()
            var re = Regex(pattern)

            re.for_each_span(corpus, callback)

        # Split on whitespace
        elif self.whitespace:
            var start = 0

            for end in range(len(corpus_utf8)):
                var byte = corpus_utf8[end]
                var is_whitespace = byte == 0x20 or (
                    byte >= 0x09 and byte <= 0x0D
                )

                if is_whitespace:
                    if start < end:
                        callback(MatchSpan(start, end))
                    start = end + 1

            var end = len(corpus_utf8)
            if start < end:
                callback(MatchSpan(start, end))

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
