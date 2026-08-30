from std.time import perf_counter_ns


struct Instant:
    var counter: Int

    def __init__(out self):
        self.counter = perf_counter_ns()

    @staticmethod
    def now() -> Instant:
        return Instant()

    def since(self, before: Instant) -> Duration:
        return Duration(self.counter - before.counter)


struct Duration:
    var duration: Int

    def __init__(out self, duration: Int):
        self.duration = duration

    def __add__(self, other: Self) -> Self:
        return Self(self.duration + other.duration)

    def __iadd__(mut self, other: Self):
        self.duration += other.duration

    def as_secs(self) -> Float64:
        return Float64(self.duration) / 1e9

    def as_millis(self) -> UInt:
        return UInt(self.duration // 1_000_000)

    def as_micros(self) -> UInt:
        return UInt(self.duration // 1_000)
