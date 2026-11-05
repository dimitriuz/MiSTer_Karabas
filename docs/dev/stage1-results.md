# Stage 1 board bring-up results

Board: DE10-Nano MiSTer at 192.168.1.13. Date: 2026-11-04.
Core: build 13 (commit ef76147), `Karabas_Profi_20261104.rbf`, `boot.rom` from
`releases/` in `/media/fat/games/Karabas_Profi/`.

How it was driven: the core loaded with `load_core` on `/dev/MiSTer_cmd`. Keys came
from a uinput virtual keyboard (`mkeys2.py` from the ZX-Spectrum_MISTer fork) and
screenshots from the `screenshot` command. OSD options were set without the OSD by
writing the 16-byte status file `/media/fat/config/Karabas_Profi.CFG` (status bits,
little endian) and reloading the core. Screenshots are in `stage1-shots/`.

| Check | Result | Evidence |
|---|---|---|
| Core loads, `boot.rom` streamed, ROMain menu at 50 Hz | PASS | `romain-menu-50hz.png` (608x272) |
| ROMain menu at 60 Hz (VSync = 60 Hz) | PASS | `romain-menu-60hz.png` (608x240) |
| Spectrum-mode video (Sinclair 128 menu) at 50 Hz | PASS after fix ef76147 | before: `spectrum128-before-blank-fix.png` (72x305, black); after: `spectrum128-menu-50hz.png` (376x304) |
| Spectrum-mode video at 60 Hz | PASS after fix d3fa0f0 (2026-11-05) | before: `spectrum128-menu-60hz-broken.png` (torn); after: `spectrum128-menu-60hz.png`, `basic128-print-60hz.png` (376x248); 50 Hz rechecked (376x304) |
| Keyboard: menu navigation (cursor down, Enter) | PASS | selection moves; Sinclair 128K starts |
| Keyboard: `10 PRINT 1`, `RUN` in 128 BASIC | PASS | `basic128-print.png`: `1`, `0 OK, 10:1` |
| ROM bank PQ-DOS | PASS | `bank-pqdos.png`: ROM-BIOS 0.42d self-test (FDD0/1 Fail: no drives until stage 2) |
| ROM bank FDImage | PASS | `bank-fdimage.png`: FDImage v0.87 |
| ROM bank FATALL | PASS (menu only) | `bank-fatall.png`: ROMain menu; the image differs from bank 0 only above 0x8000 (CP/M/FATALL), which needs a disk |
| OSD Reset | PASS | checked by the owner on the board |
| MiSTer reset button | PASS | checked by the owner on the board |
| Turbo 2x/4x/8x | PASS after fix 4d633df..b80d0ad (build 15, 2026-11-05) | before: `turbo2x-romain-hang.png` (black, every turbo); after: `turbo2x-romain.png`, `turbo8x-romain.png` (status bar "Turbo: 2x/4x/8x"), `basic128-print-turbo8x.png` (`10 PRINT 1` / `RUN` at 8x), `turbo8x-pqdos.png` (PQ-DOS BIOS boots, measures "Z80 clock: 8.3Mhz") |
| Turbo off after the wait fix | PASS | 128 BASIC `10 PRINT 1` / `RUN` at 3.5 MHz, 50 Hz; one unrepeated garbage screen (`turbo-off-oneoff-garbage.png`), see finding 5 |

## Findings

1. **RGB_BLANK polarity (fixed, ef76147).** `pentagon_video` drives BLANK low while
   blanking and `profi_video` drives it high. Upstream's own top never reads
   RGB_BLANK (its HDMI frame comes from RGB_PIXEL/RGB_FRAME), so the mismatch only
   shows in this port. The top now inverts it in the Spectrum modes (`vmode[3]` = 0).

2. **60 Hz Spectrum modes: VSYNC outside the vertical blank (fixed, 6d88edb/d3fa0f0).** In
   `pentagon_video.vhd`, with MODE60 = 1 the VSYNC pulse is on character row 27
   (`ver_cnt /= 27`), but the blank covers rows 28-29 (`ver_cnt(5:1) = 14`; the
   comment there says 13). At 50 Hz VSYNC (row 31) lies inside the blank (rows 30-31).
   MiSTer's scaler needs VSYNC inside the vertical blank. Fixed in this port's top:
   `rtl/video/vframe_gen.sv` rebuilds VS and VBlank from the run of fully blank lines,
   so VS sits inside the vertical blank in every mode.

3. **Turbo hung from 2x on (fixed, 4d633df/b80d0ad).** The SDRAM bridge returns a
   read 9-11 clk_bus clocks after the request, and a Z80 read at turbo 2x leaves
   about 6. The bridge now raises `cpu_wait` while a CPU read is not served yet or
   its write queue is nearly full. `tools/prepare_upstream.py` feeds it, in turbo
   only, into both clock.vhd's `WAIT_CPU` (freezes ENA_CPU) and the T80 `WAIT_n`
   pin. The pin is needed at 8x, where ENA_CPU is high every clock and the
   registered freeze lands after the T80 latched DI at the end of T2.
   `sim/tb_turbo_wait.vhd` reproduces the hang without the wait (no HALT at
   01/10/11) and passes with it. Turbo is slower than on the Karabas board: the
   PQ-DOS BIOS measures 8.3 MHz at the 8x setting.

4. **Palette (observation).** The machine's default palette puts the normal colours
   at level 4/7 and the bright colours at 6/7 (`video.vhd`), so plain white shows as
   RGB 144. This is upstream's palette. The DS80 extra green bit `GX0` is not carried
   into the 9-bit RGB of this port.

5. **One-off garbage screen at turbo off (not reproduced).** One key-scripted run
   (reload at turbo off right after an 8x run, menu → Sinclair 128 → 128 BASIC →
   `10 PRINT 1`) ended on a screen of garbage. The identical script repeated
   twice, and the steps taken one by one, all gave `0 OK, 10:1`. Most likely the
   scripted keys landed while the ROM was still starting; it is left on record in
   case it recurs.
