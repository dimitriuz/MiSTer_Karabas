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
