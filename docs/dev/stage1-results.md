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
| Spectrum-mode video at 60 Hz | **FAIL** | `spectrum128-menu-60hz-broken.png`: torn, colour bytes rotated |
| Keyboard: menu navigation (cursor down, Enter) | PASS | selection moves; Sinclair 128K starts |
| Keyboard: `10 PRINT 1`, `RUN` in 128 BASIC | PASS | `basic128-print.png`: `1`, `0 OK, 10:1` |
| ROM bank PQ-DOS | PASS | `bank-pqdos.png`: ROM-BIOS 0.42d self-test (FDD0/1 Fail: no drives until stage 2) |
| ROM bank FDImage | PASS | `bank-fdimage.png`: FDImage v0.87 |
| ROM bank FATALL | PASS (menu only) | `bank-fatall.png`: ROMain menu; the image differs from bank 0 only above 0x8000 (CP/M/FATALL), which needs a disk |
| OSD Reset | PASS | checked by the owner on the board |
| MiSTer reset button | not run | needs a hand on the board |
| Turbo 2x | **FAIL** | `turbo2x-romain-hang.png`: black screen with ROMain; PQ-DOS hangs the same way at 2x, 4x and 8x |

## Findings

1. **RGB_BLANK polarity (fixed, ef76147).** `pentagon_video` drives BLANK low while
   blanking and `profi_video` drives it high. Upstream's own top never reads
   RGB_BLANK (its HDMI frame comes from RGB_PIXEL/RGB_FRAME), so the mismatch only
   shows in this port. The top now inverts it in the Spectrum modes (`vmode[3]` = 0).

2. **60 Hz Spectrum modes: VSYNC outside the vertical blank (open).** In
   `pentagon_video.vhd`, with MODE60 = 1 the VSYNC pulse is on character row 27
   (`ver_cnt /= 27`), but the blank covers rows 28-29 (`ver_cnt(5:1) = 14`; the
   comment there says 13). At 50 Hz VSYNC (row 31) lies inside the blank (rows 30-31).
   MiSTer's scaler needs VSYNC inside the vertical blank. Fix in this port's top, not
   upstream: regenerate VS (and VBlank) from the blank run on the clk_sdr side, so
   VS sits inside the vertical blank in every mode.

3. **Turbo hangs from 2x on (open).** The SDRAM bridge returns a read within 12
   clk_bus clocks. A Z80 read at turbo 2x (7 MHz, one T-state = 4 clk_bus) leaves
   about 6. The machine needs `WAIT_CPU` (clock.vhd has the input) driven by the
   bridge while a read is outstanding. The stage-1 limitation "turbo above 7 MHz
   may crash" understated this: every turbo setting fails.

4. **Palette (observation).** The machine's default palette puts the normal colours
   at level 4/7 and the bright colours at 6/7 (`video.vhd`), so plain white shows as
   RGB 144. This is upstream's palette. The DS80 extra green bit `GX0` is not carried
   into the 9-bit RGB of this port.
