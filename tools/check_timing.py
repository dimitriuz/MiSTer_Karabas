#!/usr/bin/env python3
"""Gate the build on the TimeQuest closure of the Quartus compile.

usage: check_timing.py [OUTPUT_DIR]     (default: output_files)

Reads OUTPUT_DIR/Karabas_Profi.sta.summary and OUTPUT_DIR/Karabas_Profi.sta.rpt
and prints one line per problem, then `check_timing: OK` (exit 0) or
`check_timing: FAIL <n> problems` (exit 1). Quartus exits 0 with negative
slack and only warns when an sdc line matches no clock, so the qbuild exit
code alone cannot prove timing closure (final review I1). Problems:

  1. either report file is missing;
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
"""
import argparse
import re
import sys
from pathlib import Path

SUMMARY_NAME = "Karabas_Profi.sta.summary"
RPT_NAME = "Karabas_Profi.sta.rpt"
REQUIRED_CLOCKS = ("clk_bus28", "clk_bus24", "clk_mem112", "clk_mem96")
SDC_WARNING_CODES = ("Warning (332174)", "Warning (332049)", "Warning (332060)")
OUR_SDC = "Karabas_Profi.sdc"

TYPE_RE = re.compile(r"^Type\s+:")
SLACK_RE = re.compile(r"^Slack\s+:\s*(\S+)")


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


def check(output_dir):
    """List of problem lines for the report dir; empty means all good."""
    out = Path(output_dir)
    summary, rpt = out / SUMMARY_NAME, out / RPT_NAME
    problems = []
    for p in (summary, rpt):
        if not p.is_file():
            problems.append("missing report file: %s" % p)
    if summary.is_file():
        problems += check_summary(summary)
    if rpt.is_file():
        problems += check_rpt(rpt)
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
