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
no `<file>` at all, `boot-no-image-hang.png`). When it does stop, the
Drive line reads `Drive: SD` and the SD icon in the corner is lit.

Booted three times each, on build 50:

| MGL | menu | stopped on the Drive line |
|---|---|---|
| `sd_blank` (16 MiB of zeros) | 2 | 1 |
| `sd_emptyroot` (valid FAT16, no files) | 3 | 0 |
| `s4b-sd` (`test.vhd`, the populated FAT16 image) | 2 | 1 |

So it is not tied to the image, the filesystem, the tape or the mounts:
it is roughly a one-in-three coin flip at power-up, and the same MGL
flips between the two outcomes across `load_core` calls. An earlier
reading that the populated image "always hangs" was a three-boot sample
that happened to land on the wrong side.

What was ruled out:

| Suspect | How it was tested | Result |
|---|---|---|
| the disk mount landing mid-probe (a mount resets `sd_card`'s sector pointers) | build 50 holds the machine's start for 1.34 s after the last disk mount; `tb_mcu_emu` pins the hold | the hang still happens; the fix is kept (it removes one real source of nondeterminism) but it does not cure the fault |
| the card image's filesystem | the same 16 MiB image with its root directory zeroed (valid FAT16, no files) | boots 3 of 3 |
| the kernel of the image (MBR, partition, FAT) | a 16 MiB image of zeros | boots 2 of 3, Drive: CF when it hangs |
| the tape being mounted | tape-only MGL | hangs (`boot-tape-only-hang.png`) |
| the mounts at all | a core loaded with no `<file>` | 2 of 4 boots show the menu, 2 stop on the Drive line |
| the SD emulation's sector stream (CMD18 / multi-sector reads) | `tb_sd_spi`'s `read_multiple` case: sectors 4 and 5 in one CMD18 stream, the written sector 2 read back afterwards | passes |
| the machine's own SPI cadence (SCK idling low, from the machine's 28.125 MHz clock, MISO sampled at the falling edge) | `tb_sd_spi`'s `async_host` case: the same init and two CMD17 reads driven the way `zc_spi` drives them | **passes**: both sectors come back intact with the card on `clk_sys`, so the card, its buffer and the HPS-side transport are sound in the machine's clocking, and the SPI data path is not the cause of the hang |
| the card's response with no media mounted | `tb_sd_spi`'s `eject_mid_command` case | the card has no timeout: with `img_size` 0 it waits in CMD17 forever and the host has to abort with CMD12. A ROM that probes the card without media mounted and waits for the token will wait forever - which is what the bare boot shows (SD icon lit) |

What is left is the startup path outside the SPI data: the ROM's probe
against a card that `hps_io` mounts some time after the core starts.

Build 50's settle counter did not cover the case it was written for,
because it started at zero: `mounts_settled` was true at power-up, so the
machine's start was released *before* hps_io had mounted anything, and a
mount that landed after the probe had begun could still stop it - the
one-in-three boot. The rule is now in `rtl/host/mount_settle.sv`: 1.34 s
after the last disk mount, and, when no disk mount has arrived at all, 3 s
from power-up so a core loaded without a file still boots (`tb_mount_settle`
pins both windows, that a second mount restarts the window, and that the
tape's slot does not count). Build 53 is that change, and it made the
boots worse (below). Build 54 adds the card's media gate and boots every
time.

Build 53 was tried on the board and made the boots *worse*, which is the
most informative result of the session: eight boots, one menu. With the
start released only after the mount, the card always has media when the
ROM probes it, so the ROM always picks SD (`Drive: SD` on all eight) and
the boot stops there - with the zeros image as well, which build 50 had
booted as `Drive: CF`. The working boots so far were the ones where the
probe did *not* complete: the ROM then fell back to the disks. So the
fault is not the probe and not the SPI data path (the `async_host` case
reads sectors intact in the machine's clocking): it is what the ROM does
*after* it has accepted the card, most likely its own SD driver reading
the volume (the directory), which no bench case covers yet.

Two consequences are already acted on:

- With no file mounted on the card's slot, the card model answers and
  then waits forever for a sector the HPS never sends (CMD17 has no
  timeout), so the probe hangs instead of falling back. Build 54 holds
  the card in reset until a file is mounted (an absent card answers
  nothing, MISO reads 1), which makes a boot with no card deterministic:
  the probe fails, the ROM uses the disks, the menu appears.
- Build 54 (53 plus the media gate) boots to the menu 16 of 16 times,
  with a file on the card's slot included, so the board rows that need
  the menu are open now. The menu it reaches is the ROM's own (`Main
  menu`, `Drive: CF`, the clock); the drive line reads `Drive: CF`
  whenever the card is not the only usable drive.

What is still open, then, is the ROM's own SD driver against this card
model. The next instrument is its command stream on the board (a small
capture FIFO behind the top's `sd_*` pins, read out through an OSD item),
so a boot that stops on `Drive: SD` can be compared with a bench case
that replays the same commands.

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
| `tools/sim.sh sim/run_tb_sd_spi.sh` | `tb_sd_spi: PASS` (polarity, init_and_read, write_block, read_multiple, eject_mid_command, async_host) |
| `tools/sim.sh sim/run_tb_mcu_emu.sh` | `tb_mcu_emu: PASS` (with the `mounts_settle` case) |

## Builds

| Build | Result |
|---|---|
| 48 | `check_timing: FAIL 2 problems` |
| 49 | `build: exit 0`, `check_timing: OK` |
| 50 | `build: exit 0`, `check_timing: OK` (RBF on the card during the boot tests) |
| 51 | abandoned: `build: exit 3` — the `.qsf` was reverted while the fitter ran ("settings file changed outside of Quartus"), not a source error |
| 52 | `check_timing: FAIL 1 problem`: setup -0.186 ns on a PLL output counter clock (a one-line variant of build 50; reverted rather than chased) |
| 53 | `mount_settle` releases the start only after a disk mount (or 3 s): 8 boots, 1 menu - the card always has media when the probe runs, so the ROM always picks SD |
| 54 | 53 plus the card held in reset while its slot has no file: **16 boots, 16 menus**, including 8 of 8 with `test.vhd` mounted (`boot-b54-sd.png`) |