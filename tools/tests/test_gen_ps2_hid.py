"""Tests for tools/gen_ps2_hid.py.

Run: python3 -m unittest discover -s tools/tests -v

Checks the join of tools/data/hid_keyboard.txt (HID usage -> Linux keycode)
and tools/data/ev2ps2.txt (Linux keycode -> PS/2 set-2 scancode + flags)
against the values fixed in the task brief. Checks that no usage the core
delivers in the ordinary-key ranges (0x04-0x65) and the modifiers (0xE0-0xE7)
is dropped from its (ext, code) in favour of a *different* Linux keycode -
that would make the key unreachable. A second in-range usage listed in the
kernel table for the same single keycode (keycode 43 under usages 0x31 and
0x32) is one physical key behind one scancode, not an ambiguity; the
generator keeps the lowest usage and lists every dropped usage in the .svh
header comment, which the byte-identity check below pins as well.
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import gen_ps2_hid  # noqa: E402

SVH = ROOT / "rtl" / "host" / "ps2_hid_table.svh"

# (ext, code) -> usage, verbatim from the task brief.
EXPECTED = {
    (0, 0x1C): 0x04,  # A
    (0, 0x5A): 0x28,  # Enter
    (1, 0x5A): 0x58,  # keypad Enter
    (1, 0x75): 0x52,  # Up
    (0, 0x75): 0x60,  # keypad 8
    (0, 0x14): 0xE0,  # Left Control
    (1, 0x14): 0xE4,  # Right Control
    (1, 0x11): 0xE6,  # Right Alt
    (0, 0x07): 0x45,  # F12
    (0, 0x76): 0x29,  # Escape
}

# Usages whose PS/2 entry carries EMU_SWITCH_1/2 but which are real keys
# (ruling: kept despite the switch flags).
NUMLOCK_USAGE = 0x53   # ev2ps2[69]  = EMU_SWITCH_2 | 0x77
SCROLLLOCK_USAGE = 0x47  # ev2ps2[70] = EMU_SWITCH_1 | 0x7E

# Usages of the Linux keys F17..F20 (ev2ps2[187..190] = EMU_SWITCH_1 | 1..4,
# fake codes colliding with F9/F7/F5/F3); must not appear in the map.
F17_20_USAGES = {0x6C, 0x6D, 0x6E, 0x6F}


def in_core_ranges(usage):
    return 0x04 <= usage <= 0x65 or 0xE0 <= usage <= 0xE7


class Ps2HidMapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ev2ps2, hid_keyboard = gen_ps2_hid.load_tables()
        cls.usage_of, cls.claims = gen_ps2_hid.build_map(ev2ps2, hid_keyboard)

    def test_expected_usages(self):
        for (ext, code), want in EXPECTED.items():
            self.assertEqual(self.usage_of.get((ext, code)), want,
                             "(%d,0x%02X) must map to usage 0x%02X"
                             % (ext, code, want))

    def test_all_modifiers_present(self):
        for mod in range(0xE0, 0xE8):
            self.assertIn(mod, self.usage_of.values(),
                          "modifier usage 0x%02X missing" % mod)

    def test_numlock_scrolllock_kept(self):
        self.assertIn(NUMLOCK_USAGE, self.usage_of.values())
        self.assertIn(SCROLLLOCK_USAGE, self.usage_of.values())

    def test_f17_f20_skipped(self):
        values = set(self.usage_of.values())
        self.assertEqual(sorted(values & F17_20_USAGES), [])

    def test_no_ambiguous_code_in_core_ranges(self):
        # A (ext, code) collision matters only when it drops a *different*
        # physical key whose usage the core delivers (0x04-0x65, 0xE0-0xE7):
        # that key would then be unreachable. The kernel table also lists the
        # same keycode under a second in-range usage (0x31/0x32 both key 43);
        # one scancode behind one key is not an ambiguity, and the .svh header
        # comment (pinned by Ps2HidSvhTest) records it. Collisions whose loser
        # lies outside these ranges (KEY_ZENKAKU 0x94, the F-key rows, the
        # German 0x5D) are likewise out of scope.
        dropped = []
        for (ext, code), claims in sorted(self.claims.items()):
            winner_usage, winner_key = claims[0]
            for usage, key in claims[1:]:
                if key != winner_key and in_core_ranges(usage):
                    dropped.append((ext, code, winner_usage, winner_key,
                                    usage, key))
        self.assertEqual(dropped, [], "in-range usages dropped by a colliding "
                         "different key: %s" % dropped)

    def test_lowest_usage_wins(self):
        for (ext, code), claims in self.claims.items():
            usages = [u for u, _ in claims]
            self.assertEqual(claims[0][0], min(usages),
                             "(%d,0x%02X): lowest usage must win"
                             % (ext, code))


class Ps2HidSvhTest(unittest.TestCase):
    def test_generated_matches_committed(self):
        ev2ps2, hid_keyboard = gen_ps2_hid.load_tables()
        want = gen_ps2_hid.render(ev2ps2, hid_keyboard)
        self.assertTrue(SVH.is_file(), "%s missing" % SVH)
        self.assertEqual(SVH.read_bytes(), want.encode("utf-8"),
                         "%s is not byte-identical to the generator output "
                         "(run: python3 tools/gen_ps2_hid.py)" % SVH)


if __name__ == "__main__":
    unittest.main()
