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


struct Duration(Copyable, Deinitable):
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


struct Profiler(Writable):
    var durations: Dict[String, Duration]

    def __init__(out self):
        self.durations = Dict[String, Duration]()

    def record(mut self, name: String, duration: Duration):
        self.durations[name] = self.durations.get(name, Duration(0)) + duration

    def write_to(self, mut writer: Some[Writer]):
        if not self.durations:
            writer.write("Profiler: no recorded stages")
            return

        var names = List[String](capacity=len(self.durations))
        var total_ns = 0
        var longest_name = 0

        for item in self.durations.items():
            names.append(item.key.copy())
            total_ns += item.value.duration
            longest_name = max(longest_name, item.key.byte_length())

        sort(names[:])

        writer.write("Profiler (total: ", total_ns // 1_000_000, " ms)\n")

        comptime BAR_WIDTH = 24
        for name_index in range(len(names)):
            ref name = names[name_index]
            var duration_ns = self.durations.get(name, Duration(0)).duration
            var bar_length = 0
            var percent_tenths = 0

            if total_ns > 0:
                bar_length = (
                    duration_ns * BAR_WIDTH + total_ns // 2
                ) // total_ns
                percent_tenths = (
                    duration_ns * 1_000 + total_ns // 2
                ) // total_ns

            writer.write("  ", name)
            for _ in range(longest_name - name.byte_length()):
                writer.write(" ")

            writer.write("  │")
            for _ in range(bar_length):
                writer.write("█")
            for _ in range(BAR_WIDTH - bar_length):
                writer.write("░")

            writer.write(
                "│  ",
                percent_tenths // 10,
                ".",
                percent_tenths % 10,
                "%  ",
                duration_ns // 1_000_000,
                " ms",
            )

            if name_index < len(names) - 1:
                writer.write("\n")
