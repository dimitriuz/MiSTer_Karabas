#!/usr/bin/env python3
"""prepare_upstream.py — make the Karabas Go upstream compile with Quartus 17.

Reads the read-only submodule `upstream/karabas-go-core-profi` (+ its `modules/`
submodule) and writes a generated tree (default `build/upstream/`):

  * a directory-preserving mirror: upstream `src/rtl/**` -> `<out>/src/rtl/**`,
    `modules/rtl/**` -> `<out>/modules/rtl/**` (nothing under upstream/ is edited);
  * the compize_proto rewrite: Quartus 17 cannot analyse a VHDL instantiation of
    `entity work.<verilog module>` across the VHDL/Verilog boundary the Vivado flow
    tolerates, so every such instantiation of a Verilog module becomes a component
    instantiation, with a generated `component` declaration (scalar Verilog
    parameters become generics with literals as defaults, vector parameters are
    omitted; every `in` port gets a VHDL default). Files that already declare the
    component (e.g. `opl2_top` in `profi.vhd`) keep theirs;
  * the three init-file rewrites (icons.bit, the VG93 microcode hex, the SAA1099
    compressor LUT) so the paths resolve from the profile's Quartus project dir;
  * the profi.vhd wait rewrites (core profile only, PROFI_REWRITES): the SDRAM
    wait of the replaced memory.vhd (`MEM_WAIT`) is declared, mapped and, while
    turbo is on, fed to the clock's WAIT_CPU and to the `cpu_wait_n` term of the
    T80 WAIT_n pin (at turbo "11" one T-state is one clk_bus, and only WAIT_n
    stops the clock that samples DI);
  * `upstream.qip`: the file list of `src/karabas_go.prj` in prj order, as
    `set_global_assignment` lines whose paths are relative to the profile's Quartus
    project dir; `uart.v` goes to library `zxuno` (its Verilog `uart_tx`/`uart_rx`
    clash with the VHDL units of the same name in `work`), everything else to `work`;
  * `STAMP`: the two upstream commit hashes.

Profiles:
  core (default) — for the Karabas_Profi project at the repo root; the MiSTer top
      replaces the upstream clock, memory and sdram units (excluded here), and the
      HDMI/PCM5102/karabas_go_top units. Prefix: `build/upstream`.
  elab — for the `tools/elab_upstream.sh` gate in `build/elab/`: only the upstream
      clock and the top-level/HDMI units are replaced (by the gate's clock stub);
      memory/sdram stay. Prefix: `upstream`.

Rules are those of docs/superpowers/plans/stage1-assets/compize_proto.py, the
spike that made `quartus_map --analysis_and_elaboration` of `profi` pass in
raetro/quartus:17.0. A Verilog port the parser cannot read is an error naming the
module and the port text — never a silent skip.
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / "upstream" / "karabas-go-core-profi"
PRJ = "src/karabas_go.prj"

PROFILES = {
    # canonical out (relative to repo root) and the path prefix of the generated
    # qip/init strings, relative to that profile's Quartus project directory.
    "core": {"out": "build/upstream", "prefix": "build/upstream"},
    "elab": {"out": "build/elab/upstream", "prefix": "upstream"},
}

# Excluded from every profile (MiSTer/the gate replaces these units):
EXCLUDED = {
    "src/rtl/clock/clock.vhd",
    "modules/rtl/clk/kg_pll.v",
    "src/rtl/karabas_go_top.vhd",
    "src/rtl/hdmi/hdmi_frame.v",
    "modules/rtl/audio/kg_pcm5102.v",
}
# Excluded only by the core profile (rtl/replaced/ provides them):
CORE_EXTRA = {"src/rtl/memory/memory.vhd", "src/rtl/memory/sdram.vhd"}

# uart.v's Verilog uart_tx/uart_rx clash with the VHDL units in work: library zxuno.
ZXUNO_FILES = {"src/rtl/uart/uart.v"}

INIT_REWRITES = [  # (out-relative file, exact old string, new init path suffix)
    ("src/rtl/osd/icons.vhd", '"rtl/osd/icons.bit"', "src/rtl/osd/icons.bit"),
    ("src/rtl/vg93/vg93_urom.v", '`define VG93_ROM_FILE "vg93-microcode-rom.hex"',
     "src/rtl/vg93/vg93-microcode-rom.hex"),
    ("src/rtl/sound/saa1099.v", '"saa1099_compressor_lut.hex"',
     "src/rtl/sound/saa1099_compressor_lut.hex"),
]

# profi.vhd rewrites (core profile only): the SDRAM wait of
# rtl/mem/sram_bridge.vhd reaches the CPU through the replaced memory.vhd
# (MEM_WAIT), clock.vhd's WAIT_CPU and the T80 WAIT_n pin (the cpu_wait_n
# condition). The elab profile keeps upstream's memory.vhd, which has no
# MEM_WAIT port, so its profi.vhd stays untouched.
PROFI_REWRITES = [  # (out-relative file, exact old string, exact new string)
    ("src/rtl/profi.vhd",
     "signal cpu_wait \t\t\t: std_logic;",
     "signal cpu_wait \t\t\t: std_logic;\nsignal mem_wait \t\t\t: std_logic;"),
    ("src/rtl/profi.vhd",
     "\tGS_WAIT_N \t\t=> gs_wait_n,",
     "\tGS_WAIT_N \t\t=> gs_wait_n,\n\tMEM_WAIT \t\t=> mem_wait,"),
    ("src/rtl/profi.vhd",
     "cpu_wait <= '0';",
     "cpu_wait <= mem_wait when turbo_mode /= \"00\" else '0';"
     " -- MiSTer: SDRAM wait in turbo"),
    ("src/rtl/profi.vhd",
     "cpu_wait_n <= '0' when zc_busy = '1' or ",
     "cpu_wait_n <= '0' when (mem_wait = '1' and turbo_mode /= \"00\") "
     "or zc_busy = '1' or "),
]


def apply_profi_rewrites(text):
    """PROFI_REWRITES over the text of src/rtl/profi.vhd. Every old string must
    occur exactly once; anything else is an error naming the file and the
    string."""
    for rel, old, new in PROFI_REWRITES:
        n = text.count(old)
        if n != 1:
            raise SystemExit(f"{rel}: expected exactly one {old!r}, found {n}")
        text = text.replace(old, new)
    return text



class PortParseError(ValueError):
    """A module-header fragment (port or parameter) the parser cannot read."""


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def default_clause(value, is_vector):
    """VHDL default for a Verilog input default literal (compize_proto rules)."""
    value = value.strip()
    mm = re.fullmatch(r"(\d*)'([bdh])([0-9a-fA-F_]+)", value)
    num = None
    if mm:
        num = int(mm.group(3).replace("_", ""), {"b": 2, "d": 10, "h": 16}[mm.group(2)])
    zero = value == "0" or num == 0 or re.fullmatch(r"\{\w+\{1'b0\}\}", value)
    ones = bool(mm and ((mm.group(2) == "b" and set(mm.group(3)) == {"1"})
                        or (mm.group(2) == "h" and set(mm.group(3).lower()) == {"f"}))) \
        or re.fullmatch(r"\{\w+\{1'b1\}\}", value)
    if zero:
        return " := (others => '0')" if is_vector else " := '0'"
    if ones:
        return " := (others => '1')" if is_vector else " := '1'"
    raise ValueError(f"cannot map default {value!r}")


PORT_RE = re.compile(
    r"\s*(input|output|inout)\s+(wire|reg)?\s*(signed)?\s*(\[[^\]]*\])?\s*(\w+)\s*(=\s*(.*))?$",
    re.S)
PARAM_RE = re.compile(r"\s*parameter\s+(\[[^\]]*\]\s*)?(\w+)\s*=\s*(.*)", re.S)


def split_args(text):
    """Split on top-level commas; skip over (), [], {} and "..." runs.

    A Verilog sized-literal apostrophe (5'd16) is NOT a string delimiter; only
    double quotes are, exactly as in the compize_proto spike's comma split.
    """
    out, depth, cur, q = [], 0, "", None
    for ch in text:
        if q:
            cur += ch
            if ch == '"':
                q = None
        elif ch == '"':
            q = ch
            cur += ch
        elif ch in "([{":
            depth += 1
            cur += ch
        elif ch in ")]}":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def parse_ports(ports_text, module_name):
    """[(vhdl_dir, range|None, name, default_literal|None)]; PortParseError else."""
    ports = []
    for p in split_args(ports_text):
        m = PORT_RE.match(p.strip())
        if not m:
            raise PortParseError(
                f"cannot parse port {p.strip()!r} of module {module_name}")
        dr = {"input": "in", "output": "out", "inout": "inout"}[m.group(1)]
        rng = None
        if m.group(4):
            a, b = m.group(4).strip()[1:-1].split(":")
            rng = f"({a.strip()} downto {b.strip()})"
        ports.append((dr, rng, m.group(5), m.group(7)))
    return ports


def generic_clauses(params_text, module_name):
    """Generics from Verilog parameter declarations: integer/string, vectors skipped.

    A parameter-list fragment that is not a `parameter` declaration raises
    naming the module and the fragment, so `#(parameter A=1, B=2)` fails loudly
    instead of silently dropping the generic B.
    """
    gens = []
    for p in split_args(params_text or ""):
        frag = p.strip()
        m = PARAM_RE.match(frag)
        if not m:
            raise PortParseError(
                f"cannot parse parameter fragment {frag!r} of module {module_name}")
        if m.group(1):  # vector-typed parameter: no VHDL generic
            continue
        v = m.group(3).strip()
        name = m.group(2)
        if v.startswith('"'):
            gens.append(f"{name} : string := {v}")
        elif re.fullmatch(r"-?\d+", v):
            gens.append(f"{name} : integer := {v}")
        elif re.fullmatch(r"\d*'[bdh][0-9a-fA-F_]+", v):
            b, x = v.split("'")[1][0], v.split("'")[1][1:].replace("_", "")
            gens.append(f"{name} : integer := {int(x, {'b': 2, 'd': 10, 'h': 16}[b])}")
        else:
            gens.append(f"{name} : integer")
    return gens


def component_declaration(name, params_text, ports_text):
    """The VHDL component block for a Verilog module."""
    ports = parse_ports(ports_text, name)
    pl = []
    for dr, rng, pname, dv in ports:
        clause = (f"{pname} : {dr} std_logic_vector{rng}" if rng
                  else f"{pname} : {dr} std_logic")
        if dr == "in":
            clause += default_clause(dv, bool(rng)) if dv is not None \
                else (" := (others => '0')" if rng else " := '0'")
        pl.append(clause)
    gens = generic_clauses(params_text, name)
    g = ("  generic (\n    " + ";\n    ".join(gens) + "\n  );\n") if gens else ""
    return f"component {name}\n{g}  port (\n    " + ";\n    ".join(pl) + "\n  );\nend component;\n"


def scan_prj():
    """[('vhdl'|'verilog', out_rel)] in prj order."""
    entries = []
    for line in (UPSTREAM / PRJ).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r'^(vhdl|verilog) work "?([^"]+)"?$', line)
        if not m:
            raise SystemExit(f"{PRJ}: unparsable line {line!r}")
        kind, p = m.group(1), m.group(2)
        if p.startswith("../modules/"):
            rel = "modules/" + p[len("../modules/"):]
        else:
            rel = "src/" + p.lstrip("./")
        entries.append((kind, rel))
    return entries


def git_head(path):
    return subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"],
                          capture_output=True, text=True,
                          check=True).stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--profile", choices=sorted(PROFILES), default="core")
    ap.add_argument("--out", default=None,
                    help="output dir (default: the profile's canonical location)")
    args = ap.parse_args()
    prof = PROFILES[args.profile]
    prefix = prof["prefix"]
    out = Path(args.out) if args.out else (ROOT / prof["out"])

    excluded = set(EXCLUDED) | (set(CORE_EXTRA) if args.profile == "core" else set())
    entries = scan_prj()
    kept = [(k, rel) for k, rel in entries if rel not in excluded]

    # ---- mirror copy ----------------------------------------------------------
    # Never overwrite a directory that is not ours: absent, empty, or a previous
    # run's output (a STAMP file is present) are the only accepted states.
    if out.exists() and any(out.iterdir()) and not (out / "STAMP").is_file():
        raise SystemExit(
            f"{out}: refusing to replace a non-empty directory that has no STAMP "
            "file (not a prepare_upstream output); pass a fresh --out")
    if out.exists():
        shutil.rmtree(out)
    for src_rel in ("src/rtl", "modules/rtl"):
        shutil.copytree(UPSTREAM / src_rel, out / src_rel)

    # ---- init-file path rewrites (relative to the profile's project dir) ------
    for rel, old, suffix in INIT_REWRITES:
        p = out / rel
        s = p.read_text(errors="replace")
        path = f'"{prefix}/{suffix}"'
        new = f'`define VG93_ROM_FILE {path}' if old.startswith("`define") else path
        if s.count(old) != 1:
            raise SystemExit(f"{rel}: expected exactly one {old!r}, found {s.count(old)}")
        p.write_text(s.replace(old, new))

    # ---- the profi.vhd wait rewrites (core profile only) -----------------------
    if args.profile == "core":
        p = out / "src/rtl/profi.vhd"
        p.write_text(apply_profi_rewrites(p.read_text(errors="replace")))

    # ---- the compize_proto rewrite over the compiled (qip-kept) VHDL ----------
    vmods, vhd_ents = {}, set()
    for kind, rel in kept:
        s = strip_comments((out / rel).read_text(errors="replace"))
        if rel.endswith(".v"):
            for m in re.finditer(r'\bmodule\s+(\w+)\s*(#\s*\((.*?)\)\s*)?\((.*?)\)\s*;',
                                 s, re.S):
                vmods[m.group(1).lower()] = (m.group(1), m.group(3) or "", m.group(4))
        elif rel.endswith(".vhd"):
            for m in re.finditer(r'^\s*entity\s+(\w+)\s+is', s, re.I | re.M):
                vhd_ents.add(m.group(1).lower())
    rewritten = 0
    for kind, rel in kept:
        if not rel.endswith(".vhd"):
            continue
        p = out / rel
        s = p.read_text(errors="replace")
        used = [m.group(1) for m in re.finditer(r'entity\s+work\.(\w+)', s, re.I)
                if m.group(1).lower() in vmods and m.group(1).lower() not in vhd_ents]
        if not used:
            continue
        names = sorted(set(u.lower() for u in used))
        declared = {m.group(1).lower()
                    for m in re.finditer(r'^\s*component\s+(\w+)', s, re.I | re.M)}
        for u in names:
            s = re.sub(r'entity\s+work\.' + u + r'\b', vmods[u][0], s, flags=re.I)
        try:
            decl = "".join(component_declaration(vmods[u][0], vmods[u][1], vmods[u][2])
                           for u in names if u not in declared)
        except ValueError as e:
            raise SystemExit(f"{rel}: {e}")
        s, c = re.subn(r'(architecture\s+\w+\s+of\s+\w+\s+is\s*\n)',
                       lambda m: m.group(1) + decl, s, count=1, flags=re.I)
        assert c == 1, f"{rel}: no single 'architecture X of Y is' line"
        p.write_text(s)
        rewritten += 1

    # ---- upstream.qip ---------------------------------------------------------
    lines = ["# generated by tools/prepare_upstream.py — do not edit; the file "
             "order is src/karabas_go.prj"]
    for kind, rel in kept:
        lib = "zxuno" if rel in ZXUNO_FILES else "work"
        vkind = "VHDL_FILE" if kind == "vhdl" else "VERILOG_FILE"
        lines.append(f'set_global_assignment -library "{lib}" -name {vkind} '
                     f'{prefix}/{rel}')
    (out / "upstream.qip").write_text("\n".join(lines) + "\n")

    # ---- STAMP ------------------------------------------------------------------
    (out / "STAMP").write_text(
        f"karabas-go-core-profi {git_head(UPSTREAM)}\n"
        f"modules {git_head(UPSTREAM / 'modules')}\n")

    print(f"prepare_upstream: profile {args.profile}, out {out}, "
          f"{len(kept)} files in qip, {rewritten} VHDL files rewritten")
    return 0


if __name__ == "__main__":
    sys.exit(main())
