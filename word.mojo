from common import Token, int, Pair, pack_pair, i32


@fieldwise_init
struct Symbol(Copyable, Equatable, Hashable):
    var token: Token
    var prev: i32
    var next: i32
    var dead: Bool


struct Word(Copyable, Equatable, Hashable, Movable, Sized, Writable):
    var symbols: List[Symbol]

    def __init__(out self, capacity: int = 0):
        self.symbols = List[Symbol](capacity=capacity)

    def __init__(out self, tokens: List[Token]):
        self.symbols = List[Symbol](capacity=len(tokens))

        for i in range(i32(len(tokens))):
            self.symbols.append(
                Symbol(
                    token=tokens[i],
                    prev=i - 1,
                    next=i + 1 if i + 1 < i32(len(tokens)) else -1,
                    dead=False,
                )
            )

    def __len__(self) -> int:
        var c = 0
        for s in self.symbols:
            if not s.dead:
                c += 1

        return c

    def __getitem__(self, idx: int) -> Token:
        return self.symbols[idx].token

    def add(mut self, token: Token):
        var len = i32(len(self.symbols))

        var prev: i32 = -1
        if len > 0:
            ref last = self.symbols[len - 1]
            last.next = len
            prev = len - 1

        self.symbols.append(Symbol(token=token, prev=prev, next=-1, dead=False))

    def contains_pair(self, left: Token, right: Token) -> Bool:
        var i: i32 = 0
        ref symbols = self.symbols

        # -1 is a sentinel value marking the end of the list
        while i != -1:
            if symbols[i].dead:
                continue

            var next = symbols[i].next

            if (
                next != -1
                and symbols[i].token == left
                and symbols[next].token == right
            ):
                return True
            else:
                i = next

        return False

    def merge(
        mut self, left: Token, right: Token, new: Token
    ) -> List[Tuple[Pair, int]]:
        """
        Merges (`left`, `right`) into `new` in place. Returns all pair count deltas.
        """
        var deltas = List[Tuple[Pair, int]]()
        var i: i32 = 0
        ref symbols = self.symbols

        while i != -1:
            var next = symbols[i].next

            if (
                next != -1
                and symbols[i].token == left
                and symbols[next].token == right
            ):
                # Token found
                ref first = symbols[i]
                ref second = symbols[next]
                next = second.next

                var new_symbol = Symbol(
                    token=new, prev=first.prev, next=second.next, dead=False
                )

                # Decrement the current pair count
                var current = pack_pair(first.token, second.token)
                deltas.append((current, -1))

                # Pair on the left
                if first.prev != -1:
                    var left = pack_pair(symbols[first.prev].token, first.token)
                    deltas.append((left, -1))
                    var new = pack_pair(symbols[first.prev].token, new)
                    deltas.append((new, 1))

                    symbols[first.prev].next = i

                # Pair on the right
                if second.next != -1:
                    var right = pack_pair(
                        second.token, symbols[second.next].token
                    )
                    deltas.append((right, -1))
                    var new = pack_pair(new, symbols[second.next].token)
                    deltas.append((new, 1))

                    symbols[second.next].prev = i

                second.dead = True
                symbols[i] = new_symbol^

            i = next

        return deltas^

    def write_to(self, mut writer: Some[Writer]):
        var bytes = List[Byte](capacity=len(self.symbols))
        for symbol in self.symbols:
            if not symbol.dead:
                bytes.append(Byte(symbol.token))

        writer.write(String(from_utf8_lossy=bytes))
