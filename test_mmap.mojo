from std.testing import assert_equal, assert_raises, TestSuite
from std.ffi import external_call, c_int
from std.os import remove
from mmap import MappedFile
from pretokenize import Pretokenizer, gpt5_pattern
from common import MatchSpan


def test_contents_and_move() raises:
    var mapped = MappedFile("mmap.mojo")
    var moved = mapped^
    with open("mmap.mojo", "r") as file:
        var expected = file.read_bytes()
        var actual = moved.as_bytes()
        assert_equal(len(moved), len(expected))
        for i in range(len(expected)):
            assert_equal(actual[i], expected[i])
        var slice = actual[1:5]
        assert_equal(len(slice), 4)
        assert_equal(slice[0], expected[1])


def test_empty_and_missing() raises:
    var path = String("/tmp/mojobag-mmap-test-") + String(
        external_call["getpid", c_int]()
    )
    with open(path, "w") as file:
        pass
    try:
        var mapped = MappedFile(path)
        assert_equal(len(mapped), 0)
        assert_equal(len(mapped.as_bytes()), 0)
    finally:
        remove(path)
    with assert_raises():
        _ = MappedFile(path)


def test_pretokenize_mapping() raises:
    var mapped = MappedFile("mmap.mojo")
    with open("mmap.mojo", "r") as file:
        var text = file.read()
        for whitespace in range(2):
            var mode = (
                Pretokenizer.whitespace() if whitespace else
                Pretokenizer.regex(gpt5_pattern(), anchored=True)
            )
            var expected = List[Int]()
            var actual = List[Int]()
            def collect_expected(span: MatchSpan) raises {mut expected}:
                expected.append(span.start)
                expected.append(span.end)
            def collect_actual(span: MatchSpan) raises {mut actual}:
                actual.append(span.start)
                actual.append(span.end)
            mode.for_each(text, collect_expected)
            mode.for_each(mapped.as_bytes(), collect_actual)
            assert_equal(len(actual), len(expected))
            for i in range(len(actual)):
                assert_equal(actual[i], expected[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
