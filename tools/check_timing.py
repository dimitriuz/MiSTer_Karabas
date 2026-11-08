#!/usr/bin/env python3
"""Gate the build on the TimeQuest closure of the Quartus compile.

usage: check_timing.py [OUTPUT_DIR]     (default: output_files)

Reads OUTPUT_DIR/Karabas_Profi.sta.summary, OUTPUT_DIR/Karabas_Profi.sta.rpt
and OUTPUT_DIR/Karabas_Profi.map.rpt and prints one line per problem, then
`check_timing: OK` (exit 0) or `check_timing: FAIL <n> problems` (exit 1).
Quartus exits 0 with negative slack and only warns when an sdc line matches no
clock, so the qbuild exit code alone cannot prove timing closure (final review
I1). Problems:

  1. one of the three report files is missing;
  2. a `Slack :` line of the summary whose value is negative (the `Type :`
     line that precedes it is printed with the slack);
  3. the summary has no `Slack :` line at all (an empty or truncated report);
  4. the rpt Clocks table has no `Generated` row for one of the required
     clocks clk_bus28 / clk_bus24 / clk_mem112 / clk_mem96: the sdc creates
     them on fitter-made cells (the clkmux2 |clk_out~CLKENA*|outclk and the
     clkdiv4 divider register), and if a refit renames those cells
     create_generated_clock is ignored with a warning only and the clocks
     silently vanish;
  5. an rpt line carrying Warning (332174), (332049) or (332060) that
     mentions Karabas_Profi.sdc - an ignored or ineffective line of our own
     sdc. The stock sys_top.sdc(14) 332174 of every build does not count.
  6. a map.rpt line carrying Warning (10236), Quartus's Verilog implicit-net
     warning, whose `File:` path is Karabas_Profi.sv or under rtl/: an
     undeclared identifier became a 1-bit net (a83303d deleted the 16-bit
     profi_audio_l/r declarations, so the AUDIO pins carried only bit 0 of
     profi's samples). The build tree's `/work/` prefix is stripped; sys/
     and upstream warnings are not ours to declare.
  7. a map.rpt line carrying Warning (10541), Quartus's implicit-default
     warning: a port or signal was never assigned, so the fitter may prune
     the logic behind it (build 36: profi's GSM_A/GSM_DI were mapped to the
     gs_top-driven gs_mem_a/gs_mem_di instead of the profi ports and gs_mem
     lost its BRAM). SDR_CLK is upstream's unused board SDRAM clock port and
     is allowed.
"""
import argparse
import re
import sys
from pathlib import Path

SUMMARY_NAME = "Karabas_Profi.sta.summary"
RPT_NAME = "Karabas_Profi.sta.rpt"
MAP_RPT_NAME = "Karabas_Profi.map.rpt"
REQUIRED_CLOCKS = ("clk_bus28", "clk_bus24", "clk_mem112", "clk_mem96")
SDC_WARNING_CODES = ("Warning (332174)", "Warning (332049)", "Warning (332060)")
OUR_SDC = "Karabas_Profi.sdc"
IMPLICIT_NET_CODE = "Warning (10236)"
TOP_NAME = "Karabas_Profi.sv"

TYPE_RE = re.compile(r"^Type\s+:")
SLACK_RE = re.compile(r"^Slack\s+:\s*(\S+)")
FILE_RE = re.compile(r"File:\s*(\S+)")

# 10541: "used implicit default value for signal "NAME" because signal was
# never assigned a value". SDR_CLK is upstream's unconnected board SDRAM
# clock port, present on every build since stage 1.
IMPLICIT_DEFAULT_CODE = "Warning (10541)"
IMPLICIT_DEFAULT_ALLOWED = {"SDR_CLK"}
SIGNAL_NAME_RE = re.compile(r'signal "(\w+)"')


def check_summary(path):
    """Problem lines for the sta.summary."""
    problems = []
    last_type = None
    slacks = 0
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if TYPE_RE.match(line):
            last_type = line
        m = SLACK_RE.match(line)
        if not m:
            continue
        slacks += 1
        try:
            slack = float(m.group(1))
        except ValueError:
            problems.append("%s: unparsable Slack value %r (after %r)"
                            % (SUMMARY_NAME, m.group(1), last_type))
            continue
        if slack < 0:
            problems.append("%s: negative slack %s: %s"
                            % (SUMMARY_NAME, m.group(1), last_type))
    if slacks == 0:
        problems.append("%s: no 'Slack :' line - the summary is empty"
                        % SUMMARY_NAME)
    return problems


def check_rpt(path):
    """Problem lines for the sta.rpt."""
    problems = []
    found = {name: False for name in REQUIRED_CLOCKS}
    for line in path.read_text(errors="replace").splitlines():
        if ";" in line:
            fields = [f.strip() for f in line.split(";")]
            if fields and fields[0] == "":
                fields = fields[1:]  # rows start with the table's ';'
            if len(fields) >= 2 and fields[0] in found and fields[1] == "Generated":
                found[fields[0]] = True
        if any(code in line for code in SDC_WARNING_CODES) and OUR_SDC in line:
            problems.append("%s: sdc warning: %s" % (RPT_NAME, line.strip()))
    for name in REQUIRED_CLOCKS:
        if not found[name]:
            problems.append(
                "%s: Clocks table has no Generated row for %s - the sdc "
                "generated clock did not resolve (fitter cell renamed?)"
                % (RPT_NAME, name))
    return problems


def check_map(path):
    """Problem lines for the map.rpt: implicit nets and implicit defaults.

    The 10236 source is the `File: ` path with the build tree's `/work/`
    prefix stripped: Karabas_Profi.sv and rtl/ are ours, sys/ and upstream
    are not. A 10541 is a signal that was never assigned; only SDR_CLK
    (upstream's unused board SDRAM clock port) is allowed, any other one is
    a port or signal we left undriven.
    """
    problems = []
    for line in path.read_text(errors="replace").splitlines():
        if IMPLICIT_NET_CODE in line:
            line = line.strip()
            m = FILE_RE.search(line)
            source = m.group(1) if m else ""
            if source.startswith("/work/"):
                source = source[len("/work/"):]
            if source != TOP_NAME and not source.startswith("rtl/"):
                continue
            problems.append("%s: implicit net: %s" % (MAP_RPT_NAME, line))
        elif IMPLICIT_DEFAULT_CODE in line:
            line = line.strip()
            m = SIGNAL_NAME_RE.search(line)
            signal = m.group(1) if m else "?"
            if signal in IMPLICIT_DEFAULT_ALLOWED:
                continue
            problems.append("%s: implicit default for %s: %s"
                            % (MAP_RPT_NAME, signal, line))
    return problems


def check(output_dir):
    """List of problem lines for the report dir; empty means all good."""
    out = Path(output_dir)
    summary, rpt = out / SUMMARY_NAME, out / RPT_NAME
    map_rpt = out / MAP_RPT_NAME
    problems = []
    for p in (summary, rpt, map_rpt):
        if not p.is_file():
            problems.append("missing report file: %s" % p)
    if summary.is_file():
        problems += check_summary(summary)
    if rpt.is_file():
        problems += check_rpt(rpt)
    if map_rpt.is_file():
        problems += check_map(map_rpt)
    return problems


def main(argv):
    parser = argparse.ArgumentParser(prog="check_timing.py", add_help=False)
    parser.add_argument("output_dir", nargs="?", metavar="OUTPUT_DIR",
                        default="output_files")
    args = parser.parse_args(argv)
    problems = check(args.output_dir)
    for line in problems:
        print(line)
    if problems:
        print("check_timing: FAIL %d problems" % len(problems))
        return 1
    print("check_timing: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
