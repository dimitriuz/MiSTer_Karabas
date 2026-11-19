"""Tests for tools/scl.py (the SCL -> TRD reference)."""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import mk_disk  # noqa: E402
import scl  # noqa: E402


class SclTest(unittest.TestCase):
    def test_matches_the_trd_writer(self):
        # the TRD mk_disk.trd writes for the same files is what the window holds
        import tempfile
        files = [("boot", "B", bytes(range(256)) * 3), ("data", "C", b"x" * 700)]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a.trd"
            mk_disk.trd(p, files=files)
            ref = p.read_bytes()
        ents = []
        for name, t, pl in files:
            import struct
            e = name.encode().ljust(8) + t.encode() + struct.pack(
                "<HH", len(pl) if t == "B" else 0, len(pl)) + b"\0"
            ents.append((e, pl))
        w = scl.window(scl.scl(ents))
        total = 3 + 3
        self.assertEqual(len(w), 0x1000 + total * 256)
        self.assertEqual(w[:0x800], ref[:0x800])
        self.assertEqual(w[0x1000:], ref[0x1000:0x1000 + total * 256])
        # the ID sector fields the writer shares (free count and label differ
        # on purpose: the writer's free count ignores the files)
        for off in (0xE1, 0xE2, 0xE3, 0xE4, 0xE7):
            self.assertEqual(w[0x800 + off], ref[0x800 + off], hex(off))

    def test_refused(self):
        self.assertIsNone(scl.window(b"SINCLAIX\x00"))
        too = scl.scl([(b"x".ljust(8) + b"C" + bytes(5), b"\0" * 256 * 200)] * 20)
        self.assertIsNone(scl.window(too))


if __name__ == "__main__":
    unittest.main()
