# Stage 4b board results (SD card and IDE images)

Board: DE10-Nano MiSTer at 192.168.1.13. Date: 2026-11-09/10.

| build | what it was |
|---|---|
| 48 | first compile of the storage top (four slots, `img_src`, `sys/sd_card.sv`); `check_timing: FAIL 2 problems` |
| 49 | the same sources with timing closed |
| 50 | hold the machine's start until the disk mounts settle (`mounts_settled` into `mcu_emu`) |
| 51 | build 50 with the tape's mount taken out of the settle counter; abandoned (the settings file was put back under the running fitter) |
| 52 | build 51's sources again |

How it was driven: `load_core` with one MGL per check (absolute `<file>`
paths, `<file type="s" index="N" path="..."/>`, N = 0 tape, 1 SD card,
2 IDE 0, 3 IDE 1), the 16-byte status file
`/media/fat/config/Karabas_Profi.CFG` for the OSD settings that have to
be set before the machine boots (byte 0 the ROM bank, byte 1 the turbo
value, byte 2 bit 0 DivMMC), the Karabas GO menu stepped with the XT
keyboard, the OSD opened on the remote's `Home` button, stepped one
screen-checked step at a time and fired with `enter`, and the HDMI capture
card for every screenshot (MiSTer's own screenshots do not include the
OSD). The tape programs are played with the OSD `Tape play/pause` trigger
from the 128 ROM's Tape Loader screen, as in stage 4a.

## The boot problem, and what it is not

The Karabas GO loader sometimes stops on its own screen: the logo, the
Drive line and no menu, and it stays there (`boot-sd-card-hang.png`; the
same frame with only the tape mounted, `boot-tape-only-hang.png`, and with
no `<file>` at all, `boot-no-image-hang.png`). Over the session it
happened with every kind of MGL, files or not - 2 of 4 boots with no file
mounted, 2 of 4 with the card - so it is not a property of the mounts: it
is a coin flip at power-up. A card image of zeros boots and shows
Drive: CF (`boot-sd-blank.png`); when the machine does keep the Drive
line it reads `Drive: SD`, and the SD icon in the corner is lit, so the
ROM is repeating a card access that never succeeds.

What was ruled out:

| Suspect | How it was tested | Result |
|---|---|---|
| the disk mount landing mid-probe (a mount resets `sd_card`'s sector pointers) | build 50 holds the machine's start for 1.34 s after the last disk mount; `tb_mcu_emu` pins the hold | build 50 and 51 still hang; the fix is kept (it removes one real source of nondeterminism) but it does not cure the fault |
| the card image's filesystem | the same 16 MiB image with its root directory zeroed (valid FAT16, no files) | still hangs |
| the kernel of the image (MBR, partition, FAT) | a 16 MiB image of zeros | boots, Drive: CF |
| the tape being mounted | tape-only MGL | hangs |
| the mounts at all | a core loaded with no `<file>`, four boots | two show the menu (`boot-no-image.png`), two stop on the Drive line (`boot-no-image-hang.png`) |
| the SD emulation's sector stream (CMD18 / multi-sector reads) | `tb_sd_spi`'s new `read_multiple` case: sectors 4 and 5 in one CMD18 stream, the written sector 2 read back afterwards | passes, so the card and the HPS-side byte transport are sound when clocked like the bench clocks them |
| the machine's own SPI cadence | a scratch variant of `spi_bit` that samples at the SCK falling edge, as `zc_spi` does (SCK idles low, so every byte starts on a rising edge) | **fails**: the card's 512 data bytes come back wrong (`0x00, 0x83, 0x05, 0x88, 0x0a, ...` where the image holds `0x5c, 0x61, 0x66, 0x6b, 0x70, ...`) |

The two failure modes share a cause, and it is a race on the SCK falling
edge. `zc_spi` (upstream) shifts its receive byte in on the clk_bus edge
at which SCK falls, and `sys/sd_card.sv` drives MISO on that same falling
edge from `clk_spi`. Both work on the same edge, so the machine's sample
either takes the bit the card drove at the *previous* fall (correct) or
the bit it drives at this one (one bit early), depending on which edge
arrives first - and since `clk_spi` here is `clk_sys` (50 MHz) while SCK
comes from the machine's 28.125 MHz clock, the outcome can differ from
one power-up to the next. The card's own header asks for at least two
`clk_spi` clocks per SCK phase for this reason; the ratio alone does not
remove the collision, which is why the fix has to be in the glue: sample
the card's MISO on the SCK *other* edge (the rise, half a phase before
the machine's sample) so the bit is settled when the machine takes it.
That also explains why `tb_sd_spi`'s committed bit-banger never sees it -
it takes `miso` just before `sck` falls, one `clk_sys` ahead of the card's
drive, so it always reads the settled bit - and
why the fault looks like a coin flip at power-up rather than a hard
failure.

The next step is an asynchronous reproducer: SCK from a second clock
(28.125 MHz, the machine's `clk_bus`) instead of from `clk_sys`, which is
what turns the same-edge collision into a coin flip, with `zc_spi`
itself as the host so the machine's exact strobe protocol is measured
rather than approximated. With that in place the fix - a shim that
latches the card's MISO on the SCK rise, or the card's clock phase - can
be measured before it is compiled.

Not tested yet, because they need the machine to reach its menu:

- every IDE row (`hdf.tap` + `test.hdf` on IDE 0, `hdfw.tap`'s write,
  IDE 1 on slot 3) — the boot coin flip can be retried with `load_core`
  until the menu appears, so these rows stay reachable once the boot is
  deterministic;
- every SD row (DivMMC on, NMI, the esxDOS browser, `LOAD "TEST.BAS"`,
  `SAVE "OUT.BAS"`, the read-only row).

## Findings for a future script

- The machine only reaches the menu on some boots with a file mounted;
  the same MGL flips between "menu" and "Drive line, no menu" across
  `load_core` calls. A board script must capture the screen after the
  boot and retry, never sleep and assume.
- MiSTer's own screenshot API does not include the OSD; the OSD is only
  visible on the capture card.
- The OSD reopens on the last item used, so a scripted walk has to go to
  the top first, and it must capture and check the highlighted row after
  every press: a burst of presses is partly dropped, and a mis-aimed
  `enter` changes a setting (the ROM Bank item reboots the machine into
  another ROM).
- The 16-byte `.CFG` file has to be written before `load_core`: the
  DivMMC row needs byte 2 bit 0, the turbo rows need byte 1 (00 off,
  01 2x, 02 4x, 03 8x).
- Aiming the OSD by the highlighted row's pixel position is not reliable
  enough on its own: the list scrolls once the highlight passes the last
  visible row, a dropped press leaves the position unchanged, and the
  capture's scale follows the machine's video mode. `osd-highlight.png`
  shows a walk that was aimed at `Tape play/pause` landing on the item
  below it. A scripted walk needs the row's *label* checked (the OSD's
  font is fixed, so a small bitmap check is enough), not only its
  y-position.
- Card select, the tape trigger and the OSD Enter all fire (Enter on a
  listed `ROM Bank` value reboots the machine into another ROM), but a
  `Tape play/pause` trigger fired this way left the 128 ROM's Tape Loader
  screen idle, for `hello.tap` as well as for `hdf.tap`. That is one more
  reason to fix the row aiming before trusting a tape-driven row.

## Simulation gates

| Gate | Result |
|---|---|
| `tools/sim.sh sim/run_tb_sd_spi.sh` | `tb_sd_spi: PASS` (polarity, init_and_read, write_block, read_multiple, eject_mid_command) |
| `tools/sim.sh sim/run_tb_mcu_emu.sh` | `tb_mcu_emu: PASS` (with the `mounts_settle` case) |

## Builds

| Build | Result |
|---|---|
| 48 | `check_timing: FAIL 2 problems` |
| 49 | `build: exit 0`, `check_timing: OK` |
| 50 | `build: exit 0`, `check_timing: OK` (RBF on the card during the boot tests) |
| 51 | abandoned: `build: exit 3` — the `.qsf` was reverted while the fitter ran ("settings file changed outside of Quartus"), not a source error |
| 52 | `check_timing: FAIL 1 problem`: setup −0.186 ns on a PLL output counter clock. The one-line difference from build 50 (the tape left out of the settle counter) was reverted rather than chased through the fitter: build 50's sources are the committed ones and their RBF is what the board runs. |