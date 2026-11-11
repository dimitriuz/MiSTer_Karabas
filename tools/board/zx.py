"""The verified board recipe: boot, reach 128 BASIC, LOAD "", fire the tape.

This is the sequence that works, written down so it does not have to be
re-derived (2026-11-09/10 runs, `docs/dev/stage4a-results.md`,
`docs/dev/stage4b-results.md`; driving notes in AGENTS.md):

  1. `boot`  - load an MGL, wait for a picture (the Karabas GO menu).
  2. `128menu` - gamepad 6 x `down` + keyboard `Enter` = `Run Sinclair 128K`;
               the 128 ROM's menu appears with `Tape Loader` highlighted.
  3. `loader` - `Enter`: the loader takes the first file on the tape, so a
               tape mounted through an MGL needs **no typing at all**.
               (`basic` steps one down into `128 BASIC` instead, and `load`
               types `LOAD ""` there for the case where that is wanted.)
  4. `tape`  - OSD via the gamepad `home`, walk to `Tape play/pause`
               (10 x `Down` from `Video` on builds 54+), `Enter` fires it.

Traps, all measured on the board:

- The remote daemon **drops and delays presses** (about one in five, and a
  press can land seconds late). Every step here waits and verifies; typing
  counts character cells on the screenshot and retries a dropped key.
- Menu arrows and OSD steps MUST come from the gamepad (`pad()`); the Profi
  XT key path drops repeats above turbo 1x. Activations are keyboard `Enter`.
- PC `shift` is ZX SYMBOL SHIFT, so `shift+P` is `"`. Both shift keys are
  tried, whichever grows the line is kept.
- The tape is **paused by design** after mounting; without the `Tape
  play/pause` trigger the loader waits for ever with a flat grey border.
- Open the OSD with the gamepad `home` button (`BTN_MODE`), never `KEY_HOME`
  or `KEY_F12` (they stopped working after a `cold_reboot`).

    python3 tools/board/zx.py all    <mgl>      # boot, loader, fire the tape
    python3 tools/board/zx.py boot   /media/fat/games/Karabas_Profi/x.mgl
    python3 tools/board/zx.py 128menu | loader | tape | basic | load
"""
import subprocess
import sys
import time

from mister import Capture, Remote, read_bar, text_cells

SHOTS = "/tmp"
MENU_TO_128 = 6          # gamepad `down` presses on the GO menu
MENU_TO_BASIC = 1        # gamepad `down` presses on the 128 ROM menu
TAPE_ROW = 10            # `Down` presses from `Video` to `Tape play/pause`


def shot(name):
    return f"{SHOTS}/zx-{name}.png"


def cells(r) -> float:
    """Character cells of the typed line, measured on a fresh screenshot."""
    r.screen(shot("now"))
    return text_cells(shot("now"))


def pad_enter(r, presses, gap=0.45):
    for _ in range(presses):
        r.pad("down")
        time.sleep(gap)
    time.sleep(0.2)
    r.press("KEY_ENTER")
    time.sleep(0.5)


def quote(r, before):
    """Type one `"` (ZX SYMBOL SHIFT + P), trying both shift keys."""
    for shift in ("KEY_LEFTSHIFT", "KEY_RIGHTSHIFT"):
        r.key(shift, "down")
        time.sleep(0.3)
        r.press("KEY_P", 0.3)
        r.key(shift, "up")
        time.sleep(0.6)
        if cells(r) > before + 0.5:
            return shift
    raise RuntimeError("neither shift key produced a character")


def type_key(r, name, before, tries=3):
    for _ in range(tries):
        r.press(name, 0.3)
        time.sleep(0.55)
        now = cells(r)
        if now > before + 0.5:
            return now
        time.sleep(0.4)
    raise RuntimeError(f"the daemon dropped {name} {tries} times "
                       f"(cells {before:.1f} -> {cells(r):.1f})")


def type_text(r, text):
    """Type lowercase letters, digits and spaces, one verified key at a time."""
    line = cells(r)
    for ch in text:
        if ch == " ":
            name = "KEY_SPACE"
        elif ch.isdigit():
            name = f"KEY_{ch}"
        elif ch.isalpha():
            name = f"KEY_{ch.upper()}"
        else:
            raise ValueError(ch)
        line = type_key(r, name, line)
        print(f"  {name}: cells={line:.1f}")


def boot(r, mgl):
    subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
         f"root@{r.host}", f'echo "load_core {mgl}" > /dev/MiSTer_cmd'],
        check=True)
    time.sleep(1.0)
    return r.wait_picture(25.0, shot("boot"))


def to_128_menu(r):
    """GO menu -> `Run Sinclair 128K` -> the 128 ROM's own menu."""
    pad_enter(r, MENU_TO_128)
    time.sleep(3.0)
    return r.screen(shot("rom"))


def to_loader(r):
    """The 128 menu's first item is `Tape Loader`: Enter starts it, no typing.

    The loader screen (`Tape Loader` / `To cancel - press BREAK twice`) takes
    the first file on the tape, so a tape mounted through an MGL needs no
    `LOAD ""` at all.
    """
    r.press("KEY_ENTER")
    time.sleep(2.5)
    return r.screen(shot("loader"))


def to_basic(r):
    """The 128 menu's `128 BASIC` (one gamepad step down), empty editor."""
    pad_enter(r, MENU_TO_BASIC)
    time.sleep(2.0)
    return r.screen(shot("basic"))


def load(r):
    """The 128 BASIC `LOAD ""` line, verified, then Enter."""
    line = cells(r)
    for name in ("KEY_L", "KEY_O", "KEY_A", "KEY_D", "KEY_SPACE"):
        line = type_key(r, name, line)
    for _ in range(2):
        before = cells(r)
        line = quote(r, before)
    time.sleep(0.4)
    r.screen(shot("typed"))
    r.press("KEY_ENTER")
    time.sleep(2.5)
    return r.screen(shot("loading"))


def open_osd(r, cap):
    r.pad("home")
    cap.frame(shot("osd"))
    return read_bar(shot("osd"))


def tape(r, cap):
    """Open the OSD, step to `Tape play/pause` one verified press at a time."""
    row = open_osd(r, cap)
    if row is None:
        raise RuntimeError("no OSD bar on the capture")
    while row < TAPE_ROW:
        want = row + 1
        r.pad("down")
        cap.frame(shot("osd"))
        got = read_bar(shot("osd"))
        if got == row:          # a dropped press costs one extra
            continue
        if got != want:
            raise RuntimeError(f"stepped from row {row} to {got}, wanted {want}")
        row = got
    cap.frame(shot("osd"))
    if read_bar(shot("osd")) != TAPE_ROW:
        raise RuntimeError("the bar moved before the fire")
    r.press("KEY_ENTER")
    time.sleep(2.0)
    r.pad("home")               # close the OSD to watch the machine
    time.sleep(2.0)
    return r.screen(shot("play"))


def main(argv):
    what = argv[1] if len(argv) > 1 else "all"
    r = Remote()
    cap = Capture()
    try:
        r.release_all()
        if what in ("boot", "all"):
            print("boot:", boot(r, argv[2]))
        if what in ("128menu", "loader", "tape", "all"):
            print("128menu:", to_128_menu(r))
        if what in ("loader", "tape", "all"):
            print("loader:", to_loader(r))
        if what == "basic":
            print("basic:", to_basic(r), f"cells={cells(r):.1f}")
        if what == "load":
            print("load:", load(r))
        if what in ("tape", "all"):
            print("tape:", tape(r, cap))
    finally:
        r.release_all()
        r.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))