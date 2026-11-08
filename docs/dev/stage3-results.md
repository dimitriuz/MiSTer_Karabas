# Stage 3 board results

Board: DE10-Nano MiSTer at 192.168.1.13. Date: 2026-11-08. Builds 37 (General Sound,
commit aabcc04) and 38 (MIDI, commit 960b54a). The owner listened.

How it was driven: as in stage 2 (`load_core`, the 16-byte status file, uinput keys from
`mkeys2.py`, `screenshot`). The test programs were typed into 128 BASIC; uppercase letters
inside strings do not survive the key injection, so the labels are lowercase and a capital
`Y` is written `CHR$ 89`. Screenshots are in `stage3-shots/`.

| Check | Result | Evidence |
|---|---|---|
| General Sound present (build 37) | PASS | `PRINT IN 187` = 126 (idle); `OUT 187,35` (#23, RAM pages), then status 254 and `IN 179` = 62: the GS CPU runs its ROM from the loader, and its RAM test passes over the whole 2 MB (BRAM + DDR3). 2 MB is 64 pages of 32 KB (`gs-pages-build37.png`) |
| GS host interface at turbo 8x, right after the DS80 → Spectrum switch (build 38) | PASS | 300 × (`OUT 187,35`, wait for bit 7, `IN 179`): 0 wrong answers (`gs-stress-8x-build38.png`). This is the check on the asynchronous CLK_GS ruling (plan, Architecture) |
| TurboSound AY chip 0 / chip 1 | PASS | owner heard both: `OUT 65533,255` / `254`, then `PLAY "cegc"` (`chips-listing-build38.png`, `chips-run-build38.png`) |
| TurboSound FM (YM2203) | PASS | owner heard it: `OUT 65533,250` (FM on), 11 register writes through #FFFD/#BFFD (operator 4, algorithm 7, block 4), key on |
| SAA1099 | PASS | owner heard it: register #1FF / data #FF, sound enable, channel 0 amplitude, frequency, octave, tone on |
| OPL2 | PASS | owner heard it: address #C4 / data #C5, a two-operator voice, key on |
| Covox | PASS | owner heard it: `OUT 251,255` / `OUT 251,0` loop |
| Beeper, AY, PSG mix | PASS (stage 2, build 30) | `docs/dev/stage2-results.md` (Sound row, finding 5: upstream's "Mono" is ABC, kept) |
| MIDI through MidiLink (build 38) | PASS | owner heard it on the PC: 128 BASIC `PLAY CHR$ 89+"1cdefgab"` (MIDI channel 1) → TurboSound MIDI line → `UART_TXD` (UART mode MIDI, 31250) → MidiLink UDP → 192.168.1.52:1999 → a UDP-to-FluidSynth bridge on the PC (see below) |
| General Sound playing audio | deferred to stage 4 | playing needs a module or sample file loaded into the GS; there is no file or tape loading before stage 4. Its memory and host interface are proven above |
| MT32-pi on the USER port | not tested | no USER-port mt32-pi on this board; built as in pico-speccy Plan 4 (`sys/mt32pi.sv` + `rtl/sound/mt32_mix.sv`, `tb_mt32_mix`) |
| GS Reset OSD item | not tested | needs the OSD; the GS restarts on every machine reset through profi's `gs_reset_s` |

## Board setup left in place

- `/media/fat/config/uartmode.Karabas_Profi` (`03 03 00 00`: UART mode MIDI, MidiLink UDP) and
  `uartspeed.Karabas_Profi` (31250 × 3), copied from PicoSpeccy's. The same as choosing
  UART mode MIDI and MidiLink UDP in the core's OSD.
- `/media/fat/linux/MidiLink.INI`: `UDP_SERVER` changed from 192.168.1.130 to 192.168.1.52 (the
  owner's PC, where the test synth ran); the original is `MidiLink.INI.before-karabas`. The file
  is shared by every core.

The PC side was a FluidSynth server (`fluidsynth -is -o shell.port=9800 <soundfont>`) and a
small Python script that turns MidiLink's raw MIDI bytes (UDP port 1999) into FluidSynth shell
commands; a real network mt32-pi listening on UDP 1999 takes the same stream.

## Findings

1. **CLK_GS cannot be aligned to the bus clock** (plan Task 1, superseded). The bus clock is
   `clk_mem / 4` behind a fabric clock mux, whose insertion delay spreads from 9.7 ns
   (setup) to 13.8 ns (hold) against 7-8.4 ns for CLK_GS, so a phase detector between them
   cannot close timing (builds 31-35, seeds 1-3). Upstream gets the alignment for free from
   a Xilinx BUFGMUX on a PLL clock. Ruling (owner confirmed): CLK_GS is asynchronous to the
   bus clocks; `gs.v`'s host side is level-based on strobes of at least three bus clocks.
   Board check: the 8x stress row above.
2. **A build that silently drops a module passed every gate** (build 36): a rewrite mapped
   two GS outputs onto profi's internal signals, so the GS address never left profi and
   `gs_mem`'s RAM was optimised away; Quartus only warned (10541, implicit default value).
   Fixed in 14973b2; `tools/check_timing.py` now fails a build on any 10541 warning except
   upstream's `SDR_CLK` (aabcc04), and the rewrite test checks the exact port mapping.
