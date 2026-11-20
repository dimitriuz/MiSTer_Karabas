"""MiSTer Companion Remote client and the two ways to see the board.

Standard library only (the hand-rolled WebSocket below), because the board
host has no `websocket` module and `tools/` does not take dependencies.

The daemon on the board (already running after boot) owns one persistent
`uinput` device, so input through it does not wedge the MiSTer input thread
the way ad-hoc `uinput` scripts do (see AGENTS.md).

    from mister import Remote
    r = Remote()                       # 192.168.1.13:9191
    r.key("KEY_A")                     # tap, 45 ms - prefer press()
    r.press("KEY_ENTER")               # down, hold, up
    r.pad("down")                      # gamepad dpad / button
    r.system("release_all")            # drop every held key

Screens, two independent views:

- `Remote.screen(path)` - the MiSTer's own screenshot API. The ZX picture
  only (no OSD, no border), and the only view that proves what the machine's
  video generator is doing.
- `Capture.frame(path)` - the HDMI capture card, the only view with the
  **OSD** in it: one ffmpeg grab of a single frame from /dev/video4.
"""
import base64
import json
import os
import socket
import struct
import subprocess
import time
import urllib.request

import os
HOST = os.environ.get("MISTER_HOST", "192.168.1.15")
PORT = 9191


class Remote:
    def __init__(self, host=HOST, port=PORT, path="/remote/v1", timeout=10):
        self.sock = socket.create_connection((host, port), timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("handshake closed")
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError(head.decode(errors="replace"))
        self.buf = rest
        self.host = host

    # --- frames -------------------------------------------------------
    def send(self, obj):
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        n = len(data)
        hdr = b"\x81"
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(hdr + mask + masked)

    # --- input --------------------------------------------------------
    def key(self, name, action="tap"):
        self.send({"type": "keyboard", "key": name, "action": action})

    def press(self, name, hold=0.30):
        """A key held long enough for the 50 Hz ZX scan; taps are marginal."""
        self.key(name, "down")
        time.sleep(hold)
        self.key(name, "up")

    def pad(self, name, hold=0.30):
        self.send({"type": "controller", "control": "dpad" if name in
                   ("up", "down", "left", "right") else "button",
                   "name": name, "action": "down"})
        time.sleep(hold)
        self.send({"type": "controller", "control": "dpad" if name in
                   ("up", "down", "left", "right") else "button",
                   "name": name, "action": "up"})

    def system(self, command):
        self.send({"type": "system", "command": command})

    def release_all(self):
        self.system("release_all")
        time.sleep(0.3)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    # --- screens ------------------------------------------------------
    def screen(self, path):
        """The MiSTer screenshot API: the ZX picture, no OSD."""
        url = f"http://{self.host}:{PORT}/api/screenshot?fresh=1"
        urllib.request.urlretrieve(url, path)
        return path

    def wait_menu(self, seconds=120.0, path="/tmp/board-menu.png"):
        """Wait for the Karabas GO main menu, not just for any picture.

        With a disk image mounted the GO loader first tries `karabas_boot.$c`
        on the CF drive and sits on a light-green `Loading hobeta` box for
        up to a minute before it falls back to the menu (board, 2026-11-11).
        Pressing arrows at that box is lost, so wait for the menu's blue box.
        """
        from PIL import Image
        t0 = time.time()
        while time.time() - t0 < seconds:
            try:
                self.screen(path)
                im = Image.open(path).convert("RGB")
            except Exception:
                time.sleep(1.0)
                continue
            if menu_visible(im):
                return True
            time.sleep(2.0)
        return False

    def wait_loader(self, seconds=30.0, path="/tmp/board-loader.png"):
        """Wait for the 128 ROM's `Tape Loader` screen."""
        from PIL import Image
        t0 = time.time()
        while time.time() - t0 < seconds:
            try:
                self.screen(path)
                im = Image.open(path).convert("RGB")
            except Exception:
                time.sleep(0.5)
                continue
            if loader_visible(im):
                return True
            time.sleep(0.5)
        return False

    def wait_rom_menu(self, seconds=30.0, path="/tmp/board-rom.png"):
        """Wait for the 128 ROM's menu after `Run Sinclair 128K`."""
        from PIL import Image
        t0 = time.time()
        while time.time() - t0 < seconds:
            try:
                self.screen(path)
                im = Image.open(path).convert("RGB")
            except Exception:
                time.sleep(0.5)
                continue
            if rom_menu_visible(im):
                return True
            time.sleep(0.5)
        return False

    def wait_picture(self, seconds=25.0, path="/tmp/board-wait.png"):
        """Poll until the ZX picture is not all black (a core load blanks it)."""
        from PIL import Image
        t0 = time.time()
        while time.time() - t0 < seconds:
            try:
                self.screen(path)
                extrema = Image.open(path).convert("RGB").getextrema()
            except Exception:            # the API answers 500 mid reload
                time.sleep(1.0)
                continue
            if extrema != ((0, 0), (0, 0), (0, 0)):
                return True
            time.sleep(1.0)
        return False


class Capture:
    """The HDMI card view: the only one with the OSD in it.

    One `ffmpeg` grab of a frame straight off /dev/video4 (~1.5 s, in the
    `video` group, no sudo). The v4l2loopback chain with a long-lived writer
    and a reader that falls back to a frozen `/tmp/live.jpg` was the source of
    more wrong conclusions than any other part of a board run, so there is no
    long-lived writer here: every frame is fresh by construction.
    """

    # The card needs ~2 s to start delivering picture: `-frames:v 1` (and
    # even 3) with `-update 1` returns an all-black frame, and so does a 1.2 s
    # window, while 2 s or more keeps the picture. Measured 2026-11-11 on the
    # board's 1080p output: mean luminance 7.0 at 1.2 s, 96.6 at 2.0 s, 96.0
    # at 3.0 s, and the raw path (no `-input_format`) behaves the same.
    GRAB = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "v4l2",
            "-input_format", "mjpeg", "-video_size", "1920x1080",
            "-i", "/dev/video4", "-t", "2.2", "-update", "1", "-y"]

    def __init__(self, device="/dev/video4", settle=1.8):
        self.device = device
        self.settle = settle

    def frame(self, path, settle=None):
        """Wait out the card's ~1 s latency, then grab one frame into `path`.

        A fully black grab means the card is re-syncing (the core just
        reloaded, or the OSD opened), so grab again rather than believe it.
        A uniform (7,7,7) frame is not proof of "no signal": it is what this
        card returns when asked for a fixed number of frames.
        """
        from PIL import Image
        cmd = [c if c != "/dev/video4" else self.device for c in self.GRAB]
        cmd.append(path)
        time.sleep(self.settle if settle is None else settle)
        for _ in range(8):
            subprocess.run(cmd, check=True, timeout=20)
            if Image.open(path).convert("RGB").getextrema() != (
                    (0, 0), (0, 0), (0, 0)):
                return path
            time.sleep(1.5)
        return path


def loader_visible(im):
    """The 128 ROM's `Tape Loader` screen.

    Both it and `128 BASIC` draw a black bar with the ROM's stripe block near
    the bottom, so a bar alone is not enough (it made `128 BASIC` read as the
    loader, and a script then fired a tape that had nowhere to go). The loader
    has a *second* text line under the bar (`To cancel - press BREAK twice`);
    `128 BASIC` has paper there.
    """
    w, h = im.size
    px = im.load()
    top = bot = None
    for y in range(int(h * 0.6), int(h * 0.85)):
        dark = sum(1 for x in range(0, w, 4) if max(px[x, y]) < 40)
        if dark * 4 > w * 0.55:
            top = y if top is None else top
            bot = y
    if top is None:
        return False
    under = 0
    for y in range(min(h, bot + 10), min(h, bot + 70)):
        for x in range(int(w * 0.17), int(w * 0.75), 4):
            if max(px[x, y]) < 100:
                under += 1
    return under > 60


def screen_clean(im):
    """The ZX screen is drawn in at most the 16 ZX colours, on one paper.

    A crashed machine shows uninitialised RAM: hundreds of colours in squares.
    `rom_menu_visible` is true there too, so this is the check that tells a
    real menu from a hung machine (board, 2026-11-11: a remembered GO menu
    cursor sent 6 x Down to `Test&Tools Menu` and the machine ran into RAM).
    """
    from collections import Counter
    w, h = im.size
    px = im.load()
    seen = Counter()
    for y in range(int(h * 0.25), int(h * 0.75), 3):
        for x in range(int(w * 0.2), int(w * 0.8), 3):
            seen[px[x, y][:3]] += 1
    total = sum(seen.values())
    if not total:
        return False
    return seen.most_common(1)[0][1] / total >= 0.40


def rom_menu_visible(im):
    """The 128 ROM's own menu: its list fills the middle of the screen.

    The ROM's copyright screen (`(c) 1982 Sinclair Research Ltd`) has one line
    at the bottom and nothing else, and 128 BASIC has the editor's `K` at the
    bottom left, so "dark pixels in the middle band" is the menu and nothing
    else that comes before it.
    """
    w, h = im.size
    px = im.load()
    dark = 0
    for y in range(int(h * 0.35), int(h * 0.75), 2):
        for x in range(int(w * 0.15), int(w * 0.85), 2):
            if max(px[x, y]) < 100:
                dark += 1
    return dark > 1500


def menu_visible(im):
    """The GO main menu's blue list box, as opposed to the loader's pale box."""
    im = im.resize((im.width // 4, im.height // 4))
    px = im.load()
    blue = 0
    for y in range(im.height):
        for x in range(im.width):
            r, g, b = px[x, y][:3]
            if r < 40 and 90 <= g <= 130 and 120 <= b <= 170:
                blue += 1          # the list box is (0,111,144) teal
    return blue > 1200        # > ~19200 px at full size


# --- OSD geometry (from the 2026-11-10 runs, see AGENTS.md) -----------


#: rows of the Karabas_Profi page by number of `Down` presses from the first
#: item (`IDE 0`; the cursor starts there on a fresh core load). Build 77
#: regrouped the page: the images first (IDE 0/1, SD Card, the floppies and
#: their FDI entries and layout, the tape and its three controls), then the
#: settings by type (machine, input, sound, `Video`, serial), then the
#: buttons. The `-` separators are not rows. Earlier builds counted from
#: `Video` with `Tape play/pause` on 10 (54-72), 15 (73-76). Re-read from a
#: capture on every new CONF_STR before trusting any count.
ROWS = {
    0: "IDE 0", 1: "IDE 1", 2: "SD Card",
    3: "Floppy A (TRD)", 4: "Floppy B (TRD)", 5: "Floppy A (raw)", 6: "Floppy B (raw)",
    7: "Disk layout",
    8: "Tape", 9: "Tape play/pause", 10: "Tape previous block",
    11: "Tape next block",
    12: "ROM Bank", 13: "Mode", 14: "Turbo", 15: "DivMMC", 16: "Pause",
    17: "Joystick L", 18: "Joystick R", 19: "Keyboard",
    20: "PSG Mix", 21: "Covox", 22: "MT32-pi", 23: "Video",
    24: "Serial channel",
    25: "FDC trace to UART",
    26: "GS Reset", 27: "NMI", 28: "Reset",
}

BAR_X = 330      # a column inside the bar's left padding, 960 px wide
BAR_TOP = 174    # the `Video` bar's top, on the 960 px capture
ROW_H = 16


def bar_row(column, scale=1.0):
    """Row index from a bottom-to-top list of (y, bright) samples.

    `column` is the pixel column of the highlight bar (sampled left of every
    glyph): the bar is a solid ~15 px run of (255,240,243) on the 960x540
    capture. `scale` is `image height / 540` for a larger grab. Returns the
    row on the 16 px grid, or None when no bar is visible.
    """
    run = [y for y, bright in column if bright]
    if len(run) < 8 * scale:
        return None
    top = (run[0] / scale) if run[0] > 0 else run[0]
    return round((top - BAR_TOP) / ROW_H)


def read_bar(img_path, width=960):
    """`bar_row` on a capture: which OSD row the highlight is on."""
    from PIL import Image
    im = Image.open(img_path).convert("RGB")
    h = im.height
    x = round(BAR_X * im.width / width)
    px = im.load()
    col = [(y, px[x, y][0] > 245 and px[x, y][1] > 235 and px[x, y][2] > 238)
           for y in range(h)]
    return bar_row(col, scale=h / 540.0)


def text_cells(img_path, band=(0.185, 0.245)):
    """Width in ZX character cells of the text on the editor's first line.

    The MiSTer API screenshot is 1440x1080 for this core's 352x288 frame and
    the 256-px ZX screen inside it. The band is the *first line of the 128
    editor* only: a wider band picks up the ROM's status bar (the widest dark
    run on the screen) or any other text, and then a keystroke cannot be told
    from the background (board, 2026-11-11).
    """
    from PIL import Image
    im = Image.open(img_path).convert("RGB")
    w, h = im.size
    px = im.load()
    xs = [x for y in range(int(h * band[0]), int(h * band[1]))
          for x in range(int(w * 0.15), int(w * 0.9)) if max(px[x, y]) < 100]
    if not xs:
        return 0.0
    return float(len(xs)) / 100.0        # hundreds of dark pixels

