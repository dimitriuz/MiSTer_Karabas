# CP/M mouse (2026-11-18)

The owner reported that the mouse does nothing in CP/M mode.

## Cause

CP/M's mouse driver (`PCMSMOUS`, "Resident MS/PC-Mouse driver", loaded by its
`autoexec`) reads the Profi's serial-mouse emulation, an 8251-style chip at
ports #D3 (data) and #F3 (status/control), not the Kempston-mouse ports, which
are decoded outside CP/M only (`cpm='0'` in profi.vhd).

Upstream's `serial_mouse.vhd` selects the chip with `not A(6) or p4 or ds80`
(deselected whenever ds80 = 1) but enables its output with
`OE_N <= '0' when ds80 = '1' and ...`, and profi.vhd's CPU bus mux takes it
only when `serial_ms_oe_n = '0' and ds80 = '1'`; `hw_int.vhd` also works only
at ds80 = 1. No value of ds80 lets the CPU read the chip. Simulated with the
upstream VHDL, CP/M mode: ds80 = 0 the chip answers (status 7, data 60 hex) with
OE_N high; ds80 = 1 it is deselected and reads give 255. Upstream's master
carries the same lines (introduced by its commit 82d6949, "Mini2 refactoring").

## Fix

`tools/prepare_upstream.py` `SERIAL_MOUSE_REWRITES`: the select becomes
`not A(6) or p4 or (not ds80)`, so the chip is on the bus only in the Profi
video mode (ds80 = 1) and off while General Sound is mapped (ds80 = 0), which is
what the ds80 terms were for. `sim/tb_serial_mouse.vhd` runs the rewritten
chip (cpm_ds80: RxRDY and the packet 60 05 03 hex; gs_ds80_0 and no_cpm: the
chip never drives the bus) and requires the unmodified upstream chip to fail.

## Board

CP/M (`profi_cpm.img` on IDE 0, file manager `hc2`), the mouse pointer is the
red block. A virtual relative mouse (uinput on the board, 8 counts x 25, right
then down), pointer position read off the screenshot:

| build | serial mouse | pointer before | after right | after down |
|---|---|---|---|---|
| 78 | upstream | (713, 588) | (713, 588) | (713, 588) |
| 80 | rewritten | (713, 588) | (1317, 588) | (1319, 1000) |

Not tested: the buttons and the wheel in CP/M, and the DOS mode of the same chip
(`dos_act` with ROM bank 0 also selects it).

## Builds

| build | seed | result |
|---|---|---|
| 79 | 2 | `check_timing: OK` (worst setup +0.272 ns) but a black screen on the board, with and without an image; the same board boots build 78 |
| 80 | 3 | `check_timing: OK` (worst setup +0.232 ns); boots; the mouse works in CP/M |

Build 79's black screen followed a source change that cannot reach the boot
path (the chip is deselected until CP/M or DOS selects it), and build 77 (seed 1,
the HDMI PLL's timing) was black too: the design has some placement-dependent
failure that `check_timing` does not catch. Not investigated.
