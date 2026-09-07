"""Read-only, whole-file memory mapping for 64-bit Linux and macOS."""

from std.ffi import external_call, c_int
from std.os import SEEK_END
from std.sys import CompilationTarget


struct MappedFile(Movable, Sized):
    """Own a file mapping and expose its bytes without copying or decoding.

    Example:
        var mapped = MappedFile("data/corpus.txt")
        var bytes = mapped.as_bytes()
        # Pass bytes (or its pointer and length) to the pretokenizer.

    The OS loads file-backed pages on demand; this does not bound resident
    memory. Views borrow this owner, which unmaps automatically on destruction.
    The file must remain unchanged while mapped, especially its size: truncation
    can cause a process-level fault. Empty files produce an empty view.
    """

    var _address: UInt
    var _length: Int

    def __init__(out self, path: String) raises:
        """Map the current file contents read-only; close the descriptor afterward.

        Raises on open, seek, or mapping failure. Intended for regular files,
        not pipes or devices. The mapping is private and never writes the file.
        """
        comptime assert (
            CompilationTarget.is_linux() or CompilationTarget.is_macos()
        ), "MappedFile requires Linux or macOS"

        self._address = 0
        self._length = 0

        with open(path, "r") as file:
            var size = file.seek(0, SEEK_END)
            if size > UInt64(Int.MAX):
                raise Error("File is too large to map: ", path)

            if size == 0:
                return

            # PROT_READ = 1 and MAP_PRIVATE = 2 on Linux and macOS.
            # Pointer-sized integers represent the opaque C addresses here;
            # MAP_FAILED is (void *)-1, not a null pointer.
            var address = external_call["mmap", UInt](
                UInt(0),
                UInt(size),
                c_int(1),
                c_int(2),
                c_int(file.handle),
                Int64(0),
            )
            if address == UInt.MAX:
                raise Error("Failed to map file: ", path)

            self._address = address
            self._length = Int(size)

    def __deinit__(deinit self):
        if self._length != 0:
            _ = external_call["munmap", c_int](
                self._address, UInt(self._length)
            )

    def __len__(self) -> Int:
        """Return the mapped length in bytes."""
        return self._length

    def as_bytes(self) -> Span[Byte, origin_of(self)]:
        """Borrow immutable bytes; no allocation or UTF-8 validation occurs."""
        if self._length == 0:
            return Span[Byte, origin_of(self)]()

        var ptr = Pointer[Byte, origin_of(self)](
            unsafe_from_address=Int(self._address)
        )

        return Span(unsafe_ptr=ptr, length=self._length)
