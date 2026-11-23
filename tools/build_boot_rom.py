#!/usr/bin/env python3
"""boot.rom builder: the six ROMs of the Karabas Profi firmware boot image
packed at the addresses core.json gives the MCU ROM loader (Global
Constraints, boot.rom layout).

The firmware streams a MiSTer `releases/boot.rom` download to the core over
the SPI link (karabas-go-firmware docs/protocol.md, ROMLOADER); the ROM loader
address of a byte at offset o is  o < 0x50000 ? 0x00100000 + o :
0x80000000 + (o - 0x50000), which is what fixes the layout:

    0x00000  ROMain_ramdisk_D.rom          64 KiB
    0x10000  bios_pqdos.rom                64 KiB
    0x20000  FDImageGO.rom                 64 KiB
    0x30000  ROMain_fatall_ramdisk_D.rom   64 KiB
    0x40000  esxdos090.bin                 8 KiB, padded with 0xFF to 64 KiB
    0x50000  gs105b.rom                    32 KiB
                                        -----------
                             total        0x58000 = 360448 bytes

Usage:
  python3 tools/build_boot_rom.py                       # -> releases/boot.rom
  python3 tools/build_boot_rom.py --roms DIR --out FILE
  python3 tools/build_boot_rom.py --check releases/boot.rom
      rebuilds the image from --roms in memory and compares: prints
      `boot.rom: OK sha256=<hex>` and exits 0, or prints the difference and
      exits 1.
Exit codes: 0 ok, 1 a ROM does not fit its region, --check differs or a file
is unreadable.
"""
import argparse
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (offset, file name, region size) - see the table above.
LAYOUT = [
    (0x00000, "ROMain_ramdisk_D.rom", 0x10000),
    (0x10000, "bios_pqdos.rom", 0x10000),
    (0x20000, "FDImageGO.rom", 0x10000),
    (0x30000, "ROMain_fatall_ramdisk_D.rom", 0x10000),
    (0x40000, "esxdos090.bin", 0x10000),
    (0x50000, "gs105b.rom", 0x8000),
]
SIZE = 0x58000


def build(roms_dir):
    """Return the image bytes; ValueError when a ROM does not fit."""
    img = bytearray(b"\xff" * SIZE)
    for off, name, region in LAYOUT:
        data = (roms_dir / name).read_bytes()
        if len(data) > region:
            raise ValueError(
                f"{name}: {len(data)} bytes do not fit the region "
                f"{hex(off)}+{hex(region)}")
        img[off:off + len(data)] = data
    return bytes(img)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--roms", type=Path,
                    default=ROOT / "upstream/karabas-go-core-profi/src/roms",
                    help="directory of the upstream ROM files")
    ap.add_argument("--out", type=Path, default=ROOT / "releases/boot.rom",
                    help="image to write")
    ap.add_argument("--check", type=Path, metavar="FILE",
                    help="verify FILE against --roms instead of writing")
    args = ap.parse_args()

    try:
        want = build(args.roms)
    except (OSError, ValueError) as e:
        print(f"boot.rom: {e}", file=sys.stderr)
        return 1
    sha = hashlib.sha256(want).hexdigest()

    if args.check:
        try:
            got = args.check.read_bytes()
        except OSError as e:
            print(f"boot.rom: {e}", file=sys.stderr)
            return 1
        if got == want:
            print(f"boot.rom: OK sha256={sha}")
            return 0
        print(f"boot.rom: MISMATCH {args.check} "
              f"({len(got)} bytes, sha256="
              f"{hashlib.sha256(got).hexdigest()[:16]}... != "
              f"sha256={sha[:16]}... built from {args.roms})")
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(want)
    print(f"boot.rom: wrote {len(want)} bytes sha256={sha} -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
