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


def ccitt(data):
    """CCITT-FFFF: poly 0x1021, init 0xFFFF, no reflection (upstream crc_byte)"""
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def trd_sector(img, track, side, sector):
    off = ((track * 2 + side) * 16 + sector - 1) * 256
    return img[off:off + 256]


def parse_reftrack(path):
    data = bytes(int(line, 16) for line in Path(path).read_text().splitlines())
    sync = [int(line)
            for line in Path(str(path) + ".sync").read_text().splitlines()]
    return data, sync


class TrdTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img = Path(self.tmp.name) / "t.trd"

    def test_trd_geometry(self):
        mk_disk.trd(self.img, tracks=40, files=[])
        img = self.img.read_bytes()
        self.assertEqual(len(img), 40 * 8192)
        idsec = trd_sector(img, 0, 0, 9)
        self.assertEqual(idsec[0xE1], 0)
        self.assertEqual(idsec[0xE2], 1)
        self.assertEqual(idsec[0xE3], 0x16)
        self.assertEqual(idsec[0xE4], 0)
        self.assertEqual(struct.unpack_from("<H", idsec, 0xE5)[0], 40 * 32 - 16)
        self.assertEqual(idsec[0xE7], 0x10)
        self.assertEqual(idsec[0xF4], 0)
        self.assertEqual(idsec[0xF5:0xFD], b"MiSTer  ")
        self.assertEqual(idsec[:0xE1], bytes(0xE1))
        self.assertEqual(idsec[0xFD:], bytes(3))
        other = Path(self.tmp.name) / "d.trd"
        mk_disk.trd(other, files=[])
        self.assertEqual(other.stat().st_size, 80 * 8192)
        self.assertEqual(struct.unpack_from(
            "<H", trd_sector(other.read_bytes(), 0, 0, 9), 0xE5)[0],
            80 * 32 - 16)

    def test_trd_catalog(self):
        p1 = bytes((i * 5 + 1) & 0xFF for i in range(20 * 256))
        p2 = b"second file"
        mk_disk.trd(self.img, tracks=80,
                    files=[("boot", "B", p1), ("prog", "C", p2)])
        self.assertEqual(mk_disk.trd_ls(self.img),
                         [("boot", "B", len(p1)), ("prog", "C", len(p2))])
        self.assertEqual(mk_disk.trd_read(self.img, "boot"), p1)
        self.assertEqual(mk_disk.trd_read(self.img, "prog"), p2)
        img = self.img.read_bytes()
        # TR-DOS numbering is flat: logical track = cylinder * 2 + side.
        # boot starts at logical track 1 (file offset 16 * 256) and its
        # 20 sectors cross into logical track 2 (offset 32 * 256); prog
        # follows contiguously at logical track 2, sector 4.
        self.assertEqual(img[16 * 256:16 * 256 + 4096], p1[:4096])
        self.assertEqual(img[32 * 256:36 * 256], p1[4096:])
        self.assertEqual(img[36 * 256:36 * 256 + len(p2)], p2)
        e0, e1 = img[0:16], img[16:32]
        self.assertEqual(e0[0:8], b"boot    ")
        self.assertEqual(e0[8], ord("B"))
        # real TR-DOS entry: 13 sectors, 14 first sector, 15 first track
        self.assertEqual(struct.unpack_from("<H", e0, 9)[0], len(p1))
        self.assertEqual(struct.unpack_from("<H", e0, 11)[0], len(p1))
        self.assertEqual((e0[13], e0[14], e0[15]), (20, 0, 1))
        self.assertEqual(e1[0:8], b"prog    ")
        self.assertEqual(e1[8], ord("C"))
        self.assertEqual(struct.unpack_from("<H", e1, 11)[0], len(p2))
        self.assertEqual((e1[13], e1[14], e1[15]), (1, 4, 2))
        idsec = trd_sector(img, 0, 0, 9)
        used = 20 + 1
        self.assertEqual(idsec[0xE1], used % 16)
        self.assertEqual(idsec[0xE2], 1 + used // 16)
        self.assertEqual(idsec[0xE4], 2)
        self.assertEqual(struct.unpack_from("<H", idsec, 0xE5)[0],
                         80 * 32 - 16)

    def test_boot_payload(self):
        mk_disk.trd(self.img)
        self.assertEqual(mk_disk.trd_read(self.img, "boot"),
                         mk_disk.boot_program())
        self.assertEqual(mk_disk.trd_ls(self.img)[0][:2], ("boot", "B"))

    def test_trd_read_missing(self):
        mk_disk.trd(self.img, tracks=40, files=[])
        with self.assertRaises(KeyError):
            mk_disk.trd_read(self.img, "nope")

    def test_trd_deleted_entry(self):
        mk_disk.trd(self.img, tracks=40,
                    files=[("a", "B", b"x"), ("b", "B", b"yy")])
        img = bytearray(self.img.read_bytes())
        img[0] = 0x01  # TR-DOS deleted-entry marker, entry 0 ("a")
        self.img.write_bytes(img)
        self.assertEqual([name for name, _, _ in mk_disk.trd_ls(self.img)],
                         ["b"])
        self.assertEqual(mk_disk.trd_read(self.img, "b"), b"yy")
        img[0] = 0x00  # a zero first byte ends the catalog
        self.img.write_bytes(img)
        self.assertEqual(mk_disk.trd_ls(self.img), [])

    def test_cli_boot_flag(self):
        plain = Path(self.tmp.name) / "plain.trd"
        mk_disk.main(["trd", str(plain)])
        self.assertEqual(mk_disk.trd_ls(plain), [])
        with self.assertRaises(KeyError):
            mk_disk.trd_read(plain, "boot")
        mk_disk.main(["trd", str(plain), "--boot"])
        self.assertEqual([name for name, _, _ in mk_disk.trd_ls(plain)],
                         ["boot"])


class CpmTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img = Path(self.tmp.name) / "t.cpm"

    def test_cpm_geometry(self):
        mk_disk.cpm(self.img, tracks=40)
        img = self.img.read_bytes()
        self.assertEqual(len(img), 40 * 10240)
        self.assertEqual(img[15], (15 * 7 + 3) & 0xFF)
        self.assertEqual(img[10240 + 15], (15 * 7 + 3) & 0xFF)


class FdiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img = Path(self.tmp.name) / "t.fdi"

    def test_fdi_from_trd(self):
        with tempfile.TemporaryDirectory() as d:
            t = Path(d) / "a.trd"
            f = Path(d) / "a.fdi"
            mk_disk.trd(t, files=[("boot", "B", b"x" * 300)])
            mk_disk.fdi(f, source=t)
            img, trd = f.read_bytes(), t.read_bytes()
            tracks, sides, off_data, blocks = mk_disk._fdi_walk(img)
            # cylinder 3 side 1 sector 5 is logical track 7, sector 4
            data_off, secs = blocks[3 * 2 + 1]
            c, h, r, n, flags, off = secs[4]
            base = off_data + data_off + off
            self.assertEqual((c, h, r), (3, 1, 5))
            self.assertEqual(img[base:base + 256],
                             trd[(7 * 16 + 4) * 256:(7 * 16 + 5) * 256])
            # sector 9 of cylinder 0 side 0 is the TR-DOS ID sector
            data_off, secs = blocks[0]
            base = off_data + data_off + secs[8][5]
            self.assertEqual(img[base + 0xE7], 0x10)

    def test_fdi_header(self):
        mk_disk.fdi(self.img, tracks=4)
        img = self.img.read_bytes()
        self.assertEqual(img[0:3], b"FDI")
        self.assertEqual(img[3], 0)
        self.assertEqual(struct.unpack_from("<H", img, 4)[0], 4)
        self.assertEqual(struct.unpack_from("<H", img, 6)[0], 2)
        size_ext = struct.unpack_from("<H", img, 0x0C)[0]
        self.assertEqual(size_ext, 0)
        table_size = 4 * 2 * (7 + 16 * 7)
        off_text = struct.unpack_from("<H", img, 8)[0]
        off_data = struct.unpack_from("<H", img, 0x0A)[0]
        self.assertEqual(off_text, 0x0E + size_ext + table_size)
        self.assertEqual(off_data, off_text)
        # the track table: each 7-byte header is followed immediately by
        # its sector records, cylinder-major and side-minor
        dataoff, reserved, count = struct.unpack_from("<IHB", img, 0x0E)
        self.assertEqual((dataoff, reserved, count), (0, 0, 16))
        for r in range(1, 17):
            self.assertEqual(
                struct.unpack_from("<5BH", img, 0x0E + 7 + 7 * (r - 1)),
                (0, 0, r, 1, 0, (r - 1) * 256))
        # track 0 side 1: the header sits right after the 16 records
        h1 = 0x0E + 7 + 16 * 7
        dataoff1, _, count1 = struct.unpack_from("<IHB", img, h1)
        self.assertEqual((dataoff1, count1), (4096, 16))
        self.assertEqual(struct.unpack_from("<5BH", img, h1 + 7 + 7 * 15),
                         (0, 1, 16, 1, 0, 15 * 256))
        # track 1 side 0: after two full table entries; its data starts
        # after two payload blocks (the data area holds payloads only)
        h2 = 0x0E + 2 * (7 + 16 * 7)
        dataoff2, _, _ = struct.unpack_from("<IHB", img, h2)
        self.assertEqual(dataoff2, 2 * 4096)
        self.assertEqual(img[off_data], (off_data * 7 + 3) & 0xFF)
        self.assertEqual(img[off_data + 1], ((off_data + 1) * 7 + 3) & 0xFF)
        self.assertEqual(img[off_data + 8 * 4096 - 1],
                         ((off_data + 8 * 4096 - 1) * 7 + 3) & 0xFF)
        mk_disk.fdi(self.img, tracks=2, layout="wide")
        img = self.img.read_bytes()
        dataoff, _, count = struct.unpack_from("<IHB", img, 0x0E)
        self.assertEqual((dataoff, count), (0, 9))
        descs = [struct.unpack_from("<5BH", img, 0x0E + 7 + 7 * i)
                 for i in range(9)]
        self.assertEqual([d[3] for d in descs[:8]], [2] * 8)
        self.assertEqual([d[5] for d in descs[:8]], [i * 512 for i in range(8)])
        self.assertEqual(descs[8][4] & 0x40, 0x40)
        # track 1 side 0: its header follows the 9 wide records of both
        # cylinder-0 sides, and its payload starts after 2 * 4096 bytes
        hw = 0x0E + 2 * (7 + 9 * 7)
        dataoff2, _, count2 = struct.unpack_from("<IHB", img, hw)
        self.assertEqual((dataoff2, count2), (2 * 4096, 16))
        descs2 = [struct.unpack_from("<5BH", img, hw + 7 + 7 * i)
                  for i in range(16)]
        self.assertEqual([d[3] for d in descs2], [1] * 16)
        off_data = struct.unpack_from("<H", img, 0x0A)[0]
        self.assertEqual(img[off_data + 4096],
                         ((off_data + 4096) * 7 + 3) & 0xFF)


class ReftrackTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name) / "ref_t3s1"

    def test_reftrack_crc(self):
        self.assertEqual(ccitt(b"123456789"), 0x29B1)
        data_in = bytes((i * 3) & 0xFF for i in range(256))
        sectors = [(3, 1, 7, 1, data_in)]
        mk_disk.reftrack(self.out, track=3, side=1, sectors=sectors)
        data, sync = parse_reftrack(self.out)
        self.assertEqual(len(data), 6250)
        self.assertEqual(len(sync), 6250)
        self.assertEqual(data[0:10], bytes([0x4E] * 10))
        self.assertEqual(data[10:22], bytes(12))
        self.assertEqual(data[32:54], bytes([0x4E] * 22))
        self.assertEqual(data[54:66], bytes(12))
        self.assertEqual(data[328:], bytes([0x4E] * (6250 - 328)))
        ones = [i for i, s in enumerate(sync) if s]
        self.assertEqual(ones, [22, 23, 24, 66, 67, 68])
        self.assertTrue(all(data[i] == 0xA1 for i in ones))
        self.assertEqual(data[22:26], bytes([0xA1, 0xA1, 0xA1, 0xFE]))
        self.assertEqual(data[26:30], bytes([3, 0, 7, 1]))
        want = ccitt([0xA1, 0xA1, 0xA1, 0xFE, 3, 0, 7, 1])
        self.assertEqual(data[30:32], struct.pack(">H", want))
        self.assertEqual(data[66:70], bytes([0xA1, 0xA1, 0xA1, 0xFB]))
        self.assertEqual(data[70:326], data_in)
        want = ccitt([0xA1, 0xA1, 0xA1, 0xFB] + list(data_in))
        self.assertEqual(data[326:328], struct.pack(">H", want))
        mk_disk.reftrack(Path(str(self.out) + "c"), track=3, side=1,
                         sectors=sectors, cpm=True)
        cpm, _ = parse_reftrack(Path(str(self.out) + "c"))
        self.assertEqual(cpm[27], 1)
        self.assertEqual(cpm[26], 3)

    def test_reftrack_bad_sector(self):
        with self.assertRaises(ValueError):
            mk_disk.reftrack(self.out, track=0, side=0,
                             sectors=[(0, 0, 1, 1, bytes(512))])




def parse_stream(path):
    """fdistream output: pairs of (address, data)"""
    vals = [int(line, 16) for line in Path(path).read_text().splitlines()]
    return list(zip(vals[0::2], vals[1::2]))


class ReffromTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img = Path(self.tmp.name) / "t.img"
        self.out = Path(self.tmp.name) / "ref"

    def test_reffrom_trd(self):
        mk_disk.trd(self.img)                 # the auto-run boot disk
        img = self.img.read_bytes()
        mk_disk.reffrom(self.out, self.img, track=5, side=1, kind="trd")
        data, _ = parse_reftrack(self.out)
        for r in range(1, 17):
            base = (r - 1) * 388
            self.assertEqual(data[base + 22:base + 30],
                             bytes([0xA1, 0xA1, 0xA1, 0xFE, 5, 0, r, 1]))
            want = ccitt([0xA1, 0xA1, 0xA1, 0xFE, 5, 0, r, 1])
            self.assertEqual(data[base + 30:base + 32],
                             struct.pack(">H", want))
            self.assertEqual(data[base + 70:base + 326],
                             trd_sector(img, 5, 1, r))

    def test_reffrom_trd_uses_the_image(self):
        # track 0 side 0 is the catalog: its sector 1 is the first
        # directory entry, not any pattern the CLI could invent
        mk_disk.trd(self.img)
        img = self.img.read_bytes()
        mk_disk.reffrom(self.out, self.img, track=0, side=0, kind="trd")
        data, _ = parse_reftrack(self.out)
        self.assertEqual(data[70:78], img[0:8])
        self.assertEqual(data[70], ord("b"))  # the boot file's entry

    def test_reffrom_cpm(self):
        mk_disk.cpm(self.img, tracks=80)
        img = self.img.read_bytes()
        mk_disk.reffrom(self.out, self.img, track=3, side=1, kind="cpm")
        data, _ = parse_reftrack(self.out)
        lt = 7
        for r in range(1, 6):
            base = (r - 1) * 1156
            self.assertEqual(data[base + 22:base + 30],
                             bytes([0xA1, 0xA1, 0xA1, 0xFE, 3, 1, r, 3]))
            self.assertEqual(data[base + 70:base + 70 + 1024],
                             img[lt * 5120 + (r - 1) * 1024:
                                 lt * 5120 + r * 1024])
        # side 1 sits 5120 into its two-side track block: byte value
        # (5120 * 7 + 3) & 0xFF, where the CLI pattern would say 3
        self.assertEqual(data[70], (5120 * 7 + 3) & 0xFF)

    def test_reffrom_fdi(self):
        mk_disk.fdi(self.img, tracks=4)
        img = self.img.read_bytes()
        off_data = struct.unpack_from("<H", img, 0x0A)[0]
        mk_disk.reffrom(self.out, self.img, track=0, side=1, kind="fdi")
        data, _ = parse_reftrack(self.out)
        for r in range(1, 17):
            base = (r - 1) * 388
            # H comes from the sector record, and it is the side
            self.assertEqual(data[base + 22:base + 30],
                             bytes([0xA1, 0xA1, 0xA1, 0xFE, 0, 1, r, 1]))
            want = ccitt([0xA1, 0xA1, 0xA1, 0xFE, 0, 1, r, 1])
            self.assertEqual(data[base + 30:base + 32],
                             struct.pack(">H", want))
            self.assertEqual(data[base + 70:base + 326],
                             img[off_data + 4096 + (r - 1) * 256:
                                 off_data + 4096 + r * 256])

    def test_reffrom_fdi_nodata(self):
        mk_disk.fdi(self.img, tracks=2, layout="wide")
        mk_disk.reffrom(self.out, self.img, track=0, side=0, kind="fdi")
        data, sync = parse_reftrack(self.out)
        base = 8 * 644                       # after the eight 512 B sectors
        self.assertEqual(data[base + 22:base + 30],
                         bytes([0xA1, 0xA1, 0xA1, 0xFE, 0, 0, 9, 1]))
        want = ccitt([0xA1, 0xA1, 0xA1, 0xFE, 0, 0, 9, 1])
        self.assertEqual(data[base + 30:base + 32], struct.pack(">H", want))
        # ID only: the 4E gap follows the ID's CRC, no data mark anywhere
        self.assertEqual(data[base + 32], 0x4E)
        self.assertNotIn(0xFB, data[base + 32:base + 92])
        self.assertEqual(sync[base + 22:base + 25], [1, 1, 1])
        self.assertEqual(set(s for s in sync[base + 25:base + 92]), {0})


class FdistreamTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.img = Path(self.tmp.name) / "t.fdi"
        self.out = Path(self.tmp.name) / "prog"

    def test_fdistream_table(self):
        mk_disk.fdi(self.img, tracks=2, layout="wide")
        img = self.img.read_bytes()
        mk_disk.fdistream(self.out, self.img, [(0, 0)])
        prog = parse_stream(self.out)
        table = {a: d for a, d in prog if a & 0x200000}
        # the track header of block 0: u32 DataOffset, then the count
        for b, v in enumerate(struct.pack("<I", 0)):
            self.assertEqual(table[0x300000 | b], v)
        self.assertEqual(table[0x300000 | 4], 9)
        self.assertNotIn(0x300000 | 5, table)
        for s in range(9):
            rec = struct.unpack_from("<5BH", img, 0x0E + 7 + 7 * s)
            for b, v in enumerate(struct.pack("<5BH", *rec)):
                self.assertEqual(table[0x200000 | (s << 3) | b], v)
        # block 1 (track 0, side 1) is not requested and not streamed
        self.assertNotIn(0x300000 | 8, table)

    def test_fdistream_data(self):
        mk_disk.fdi(self.img, tracks=2, layout="wide")
        img = self.img.read_bytes()
        off_data = struct.unpack_from("<H", img, 0x0A)[0]
        mk_disk.fdistream(self.out, self.img, [(0, 0)])
        prog = parse_stream(self.out)
        data = {a: d for a, d in prog if not a & 0x200000}
        self.assertEqual(len(data), 8 * 512)  # the 0x40 sector has none
        for addr, val in data.items():
            self.assertEqual(val, img[off_data + addr])


if __name__ == "__main__":
    unittest.main()