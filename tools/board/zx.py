"""The verified board recipe: boot, reach the loader, fire the tape.

This is the sequence that works, written down so it does not have to be
re-derived (2026-11-09/10 runs, `docs/dev/stage4a-results.md`,
`docs/dev/stage4b-results.md`; driving notes in AGENTS.md):

  1. `boot`  - load an MGL, wait 18 s for the core, then for the GO main
               menu (its teal list box). With a disk image mounted the loader
               probes the CF first and the menu can take 40 s.
  2. `128menu` - settle 5 s, gamepad 6 x `down`, keyboard `Enter` =
               `Run Sinclair 128K`. **With a tape mounted the ROM goes
               straight to `Tape Loader`; without one it shows the 128 menu.**
  3. `loader` - the loader screen takes the tape's first file, so a tape
               mounted through an MGL needs **no typing at all**. (`basic`
               steps one down into `128 BASIC` instead, and `load` types
               `LOAD ""` there for the case where that is wanted.)
  4. `fire`  - `Tape play/pause` blind (Home, 10 x gamepad Down, keyboard
               Enter, Home) and verified by the machine's screen changing:
               the loader prints `Program: <name>`. `tape` is the same walk
               with the OSD bar read off the capture card, which is only
               possible while the card has an HDMI signal.

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

    python3 tools/board/zx.py all    <mgl>      # boot, 128menu, loader, fire
    python3 tools/board/zx.py boot   /media/fat/games/Karabas_Profi/x.mgl
    python3 tools/board/zx.py 128menu | loader | fire | tape | basic | load
"""
import subprocess
import sys
import time

import mister
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
        if cells(r) > before + 0.3:
            return shift
    raise RuntimeError("neither shift key produced a character")


def type_key(r, name, before, tries=6):
    """One character, proven by the editor line growing.

    The daemon drops a key now and then - `A` landed and `D` was lost twice in
    a row on the board (2026-11-11) - and a dropped key costs the whole walk,
    so each one gets six attempts with a growing gap: uinput input queues.
    """
    for attempt in range(tries):
        r.press(name, 0.3)
        time.sleep(0.55 + attempt * 0.8)
        now = cells(r)
        if now > before + 0.3:
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


def boot(r, mgl, menu=True):
    """Load an MGL and wait for the picture; with `menu`, for the main menu."""
    subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
         f"root@{r.host}", f'echo "load_core {mgl}" > /dev/MiSTer_cmd'],
        check=True)
    # The old picture stays on the API until the new core drives video, so a
    # "wait for a picture" right after load_core returns the *previous*
    # machine's screen. Give the core its 17-20 s first.
    time.sleep(18.0)
    if menu and not r.wait_menu(150.0, shot("menu")):
        raise RuntimeError("no main menu after 150 s")
    return r.screen(shot("boot"))


def to_128_menu(r, settle=5.0):
    """GO menu -> `Run Sinclair 128K` -> the 128 ROM's own menu.

    The GO menu is drawn while the loader finishes probing the drives, and a
    `Down` sent into that window can land on a different row (board,
    2026-11-11: 6 x Down reached `Run TR-DOS 128K`, i.e. the machine booted
    TR-DOS and then ran into RAM). Settle before the first press, and let the
    caller retry the whole walk when the 128 menu does not appear.

    The ROM shows its copyright for a couple of seconds first; wait for the
    menu itself, because a key sent to the copyright screen is lost.
    """
    time.sleep(settle)
    pad_enter(r, MENU_TO_128)
    # Past the GO menu the ROM ends in one of four places - its copyright, its
    # menu, `Tape Loader`, or `128 BASIC` - and which one depends on the tape
    # and on whether a press was delivered twice. All of them are fine here;
    # `start_tape` takes it from the screen it finds. Only "still on the GO
    # menu" is a failure (the presses did not take).
    from PIL import Image
    t0 = time.time()
    while time.time() - t0 < 25.0:
        try:
            r.screen(shot("rom"))
            im = Image.open(shot("rom")).convert("RGB")
        except Exception:
            continue
        if not mister.menu_visible(im):
            return shot("rom")
        time.sleep(0.5)
    raise RuntimeError("still on the GO menu after Enter - presses lost")


def to_loader(r):
    """Reach the `Tape Loader` screen, whichever way the ROM got there.

    A mounted tape makes `Run Sinclair 128K` enter the loader directly; a
    machine without one shows the 128 menu instead, where the first item is
    `Tape Loader`. The loader takes the tape's first file, so no `LOAD ""`
    and no typing are needed at all.
    """
    from PIL import Image
    im = Image.open(shot("rom")).convert("RGB")
    if not mister.loader_visible(im):
        r.press("KEY_ENTER")
        if not r.wait_loader(20.0, shot("loader")):
            raise RuntimeError("the Tape Loader screen did not appear")
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


def changed(a, b, frac=0.02, band=(0.10, 0.55)):
    """True when the machine's *program area* moved between two screenshots.

    Only the upper part of the picture is compared: that is where a running
    program prints (`Program: hello`, `tape ok`), while the OSD overlay, the
    ROM's status bar and the BASIC cursor sit outside it. A whole-frame
    compare reported "the tape started" for a screen that merely redrew its
    status bar (board, 2026-11-11).
    """
    from PIL import Image, ImageChops
    box = None
    ia = Image.open(a).convert("L")
    w, h = ia.size
    box = (0, int(h * band[0]), w, int(h * band[1]))
    ia, ib = ia.crop(box), Image.open(b).convert("L").crop(box)
    diff = ImageChops.difference(ia, ib).point(lambda v: 255 if v > 40 else 0)
    return sum(diff.histogram()[255:]) > frac * ia.width * ia.height


def fire_tape(r, tries=2):
    """Fire `Tape play/pause` blind, and prove it by the machine's screen.

    With no HDMI signal on the capture card the OSD bar cannot be read, so the
    walk is the documented one (Home, `TAPE_ROW` x gamepad Down, keyboard
    Enter, Home) and the *effect* is the check: the loader screen changes when
    the tape starts. A dropped press costs a whole walk, hence `tries`.
    """
    before = r.screen(shot("before"))
    for attempt in range(1, tries + 1):
        r.pad("home")
        time.sleep(2.0)
        for _ in range(TAPE_ROW):
            r.pad("down")
            time.sleep(1.8)
        r.press("KEY_ENTER")
        time.sleep(1.5)
        r.pad("home")
        for _ in range(5):                 # the program needs a few seconds
            time.sleep(2.0)
            after = r.screen(shot(f"after{attempt}"))
            if changed(before, after):
                return after
    print(f"WARNING: the screen did not change after {tries} walks - read "
          f"{shot(f'after{tries}')} before believing the tape ran")
    return shot(f"after{tries}")


def start_tape(r):
    """Get the machine waiting for the tape, *before* the OSD is ever used.

    `Run Sinclair 128K` ends in the `Tape Loader` when the ROM takes the tape
    path, in its own menu otherwise (then `Enter` starts the loader), and -
    if a press is delivered twice - in `128 BASIC` (then `LOAD ""` is typed,
    one verified key at a time). Typing has to happen before any `home`
    press: the OSD is invisible in the MiSTer screenshot, so a script that
    leaves it open types into it and nothing lands (board, 2026-11-11).
    """
    from PIL import Image
    # The ROM boots through three screens of its own - the copyright, its menu
    # (`Tape Loader` highlighted) and the loader - and one `Enter` walks one
    # step, whichever is showing. So press on until the loader shows; in
    # `128 BASIC` an `Enter` only opens a fresh line, which is harmless.
    for _ in range(3):
        r.screen(shot("now"))
        im = Image.open(shot("now")).convert("RGB")
        if mister.loader_visible(im):
            return shot("now")
        r.press("KEY_ENTER")
        time.sleep(2.5)
    r.screen(shot("now"))
    im = Image.open(shot("now")).convert("RGB")
    if mister.loader_visible(im):
        return shot("now")
    load(r)                             # 128 BASIC: LOAD "" + Enter
    return shot("loading")


def main(argv):
    what = argv[1] if len(argv) > 1 else "all"
    r = Remote()
    cap = Capture()
    try:
        r.release_all()
        if what == "boot":
            print("boot:", boot(r, argv[2]))
        if what == "all":
            for attempt in range(1, 4):
                print("boot:", boot(r, argv[2]))
                try:
                    print("128menu:", to_128_menu(r))
                    break
                except RuntimeError as exc:
                    print(f"attempt {attempt}: {exc}")
            else:
                raise RuntimeError("the 128 ROM menu did not appear")
        if what in ("128menu", "loader", "tape"):
            print("128menu:", to_128_menu(r))
        if what == "loader":
            print("loader:", to_loader(r))
        if what == "basic":
            print("basic:", to_basic(r), f"cells={cells(r):.1f}")
        if what == "load":
            print("load:", load(r))
        if what == "tape":                 # OSD verified through the capture
            print("tape:", tape(r, cap))
        if what == "fire":                 # no capture: verified by effect
            print("fire:", fire_tape(r))
        if what == "all":
            print("start:", start_tape(r))
            print("tape:", fire_tape(r))
    finally:
        r.release_all()
        r.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))