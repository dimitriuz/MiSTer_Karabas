"""scl.py - Sinclair SCL images: a writer for the benches and the reference
for what the core builds from one.

An SCL is "SINCLAIR", a file count N, N 14-byte catalog entries (the TR-DOS
entry without its last two bytes), the files' sectors back to back, and a
32-bit sum of every byte before it. The core (rtl/disk/fdd_src.sv, P_SCL)
streams it into the drive's 2 MiB window as the flat TRD a TR-DOS disk is:
logical track = cylinder * 2 + side, offset = (track * 16 + sector) * 256,
the catalog at 0..2047, the ID sector at 0x800, file data from 0x1000. The
catalog's last two bytes (first sector, first track) are made up here from
the running sector count, the ID sector says what is free, and the first
4 KiB are cleared first (the window keeps the last image's bytes).

CLI:
  scl.py make OUT.scl [--files N] [--sectors S] [--seed K]
  scl.py trd  IN.scl OUT.trd
"""
import argparse
import random
import struct
import sys
from pathlib import Path

SEC = 256
MAX_FILES = 128
DISK_SECTORS = 80 * 2 * 16 - 16          # the data sectors of an 80-cylinder DS disk


def scl(files):
    """files: [(entry14: bytes, payload: bytes)]; payload padded to sectors"""
    out = bytearray(b"SINCLAIR")
    out.append(len(files))
    body = bytearray()
    for entry, payload in files:
        sectors = -(-len(payload) // SEC)
        e = bytearray(entry)
        e[13] = sectors
        out += e
        body += payload.ljust(sectors * SEC, b"\0")
    out += body
    out += struct.pack("<I", sum(out) & 0xFFFFFFFF)
    return bytes(out)


def parse(data):
    """-> (entries [bytes14], payload bytes) or None when the header is bad"""
    if data[:8] != b"SINCLAIR" or len(data) < 9:
        return None
    n = data[8]
    if n > MAX_FILES or len(data) < 9 + 14 * n:
        return None
    entries = [bytes(data[9 + 14 * i:9 + 14 * (i + 1)]) for i in range(n)]
    total = sum(e[13] for e in entries)
    if total > DISK_SECTORS:
        return None
    return entries, bytes(data[9 + 14 * n:9 + 14 * n + total * SEC])


def window(data):
    """the bytes the core writes into the window, from 0 up to the last data
    byte (what is after the last file's sectors is not written), or None when
    the core refuses the file"""
    p = parse(data)
    if p is None:
        return None
    entries, payload = p
    total = sum(e[13] for e in entries)
    img = bytearray(0x1000 + total * SEC)
    run = 0
    for i, e in enumerate(entries):
        img[i * 16:i * 16 + 14] = e
        img[i * 16 + 14] = run % 16
        img[i * 16 + 15] = 1 + run // 16
        run += e[13]
    ident = 0x800
    img[ident + 0xE1] = total % 16
    img[ident + 0xE2] = 1 + total // 16
    img[ident + 0xE3] = 0x16
    img[ident + 0xE4] = len(entries)
    struct.pack_into("<H", img, ident + 0xE5, DISK_SECTORS - total)
    img[ident + 0xE7] = 0x10
    img[0x1000:0x1000 + len(payload)] = payload
    return bytes(img)


def sample(nfiles=3, sectors=5, seed=1):
    rnd = random.Random(seed)
    files = []
    for i in range(nfiles):
        name = f"f{i}".ljust(8).encode()
        entry = name + b"C" + struct.pack("<HH", 0x8000, sectors * SEC) + b"\0"
        files.append((entry, bytes(rnd.randrange(256) for _ in range(sectors * SEC))))
    return scl(files)


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("make")
    m.add_argument("out")
    m.add_argument("--files", type=int, default=3)
    m.add_argument("--sectors", type=int, default=5)
    m.add_argument("--seed", type=int, default=1)
    t = sub.add_parser("trd")
    t.add_argument("inp")
    t.add_argument("out")
    a = ap.parse_args(argv)
    if a.cmd == "make":
        Path(a.out).write_bytes(sample(a.files, a.sectors, a.seed))
    else:
        w = window(Path(a.inp).read_bytes())
        if w is None:
            sys.exit("scl: refused")
        img = bytearray(640 * 1024)
        img[:len(w)] = w
        Path(a.out).write_bytes(bytes(img))


if __name__ == "__main__":
    main()
