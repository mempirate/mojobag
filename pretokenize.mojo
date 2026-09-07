from pcre2 import Regex, MatchSpan
from common import Token, int


@fieldwise_init
struct Pretokenizer:
    var _whitespace: Bool
    var _regex: Optional[String]
    var _anchored: Bool

    @staticmethod
    def whitespace() -> Self:
        return Self(_whitespace=True, _regex=None, _anchored=False)

    @staticmethod
    def regex(pattern: String, *, anchored: Bool = False) -> Self:
        """Use anchored=True only for patterns that cover every input byte.

        Anchoring avoids searching ahead. Unmatched input raises instead of
        silently dropping the rest of the corpus.
        """
        return Self(_whitespace=False, _regex=pattern, _anchored=anchored)

    def for_each[
        F: def(MatchSpan) raises
    ](self, corpus: String, callback: F) raises:
        self.for_each(corpus.as_bytes(), callback)

    def for_each[
        F: def(MatchSpan) raises
    ](self, corpus_utf8: Span[Byte, _], callback: F) raises:
        """Pretokenize a complete borrowed byte view without copying it.

        Regex mode expects valid UTF-8; whitespace mode scans raw bytes.
        Callback offsets are relative to this view.
        """

        # Split with regex
        if self._regex:
            var pattern = self._regex.value()
            var re = Regex(pattern, anchored=self._anchored)

            if self._anchored:
                var end = 0
                def visit(span: MatchSpan) raises {mut end, imm callback}:
                    callback(span)
                    end = span.end
                re.for_each_span(corpus_utf8, visit)
                if end != len(corpus_utf8):
                    raise Error("Anchored pretokenizer failed at byte ", end)
            else:
                re.for_each_span(corpus_utf8, callback)

        # Split on whitespace
        elif self._whitespace:
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
