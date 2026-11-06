"""Tests for tools/prepare_upstream.py.

Run: python3 -m unittest discover -s tools/tests -v
They run the tool into temporary directories and assert on the generated tree.
The upstream submodule must be checked out (recursive) at its pinned commits.
"""
import atexit
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "prepare_upstream.py"
UPSTREAM = ROOT / "upstream" / "karabas-go-core-profi"

# The 17 Verilog modules that VHDL instantiates directly at the pinned upstream.
NAMES = sorted("""
audio_mixer dot_matrix gs_top hdf_ata hrdy_fdc img_sdc kg_cursor kg_fifo kg_mcu
kg_pix_doubler kg_sdpram kg_soft_switches kg_sprom opl2_top saa1099 turbosound
zc_spi
""".split())

# Excluded from every profile (brief Step 5 list, in output-relative form).
EXCLUDED_ALL = {
    "src/rtl/clock/clock.vhd",
    "src/rtl/memory/memory.vhd",
    "src/rtl/memory/sdram.vhd",
    "modules/rtl/clk/kg_pll.v",
    "src/rtl/karabas_go_top.vhd",
    "src/rtl/hdmi/hdmi_frame.v",
    "modules/rtl/audio/kg_pcm5102.v",
}
KEPT_BY_ELAB_ONLY = {"src/rtl/memory/memory.vhd", "src/rtl/memory/sdram.vhd"}

# Init-path / qip path prefix per profile: relative to the profile's Quartus
# project dir (core: repo root with the tree in build/upstream; elab:
# build/elab with the tree in upstream).
PREFIX = {"core": "build/upstream", "elab": "upstream"}

QIP_LINE = re.compile(r'^set_global_assignment -library "(\w+)" -name (VHDL_FILE|VERILOG_FILE) (\S+)$')

_OUTS = {}
_TMP = tempfile.mkdtemp(prefix="karabas-prepare-tests-")


def _cleanup():
    shutil.rmtree(_TMP, ignore_errors=True)


atexit.register(_cleanup)


def prepared(profile):
    """Run the tool once per profile into a temp dir; return the out path."""
    if profile not in _OUTS:
        out = os.path.join(_TMP, profile)
        subprocess.run(
            [sys.executable, str(TOOL), "--profile", profile, "--out", out],
            check=True, cwd=ROOT, capture_output=True, text=True)
        _OUTS[profile] = Path(out)
    return _OUTS[profile]


def qip_entries(profile):
    """[(lib, kind, out_rel_path, raw_path)] of out/upstream.qip, in file order."""
    out = prepared(profile)
    entries = []
    for line in (out / "upstream.qip").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = QIP_LINE.match(line)
        assert m, f"unparsable qip line: {line!r}"
        lib, kind, path = m.groups()
        prefix = PREFIX[profile]
        assert path.startswith(prefix + "/"), f"qip path {path!r} not below {prefix}/"
        entries.append((lib, kind, path[len(prefix) + 1:], path))
    return entries


def prj_order():
    """[('vhdl'|'verilog', out_rel_path)] in karabas_go.prj order."""
    entries = []
    text = (UPSTREAM / "src" / "karabas_go.prj").read_text()
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r'^(vhdl|verilog) work "?([^"]+)"?$', line)
        assert m, f"unparsable prj line: {line!r}"
        kind, p = m.group(1), m.group(2)
        if p.startswith("../modules/"):
            rel = "modules/" + p[len("../modules/"):]
        else:
            rel = "src/" + p.lstrip("./")
        entries.append((kind, rel))
    return entries


def upstream_of(rel):
    """output-relative path -> file in the (read-only) upstream submodule."""
    return UPSTREAM / rel


def component_block(text, name):
    """The single generated `component <name> ... end component;` block in text."""
    m = re.search(rf'(?im)^[ \t]*component[ \t]+{name}[ \t]*\r?\n(.*?)^[ \t]*end[ \t]+component[ \t]*;',
                  text, re.S)
    return m.group(0) if m else None


def load_tool_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("prepare_upstream", TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestPrepareUpstream(unittest.TestCase):
    # ---- component rewrite (Step 3 rules) ------------------------------------

    def test_component_rewrite(self):
        # The set of names VHDL instantiates directly, computed from the prj-kept
        # files the same way the tool does it, is exactly the brief's 17 names.
        profile = "core"
        kept = {rel for _, _, rel, _ in qip_entries(profile)}
        vmods, vhd_ents = set(), set()
        for kind, rel in prj_order():
            if rel not in kept:
                continue
            s = upstream_of(rel).read_text(errors="replace")
            s_nc = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
            s_nc = re.sub(r'//[^\n]*', '', s_nc)
            if rel.endswith(".v"):
                vmods |= {m.group(1).lower() for m in re.finditer(r'\bmodule\s+(\w+)', s_nc)}
            elif rel.endswith(".vhd"):
                vhd_ents |= {m.group(1).lower()
                             for m in re.finditer(r'^\s*entity\s+(\w+)\s+is', s, re.I | re.M)}
        used = set()
        inst_in = {}  # kept vhdl rel -> names it instantiates (from the original)
        for kind, rel in prj_order():
            if rel not in kept or not rel.endswith(".vhd"):
                continue
            s = upstream_of(rel).read_text(errors="replace")
            names = {m.group(1).lower() for m in re.finditer(r'entity\s+work\.(\w+)', s, re.I)
                     if m.group(1).lower() in vmods and m.group(1).lower() not in vhd_ents}
            if names:
                inst_in[rel] = names
                used |= names
        self.assertEqual(used, set(NAMES), "instantiated-Verilog set differs from the brief's 17")

        out = prepared(profile)
        for rel, names in inst_in.items():
            otext = (out / rel).read_text(errors="replace")
            for name in names:
                # no `entity work.<name>` survived the rewrite
                self.assertNotRegex(otext, rf'(?i)entity\s+work\.{name}\b',
                                    f"{rel} still instantiates entity work.{name}")
                # and it carries exactly one declaration (own or generated)
                n = len(re.findall(rf'(?im)^[ \t]*component[ \t]+{name}[ \t]*($|\r?\n)', otext))
                self.assertEqual(n, 1, f"{rel} has {n} component {name} declarations")
        # the brief's example: profi.vhd keeps its own opl2_top and gets no second
        ptext = (out / "src/rtl/profi.vhd").read_text(errors="replace")
        self.assertEqual(
            len(re.findall(r'(?im)^[ \t]*component[ \t]+opl2_top[ \t]*($|\r?\n)', ptext)), 1)

    def test_component_ports_have_defaults(self):
        profile = "core"
        out = prepared(profile)
        generated = []  # (out_vhdl_file, name) pairs where the tool generated the decl
        for kind, rel in prj_order():
            if not rel.endswith(".vhd"):
                continue
            src = upstream_of(rel).read_text(errors="replace")
            otext = (out / rel).read_text(errors="replace")
            for name in NAMES:
                was_declared = re.search(rf'(?im)^[ \t]*component[ \t]+{name}[ \t]*($|\r?\n)', src)
                block = component_block(otext, name)
                if block and not was_declared:
                    generated.append((rel, name, block))
        self.assertTrue(generated, "no generated components found in the output")
        for rel, name, block in generated:
            # The port clause runs to the `);` directly before `end component` —
            # a lazy `\);` would stop inside `(others => '0');` and only check
            # the ports before the first vector default.
            ports = re.search(r'(?is)port[ \t]*\((.*?)\n[ \t]*\);[ \t]*\r?\nend[ \t]+component',
                              block)
            self.assertIsNotNone(ports, f"component {name} in {rel} has no port clause")
            for entry in ports.group(1).split(";\n"):
                entry = entry.strip()
                if not entry or not re.match(r'\w+[ \t]*:[ \t]*in\b', entry):
                    continue
                self.assertIn(":=", entry,
                              f"in port without default: {rel} {name} :: {entry!r}")
        # If a Verilog input port has an explicit all-ones default, the generated
        # VHDL default must be (others => '1') / '1'. (The pinned upstream has no
        # such input port, so this loop is a pass-through there; the mapping rule
        # itself is unit-tested in test_default_mapping_helpers.)
        byname = {}
        for kind, rel in prj_order():
            if not rel.endswith(".v"):
                continue
            s = upstream_of(rel).read_text(errors="replace")
            s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
            s = re.sub(r'//[^\n]*', '', s)
            for mm in re.finditer(r'\bmodule\s+(\w+)\s*(#\s*\((.*?)\)\s*)?\((.*?)\)\s*;',
                                  s, re.S):
                byname[mm.group(1).lower()] = mm.group(4)
        for rel, name, block in generated:
            ports_text = byname.get(name.lower())
            if not ports_text:
                continue
            for p in re.finditer(
                    r'input\s+(?:wire|reg)?\s*(?:signed\s+)?(\[[^\]]*\])?\s*(\w+)\s*=\s*([^\s,]+)',
                    ports_text):
                vec, port, val = p.group(1), p.group(2), p.group(3)
                if not self._is_all_ones(val):
                    continue
                vhdl = re.search(rf'^[ \t]*{port}[ \t]*:[ \t]*in\b.*', block, re.M)
                self.assertIsNotNone(vhdl, f"{name}.{port}: not an in port of the generated block")
                if vec:
                    self.assertIn("(others => '1')", vhdl.group(0),
                                  f"{name}.{port} = {val} must become (others => '1')")
                else:
                    self.assertIn("'1'", vhdl.group(0),
                                  f"{name}.{port} = {val} must become '1'")
    @staticmethod
    def _is_all_ones(val):
        m = re.fullmatch(r"(\d*)'([bBhHdD])([0-9a-fA-F_]+)", val)
        if m:
            digits = m.group(3).replace("_", "").lower()
            if m.group(2) == "b":
                return set(digits) == {"1"}
            if m.group(2) == "h":
                return set(digits) == {"f"}
            return False
        return bool(re.fullmatch(r"\{\w+\{1'b1\}\}", val))

    def test_sized_literal_generics(self):
        out = prepared("core")
        ptext = (out / "src/rtl/profi.vhd").read_text(errors="replace")
        blk = component_block(ptext, "hdf_ata")
        self.assertIsNotNone(blk, "hdf_ata component was not generated into profi.vhd")
        self.assertIn("DEF_HEADS : integer := 16", blk)
        self.assertIn("DEF_SPT : integer := 63", blk)
        # vector-typed Verilog parameters are omitted
        blk = component_block(ptext, "kg_soft_switches")
        self.assertIsNotNone(blk, "kg_soft_switches component was not generated")
        self.assertNotRegex(blk, r'\bINIT\b')

    # ---- qip contents ----------------------------------------------------------

    def test_uart_library(self):
        entries = qip_entries("core")
        zxuno = [rel for lib, _, rel, _ in entries if lib == "zxuno"]
        self.assertEqual(zxuno, ["src/rtl/uart/uart.v"],
                         "uart.v must be the only -library zxuno file")
        for lib, _, rel, _ in entries:
            if rel != "src/rtl/uart/uart.v":
                self.assertEqual(lib, "work", f"{rel} is not in library work")

    def test_init_paths(self):
        out = prepared("core")
        p = "build/upstream/src/rtl/osd/icons.bit"
        self.assertIn(f'INIT_FILE => "{p}"',
                      (out / "src/rtl/osd/icons.vhd").read_text(errors="replace"))
        p = "build/upstream/src/rtl/vg93/vg93-microcode-rom.hex"
        self.assertIn(f'`define VG93_ROM_FILE "{p}"',
                      (out / "src/rtl/vg93/vg93_urom.v").read_text(errors="replace"))
        p = "build/upstream/src/rtl/sound/saa1099_compressor_lut.hex"
        self.assertIn(f'"{p}"',
                      (out / "src/rtl/sound/saa1099.v").read_text(errors="replace"))
        for f in ("src/rtl/osd/icons.bit", "src/rtl/vg93/vg93-microcode-rom.hex",
                  "src/rtl/sound/saa1099_compressor_lut.hex"):
            self.assertTrue((out / f).is_file(), f"{f} missing from the output")
        # elab profile: prefix relative to its project dir (build/elab/)
        el = prepared("elab")
        self.assertIn('INIT_FILE => "upstream/src/rtl/osd/icons.bit"',
                      (el / "src/rtl/osd/icons.vhd").read_text(errors="replace"))
        self.assertIn('`define VG93_ROM_FILE "upstream/src/rtl/vg93/vg93-microcode-rom.hex"',
                      (el / "src/rtl/vg93/vg93_urom.v").read_text(errors="replace"))

    def test_core_profile_excludes(self):
        core = {rel for _, _, rel, _ in qip_entries("core")}
        for rel in EXCLUDED_ALL:
            self.assertNotIn(rel, core, f"core qip must exclude {rel}")
        elab = {rel for _, _, rel, _ in qip_entries("elab")}
        for rel in KEPT_BY_ELAB_ONLY:
            self.assertIn(rel, elab, f"elab qip must keep {rel}")
        for rel in EXCLUDED_ALL - KEPT_BY_ELAB_ONLY:
            self.assertNotIn(rel, elab, f"elab qip must exclude {rel}")

    def test_file_order(self):
        expected = [(kind, rel) for kind, rel in prj_order()]
        kept = [e for e in expected if e[1] not in EXCLUDED_ALL]
        qip = [(kind, rel) for _, kind, rel, _ in qip_entries("core")]
        qip = [("vhdl" if k == "VHDL_FILE" else "verilog", rel) for k, rel in qip]
        self.assertEqual(qip, kept)
        elab_keep = EXCLUDED_ALL - KEPT_BY_ELAB_ONLY
        qip = [(kind, rel) for _, kind, rel, _ in qip_entries("elab")]
        qip = [("vhdl" if k == "VHDL_FILE" else "verilog", rel) for k, rel in qip]
        self.assertEqual(qip, [e for e in expected if e[1] not in elab_keep])

    def test_stamp_and_mirror(self):
        out = prepared("core")
        stamp = (out / "STAMP").read_text()
        for sub in ("", "modules"):
            h = subprocess.run(["git", "-C", str(UPSTREAM / sub if sub else UPSTREAM),
                                "rev-parse", "HEAD"],
                               capture_output=True, text=True, check=True).stdout.strip()
            self.assertIn(h, stamp, f"STAMP missing {sub or 'core-profi'} hash")
        # directory-preserving mirror
        self.assertTrue((out / "src/rtl/profi.vhd").is_file())
        self.assertTrue((out / "modules/rtl/mcu/kg_mcu.v").is_file())

    # ---- pure helpers (rules taken from the compize_proto spike) ----------------

    def test_default_mapping_helpers(self):
        m = load_tool_module()
        self.assertEqual(m.default_clause("16'd0", True), " := (others => '0')")
        self.assertEqual(m.default_clause("0", False), " := '0'")
        self.assertEqual(m.default_clause("{W{1'b0}}", True), " := (others => '0')")
        self.assertEqual(m.default_clause("1'b1", False), " := '1'")
        self.assertEqual(m.default_clause("4'b1111", True), " := (others => '1')")
        self.assertEqual(m.default_clause("8'hFF", True), " := (others => '1')")
        self.assertEqual(m.default_clause("{N{1'b1}}", True), " := (others => '1')")
        with self.assertRaises(ValueError):
            m.default_clause("4'b1010", True)

    def test_unparsable_port_is_a_named_error(self):
        m = load_tool_module()
        with self.assertRaises(m.PortParseError) as ctx:
            m.component_declaration("nosuchmodule", "", "input wire ok, this is nonsense p")
        msg = str(ctx.exception)
        self.assertIn("nosuchmodule", msg)
        self.assertIn("this is nonsense p", msg)

    def test_unparsable_parameter_fragment_is_a_named_error(self):
        m = load_tool_module()
        # `#(parameter A=1, B=2)`: the comma-elided second declaration `B=2` must
        # not be silently skipped.
        with self.assertRaises(m.PortParseError) as ctx:
            m.component_declaration("nosuchmodule", "parameter A=1, B=2", "input wire ok")
        msg = str(ctx.exception)
        self.assertIn("nosuchmodule", msg)
        self.assertIn("B=2", msg)

    # ---- profi.vhd rewrites (Task 9 wait removed, Task 4 no-wait) ------------

    PROFIS = "src/rtl/profi.vhd"

    def upstream_profi(self):
        return (UPSTREAM / "src/rtl/profi.vhd").read_text(errors="replace")

    def test_profi_rewrites_on_real_text(self):
        # Every new string lands exactly once; the stage-1 mem_wait strings
        # are gone and upstream's own `cpu_wait <= '0';` stands again (with
        # its two comment lines).
        m = load_tool_module()
        out = m.apply_profi_rewrites(self.upstream_profi())
        for _rel, _old, new in m.PROFI_REWRITES:
            self.assertEqual(out.count(new), 1)
        self.assertEqual(out.count("cpu_wait <= '0';"), 1)
        self.assertEqual(
            out.count("-- wait always disabled\n"
                      "-- actual wait signal is controlled by ena_cpu\n"), 1)
        self.assertEqual(out.count("mem_wait"), 0)

    def test_profi_rewrites_anchor_missing(self):
        m = load_tool_module()
        with self.assertRaises(SystemExit) as ctx:
            m.apply_profi_rewrites("-- some other file\n")
        msg = str(ctx.exception)
        self.assertIn(self.PROFIS, msg)
        self.assertIn("signal clk_vid", msg)

    def test_profi_rewrites_anchor_duplicated(self):
        m = load_tool_module()
        line = "signal cpu_wait \t\t\t: std_logic;"
        text = self.upstream_profi().replace(line, line + "\n" + line)
        with self.assertRaises(SystemExit) as ctx:
            m.apply_profi_rewrites(text)
        msg = str(ctx.exception)
        self.assertIn(self.PROFIS, msg)
        self.assertIn("signal cpu_wait", msg)

    def test_profi_rewrites_each_anchor_missing(self):
        # Every rewrite's old string is required exactly once: removing any
        # one of them raises, naming the file and the string.
        m = load_tool_module()
        for _rel, old, _new in m.PROFI_REWRITES:
            text = self.upstream_profi().replace(old, "", 1)
            self.assertNotEqual(text, self.upstream_profi())
            with self.assertRaises(SystemExit) as ctx:
                m.apply_profi_rewrites(text)
            self.assertIn(self.PROFIS, str(ctx.exception))

    def test_profi_rewrites_each_anchor_duplicated(self):
        m = load_tool_module()
        for _rel, old, _new in m.PROFI_REWRITES:
            text = self.upstream_profi().replace(old, old + "\n" + old, 1)
            with self.assertRaises(SystemExit) as ctx:
                m.apply_profi_rewrites(text)
            self.assertIn(self.PROFIS, str(ctx.exception))

    def test_profi_rewrites_clocktree_strings(self):
        # Task 1: CLK_VID port, bus_phase/reset_mem signals and the U1
        # mappings must each appear exactly once in the core profi, and the
        # port addition must sit right below CLK_SDR's.
        m = load_tool_module()
        out = m.apply_profi_rewrites(self.upstream_profi())
        self.assertEqual(out.count("\tCLK_VID : buffer std_logic;"), 1)
        self.assertEqual(
            out.count("\tCLK_SDR : buffer std_logic;\n"
                      "\tCLK_VID : buffer std_logic;"), 1)
        self.assertEqual(
            out.count("signal bus_phase : std_logic_vector(1 downto 0);"), 1)
        self.assertEqual(out.count("signal reset_mem : std_logic;"), 1)
        self.assertEqual(
            out.count("\tCLK_SDR  \t\t=> clk_sdr, -- 84\n"
                      "\tCLK_VID  \t\t=> CLK_VID,\n"
                      "\tBUS_PHASE \t\t=> bus_phase,\n"
                      "\tRESET_MEM \t\t=> reset_mem,"), 1)
        # the dead upstream clk_vid signal must be gone (port name clash)
        self.assertEqual(out.count("\nsignal clk_vid "), 0)
        self.assertEqual(
            out.count("-- signal clk_vid \t\t: std_logic;"), 1)

    def test_profi_rewrites_nowait_strings(self):
        # Task 4: MEM_READY port, cpu_ts/cpu_mc signals, the G_T80s TS_O/MC_O
        # mapping and the U3 no-wait mappings, each exactly once with the
        # documented adjacency.
        m = load_tool_module()
        out = m.apply_profi_rewrites(self.upstream_profi())
        self.assertEqual(
            out.count("\tCLK_12: buffer std_logic;\n"
                      "\tMEM_READY : out std_logic;"), 1)
        self.assertEqual(
            out.count("signal cpu_wait \t\t\t: std_logic;\n"
                      "signal cpu_ts : std_logic_vector(2 downto 0);\n"
                      "signal cpu_mc : std_logic_vector(2 downto 0);"), 1)
        self.assertEqual(
            out.count("\tDO\t\t\t\t\t=> cpu_do_bus,\n"
                      "\tTS_O\t\t\t\t=> cpu_ts,\n"
                      "\tMC_O\t\t\t\t=> cpu_mc\n"
                      ");\nend generate;\n\n\n-- memory manager"), 1)
        # the T80pa instance (the other DO => cpu_do_bus) stays untouched
        self.assertEqual(out.count("\tDO\t\t\t\t\t=> cpu_do_bus\n);"), 1)
        self.assertEqual(
            out.count("\tGS_WAIT_N \t\t=> gs_wait_n,\n"
                      "\tBUS_PHASE \t\t=> bus_phase,\n"
                      "\tRESET_MEM \t\t=> reset_mem,\n"
                      "\tCPU_TS \t\t\t=> cpu_ts,\n"
                      "\tCPU_MC \t\t\t=> cpu_mc,\n"
                      "\tCPU_RESET_N \t\t=> cpu_reset_n,\n"
                      "\tMEM_READY \t\t=> MEM_READY,"), 1)

    def test_profi_rewrites_core_only(self):
        # The rewritten profi.vhd maps the no-wait ports of the replaced
        # memory.vhd and the T80s TS_O/MC_O ports, so only the core profile
        # may carry the rewrites; the elab profile keeps upstream's
        # memory.vhd/T80s and profi.vhd as is.
        m = load_tool_module()
        core = (prepared("core") / "src/rtl/profi.vhd").read_text(errors="replace")
        elab = (prepared("elab") / "src/rtl/profi.vhd").read_text(errors="replace")
        for _rel, _old, new in m.PROFI_REWRITES:
            self.assertEqual(core.count(new), 1)
            self.assertEqual(elab.count(new), 0)
        self.assertEqual(elab.count("cpu_wait <= '0';"), 1)

    # ---- T80s.vhd TS_O/MC_O rewrites (Task 4; the recorded exception to
    # "never patch T80": spec §5.2 needs the T-state/M-cycle visibility) ------

    T80S = "src/rtl/t80se/T80s.vhd"

    def upstream_t80s(self):
        return (UPSTREAM / "src/rtl/t80se/T80s.vhd").read_text(errors="replace")

    def test_t80s_rewrites_on_real_text(self):
        m = load_tool_module()
        out = m.apply_t80s_rewrites(self.upstream_t80s())
        for _rel, _old, new in m.T80S_REWRITES:
            self.assertEqual(out.count(new), 1)
        # the ports keep the list legal: DO gains its semicolon, MC_O ends
        # without one, the assignments are concurrent statements after begin
        self.assertEqual(
            out.count("\t\tDO      : out std_logic_vector(7 downto 0);\n"
                      "\t\tTS_O    : out std_logic_vector(2 downto 0);\n"
                      "\t\tMC_O    : out std_logic_vector(2 downto 0)\n"
                      "\t);"), 1)
        self.assertEqual(
            out.count("begin\n\n\tTS_O <= TState;\n\tMC_O <= MCycle;\n"), 1)

    def test_t80s_rewrites_anchor_missing(self):
        m = load_tool_module()
        with self.assertRaises(SystemExit) as ctx:
            m.apply_t80s_rewrites("-- some other file\n")
        msg = str(ctx.exception)
        self.assertIn(self.T80S, msg)
        self.assertIn("DO      : out std_logic_vector(7 downto 0)", msg)

    def test_t80s_rewrites_each_anchor_missing(self):
        m = load_tool_module()
        for _rel, old, _new in m.T80S_REWRITES:
            text = self.upstream_t80s().replace(old, "", 1)
            self.assertNotEqual(text, self.upstream_t80s())
            with self.assertRaises(SystemExit) as ctx:
                m.apply_t80s_rewrites(text)
            self.assertIn(self.T80S, str(ctx.exception))

    def test_t80s_rewrites_each_anchor_duplicated(self):
        m = load_tool_module()
        for _rel, old, _new in m.T80S_REWRITES:
            text = self.upstream_t80s().replace(old, old + "\n" + old, 1)
            with self.assertRaises(SystemExit) as ctx:
                m.apply_t80s_rewrites(text)
            self.assertIn(self.T80S, str(ctx.exception))

    def test_t80s_rewrites_core_only(self):
        m = load_tool_module()
        core = (prepared("core") / "src/rtl/t80se/T80s.vhd").read_text(errors="replace")
        elab = (prepared("elab") / "src/rtl/t80se/T80s.vhd").read_text(errors="replace")
        for _rel, _old, new in m.T80S_REWRITES:
            self.assertEqual(core.count(new), 1)
            self.assertEqual(elab.count(new), 0)


if __name__ == "__main__":
    unittest.main()
