# Stage 5 results (the serial channels on the HPS UART)

Board run on build 75, 2026-11-17. Simulation gates first, then the board.

## What is in the tree

`rtl/host/uart_route.sv` is the channel mux between the machine and Main_MiSTer's
`/dev/ttyS1`: the ESP channel is a wire pass-through (the software's baud), the USB
channel is bytes over the MCU link (`mcu_emu` carries `CMD_UART` both ways) through a
fixed 115200 baud 8N1 serialiser, and MIDI (`uart_mode == 3`) keeps priority with
exactly `mt32_mix`'s line. The OSD item is `Serial channel,ESP,USB` (`status[36]`,
row 18). `CONF_STR` header is `UART115200:31250,MIDI`.

## Simulation gates

|Gate|Command|Result|
|---|---|---|
|Python tools|`python3 -m unittest discover -s tools/tests`|`Ran 121 tests ... OK`|
|Upstream untouched|`tools/check_upstream.sh`|`check_upstream: OK`|
|`uart_route`|`tools/sim.sh sim/run_tb_uart_route.sh`|`tb_uart_route: PASS`, 21 cases, 29 mutants, 28 killed, 1 equivalent (`m18`)|
|`mcu_emu`|`tools/sim.sh sim/run_tb_mcu_emu.sh`|`tb_mcu_emu: PASS` on the final tree (~16 min)|
|`mcu_input`, `mt32_mix`|`run_tb_mcu_input.sh`, `run_tb_mt32_mix.sh`|PASS, PASS|
|Everything|`tools/sim.sh sim/run_all.sh`|24 passed, 0 failed|
|Build|`tools/build.sh`|build 75: `build: exit 0`, `check_timing: OK`, worst setup slack +0.244 ns (`clk_mem112`)|

## Board run (build 75)

Board 192.168.1.15, menu core idle at the start (`/tmp/CORENAME` = `MENU`), `menu.rbf`
restored at the end (`/tmp/CORENAME` = `MENU` again). The build is
`/media/fat/_Computer/Karabas_Profi_20261117b.rbf` (SHA-1 equal to the local
`output_files/Karabas_Profi.rbf`). One MGL and one TR-DOS disk per program
(`s5-zxuno`, `s5-esp`, `s5-usb`, `s5-dbg`, drive A, `type="s"` index 4), the walk is
`tools/board/zx.py trdos <mgl>` (GO menu, 4 Down, Enter, no typing). The BASIC programs
were tokenised by `tools/zxtap.py` and written as the disk's `boot` by `tools/mk_disk.py`.

The Linux side was a small Python probe on the board (`stty -F /dev/ttyS1 115200 raw`,
then read and log with timestamps; once the 21-byte string had arrived it waited 8 s and
sent 12 bytes, one every 0.4 s). **`uartmode` and `user-startup.sh` were not touched**, and
no UART mode was picked in the OSD: the probe set the tty speed itself. The machine's
screen came from the daemon's own screenshot.

The BASIC programs: TX `KARABAS-TX-0123456789` (21 bytes), print `tx done`, then read 12
bytes and print them. ZXUNO UART: select `OUT 64571,198/199` (`#FC3B`), data `OUT 64827`
(`#FD3B`), status `#C7` bit 6 = TX busy, bit 7 = byte received. ZiFi API:
`OUT 51183,241` (`#C7EF`, API on), the FIFO registers `#C1EF`/`#C0EF` (ESP) and
`#C3EF`/`#C2EF` (USB RS232, selected by reading its FIFO register), data `#BFEF` (49135).

### Checks

|Row|Pass condition|Result|Shot / log|
|---|---|---|---|
|ESP channel TX (ZXUNO UART)|the tty reads the 21 bytes byte-exact at 115200|PASS: `KARABAS-TX-0123456789`, 21 bytes in 0.3 s|log below|
|ESP channel RX (ZXUNO UART)|12 bytes written to `ttyS1`, read through the UART status/data registers and printed|PASS: `RX-ESP-OK-12` on the screen, `rx done`|`esp-zxuno-uart.png`|
|USB channel TX (OSD `Serial channel` = USB, ZiFi RS232 FIFO)|the tty reads the 21 bytes byte-exact|PASS: `KARABAS-TX-0123456789`, 21 bytes, 0.04 s apart (the program paused 2 frames per byte, see finding 2)|log below|
|USB channel RX|12 bytes written to `ttyS1` reach the machine through the MCU link|PASS: `RX-USB-OK-12` on the screen, `rx done`. The first byte went into an empty queue and arrived|`usb-channel.png`|
|Channel select is real (control)|the same USB program on the ESP channel puts nothing on the tty|PASS: 0 bytes in 70 s, the machine reached `tx done`|`usb-program-on-esp-channel.png`|
|Row 18 is `Serial channel`|the walk (Home, 18 Down, Enter, Home) toggles the item|PASS by effect: after it the USB program's bytes reached the tty, before it they did not. The OSD itself was not captured (the walk is the one `zx.py fire` uses)|none|
|No tty reader|nobody on `ttyS1`: the machine does not stall|PASS: the ZXUNO program printed `tx done` with no reader attached|`no-reader.png`|
|The setting does not persist|a reload through the MGL starts on ESP|OBSERVED: the USB program sent nothing after a reload; there is no `Karabas_Profi*` file in `/media/fat/config`, so the owner's saved settings were not changed|-|

Probe log of the ESP TX run (timestamps are seconds after the probe started; the core
boot took 34 s of that): `34.2s rx 'K'` ... `34.5s rx '9'`, then `47.4s sent
'RX-ESP-OK-12'`. Every byte of the 21 arrived, in order. The USB run: `81.7s rx 'K'` ...
`82.6s rx '9'`, `95.4s sent 'RX-USB-OK-12'`.

### Findings

1. **The USB channel works both ways on the board**, including the first byte into the
   empty `mcu_emu` queue (the inferred-RAM concern of the review): `R` of `RX-USB-OK-12`
   arrived and was printed first.
2. **The ZiFi API loses bytes when the program writes the FIFO back to back.** With
   `FOR i...: OUT 49135,CODE s$(i): NEXT i` (no pause) only 4 of 21 bytes reached the tty
   (`A A A -`, every other byte of `KARABAS-` and nothing after the eighth;
   `zifi-esp-fast-writes.png`, `tx done` was printed so the machine did not stall).
   With `PAUSE 2` between the writes all 8 of 8 (`A`..`H`) arrived in one run and all 21 in
   the USB run. The ZXUNO UART, which uses the same `esp_tx` wire through `uart_route`,
   carried 21 back-to-back bytes cleanly, so the wire path is not the suspect; the cause
   is in the upstream ZiFi write handshake (`zifi_usb.vhd`, `zifi_wr_allow` and the
   `zifi_fifo_tx_wr_req` pulse) and was **not investigated or proven**. A real ZiFi
   driver would poll the FIFO's free count; this one did not.
3. The probe saw no junk byte when the core was loaded with the probe already open: the
   line idles high through the load.
4. `/tmp/UART_SPEED` still read 31250 from the earlier MIDI session; the machine's bytes
   reached the tty anyway, which shows `uart_mode != 3` (Main's mode was not MIDI) and
   that `uart_route` does not depend on the speed Main wrote.

### Closed untested

* **MIDI unchanged.** No MidiLink listener was set up; cited from `tb_mt32_mix` (PASS)
  and the `uart_mode == 3` priority cases of `tb_uart_route`.
* **Switching the channel while bytes are in flight.** Simulation only (`switch_mid_byte`
  and the channel-race cases of `tb_uart_route`).
* **The UART modes** (PPP, Console, Modem...): what Main does with `/dev/ttyS1` in each
  was not driven; the README states these facts as source-derived.
* **Baud other than 115200**, ZiFi RX from the ESP wire, and whether ZiFi software needs
  `dll/dlm` honoured: not tested (the USB serialiser is fixed 115200; `dll/dlm` are ignored).
* **`.rbf` size/timing on other machines**: not applicable.

### Not changed on the board

`menu.rbf` restored, `/tmp` files of the probe removed. Left on the board (our own, new
names): `Karabas_Profi_20261117b.rbf`, `s5-*.trd` and `s5-*.mgl` in
`/media/fat/games/Karabas_Profi/`.
