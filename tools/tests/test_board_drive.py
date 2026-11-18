"""Unit tests for tools/board: the OSD bar arithmetic and the key sequences.

The board itself is not reachable from a test (and must not be), so the
transport is faked: what is pinned here is the *sequence* a script sends and
the row the highlight bar is read as - the two things a scripted board run
gets wrong when they drift (a dropped press, a bar read one row off).
"""
import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "board"))

import mister  # noqa: E402
import zx  # noqa: E402


class BarRow(unittest.TestCase):
    """`read_bar`'s arithmetic, without a picture."""

    def column(self, top, h=540):
        """A capture column: everything dark but the bar's 15-px run."""
        return [(y, top <= y < top + 15) for y in range(h)]

    def test_video_is_row_zero(self):
        self.assertEqual(mister.bar_row(self.column(174)), 0)

    def test_tape_play_is_row_ten(self):
        self.assertEqual(mister.bar_row(self.column(334)), 10)

    def test_every_row_of_the_map(self):
        for row, name in mister.ROWS.items():
            top = mister.BAR_TOP + row * mister.ROW_H
            if top + 15 > 540:       # the list scrolls past the capture
                continue
            self.assertEqual(mister.bar_row(self.column(top)), row, name)

    def test_no_bar_is_none(self):
        self.assertIsNone(mister.bar_row(self.column(174, h=0)))

    def test_tape_play_default_map(self):
        self.assertEqual(mister.ROWS[zx.TAPE_ROW], "Tape play/pause")


class FakeRemote:
    """Records what a script sends, in order, without a socket."""

    host = "192.168.1.13"

    def __init__(self, grow=None):
        self.sent = []
        self.grow = grow if grow is not None else {}

    def key(self, name, action="tap"):
        self.sent.append(("key", name, action))

    def press(self, name, hold=0.3):
        self.sent.append(("key", name, "down"))
        self.sent.append(("key", name, "up"))

    def pad(self, name, hold=0.3):
        self.sent.append(("pad", name, "down"))
        self.sent.append(("pad", name, "up"))

    def system(self, command):
        self.sent.append(("system", command, None))

    def release_all(self):
        self.system("release_all")

    def screen(self, path):
        return path

    def wait_picture(self, seconds=25.0, path=None):
        return True

    def close(self):
        pass

    def names(self, kind):
        return [n for k, n, _ in self.sent if k == kind]


class Sequences(unittest.TestCase):
    """The recipe itself: which presses, in which order."""

    def test_rom_menu_to_128_is_six_pads_then_enter(self):
        r = FakeRemote()
        real_pause = zx.time.sleep
        zx.time.sleep = lambda s: None
        try:
            zx.pad_enter(r, zx.MENU_TO_128)
        finally:
            zx.time.sleep = real_pause
        self.assertEqual([n for k, n, a in r.sent if k == "pad" and a == "down"],
                         ["down"] * 6)
        self.assertEqual([n for k, n, a in r.sent
                          if k == "key" and a == "down" and n == "KEY_ENTER"],
                         ["KEY_ENTER"])

    def test_load_typing_order(self):
        r = FakeRemote()
        typed = []
        state = {"cells": 0.0}

        def fake_cells(r=None):
            return state["cells"]

        real = (zx.cells, zx.time.sleep)
        zx.cells = fake_cells
        zx.time.sleep = lambda s: None

        def press(name, hold=0.3):
            r.sent.append(("key", name, "down"))
            typed.append(name)
            state["cells"] += 1.0

        r.press = press
        try:
            zx.type_text(r, "load ")
        finally:
            zx.cells, zx.time.sleep = real
        self.assertEqual(typed, ["KEY_L", "KEY_O", "KEY_A", "KEY_D", "KEY_SPACE"])

    def test_a_dropped_key_is_pressed_again(self):
        r = FakeRemote()
        state = {"cells": 0.0, "lost": 1}

        def fake_cells(r=None):
            return state["cells"]

        real = (zx.cells, zx.time.sleep)
        zx.cells = fake_cells
        zx.time.sleep = lambda s: None
        presses = []

        def press(name, hold=0.3):
            r.sent.append(("key", name, "down"))
            presses.append(name)
            if state["lost"]:
                state["lost"] -= 1        # this one the daemon eats
            else:
                state["cells"] += 1.0

        r.press = press
        try:
            zx.type_text(r, "a")
        finally:
            zx.cells, zx.time.sleep = real
        self.assertEqual(presses, ["KEY_A", "KEY_A"])



class FloppyBuild(unittest.TestCase):
    """The build-73 OSD map and the TR-DOS walk (stage 4c)."""

    def test_tape_row_is_nine_on_build_77(self):
        self.assertEqual(zx.TAPE_ROW, 9)
        self.assertEqual(mister.ROWS[zx.TAPE_ROW], "Tape play/pause")

    def test_the_storage_rows_come_before_the_tape(self):
        for row, name in ((0, "IDE 0"), (1, "IDE 1"), (2, "SD Card"),
                          (3, "Floppy A"), (4, "Floppy B"),
                          (5, "Floppy A FDI"), (6, "Floppy B FDI"),
                          (7, "Disk layout"), (8, "Tape")):
            self.assertEqual(mister.ROWS[row], name)

    def test_rom_menu_to_trdos_is_four_pads_then_enter(self):
        r = FakeRemote()
        real_pause = zx.time.sleep
        zx.time.sleep = lambda s: None
        try:
            zx.pad_enter(r, zx.MENU_TO_TRDOS_128)
        finally:
            zx.time.sleep = real_pause
        self.assertEqual([n for k, n, a in r.sent if k == "pad" and a == "down"],
                         ["down"] * 4)
        self.assertEqual([n for k, n, a in r.sent
                          if k == "key" and a == "down" and n == "KEY_ENTER"],
                         ["KEY_ENTER"])

    def test_trdos_walk_watches_for_the_boot_output(self):
        r = FakeRemote()
        seen = {"watches": 0}
        real = (zx.time.sleep, zx.changed)
        zx.time.sleep = lambda s: None

        def fake_changed(a, b):
            seen["watches"] += 1
            return True

        zx.changed = fake_changed
        try:
            zx.to_trdos(r, settle=0.0)
        finally:
            zx.time.sleep, zx.changed = real
        self.assertEqual([n for k, n, a in r.sent if k == "pad" and a == "down"],
                         ["down"] * zx.MENU_TO_TRDOS_128)
        self.assertGreaterEqual(seen["watches"], 1)


class ConfStrRowMap(unittest.TestCase):
    """The scripts' row map, recounted from the core's own CONF_STR.

    A new OSD item moves every row below it, and a scripted walk counts the
    rows by hand (`zx.TAPE_ROW`, `mister.ROWS`), so the count is derived here
    from `Karabas_Profi.sv` the way MiSTer renders the main page: a
    `P<n>,label;` page header is one row and every un-prefixed `O`/`T`/`R`/
    `S`/`F` item is one row; the `-` separators are not rows, and an item
    carrying a `P<n>` prefix lives inside that page, not on the main one.
    """

    TOP = HERE.parents[1] / "Karabas_Profi.sv"

    def conf_str_rows(self):
        body = self.TOP.read_text().split("localparam CONF_STR = {", 1)[1]
        body = body.split("\n};", 1)[0]
        fields = "".join(re.findall(r'"([^"]*)"', body)).split(";")
        rows = []
        for item in fields[2:]:              # 0 the core name, 1 the misc string
            item = item.strip()
            if not item or item == "-":
                continue
            page = re.match(r"^P(\d+)(.*)$", item)
            if page:
                if page.group(2).startswith(","):
                    rows.append(page.group(2)[1:].split(",")[0])
                continue
            parts = item.split(",")
            if item[0] in "OTR" and len(parts) > 1:
                rows.append(parts[1])
            elif item[0] in "SF" and len(parts) > 2:
                rows.append(parts[2])
        return rows

    def test_the_scripts_map_matches_the_core(self):
        rows = self.conf_str_rows()
        for row, name in sorted(mister.ROWS.items()):
            self.assertEqual(rows[row], name, "row %d" % row)

    def test_the_tape_row_counts_from_the_core(self):
        self.assertEqual(self.conf_str_rows().index("Tape play/pause"),
                         zx.TAPE_ROW)

    def test_the_images_come_first_then_the_settings_by_type(self):
        rows = self.conf_str_rows()
        self.assertEqual(rows[:12], [
            "IDE 0", "IDE 1", "SD Card",
            "Floppy A", "Floppy B", "Floppy A FDI", "Floppy B FDI",
            "Disk layout",
            "Tape", "Tape play/pause", "Tape previous block",
            "Tape next block"])
        self.assertEqual(rows[zx.TAPE_ROW:zx.TAPE_ROW + 3],
                         ["Tape play/pause", "Tape previous block",
                          "Tape next block"])
        self.assertLess(rows.index("Tape next block"),
                        rows.index("ROM Bank"))


if __name__ == "__main__":
    unittest.main()