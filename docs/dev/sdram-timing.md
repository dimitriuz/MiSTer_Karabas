# SDRAM pin timing: the cause of the "black" builds

Builds 77, 79, 81, 82, 85 and 88 passed `check_timing` and still did not boot
properly: black screen, or the Karabas GO screen full of stripes of garbage
that changed with the ROM bank (the CPU runs, what it reads is wrong).
Whether a given source booted depended on the Quartus seed.

## Cause

`Karabas_Profi.sdc` had **no constraint on the SDRAM pins**: no
`set_input_delay`/`set_output_delay` against `SDRAM_CLK`. The STA timed only
paths inside the FPGA, so the data the chip returns was never checked, and the
fitter had no reason to put the capture register near its pin. The read data
goes pad -> a lane-select LUT -> `cpu_byte_r` (rtl/mem/sdram_nowait.vhd) in the
fabric. In build 88 (seed 7, boots to garbage) that path was 11.3 ns: the data
pin sits at the top edge of the die (X38 Y81) and the register ended up at the
bottom (X59 Y6), 9.5 ns of routing. Re-timing the saved build 88 with the
constraints below gave **-0.222 ns** on exactly that path and nothing else
violated.

## Fix (Karabas_Profi.sdc, from build 89)

- `SDRAM_CLK112` / `SDRAM_CLK96`: generated clocks on the `SDRAM_CLK` pin
  (the DDR output register inverts clk_mem), one per clkmux2 input, in the
  same logically exclusive groups as clk_mem112/96.
- `set_input_delay` on `SDRAM_DQ` -max 6.4 / -min 3.2 (tAC 5.4 + ~1 board,
  tOH 2.5 + ~0.7), `set_output_delay` on the address, bank, command, DQM and DQ
  pins -max 1.5 / -min -0.8 (tIS, tIH).
- `set_multicycle_path -setup 3 / -hold 2` from `SDRAM_CLK*` to `clk_mem*`: a
  READ at S0+2 is captured at S0+5, so the data the chip launches CL2 after
  the command is taken three clk_mem edges after that launch edge.

With the constraints the fitter pulls the capture registers to the pins: build
89 (seed 7 again) closes the read path at **+1.212 ns** (112.5 MHz) / +1.957 ns
(96.4 MHz), outputs +1.2 / hold +2.8, and boots.

The multicycle count is derived from the controller's schedule, not measured
on the chip; if a future build passes timing and misbehaves, look at this path
first (`report_timing -from [get_ports {SDRAM_DQ[*]}]`).

Earlier notes that blamed "the HDMI PLL's counter clock" for the failing
seeds 1, 5 and 6 were wrong: the failing clock there is the core's own
`general[2]` PLL counter, i.e. clk_mem112 (the SDRAM domain).

## Correction (2026-11-23): the S0+5 capture and the `-setup 3` multicycle were wrong

"The multicycle count is derived from the controller's schedule, not measured"
turned out to be the weak point. A second user's board did not start ROMain from
the same source (their own Quartus build did); their report showed the same SDC
and seed, so the difference was placement.

What the numbers say. SDRAM_CLK is clk_mem inverted. A READ at S0+2 is sampled by
the chip at S0+2.5, and the CL2 data is launched by the chip edge S0+4.5. At the
pins it is valid about `T_CLK + tAC = 2.4 + 6.4 = 8.8 ns` later (the SDRAM_CLK pad
lags the capture register's clock by ~2.4 ns: DDR cell + output buffer; read from
the STA path report) and held until about `2.4 + 3.2 ns` after the next chip edge.
At 112.5 MHz that is a window of roughly S0+5.5 .. S0+6.1. The old capture was at
S0+5: half a period (4.4 ns) after the launch edge, before the data existed. It
worked only when the fitter happened to give the capture register a late clock.
`-setup 3` told STA the capture was a whole period later than it is, which hid the
real figures: with the plain one-edge relation the S0+5 capture is **-8.1 ns**
(112.5 MHz) / **-7.4 ns** (96.4 MHz). A second user's tree captures on the falling
edge S0+5.5; that is still about -3.7 ns under these worst-case constraints.

The fix (branch `sdram-io-capture`):
- capture at **S0+6**, the second rising clk_mem edge after the launch; STA:
  `set_multicycle_path -setup 2` and NO `-hold` override (the default hold then
  checks the next chip data against this very edge, the real hold requirement).
  Build: setup SDRAM_CLK112 +1.12 / SDRAM_CLK96 +1.81 ns, hold +2.97 / +3.69 ns.
- the read data goes into ONE bare 8-bit register on SDRAM_DQ[7:0] (enable only,
  no reset, no mux), which the fitter puts into the pin's IO input register
  (FAST_INPUT_REGISTER). To make that possible every byte lives alone in its own
  SDRAM word (lane 0, DQMH masks lane 1 on writes): word address = byte address,
  row = addr(12:0), column = addr(20:13); half of the module is unused.
- S0+6 is the clk_bus edge E2 at turbo 11, where the T80 latches DI. memory.vhd
  holds T2 of a memory read one clk_bus period at turbo 11 only (MEM_WAIT ->
  upstream's cpu_wait_n, see tools/prepare_upstream.py); the latch is at E3.
  Cost: about +18 % run time of a program at 8x in tb_turbo_nowait. Lower turbos
  have room and need no wait.
- WRITE moves to sample+3 (S0+7 at turbo 11): the chip may drive the previous
  read data until about S0+6.4 (tHZ).
- sim/models/sdram_chip.vhd models T_CLK/tAC/tOH/tHZ at the pins, so a capture
  outside the window reads 'X' and fails the DI check (mutation tested: capture
  back at S0+5 fails tb_sdram_nowait). tb_sdram_nowait's CPU driver models the
  turbo-11 wait; before, it read the capture register in the same delta as it
  loaded and could not tell E2 from E3.
