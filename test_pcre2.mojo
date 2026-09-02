from pcre2 import PCRE2Regex
from pretokenize import gpt5_pattern
from std.testing import assert_equal


def main() raises:
    var text = "Hello, WORLD! 1234\nI'm fine. Привет世界 café"
    var regex = PCRE2Regex(gpt5_pattern())
    var spans = regex.find_all_spans(text)

    var expected_starts = [0, 5, 6, 12, 13, 14, 17, 18, 19, 22, 27, 28, 47]
    var expected_ends = [5, 6, 12, 13, 14, 17, 18, 19, 22, 27, 28, 47, 53]

    assert_equal(len(spans), len(expected_starts))
    for i in range(len(spans)):
        assert_equal(spans[i].start, expected_starts[i])
        assert_equal(spans[i].end, expected_ends[i])

        if i > 0:
            assert_equal(spans[i - 1].end, spans[i].start)

    assert_equal(spans[0].start, 0)
    assert_equal(spans[len(spans) - 1].end, text.byte_length())
    assert_equal(len(regex.find_all_spans("")), 0)

    print("PCRE2 GPT-5 pretokenization test passed")
