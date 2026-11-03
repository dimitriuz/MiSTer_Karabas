#!/usr/bin/env python3
"""Generate rtl/host/ps2_hid_table.svh from the extracted source tables.

Joins tools/data/hid_keyboard.txt (HID usage -> Linux keycode, Linux v6.6
drivers/hid/hid-input.c) on tools/data/ev2ps2.txt (Linux keycode -> PS/2
set-2 scancode + flag bits, Main_MiSTer input.cpp @
afb917fce1f3089e3d242331ddae6456ac0da8e4) to a (ext, code) -> HID usage map
for rtl/host/ps2_hid.sv.

Rules (Stage 1 task 4 ruling): for every HID usage 0x04-0xE7 take
k = hid_keyboard[u]; skip k == 0 and k beyond the ev2ps2 table; v = ev2ps2[k];
skip NONE (low byte 0xFF), strip the MODMASK, CAPS_TOGGLE and UPSTROKE bits
(the MODMASK bits are Main's key-repeat hints, not part of the code), skip
entries flagged OSD or OSD_OPEN, skip EMU_SWITCH_1/2 entries except the two
real keys NumLock (k = 69) and ScrollLock (k = 70) whose codes the core does
receive (F17-F20 carry the fake codes 1-4 which collide with F9/F7/F5/F3),
and skip entries whose low byte is 0. ext = (v & EXT), code = v & 0xFF. On a
collision the lowest usage wins; the dropped usages are listed in the .svh
header comment.

Run: python3 tools/gen_ps2_hid.py [-o OUT]
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EV2PS2 = ROOT / "tools" / "data" / "ev2ps2.txt"
HID_KEYBOARD = ROOT / "tools" / "data" / "hid_keyboard.txt"
OUT_DEFAULT = ROOT / "rtl" / "host" / "ps2_hid_table.svh"

FLAG_NAMES = ("NONE", "LCTRL", "LSHIFT", "LALT", "LGUI", "RCTRL", "RSHIFT",
              "RALT", "RGUI", "MODMASK", "OSD", "OSD_OPEN", "CAPS_TOGGLE",
              "EXT", "EMU_SWITCH_1", "EMU_SWITCH_2", "UPSTROKE")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")

# Real keys despite the EMU_SWITCH flags (Linux keycodes).
EMU_SWITCH_KEEP = (69, 70)

# Flag bits used by the join. Fixed by the task ruling; parse_ev2ps2 checks
# them against the defines in the data file so a changed pin trips a failure.
NONE = 0xFF
MODMASK = 0x00FF00
OSD = 0x010000
OSD_OPEN = 0x020000
CAPS_TOGGLE = 0x040000
EXT = 0x080000
EMU_SWITCH_1 = 0x100000
EMU_SWITCH_2 = 0x200000
UPSTROKE = 0x400000


def parse_ev2ps2(text):
    """Return the ev2ps2[] values, indexed by Linux keycode."""
    defines = {}
    for line in text.splitlines():
        m = re.match(r"#define\s+(\w+)\s+(0[xX][0-9a-fA-F]+|\d+)", line)
        if m:
            defines[m.group(1)] = int(m.group(2), 0)
    want = {"NONE": NONE, "MODMASK": MODMASK, "OSD": OSD, "OSD_OPEN": OSD_OPEN,
            "CAPS_TOGGLE": CAPS_TOGGLE, "EXT": EXT, "EMU_SWITCH_1": EMU_SWITCH_1,
            "EMU_SWITCH_2": EMU_SWITCH_2, "UPSTROKE": UPSTROKE}
    for name in FLAG_NAMES:
        if name not in defines:
            raise ValueError("ev2ps2.txt: missing define %s" % name)
        if name in want and defines[name] != want[name]:
            raise ValueError("ev2ps2.txt: define %s = 0x%X, expected 0x%X"
                             % (name, defines[name], want[name]))

    lines = text.splitlines()
    try:
        i = next(n for n, l in enumerate(lines)
                 if l.strip().startswith("static const int ev2ps2[]")) + 2
    except StopIteration:
        raise ValueError("ev2ps2.txt: no `static const int ev2ps2[]`")
    vals = []
    while True:
        line = lines[i].strip()
        i += 1
        if line.startswith("};"):
            break
        if "//" not in line:
            raise ValueError("ev2ps2.txt: entry without comment: %r" % line)
        index = re.search(r"//\s*(\d+)", line)
        if not index or int(index.group(1)) != len(vals):
            raise ValueError("ev2ps2.txt: index out of sequence: %r" % line)
        body = line.split("//")[0].strip().rstrip(",").strip()
        v = 0
        for part in body.split("|"):
            part = part.strip()
            if IDENT.match(part):
                v |= defines[part]
            else:
                v |= int(part, 0)
        vals.append(v)
    return vals


def parse_hid_keyboard(text):
    """Return the hid_keyboard[] values, indexed by HID usage."""
    lines = text.splitlines()
    try:
        i = next(n for n, l in enumerate(lines)
                 if l.strip().startswith("static const unsigned char hid_keyboard[256]")) + 1
    except StopIteration:
        raise ValueError("hid_keyboard.txt: no `hid_keyboard[256]` table")
    vals = []
    while True:
        line = lines[i].strip()
        i += 1
        if line.startswith("};"):
            break
        for field in line.strip("{}").rstrip(";").split(","):
            field = field.strip()
            if not field:
                continue
            # `unk` is the kernel's abbreviation of KEY_UNKNOWN (= 0).
            vals.append(0 if field == "unk" else int(field, 0))
    return vals


def build_map(ev2ps2, hid_keyboard):
    """Return (usage_of, claims).

    usage_of: {(ext, code): usage} - the generated map.
    claims:   {(ext, code): [(usage, linux_key), ...]} for every (ext, code)
              claimed by more than one usage, sorted, lowest usage first.
    """
    takers = {}
    for usage in range(0x04, 0xE8):
        key = hid_keyboard[usage]
        if key == 0 or key >= len(ev2ps2):
            continue
        v = ev2ps2[key]
        if v & 0xFF == 0xFF:  # NONE
            continue
        v &= ~(MODMASK | CAPS_TOGGLE | UPSTROKE)
        if v & (OSD | OSD_OPEN):
            continue
        if v & (EMU_SWITCH_1 | EMU_SWITCH_2) and key not in EMU_SWITCH_KEEP:
            continue
        if v & 0xFF == 0:
            continue
        claim = (1 if v & EXT else 0, v & 0xFF)
        takers.setdefault(claim, []).append((usage, key))
    # Usages ascend, so the first taker of each (ext, code) is the lowest.
    usage_of = {claim: t[0][0] for claim, t in takers.items()}
    claims = {claim: t for claim, t in takers.items() if len(t) > 1}
    return usage_of, claims


def render(ev2ps2, hid_keyboard):
    usage_of, claims = build_map(ev2ps2, hid_keyboard)
    out = ["// generated by tools/gen_ps2_hid.py \u2014 do not edit",
           "//",
           "// PS/2 set-2 scancode -> USB HID boot usage, for "
           "rtl/host/ps2_hid.sv.",
           "// Join of tools/data/hid_keyboard.txt (Linux v6.6 hid-input.c) and",
           "// tools/data/ev2ps2.txt (Main_MiSTer input.cpp "
           "afb917fce1f3089e3d242331ddae6456ac0da8e4)",
           "// on the Linux keycode; ext = the E0 prefix, 0x00 = unknown usage.",
           "// Include inside a module: provides ps2_to_hid(ext, code)."]
    if claims:
        out.append("//")
        out.append("// (ext, code) claimed by several usages; the lowest "
                   "usage is kept, and")
        out.append("// the dropped usages are listed here:")
        for (ext, code), takers in sorted(claims.items()):
            out.append("//   (ext=%d,0x%02x): kept 0x%02x, dropped %s"
                       % (ext, code, takers[0][0],
                          " ".join("0x%02x" % u for u, _ in takers[1:])))
    out.append("")
    out.append("function automatic [7:0] ps2_to_hid(input ext, "
               "input [7:0] code);")
    out.append("    case ({ext, code})")
    for (ext, code), usage in sorted(usage_of.items()):
        out.append("        9'h%03X: ps2_to_hid = 8'h%02X;"
                   % ((0x100 if ext else 0) | code, usage))
    out.append("        default: ps2_to_hid = 8'h00;")
    out.append("    endcase")
    out.append("endfunction")
    return "\n".join(out) + "\n"


def load_tables():
    return (parse_ev2ps2(EV2PS2.read_text()),
            parse_hid_keyboard(HID_KEYBOARD.read_text()))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-o", "--output", type=Path, default=OUT_DEFAULT)
    args = ap.parse_args(argv)
    ev2ps2, hid_keyboard = load_tables()
    text = render(ev2ps2, hid_keyboard)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text)
    print("wrote %s (%d entries)"
          % (args.output, len(build_map(ev2ps2, hid_keyboard)[0])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
