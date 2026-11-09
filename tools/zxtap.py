"""ZX Spectrum BASIC source to TAP, and TAP to TZX/CSW.

The tokeniser emits the stored-program form of 48K/128K BASIC: each line is
`number (2, big-endian) + length (2, little-endian) + body + 0x0d`, where
`length` covers the body and the terminator. Keywords become their single
byte token, numeric literals keep their source text and are followed by the
six-byte number form (0x0e + five bytes), and strings and the rest of a REM
line are copied byte for byte.
"""
import argparse
import re
import struct
import sys
from fractions import Fraction
from pathlib import Path

# Token byte -> spelling. The 48K set plus the 128K SPECTRUM and PLAY.
_KEYWORDS = [
    (0xA3, "SPECTRUM"), (0xA4, "PLAY"), (0xA5, "RND"), (0xA6, "INKEY$"),
    (0xA7, "PI"), (0xA8, "FN"), (0xA9, "POINT"), (0xAA, "SCREEN$"),
    (0xAB, "ATTR"), (0xAC, "AT"), (0xAD, "TAB"), (0xAE, "VAL$"),
    (0xAF, "CODE"), (0xB0, "VAL"), (0xB1, "LEN"), (0xB2, "SIN"),
    (0xB3, "COS"), (0xB4, "TAN"), (0xB5, "ASN"), (0xB6, "ACS"),
    (0xB7, "ATN"), (0xB8, "LN"), (0xB9, "EXP"), (0xBA, "INT"),
    (0xBB, "SQR"), (0xBC, "SGN"), (0xBD, "ABS"), (0xBE, "PEEK"),
    (0xBF, "IN"), (0xC0, "USR"), (0xC1, "STR$"), (0xC2, "CHR$"),
    (0xC3, "NOT"), (0xC4, "BIN"), (0xC5, "OR"), (0xC6, "AND"),
    (0xC7, "<="), (0xC8, ">="), (0xC9, "<>"), (0xCA, "LINE"),
    (0xCB, "THEN"), (0xCC, "TO"), (0xCD, "STEP"), (0xCE, "DEF FN"),
    (0xCF, "CAT"), (0xD0, "FORMAT"), (0xD1, "MOVE"), (0xD2, "ERASE"),
    (0xD3, "OPEN #"), (0xD4, "CLOSE #"), (0xD5, "MERGE"),
    (0xD6, "VERIFY"), (0xD7, "BEEP"), (0xD8, "CIRCLE"), (0xD9, "INK"),
    (0xDA, "PAPER"), (0xDB, "FLASH"), (0xDC, "BRIGHT"),
    (0xDD, "INVERSE"), (0xDE, "OVER"), (0xDF, "OUT"), (0xE0, "LPRINT"),
    (0xE1, "LLIST"), (0xE2, "STOP"), (0xE3, "READ"), (0xE4, "DATA"),
    (0xE5, "RESTORE"), (0xE6, "NEW"), (0xE7, "BORDER"),
    (0xE8, "CONTINUE"), (0xE9, "DIM"), (0xEA, "REM"), (0xEB, "FOR"),
    (0xEC, "GO TO"), (0xED, "GO SUB"), (0xEE, "INPUT"), (0xEF, "LOAD"),
    (0xF0, "LIST"), (0xF1, "LET"), (0xF2, "PAUSE"), (0xF3, "NEXT"),
    (0xF4, "POKE"), (0xF5, "PRINT"), (0xF6, "PLOT"), (0xF7, "RUN"),
    (0xF8, "SAVE"), (0xF9, "RANDOMIZE"), (0xFA, "IF"), (0xFB, "CLS"),
    (0xFC, "DRAW"), (0xFD, "CLEAR"), (0xFE, "RETURN"), (0xFF, "COPY"),
    # Unspaced forms of the multi-word keywords.
    (0xEC, "GOTO"), (0xED, "GOSUB"),
]
_KEYWORDS.sort(key=lambda item: len(item[1]), reverse=True)

_REM = 0xEA
_LINE_END = 0x0D
_TSTATES_PER_SECOND = 3_500_000


def _xor(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
    return value


def _name_bytes(name: str) -> bytes:
    return name.encode("ascii")[:10].ljust(10, b" ")


def _match_keyword(text: str, upper: str, i: int):
    """Longest keyword at `i`, honouring the word-boundary rules."""
    for token, spelling in _KEYWORDS:
        if not upper.startswith(spelling, i):
            continue
        if spelling[0].isalpha() and i > 0 and text[i - 1].isalnum():
            continue
        if spelling[-1].isalpha():
            end = i + len(spelling)
            if end < len(text) and text[end].isalpha():
                continue
        return token, spelling
    return None


def _scan_number(text: str, i: int) -> int:
    end = i
    while end < len(text) and text[end].isdigit():
        end += 1
    if end < len(text) and text[end] == ".":
        end += 1
        while end < len(text) and text[end].isdigit():
            end += 1
    if end < len(text) and text[end] in "eE":
        after = end + 1
        if after < len(text) and text[after] in "+-":
            after += 1
        if after < len(text) and text[after].isdigit():
            end = after
            while end < len(text) and text[end].isdigit():
                end += 1
    return end


def _tokenize_body(text: str, upper: str) -> bytes:
    out = bytearray()
    i = 0
    while i < len(text):
        char = text[i]
        if char == '"':
            end = text.find('"', i + 1)
            if end < 0:
                end = len(text)
            else:
                end += 1
            out.extend(text[i:end].encode("ascii"))
            i = end
            continue

        keyword = _match_keyword(text, upper, i)
        if keyword is not None:
            token, spelling = keyword
            while out and out[-1] == 0x20:
                out.pop()
            out.append(token)
            i += len(spelling)
            if i < len(text) and text[i] == " ":
                i += 1
            if token == _REM:
                out.extend(text[i:].encode("ascii"))
                i = len(text)
            elif token == 0xC4:  # BIN: digits are binary, copied as text
                start = i
                while i < len(text) and text[i] in "01":
                    i += 1
                if i > start:
                    literal = text[start:i]
                    out.extend(literal.encode("ascii"))
                    out.extend(number_form(str(int(literal, 2))))
            continue

        if char.isdigit() and (
            i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "$")
        ):
            end = _scan_number(text, i)
            literal = text[i:end]
            out.extend(literal.encode("ascii"))
            out.extend(number_form(literal))
            i = end
            continue

        out.append(ord(char))
        i += 1
    return bytes(out)


def tokenize_line(text: str) -> bytes:
    """Tokenise one BASIC line into its stored-program bytes."""
    if not text.isascii():
        raise ValueError(f"non-ASCII in line: {text!r}")
    match = re.match(r"(\d+)", text)
    if match is None:
        raise ValueError(f"line has no number: {text!r}")
    number = int(match.group(1))
    if not 0 <= number <= 0xFFFF:
        raise ValueError(f"line number out of range: {text!r}")

    rest = text[match.end():]
    if rest.startswith(" "):
        rest = rest[1:]
    body = _tokenize_body(rest, rest.upper())
    payload = body + bytes([_LINE_END])
    if len(payload) > 0xFFFF:
        raise ValueError(f"line too long: {text!r}")
    return number.to_bytes(2, "big") + len(payload).to_bytes(2, "little") + payload


def tokenize_program(src: str) -> bytes:
    """Tokenise every non-empty source line, in source order."""
    program = bytearray()
    for index, raw in enumerate(src.splitlines(), 1):
        line = raw.rstrip("\r")
        if not line.strip():
            continue
        try:
            program.extend(tokenize_line(line))
        except ValueError as error:
            raise ValueError(f"line {index}: {error}") from error
    return bytes(program)


def _floor_log2(value: Fraction) -> int:
    exponent = value.numerator.bit_length() - value.denominator.bit_length()
    two = Fraction(2)
    while value < two ** exponent:
        exponent -= 1
    while value >= two ** (exponent + 1):
        exponent += 1
    return exponent


def number_form(text: str) -> bytes:
    """The 0x0e marker plus the five-byte Spectrum number form."""
    if not text:
        raise ValueError("empty number literal")

    negative = text.startswith("-")
    unsigned = text.lstrip("+-")
    if re.fullmatch(r"\d+", unsigned):
        value = int(unsigned)
    else:
        literal = unsigned
        if literal.endswith("."):
            literal += "0"
        if literal.startswith("."):
            literal = "0" + literal
        value = Fraction(literal)
    if negative:
        value = -value

    if value.denominator == 1 and -65535 <= value <= 65535:
        integer = int(value)
        packed = integer & 0xFFFF
        return bytes([
            0x0E,
            0x00,
            0x00 if integer >= 0 else 0xFF,
            packed & 0xFF,
            packed >> 8,
            0x00,
        ])

    value = Fraction(value)

    magnitude = abs(value)
    exponent = _floor_log2(magnitude) + 1
    mantissa_fraction = magnitude / (Fraction(2) ** exponent) - Fraction(1, 2)
    mantissa = round(mantissa_fraction * (1 << 32))
    exponent_byte = exponent + 128
    if not 1 <= exponent_byte <= 255:
        raise ValueError(f"number out of range: {text!r}")
    if value < 0:
        mantissa |= 1 << 31
    return bytes([0x0E, exponent_byte]) + mantissa.to_bytes(4, "big")


def tap_block(flag: int, data: bytes) -> bytes:
    """A TAP block: length, flag, data, XOR checksum."""
    body = bytes([flag]) + bytes(data)
    if len(body) >= 0xFFFF:
        raise ValueError("TAP block too long")
    return struct.pack("<H", len(body) + 1) + body + bytes([_xor(body)])


def program_tap(name: str, program: bytes, autostart: int | None) -> bytes:
    """A BASIC program as a type-0 header block plus a data block."""
    program = bytes(program)
    if len(program) > 0xFFFF:
        raise ValueError("program too long for TAP")
    param1 = 32768 if autostart is None else autostart
    if not 0 <= param1 <= 0xFFFF:
        raise ValueError("autostart line out of range")
    header = (
        bytes([0x00])
        + _name_bytes(name)
        + struct.pack("<H", len(program))
        + struct.pack("<H", param1)
        + struct.pack("<H", len(program))
    )
    return tap_block(0x00, header) + tap_block(0xFF, program)


def code_tap(name: str, data: bytes, addr: int) -> bytes:
    """A binary as a type-3 CODE header block plus a data block."""
    data = bytes(data)
    if len(data) > 0xFFFF:
        raise ValueError("code too long for TAP")
    if not 0 <= addr <= 0xFFFF:
        raise ValueError("address out of range")
    header = (
        bytes([0x03])
        + _name_bytes(name)
        + struct.pack("<H", len(data))
        + struct.pack("<H", addr)
        + struct.pack("<H", 32768)
    )
    return tap_block(0x00, header) + tap_block(0xFF, data)


def _tap_blocks(tap: bytes) -> list[bytes]:
    blocks = []
    i = 0
    while i < len(tap):
        if i + 2 > len(tap):
            raise ValueError("truncated TAP length")
        size = int.from_bytes(tap[i:i + 2], "little")
        i += 2
        if size < 2 or i + size > len(tap):
            raise ValueError("bad TAP block length")
        blocks.append(tap[i:i + size])
        i += size
    return blocks


def tap_to_tzx(tap: bytes, pause_ms: int = 1000) -> bytes:
    """Wrap each TAP block in a TZX standard-speed data block (0x10)."""
    if not 0 <= pause_ms <= 0xFFFF:
        raise ValueError("pause out of range")
    out = bytearray(b"ZXTape!\x1a\x01\x14")
    for block in _tap_blocks(tap):
        if len(block) > 0xFFFF:
            raise ValueError("TAP block too long for TZX")
        out.append(0x10)
        out += struct.pack("<H", pause_ms)
        out += struct.pack("<H", len(block))
        out += block
    return bytes(out)


def _samples(tstates: int, rate: int) -> int:
    return max(1, round(tstates * rate / _TSTATES_PER_SECOND))


def _rle(samples: int) -> bytes:
    if samples > 255:
        return b"\x00" + struct.pack("<I", samples)
    return bytes([samples])


def tap_to_csw(tap: bytes, rate: int = 44100) -> bytes:
    """A TAP as CSW: ROM pilot/sync/bits, RLE pulse lengths.

    The data pilot is 8064 pulses, not the standard 3223: the Profi ROM
    consumes the data lead-in while its LD_WAIT/LD_LEADER run, and 3223
    fails on the board while 8064 loads (the header stays 8063).

    The header is 32 bytes (the three zero bytes after compression and flags
    are what the MiSTer tape player consumes before the RLE data).
    """
    if not 1 <= rate <= 0xFFFF:
        raise ValueError("sample rate out of range")
    out = bytearray(
        b"Compressed Square Wave\x1a"
        + bytes([1, 1])
        + struct.pack("<H", rate)
        + bytes([1, 0])
        + bytes(3)
    )
    for block in _tap_blocks(tap):
        pilot = 8063 if block[0] < 128 else 8064
        pulses = [2168] * pilot + [667, 735]
        for byte in block:
            for bit in range(7, -1, -1):
                length = 1710 if byte & (1 << bit) else 855
                pulses.extend((length, length))
        pulses.append(1000 * _TSTATES_PER_SECOND // 1000)  # 1000 ms pause
        for tstates in pulses:
            out += _rle(_samples(tstates, rate))
    return bytes(out)


def _command_bas(args) -> None:
    source = Path(args.src).read_text(encoding="utf-8")
    name = args.name if args.name is not None else Path(args.src).stem
    Path(args.out).write_bytes(
        program_tap(name, tokenize_program(source), args.autostart)
    )


def _command_code(args) -> None:
    Path(args.out).write_bytes(
        code_tap(args.name, Path(args.bin).read_bytes(), args.addr)
    )


def _command_tzx(args) -> None:
    Path(args.out).write_bytes(tap_to_tzx(Path(args.src).read_bytes()))


def _command_csw(args) -> None:
    Path(args.out).write_bytes(tap_to_csw(Path(args.src).read_bytes()))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    bas = sub.add_parser("bas", help="tokenise BASIC source into a TAP")
    bas.add_argument("src")
    bas.add_argument("out")
    bas.add_argument("--name")
    bas.add_argument("--autostart", type=int)
    bas.set_defaults(func=_command_bas)

    code = sub.add_parser("code", help="wrap a binary as a CODE TAP")
    code.add_argument("bin")
    code.add_argument("out")
    code.add_argument("--name", required=True)
    code.add_argument("--addr", type=int, required=True)
    code.set_defaults(func=_command_code)

    tzx = sub.add_parser("tzx", help="convert a TAP to TZX")
    tzx.add_argument("src")
    tzx.add_argument("out")
    tzx.set_defaults(func=_command_tzx)

    csw = sub.add_parser("csw", help="convert a TAP to CSW")
    csw.add_argument("src")
    csw.add_argument("out")
    csw.set_defaults(func=_command_csw)

    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())