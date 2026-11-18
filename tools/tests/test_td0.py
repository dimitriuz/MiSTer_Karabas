"""Tests for tools/td0.py: the model the TD0 hardware is checked against.

Run: python3 -m unittest discover -s tools/tests -v
"""
import random
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import td0  # noqa: E402


class LzhTest(unittest.TestCase):
    def test_position_table_runs(self):
        # 256 lookahead entries, 64 symbols, code lengths 3..8 in the
        # run lengths LZHUF's static table has
        self.assertEqual(len(td0.D_CODE), 256)
        self.assertEqual(max(td0.D_CODE), 63)
        self.assertEqual([td0.D_LEN.count(n) for n in range(3, 9)],
                         [32, 48, 64, 48, 48, 16])

    def test_round_trip(self):
        rnd = random.Random(1)
        for n in (0, 1, 7, 300, 5000):
            data = bytes(rnd.choice(b"abcdefgh\x00\xff") if rnd.random() < .7
                         else rnd.randrange(256) for _ in range(n))
            out = td0.LzhDecoder(td0.lzh_encode(data)).read(10 ** 9)
            self.assertEqual(out[:n], data)
            self.assertLessEqual(len(out) - n, 1)

    def test_tree_rebuild_round_trip(self):
        # more than 32768 symbols: the tree is rebuilt (MAX_FREQ) at least once
        rnd = random.Random(2)
        data = bytes(rnd.randrange(256) for _ in range(40000))
        comp = td0.lzh_encode(data)
        self.assertEqual(td0.LzhDecoder(comp).read(10 ** 9)[:40000], data)


class ParseTest(unittest.TestCase):
    def test_sector_shapes(self):
        tr = td0.bench_tracks()
        for compress in (True, False):
            f = td0.build(tr, compress=compress, comment=b"hello")
            self.assertEqual(f[:2], b"td" if compress else b"TD")
            hdr, tracks = td0.parse(f)
            self.assertEqual(hdr["sides"], 2)
            self.assertEqual([(c, h, len(s)) for c, h, s in tracks],
                             [(0, 0, 7), (0, 1, 3), (1, 0, 16)])
            for (_c, _h, got), (_c2, _h2, want) in zip(tracks, tr):
                for g, w in zip(got, want):
                    self.assertEqual(g[5], w[5])

    def test_size_code_past_6_has_no_data(self):
        # a sector whose size code is 15 carries no data block (CPM16.TD0)
        tr = [(0, 0, [(0, 0, 1, 15, 0, None), (0, 0, 2, 1, 0, b"\x07" * 256, 0)])]
        _hdr, tracks = td0.parse(td0.build(tr, compress=False))
        self.assertIsNone(tracks[0][2][0][5])
        self.assertEqual(tracks[0][2][1][5], b"\x07" * 256)

    def test_runs_expand_to_the_sector(self):
        data = bytes(100) + bytes(range(156))
        blk = td0.sector_block(data, 2)
        self.assertEqual(td0._expand(2, blk[3:], 256), data)

    def test_not_a_td0(self):
        with self.assertRaises(ValueError):
            td0.parse(b"FDI" + bytes(20))


if __name__ == "__main__":
    unittest.main()
