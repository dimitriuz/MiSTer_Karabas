# FDC trace over the HPS UART (2026-11-19)

A debug aid for the floppy path: the core logs the CPU's accesses to the VG93 and sends
them out of the HPS UART, so the board shows the same kind of trace PicoSpeccy's
`FDD_PORT_TRACE` gives (see `sim/data/ams_loader.trace`).

## Use

1. OSD: `FDC trace to UART` = On. This forces the `Serial channel` to USB and replaces the
   MCU's USB bytes while it is on (the machine's own serial traffic is not forwarded then).
2. On the board, from the PC:

       ssh root@<board> 'stty -F /dev/ttyS1 115200 raw -echo; timeout 120 cat /dev/ttyS1' \
         | python3 tools/fdc_trace.py

   (`/dev/ttyS1` is the HPS UART; the core's UART mode must be the default 115200 one.)
3. Boot the disk. Each line is a write to the controller (`CMD`/`TRK`/`SEC`/`DAT`, `SYS` for
   port #FF) or a read of the status register whose value changed.

## What is logged

`rtl/host/fdc_trace.sv`: records of 21 bits in a 64-entry buffer on clk_bus, taken 2 clk_bus
after the qualified strobe rises; the write pointer and the read pointer cross as Gray codes.
A full buffer drops the newest record. Each record leaves as three bytes, one every 4400
clk_sys, so the 16-byte FIFO of `uart_route` never overflows.
Logged: every write to the controller, every status read, and for a run of data reads one
summary (the count, the first four bytes, the last byte; logged when the next write or status
read ends the run). Writes to #FF are logged only 8 in a row (the TR-DOS beeper at 02BE toggles
bit 3 of it in a loop). The taps are read-only wires added to `profi.vhd` by `PROFI_REWRITES`
(`DBG_FDC_*`).

## Tests

`sim/run_tb_fdc_trace.sh` (the record format, the dedup of status reads, a burst longer than
the buffer), `tools/fdc_trace.py`'s decoder is exercised by the same bytes by hand.

## The PC flight recorder and the beacon (2026-11-20)

`rtl/host/pc_trace.sv`: when `fdc_trace` sees a run of >= 512 data reads end (the loader has
read a sector), the next 4096 opcode fetches are stored as {address, opcode} and sent out on
the same UART byte port once `fdc_trace` is idle, as `'P' 'C'` followed by 4096 records of
address high, address low, opcode. One shot per switch-on. `sim/run_tb_pc_trace.sh` covers it.
`tools/fdc_trace.py` does not decode the `PC` section yet; the bytes can be read with a few
lines of Python (the capture that located the AMS hang is how the TR-DOS first-fetch paging
bug was found).

`rtl/host/core_beacon.sv`: a heartbeat for a core that does not come up (no video sync). One
`S<ff> <bus> <mem> <vid> <vs> <cpu> <seq>` line every 128 ms on a separate UART line, with
the toggle counts of the main clocks, so a dead clock domain shows `0000`. It is compiled in
but off: `localparam BEACON = 0;` in `Karabas_Profi.sv`; set it to 1 for a build hunt.
`sim/run_tb_core_beacon.sh` covers it.

## Related benches

`sim/run_tb_rom_entry.sh` (ROM entry at TR-DOS #3Dxx and the DivMMC AUTOMAP traps against the
SDRAM latch time), `sim/run_tb_fdd_ams.sh` (AMS.fdi through the FDD model),
`sim/run_tb_jtopl_eg_rate.sh` (jtopl envelope rates).
