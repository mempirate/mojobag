from std.ffi import OwnedDLHandle
from std.memory import Pointer
from std.os import abort
from std.sys import CompilationTarget

from common import MatchSpan


comptime _ForeignPtr = Pointer[NoneType, MutUntrackedOrigin]
comptime _NullableForeignPtr = Optional[_ForeignPtr]

comptime _PCRE2_UCP = UInt32(0x0002_0000)
comptime _PCRE2_UTF = UInt32(0x0008_0000)
comptime _PCRE2_JIT_COMPLETE = UInt32(0x0000_0001)
comptime _PCRE2_INFO_JITSIZE = UInt32(10)
comptime _PCRE2_ERROR_NOMATCH = Int32(-1)


struct Regex(Movable):
    """An owning, JIT-compiled wrapper around PCRE2's 8-bit API.

    JIT compilation is mandatory; failure aborts the process. Subjects must
    be valid UTF-8: the direct JIT API does not validate them.
    The match-data buffer is reused, so a value must not be used concurrently.
    """

    var _lib: OwnedDLHandle
    var _code: _NullableForeignPtr
    var _match_data: _NullableForeignPtr

    def __init__(out self, pattern: String) raises:
        comptime if CompilationTarget.is_macos():
            self._lib = OwnedDLHandle("libpcre2-8.dylib")
        else:
            self._lib = OwnedDLHandle("libpcre2-8.so")
        self._code = None
        self._match_data = None

        var error_code = Int32(0)
        var error_offset = UInt(0)
        var pattern_bytes = pattern.as_bytes()
        var null_context: _NullableForeignPtr = None

        var code = self._lib.call["pcre2_compile_8", _NullableForeignPtr](
            pattern_bytes.unsafe_ptr(),
            UInt(len(pattern_bytes)),
            _PCRE2_UTF | _PCRE2_UCP,
            Pointer(to=error_code),
            Pointer(to=error_offset),
            null_context,
        )

        if not code:
            raise Error(
                "PCRE2 compilation failed with error ",
                error_code,
                " at byte ",
                error_offset,
            )

        self._code = code.take()

        var jit_result = self._lib.call["pcre2_jit_compile_8", Int32](
            self._code.value(), _PCRE2_JIT_COMPLETE
        )
        if jit_result != 0:
            abort(
                String("PCRE2 JIT compilation required; error ") + String(jit_result)
            )
        # A pattern can explicitly disable JIT with (*NO_JIT).
        var jit_size = UInt(0)
        var info_result = self._lib.call["pcre2_pattern_info_8", Int32](
            self._code.value(), _PCRE2_INFO_JITSIZE, Pointer(to=jit_size)
        )
        if info_result != 0 or jit_size == 0:
            abort("PCRE2 JIT compilation required; no JIT code available")
        var match_data = self._lib.call[
            "pcre2_match_data_create_from_pattern_8", _NullableForeignPtr
        ](self._code.value(), null_context)
        if not match_data:
            raise Error("PCRE2 could not allocate match data")

        self._match_data = match_data.take()

    def __deinit__(deinit self):
        if self._match_data:
            self._lib.call["pcre2_match_data_free_8"](self._match_data.take())

        if self._code:
            self._lib.call["pcre2_code_free_8"](self._code.take())

    def find_next(
        self, text: String, start_offset: Int = 0
    ) raises -> Optional[MatchSpan]:
        """Find the first match at or after a UTF-8 byte offset."""

        if start_offset < 0 or start_offset > text.byte_length():
            raise Error("match start offset is outside the subject")

        var subject = text.as_bytes()
        var subject_length = UInt(len(subject))
        var null_context: _NullableForeignPtr = None
        var match_fn = self._lib.get_function[Int32]("pcre2_jit_match_8")
        var rc = match_fn(
            self._code.value(),
            subject.unsafe_ptr(),
            subject_length,
            UInt(start_offset),
            UInt32(0),
            self._match_data.value(),
            null_context,
        )

        if rc == _PCRE2_ERROR_NOMATCH:
            return None
        if rc < 0:
            raise Error("PCRE2 matching failed with error ", rc)

        var ovector = self._lib.call[
            "pcre2_get_ovector_pointer_8",
            Pointer[UInt, MutUntrackedOrigin],
        ](self._match_data.value())
        var start = ovector[unsafe_offset=0]
        var end = ovector[unsafe_offset=1]

        if end <= start:
            raise Error("zero-length matches are not supported")

        return MatchSpan(Int(start), Int(end))

    def find_all_spans(self, text: String) raises -> List[MatchSpan]:
        """Return non-overlapping matches as half-open UTF-8 byte ranges."""

        var result = List[MatchSpan]()

        def append_span(span: MatchSpan) raises {mut result}:
            result.append(span)

        self.for_each_span(text, append_span)

        return result^

    def for_each_span[
        FuncType: def(MatchSpan) raises -> None
    ](self, text: String, callback: FuncType) raises:
        """Call `callback` for each match without allocating a match list."""

        self.for_each_span(text.as_bytes(), callback)

    def for_each_span[
        FuncType: def(MatchSpan) raises -> None
    ](self, subject: Span[Byte, _], callback: FuncType) raises:
        """Match borrowed UTF-8 bytes without copying the subject.

        The subject must be complete, valid UTF-8. Callbacks run synchronously
        while it is borrowed; offsets are relative to this byte view.
        """
        var subject_length = UInt(len(subject))
        var offset = UInt(0)
        var null_context: _NullableForeignPtr = None
        var match_fn = self._lib.get_function[Int32]("pcre2_jit_match_8")
        var ovector_fn = self._lib.get_function[
            Pointer[UInt, MutUntrackedOrigin]
        ]("pcre2_get_ovector_pointer_8")

        while offset < subject_length:
            var rc = match_fn(
                self._code.value(),
                subject.unsafe_ptr(),
                subject_length,
                offset,
                UInt32(0),
                self._match_data.value(),
                null_context,
            )

            if rc == _PCRE2_ERROR_NOMATCH:
                break

            if rc < 0:
                raise Error("PCRE2 matching failed with error ", rc)

            var ovector = ovector_fn(self._match_data.value())
            var start = ovector[unsafe_offset=0]
            var end = ovector[unsafe_offset=1]

            if end <= start:
                raise Error("zero-length matches are not supported")

            callback(MatchSpan(Int(start), Int(end)))

            offset = end
