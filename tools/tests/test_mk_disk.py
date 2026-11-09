"""Tests for tools/mk_disk.py.

Run: python3 -m unittest discover -s tools/tests -v
"""
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import mk_disk  # noqa: E402
import zxtap  # noqa: E402

SECTOR = 512
PART_START = 2048
PART_SECTORS = 32768 - PART_START


class SdVhdTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.img = Path(cls.tmp.name) / "sd.vhd"
        mk_disk.sd_vhd(cls.img)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def read(self, offset, length):
        with self.img.open("rb") as f:
            f.seek(offset)
            return f.read(length)

    def bpb(self):
        return self.read(PART_START * SECTOR, SECTOR)

    def test_mbr(self):
        mbr = self.read(0, SECTOR)
        self.assertEqual(mbr[510:512], b"\x55\xaa")
        entry = mbr[446:462]
        self.assertEqual(entry[0], 0x80)
        self.assertEqual(entry[4], 0x06)
        self.assertEqual(struct.unpack("<I", entry[8:12])[0], PART_START)
        self.assertEqual(struct.unpack("<I", entry[12:16])[0], PART_SECTORS)
        self.assertEqual(mbr[462:510], bytes(48))

    def test_bpb(self):
        bpb = self.bpb()
        self.assertEqual(bpb[510:512], b"\x55\xaa")
        self.assertEqual(struct.unpack("<H", bpb[11:13])[0], SECTOR)
        self.assertEqual(struct.unpack("<H", bpb[16:18])[0], 2)
        self.assertEqual(struct.unpack("<H", bpb[17:19])[0], 512)
        self.assertEqual(struct.unpack("<I", bpb[28:32])[0], PART_START)
        self.assertEqual(struct.unpack("<I", bpb[32:36])[0], PART_SECTORS)
        self.assertEqual(bpb[43:54], b"KARABAS SD ")
        self.assertEqual(bpb[54:62], b"FAT16   ")

    def test_fat_sizes(self):
        bpb = self.bpb()
        spc = bpb[13]
        fats = struct.unpack("<H", bpb[16:18])[0]
        root = struct.unpack("<H", bpb[17:19])[0]
        total = struct.unpack("<H", bpb[19:21])[0]
        fat_sectors = struct.unpack("<H", bpb[22:24])[0]
        clusters = (total - 1 - fats * fat_sectors - root * 32 // SECTOR) // spc
        self.assertGreaterEqual(fat_sectors * SECTOR // 2, clusters + 2)
        fat1 = self.read((PART_START + 1) * SECTOR, fat_sectors * SECTOR)
        fat2 = self.read((PART_START + 1 + fat_sectors) * SECTOR,
                         fat_sectors * SECTOR)
        self.assertEqual(fat1, fat2)
        self.assertEqual(struct.unpack("<H", fat1[0:2])[0], 0xFFF8)
        self.assertEqual(struct.unpack("<H", fat1[2:4])[0], 0xFFFF)

    def test_file_roundtrip(self):
        names = [name for name, _ in mk_disk.fat_list(self.img)]
        self.assertIn("TEST.TXT", names)
        self.assertIn("TEST.BAS", names)
        self.assertEqual(mk_disk.fat_read(self.img, "TEST.TXT"), b"sd ok\n")
        self.assertEqual(mk_disk.fat_read(self.img, "TEST.BAS"),
                         zxtap.tokenize_program('10 PRINT "sd ok"'))

    def test_cat_missing(self):
        with self.assertRaises(KeyError):
            mk_disk.fat_read(self.img, "NOPE")

    def test_cli_cat_missing(self):
        self.assertEqual(mk_disk.main(["cat", str(self.img), "NOPE"]), 1)


class HdfTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_geometry(self):
        path = self.dir / "test.hdf"
        mk_disk.hdf(path)
        data = path.read_bytes()
        self.assertEqual(len(data), 2048 * SECTOR)
        self.assertEqual(data[0:4], b"RDSK")
        self.assertEqual(struct.unpack(">I", data[4:8])[0], SECTOR)
        self.assertEqual(struct.unpack(">III", data[64:76]), (2, 63, 16))
        self.assertEqual(data[SECTOR:SECTOR + 12], b"KARABAS HDF\n")
        self.assertEqual(data[SECTOR + 15], (15 * 7 + 3) & 0xFF)
        self.assertEqual(data[2 * SECTOR:], bytes(len(data) - 2 * SECTOR))

    def test_too_small(self):
        with self.assertRaises(ValueError):
            mk_disk.hdf(self.dir / "small.hdf", sectors=1000)

    def test_sectors_argument(self):
        path = self.dir / "one.hdf"
        mk_disk.hdf(path, sectors=2016)
        data = path.read_bytes()
        self.assertEqual(len(data), 2016 * SECTOR)
        self.assertEqual(struct.unpack(">I", data[64:68])[0], 2)


if __name__ == "__main__":
    unittest.main()