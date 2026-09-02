from pcre2 import Regex, MatchSpan


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
