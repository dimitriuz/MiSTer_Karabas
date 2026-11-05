"""Tests for tools/check_timing.py.

Run: python3 -m unittest discover -s tools/tests -v

Fixtures copy the line shapes of the build 15/16 reports: the `Type  : ` /
`Slack : ` blocks of Karabas_Profi.sta.summary, the `; clk_bus24   ;
Generated ; 41.481 ; ...` rows of the Clocks table (the four Stage-2 generated
clocks clk_bus28/clk_bus24/clk_mem112/clk_mem96) and the stock
`Warning (332174): Ignored filter at sys_top.sdc(14) ...` line of
Karabas_Profi.sta.rpt. The good rpt keeps that stock warning in (it is
emitted on every build and must not fail the gate) plus its plain
`Karabas_Profi.sdc` mentions (SDC File List, Info 332104), so the OK case
also pins that a mention of our sdc outside the three warning codes is
harmless.
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import check_timing  # noqa: E402

SUMMARY_NAME = "Karabas_Profi.sta.summary"
RPT_NAME = "Karabas_Profi.sta.rpt"

SUMMARY_GOOD = """\
------------------------------------------------------------
TimeQuest Timing Analyzer Summary
------------------------------------------------------------

Type  : Setup 'clk_bus28'
Slack : 10.295
TNS   : 0.000

Type  : Setup 'clk_bus24'
Slack : 13.105
TNS   : 0.000

Type  : Hold 'clk_bus28'
Slack : 0.251
TNS   : 0.000

------------------------------------------------------------
"""

# one block replaced by a failing one; shape verbatim from a real summary
SUMMARY_NEG_SLACK = SUMMARY_GOOD.replace(
    "Type  : Hold 'clk_bus28'\nSlack : 0.251\nTNS   : 0.000",
    "Type  : Hold 'clk_bus28'\nSlack : -0.481\nTNS   : 3.122",
)

SUMMARY_NO_SLACK = """\
------------------------------------------------------------
TimeQuest Timing Analyzer Summary
------------------------------------------------------------

"""

# The Clocks table plus the stock sys_top.sdc 332174 and the two plain
# Karabas_Profi.sdc mentions the clean build 15 rpt really carries. The
# `; clk_bus28   ; 10.295 ;` rows mimic the setup/hold report tables: the
# clock name is the first field there too, but the type is not `Generated`.
RPT_GOOD = """\
+-------------------+--------+--------------------------+
; SDC File Path     ; Status ; Read at                  ;
+-------------------+--------+--------------------------+
; sys/sys_top.sdc   ; OK     ; Thu Nov  5 15:17:17 2026 ;
; Karabas_Profi.sdc ; OK     ; Thu Nov  5 15:17:17 2026 ;
+-------------------+--------+--------------------------+
; Clocks
; Clock Name ; Type      ; Period  ; Frequency ;
; clk_bus24  ; Generated ; 41.481  ; 24.11 MHz ;
; clk_bus28  ; Generated ; 35.555  ; 28.13 MHz ;
; clk_mem96  ; Generated ; 10.370  ; 96.43 MHz ;
; clk_mem112 ; Generated ; 8.889   ; 112.50 MHz ;
+------------+-----------+---------+-----------+
; clk_bus28   ; 10.295 ; 0.000         ;
; clk_bus24   ; 13.105 ; 0.000         ;
Info (332104): Reading SDC File: 'Karabas_Profi.sdc'
Warning (332174): Ignored filter at sys_top.sdc(14): *|pll|pll_inst|altera_pll_i|*[*].*|divclk could not be matched with a clock File: /work/sys/sys_top.sdc Line: 14
"""

def drop_row(text, prefix):
    """RPT_GOOD without every line starting with prefix."""
    return "\n".join(
        line for line in text.splitlines()
        if not line.startswith(prefix)
    ) + "\n"


RPT_NO_CLK24_ROW = drop_row(RPT_GOOD, "; clk_bus24  ; Generated")
RPT_NO_CLKMEM112_ROW = drop_row(RPT_GOOD, "; clk_mem112 ; Generated")

# a refit renamed the CLKENA cell: create_generated_clock was ignored, the
# clock exists (from its source) but not as our named Generated clock.
RPT_CLK24_WRONG_TYPE = RPT_GOOD.replace(
    "; clk_bus24  ; Generated ; 41.481  ; 24.11 MHz ;",
    "; clk_bus24  ; Base      ; 41.481  ; 24.11 MHz ;",
)

RPT_CLKMEM96_WRONG_TYPE = RPT_GOOD.replace(
    "; clk_mem96  ; Generated ; 10.370  ; 96.43 MHz ;",
    "; clk_mem96  ; Base      ; 10.370  ; 96.43 MHz ;",
)

RPT_OUR_SDC_IGNORED = RPT_GOOD + (
    "Warning (332174): Ignored filter at Karabas_Profi.sdc(49):"
    " emu|u_profi|U1|U9|clk_out~CLKENA0|outclk could not be matched with a"
    " clock File: /work/Karabas_Profi.sdc Line: 49\n"
)

RPT_OUR_SDC_332060 = RPT_GOOD + (
    "Warning (332060): Ignored create_generated_clock at"
    " Karabas_Profi.sdc(49): Argument <targets> is an empty collection"
    " File: /work/Karabas_Profi.sdc Line: 49\n"
)


def run_main(argv):
    """check_timing.main(argv) with stdout captured; (code, output)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = check_timing.main(argv)
    return code, buf.getvalue()


class CheckTimingTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="karabas-check-timing-")
        self.addCleanup(tmp.cleanup)
        self.out = Path(tmp.name)

    def check(self, summary=SUMMARY_GOOD, rpt=RPT_GOOD):
        """Write the two fixtures into the report dir and run main() on it."""
        if summary is not None:
            (self.out / SUMMARY_NAME).write_text(summary)
        if rpt is not None:
            (self.out / RPT_NAME).write_text(rpt)
        return run_main([str(self.out)])

    # ---- OK cases ---------------------------------------------------------
    def test_all_good(self):
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertEqual(out.strip().splitlines()[-1], "check_timing: OK")

    def test_stock_sys_top_332174_alone_is_ok(self):
        # the fixture rpt carries the stock sys_top.sdc(14) 332174 -
        # emitted on every build, it must not fail the gate.
        self.assertIn("Warning (332174)", RPT_GOOD)
        code, out = self.check()
        self.assertEqual(code, 0, out)

    def test_default_output_dir(self):
        sub = self.out / "output_files"
        sub.mkdir()
        (sub / SUMMARY_NAME).write_text(SUMMARY_GOOD)
        (sub / RPT_NAME).write_text(RPT_GOOD)
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.out)
        code, out = run_main([])
        self.assertEqual(code, 0, out)
        self.assertEqual(out.strip().splitlines()[-1], "check_timing: OK")

    # ---- negative slack ---------------------------------------------------
    def test_negative_slack_fails_naming_type(self):
        code, out = self.check(summary=SUMMARY_NEG_SLACK)
        self.assertEqual(code, 1)
        self.assertIn("Hold 'clk_bus28'", out)
        self.assertIn("-0.481", out)
        self.assertEqual(out.strip().splitlines()[-1],
                         "check_timing: FAIL 1 problems")

    def test_no_slack_line_fails(self):
        code, out = self.check(summary=SUMMARY_NO_SLACK)
        self.assertEqual(code, 1)
        self.assertIn("Slack", out)
        self.assertEqual(out.strip().splitlines()[-1],
                         "check_timing: FAIL 1 problems")

    # ---- clock table ------------------------------------------------------
    def test_missing_clk_bus24_row_fails(self):
        code, out = self.check(rpt=RPT_NO_CLK24_ROW)
        self.assertEqual(code, 1)
        self.assertIn("clk_bus24", out)
        self.assertEqual(out.strip().splitlines()[-1],
                         "check_timing: FAIL 1 problems")

    def test_clk_bus24_row_wrong_type_fails(self):
        # the name alone must not pass: the row must be a Generated clock
        # (the setup-report rows name clk_bus28/24 as their first field
        # too - they are in every fixture rpt).
        code, out = self.check(rpt=RPT_CLK24_WRONG_TYPE)
        self.assertEqual(code, 1)
        self.assertIn("clk_bus24", out)

    def test_missing_clk_mem112_row_fails(self):
        code, out = self.check(rpt=RPT_NO_CLKMEM112_ROW)
        self.assertEqual(code, 1)
        self.assertIn("clk_mem112", out)
        self.assertEqual(out.strip().splitlines()[-1],
                         "check_timing: FAIL 1 problems")

    def test_clk_mem96_row_wrong_type_fails(self):
        code, out = self.check(rpt=RPT_CLKMEM96_WRONG_TYPE)
        self.assertEqual(code, 1)
        self.assertIn("clk_mem96", out)

    # ---- sdc warnings -----------------------------------------------------
    def test_our_sdc_332174_fails(self):
        code, out = self.check(rpt=RPT_OUR_SDC_IGNORED)
        self.assertEqual(code, 1)
        self.assertIn("Karabas_Profi.sdc", out)
        self.assertEqual(out.strip().splitlines()[-1],
                         "check_timing: FAIL 1 problems")

    def test_our_sdc_332060_fails(self):
        code, out = self.check(rpt=RPT_OUR_SDC_332060)
        self.assertEqual(code, 1)
        self.assertIn("Karabas_Profi.sdc", out)

    # ---- missing files ----------------------------------------------------
    def test_missing_summary_fails(self):
        code, out = self.check(summary=None)
        self.assertEqual(code, 1)
        self.assertIn(SUMMARY_NAME, out)
        self.assertEqual(out.strip().splitlines()[-1],
                         "check_timing: FAIL 1 problems")

    def test_missing_rpt_fails(self):
        code, out = self.check(rpt=None)
        self.assertEqual(code, 1)
        self.assertIn(RPT_NAME, out)

    def test_both_missing_counts_two_problems(self):
        code, out = self.check(summary=None, rpt=None)
        self.assertEqual(code, 1)
        self.assertEqual(out.strip().splitlines()[-1],
                         "check_timing: FAIL 2 problems")


if __name__ == "__main__":
    unittest.main()
