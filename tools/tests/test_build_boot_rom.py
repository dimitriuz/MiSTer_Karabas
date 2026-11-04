"""Tests for tools/build_boot_rom.py.

Run: python3 -m unittest discover -s tools/tests -v
The tool packs upstream's src/roms into the boot.rom image of the Global
Constraints (see the LAYOUT table): the tests build it from synthetic ROM
files of exactly the pinned sizes and check the byte-exact layout, the 0xFF
padding and --check on good and corrupted files; one test runs the default
--roms (the checked-out upstream submodule) and checks the size.
"""
import hashlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "build_boot_rom.py"
REAL_ROMS = ROOT / "upstream" / "karabas-go-core-profi" / "src" / "roms"

SIZE = 0x58000

# name -> (offset, size), the Global-Constraints layout
LAYOUT = [
    ("ROMain_ramdisk_D.rom", 0x00000, 0x10000),
    ("bios_pqdos.rom", 0x10000, 0x10000),
    ("FDImageGO.rom", 0x20000, 0x10000),
    ("ROMain_fatall_ramdisk_D.rom", 0x30000, 0x10000),
    ("esxdos089.bin", 0x40000, 0x2000),        # padded with 0xFF to 0x10000
    ("gs105b.rom", 0x50000, 0x8000),
]


class TmpRoms(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="karabas-bootrom-tests-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.roms = self.tmp / "roms"
        self.roms.mkdir()
        for i, (name, _off, size) in enumerate(LAYOUT, start=1):
            (self.roms / name).write_bytes(bytes([0x10 * i]) * size)
        self.out = self.tmp / "boot.rom"

    def build(self, *extra, roms=None, expect=0):
        args = [sys.executable, str(TOOL),
                "--roms", str(self.roms if roms is None else roms),
                "--out", str(self.out), *extra]
        r = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(r.returncode, expect,
                         f"exit {r.returncode}\nout: {r.stdout}\nerr: {r.stderr}")
        return r

    def test_layout_is_byte_exact(self):
        self.build()
        data = self.out.read_bytes()
        self.assertEqual(len(data), SIZE)
        for name, off, size in LAYOUT:
            self.assertEqual(data[off:off + size], (self.roms / name).read_bytes(),
                             f"region of {name} at {hex(off)}")
        self.assertEqual(data[0x42000:0x50000], b"\xff" * 0xE000,
                         "esxdos padding 0x42000-0x4FFFF")

    def test_check_ok(self):
        self.build()
        r = self.build("--check", str(self.out))
        self.assertIn("OK", r.stdout)
        want = hashlib.sha256(self.out.read_bytes()).hexdigest()
        self.assertIn(want, r.stdout)

    def test_check_modified_exits_1(self):
        self.build()
        copy = self.tmp / "modified.rom"
        blob = bytearray(self.out.read_bytes())
        blob[0x30010] ^= 0xFF
        copy.write_bytes(bytes(blob))
        r = self.build("--check", str(copy), expect=1)
        self.assertNotIn("OK", r.stdout)

    def test_rom_too_big_fails(self):
        big = self.tmp / "big"
        big.mkdir()
        for name, _off, size in LAYOUT:
            n = size + 1 if name == "FDImageGO.rom" else size
            (big / name).write_bytes(b"\x5a" * n)
        self.build("--out", str(self.tmp / "never.rom"), roms=big, expect=1)

    def test_real_roms_size(self):
        if not REAL_ROMS.is_dir():
            self.skipTest("upstream submodule not checked out")
        r = subprocess.run([sys.executable, str(TOOL),
                            "--out", str(self.tmp / "real.rom")],
                           capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.tmp / "real.rom").stat().st_size, SIZE)


if __name__ == "__main__":
    unittest.main()
