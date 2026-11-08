"""Tests for tools/zxtap.py.

Run: python3 -m unittest discover -s tools/tests -v
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import zxtap  # noqa: E402

CSW_SIG = b"Compressed Square Wave\x1a"
TSTATES_PER_SECOND = 3_500_000


def body_of(line: bytes) -> bytes:
    """The statements of one tokenised line, without its 0x0d terminator."""
    return line[4:-1]


def xor_all(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
    return value


def tap_blocks(tap: bytes) -> list[bytes]:
    blocks = []
    i = 0
    while i < len(tap):
        size = int.from_bytes(tap[i:i + 2], "little")
        i += 2
        blocks.append(tap[i:i + size])
        i += size
    return blocks


def parse_program(program: bytes) -> dict[int, bytes]:
    lines = {}
    i = 0
    while i < len(program):
        number = int.from_bytes(program[i:i + 2], "big")
        size = int.from_bytes(program[i + 2:i + 4], "little")
        payload = program[i + 4:i + 4 + size]
        assert payload[-1] == 0x0D
        lines[number] = payload[:-1]
        i += 4 + size
    return lines


def csw_pulses(csw: bytes, rate: int) -> list[int]:
    """Decode the CSW header and its RLE run into sample lengths."""
    assert csw.startswith(CSW_SIG), csw[:23]
    i = len(CSW_SIG)
    assert csw[i:i + 2] == bytes([1, 1])
    i += 2
    assert int.from_bytes(csw[i:i + 2], "little") == rate
    i += 2
    assert csw[i] == 1  # RLE
    i += 1
    assert csw[i] == 0  # flags
    i += 1
    # The upstream tape.sv player consumes a 32-byte header: the three
    # remaining bytes are zero and the RLE starts at byte 32.
    assert csw[i:i + 3] == b"\x00\x00\x00"
    i += 3
    assert i == 32
    pulses = []
    while i < len(csw):
        value = csw[i]
        i += 1
        if value == 0:
            value = int.from_bytes(csw[i:i + 4], "little")
            i += 4
        pulses.append(value)
    return pulses


def decode_csw_block(pulses: list[int], pos: int, block: bytes, rate: int) -> int:
    """Consume one TAP block from the pulse list and return the block bytes.

    A pulse length is a sample count; the tolerance is one sample per pulse,
    as the round-trip through integer samples loses up to half a sample.
    """
    sample_ts = TSTATES_PER_SECOND / rate
    tolerance = sample_ts

    def check(pos: int, tstates: int) -> int:
        actual = pulses[pos] * sample_ts
        assert abs(actual - tstates) <= tolerance, (pos, actual, tstates)
        return pos + 1

    pilot_count = 8063 if block[0] < 128 else 3223
    for _ in range(pilot_count):
        pos = check(pos, 2168)
    pos = check(pos, 667)
    pos = check(pos, 735)

    recovered = bytearray()
    for _ in block:
        value = 0
        for bit in range(7, -1, -1):
            first = pulses[pos] * sample_ts
            second = pulses[pos + 1] * sample_ts
            pos += 2
            if first + second > 2500:
                value |= 1 << bit
            else:
                assert first + second < 2500
        recovered.append(value)
    assert bytes(recovered) == block, (bytes(recovered).hex(), block.hex())

    pause = pulses[pos]
    pos += 1
    assert abs(pause * sample_ts - 1000 * TSTATES_PER_SECOND / 1000) <= tolerance
    return pos


class TokenizerTest(unittest.TestCase):
    def test_print_one(self):
        self.assertEqual(
            zxtap.tokenize_line("10 PRINT 1"),
            bytes.fromhex("000a0900f5310e0000010000" + "0d"),
        )

    def test_goto_gosub(self):
        body = body_of(zxtap.tokenize_line("20 GO TO 10: GO SUB 30"))
        self.assertIn(0xEC, body)
        self.assertIn(0xED, body)
        self.assertNotIn(b"GO", body)

    def test_string_and_rem(self):
        body = body_of(zxtap.tokenize_line('30 PRINT "PRINT": REM PRINT 1'))
        self.assertEqual(body.count(b"\xf5"), 1)
        start = body.index(b"\xf5")
        self.assertEqual(body[start + 1:start + 8], b'"PRINT"')
        self.assertEqual(body[body.index(b"\xea") + 1:], b"PRINT 1")

    def test_lowercase_keywords(self):
        self.assertEqual(
            zxtap.tokenize_line("10 print 1"),
            zxtap.tokenize_line("10 PRINT 1"),
        )

    def test_numbers(self):
        self.assertEqual(zxtap.number_form("0"), bytes.fromhex("0e0000000000"))
        self.assertEqual(zxtap.number_form("65535"), bytes.fromhex("0e0000ffff00"))
        self.assertEqual(zxtap.number_form("0.5"), bytes.fromhex("0e8000000000"))
        self.assertEqual(zxtap.number_form("1.5"), bytes.fromhex("0e8140000000"))
        # Integral values use the small form whatever their spelling.
        self.assertEqual(zxtap.number_form("1e3"), zxtap.number_form("1000"))
        # 65536 is outside the small range: 0.5 * 2**17.
        self.assertEqual(zxtap.number_form("65536"), bytes.fromhex("0e9100000000"))
        # '-' is the operator, not part of the literal.
        self.assertEqual(
            body_of(zxtap.tokenize_line("10 PRINT -1")),
            bytes.fromhex("f52d310e0000010000"),
        )

    def test_variable_digits(self):
        self.assertEqual(
            body_of(zxtap.tokenize_line("10 LET a1=2")),
            bytes.fromhex("f161313d320e0000020000"),
        )

    def test_play_token(self):
        body = body_of(zxtap.tokenize_line('10 PLAY "c"'))
        self.assertEqual(body[0], 0xA4)
        self.assertEqual(body, bytes.fromhex("a4226322"))

    def test_bin(self):
        self.assertEqual(
            body_of(zxtap.tokenize_line("10 BIN 101")),
            bytes.fromhex("c43130310e0000050000"),
        )

    def test_word_boundaries(self):
        # `total` is a name, and ATN wins over AT.
        self.assertEqual(
            body_of(zxtap.tokenize_line("10 total=ATN 1")),
            bytes.fromhex("746f74616c3db7310e0000010000"),
        )


class TapTest(unittest.TestCase):
    def setUp(self):
        self.program = zxtap.tokenize_program("10 PRINT 1\n20 STOP\n")

    def test_tap_checksum(self):
        tap = zxtap.program_tap("hello", self.program, 10)
        blocks = tap_blocks(tap)
        self.assertEqual(len(blocks), 2)

        header = blocks[0]
        self.assertEqual(len(header), 19)
        self.assertEqual(header[0], 0x00)
        self.assertEqual(xor_all(header), 0)
        self.assertEqual(header[1], 0x00)  # type: program
        self.assertEqual(header[2:12], b"hello     ")
        self.assertEqual(int.from_bytes(header[12:14], "little"), len(self.program))
        self.assertEqual(int.from_bytes(header[14:16], "little"), 10)
        self.assertEqual(int.from_bytes(header[16:18], "little"), len(self.program))

        data = blocks[1]
        self.assertEqual(data[0], 0xFF)
        self.assertEqual(xor_all(data), 0)
        self.assertEqual(data[1:-1], self.program)

    def test_tzx(self):
        tap = zxtap.program_tap("hello", self.program, 10)
        tzx = zxtap.tap_to_tzx(tap)
        self.assertEqual(tzx[:10], b"ZXTape!\x1a\x01\x14")

        blocks = tap_blocks(tap)
        i = 10
        recovered = []
        while i < len(tzx):
            self.assertEqual(tzx[i], 0x10)
            i += 1
            pause = int.from_bytes(tzx[i:i + 2], "little")
            i += 2
            self.assertEqual(pause, 1000)
            size = int.from_bytes(tzx[i:i + 2], "little")
            i += 2
            recovered.append(tzx[i:i + size])
            i += size
        self.assertEqual(recovered, blocks)

    def test_csw_roundtrip(self):
        rate = 44100
        tap = zxtap.program_tap("hello", self.program, 10)
        csw = zxtap.tap_to_csw(tap, rate)
        pulses = csw_pulses(csw, rate)

        pos = 0
        for block in tap_blocks(tap):
            pos = decode_csw_block(pulses, pos, block, rate)
        self.assertEqual(pos, len(pulses))


class ProgramSourceTest(unittest.TestCase):
    def tokenised(self, name: str) -> dict[int, bytes]:
        source = (ROOT / "tests" / "zx" / name).read_text(encoding="ascii")
        return parse_program(zxtap.tokenize_program(source))

    def test_hello(self):
        lines = self.tokenised("hello.bas")
        self.assertEqual(len(lines), 2)
        self.assertIn(0xBE, lines[20])  # PEEK

    def test_sound(self):
        lines = self.tokenised("sound.bas")
        self.assertIn(0xEB, lines[30])  # FOR
        self.assertIn(0xCC, lines[30])  # TO
        self.assertEqual(lines[200][0], 0xE4)  # DATA

    def test_gsquery(self):
        body = self.tokenised("gsquery.bas")[30]
        for token in (0xFA, 0xBF, 0xCB, 0xEC):  # IF, IN, THEN, GO TO
            self.assertIn(token, body)


if __name__ == "__main__":
    unittest.main()