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

Reachable now, and partly walked on build 54:

- the IDE row `s4b-hdf0` reaches 128 BASIC and the tape loader
  (`ide-loader-paused.png`: the 128 ROM's `Load """` screen, the tape
  still paused). The row aiming is solved: the gamepad's Home/Mode button
  opens the OSD (a keyboard `Home`/`F12` stopped doing it after the
  `cold_reboot`), and the highlighted row is read from its pixel band on
  the capture - 172 `Video`, 316 `IDE 0`, 332 `IDE 1`, **348 `Tape
  play/pause`**. A later attempt measured 352: the bar is 20 pixels tall
  and the brightest of its rows moves by up to 4 pixels with the row's
  text, so 348 and 352 are the same row; 332 (IDE 1) and 364 (previous
  block) are neighbours and are *not*.
- What that session did not settle is the tape trigger itself. On 2026-11-10, with the
  bar verified on `Tape play/pause` (348), `Enter` left the loader idle on
  build 54 (three presses, `hello`-size tape) **and on build 47** (three
  presses, `hdf.tap`), the build whose stage 4a run has screenshots of a
  playing tape fired the same way. The same session proved `Enter` does
  activate the OSD: it cycled `Joystick L`'s value (and had to be put back
  to `Kempston`), it opened the file browser from a file row, and it fired
  the `Reset` button, which rebooted the core to the Karabas menu.
- The input path is the prime suspect, not the core: the companion daemon
  both drops and **delays** presses in this session. A press usually
  arrives 1-2 s late - an `Enter` meant for `Tape play/pause` changed
  `Joystick L` about two seconds after the command returned, and a burst
  of eight `Down` presses put the bar on `Joystick L` (two rows past) while
  the capture taken right after the burst still showed `Tape play/pause`.
  A scripted fire therefore has to verify the row, wait >=2.5 s, verify it
  again, and only then press `Enter`.
- The trigger RTL is unchanged between builds 47 and 54 (`631cec8`, the
  15-clock hold, `4'hF` counted down); nothing in stage 4b touches
  `status[31]`. If the trigger
  still does not act on a freshly rebooted board with the row verified
  twice, the next instrument is a build that shows `status[31]` and
  `tape.sv`'s `play_pause` on the screen, not more OSD aiming.
- `Enter` does reach `T[]` items on this board: the stage 4a run fired
  `Tape next block` and `Tape previous block` (`T[32]`, `T[33]`) through the
  OSD and the captured borders show the block's lead-in
  (`next-prev-play-border.png`, `next-block-pilot.png`,
  `prev-block-pilot.png`), on build 47, the same RTL as 54 (that `previous`
  restarted the *current* block is the 4a review's finding, not the
  trigger's). `Reset` is an
  `R[0]` row and `Joystick L` an `O[]` row, so those two prove nothing about
  `T[]`; the tape screenshots do. What failed on 2026-11-10 was therefore
  the session's input delivery, not the `T[]` path - and the tape trigger in
  particular has to be re-fired once with the verified-row protocol. If it
  still fails there, the probe build (which shows `status[31]` and
  `play_pause`) is the next step; `T[20] NMI` with DivMMC on is the cheap
  cross-check that this session's `Enter` reaches a `T[]` row at all
  (a second-page row, so it needs the page-2 screen, not the page-1 band
  map).
- **Re-fired on build 55, same session, with the stepwise protocol:** the
  OSD was opened, the bar read at 348 (`Tape play/pause`), left alone 2.8 s,
  read again at 348, and one `Enter` started the tape - `Program: sound`
  on the 128 loader screen behind the still-open OSD
  (`b55-play-fired.png`, 11:24). The row was reached one press at a time,
  each press followed by >=2.5 s and a read of the bar; two presses that
  produced no change were simply repeated. So the stage 4a trigger path
  (`T[31]` -> synchroniser -> 15-clock hold -> `tape.sv`'s `ce`-sampled
  `play_pause`) works on build 55, and the earlier build 54/47 failures
  were the session's input delivery.
- **`Tape previous block` (`T[32]`) re-checked on build 55 too:** from
  `Tape play/pause` (verified) one Down, then `Enter`, mid-load of
  `sound.tap`'s data block - the border showed the tape signal while
  playing (`b55-play-border-stripes.png`), and after the jump the header
  block came back: `Program: sound` printed again and the loader reported
  `R Tape loading error, 0:1`, which is the ROM finding a header where it
  expected data (`docs/dev/stage4a-shots/b55-prev-block-header.png`). The
  `next` direction keeps its stage 4a evidence (the ROM never prints
  `Program: gsquery` after `next` skips the header).
- **IDE 0 walked for the first time on build 55 (2026-11-10 13:00), and it
  fails:** with `test.hdf` on slot 2 (`b55-hdf0.mgl`), `hdf.tap` loads and
  runs but reports `hdf busy` and stops - the ATA status port (240) kept
  bit 7 (BUSY) set for its 1000-poll bound (`ide0-busy.png`). Without any
  image the same tape prints `no hdf` inside the bound and stops cleanly
  (`ide0-no-image.png`), so the *presence* path works and only the mounted
  case hangs on BUSY. Neither `hdf ok RDSK` nor the `hdfw.tap` write check
  has ever passed on this core; step 2 of the 4b board run is open with
  this as its repro. The image on the card still hashes
  `e86a3e44f4ff0d99d4ce6a2ee0fe57eba473277a0dbd662ec7305dcacb20be2a`.
- The OSD's row map on this core page, from `Video` (0): 1
  `MiSTer-pi`, 2 `ROM Bank`, 3 `Turbo`, 4 `PSG Mix`, 5 `Covox`,
  6 `Tape`, 7 `SD Card`, 8 `IDE 0`, 9 `IDE 1`, 10 `Tape play/pause`,
  11 `Tape previous block` (`osd-rows.png`; the stage 4a note that
  `Tape play/pause` is 7 rows down predates the SD and IDE rows). The
  `Video` and `MT32-pi` rows are page headers: one row each, and
  activating one expands the page inline.
- every SD row (DivMMC on, NMI, the esxDOS browser, `LOAD "TEST.BAS"`,
  `SAVE "OUT.BAS"`, the read-only row) and the IDE 1 and write rows.

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
| `tools/sim.sh sim/run_all.sh` | `run_all: 19 passed, 0 failed` |

The full suite was red from `6bea700` (the `mounts_settled` input on
`mcu_emu`) until 2026-11-10: `tb_mcu_input.sv` was not updated, so the port
floated, `mr_ok` never went high, the download's `ioctl_wait` stayed raised
and the bench ran into its own 50 ms timeout (`tb_mcu_input: FAIL timeout`).
It drives `.mounts_settled(1'b1)` now, the fixed value `tb_mcu_emu` uses for
its non-settle cases. The gate was missed because the per-task runs only
listed `tb_sd_spi` and `tb_mcu_emu`; `run_all` is the gate that catches it.

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
| 55 | 54 plus the stage 4a review fixes: `tape_conv.sv` steps to the previous block, and `blk_seek` is held 15 clocks like the OSD triggers. `build: exit 0`, `check_timing: OK`, 826 s; setup 0.419 ns, hold 0.247 ns. The tape triggers re-checked on it: `play/pause` starts the load, `previous block` returns to the header |
## The IDE 0 BUSY hang: what the crossing has to do (builds 55-67)

`hdf.tap` and the status probe (`dbg8.tap`, ATA port 240 = `S`, 241 = error)
on a series of builds narrowed it in this order:

| build | change | `hdf.tap` | why it mattered |
|---|---|---|---|
| 55 | `mnt_q` held until the next mount (a *level*) | `hdf busy` | a level reaches `hdf_ata`, but it re-examines the image every clock |
| 61 | strobe of 1 `clk`, size sampled on the mount edge | `no hdf`, `S=0` | the strobe is not seen; the size sampled on the edge is still 0 |
| 63 | the same, with the bench wires corrected (see below) | `no hdf`, `S=0` | sim green, board still 0 |
| 64 | the size crossed only after it stops changing (settle, 1024 clk_sys) | `no hdf` | fixes the size, not the strobe |
| 65 | plus the strobe held 8 clk | `no hdf` | still nothing at the drive |
| 66 | 65 with `sdc_img_size` hardcoded to 1 MiB | `no hdf`, `S=0` | rules out the size: even a known-good size does not stick, so `hdf_ata` never sees a mount bit at all (or `dev0_en` is 0) |
| 67 | forced: strobe and size from reset | inconclusive | the machine booted to the logo with a striped body on both runs and never ran the tape |

The open question after 66 is which of those two it is: no mount bit at
`hdf_ata`, or `dev0_en` (`sw_hdd`) 0 so `ide_mux` sends the IDE bus to the
CF pins. ATA port 240 reads 0x0000, which is what `hdf_ata` drives while
`!here` (a floating CF bus reads 0xFF), so the HDF path is likely the live
one - but that is inference, not a measurement. The next experiment has to
observe `img_mounted[3:2]` itself - routing it into the OSD or into the
tape's EAR bit and reading it from BASIC is enough.

What build 66 does establish is that a size sampled on the mount edge is
wrong: hps_io raises `img_mounted` on Main's `0x1c` and writes `img_size`
with the `0x1d` commands that follow, so the edge sees the previous size
(0 at the first mount) and the image reads as an eject. Build 55's level
hid this by re-sampling the size every clock until the burst had finished.

**Re-run on build 70 (2026-11-11), with the board driven by
`tools/board/zx.py`:** `hdf.tap` + `test.hdf` on slot 2 (MGL `b70-hdf.mgl`)
loads and runs, and prints `no hdf` again - same symptom as builds 61-66, so
the mount-strobe/size work did not close it. The GO screen says `Drive: CF`
and the loader's own attempt to open `karabas_boot.$c` on the CF then stalls
about 40 s before the menu appears; both are consistent with the HDF being
visible as a device and its sector 0 never arriving, but neither distinguishes
"no mount bit at `hdf_ata`" from "`dev0_en` 0", which is still the question.
The machine-side path of the run is now one command (`python3
tools/board/zx.py all <mgl>`: boot, settle, `Run Sinclair 128K`, `Tape
Loader`, fire play/pause), so the next probe build costs one command, not a
session of key hunting.

`run_all` was re-run on this tree: `run_all: 19 passed, 0 failed`
(6142 s; `tb_tape_play` alone is over an hour, it simulates ~28M clocks of
silence per inter-block pause).

The simulation did not catch either half, and the reason is in the bench:
`tb_img_src` fed `hdf_ata` from the *raw* `img_mounted`/`img_size` instead
of from the engine's `sdc_img_mounted`/`sdc_img_size`, and it wrote the
size *before* the mount. It now drives the drive from the engine's outputs
and writes the size after the mount pulse, like Main; with the settle
removed the bench then fails exactly as the board did (`ident size got 0
want 524288`), so both fixes are covered by `sim/run_tb_img_src.sh`.
