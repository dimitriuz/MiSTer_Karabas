# Stage 4c results (the VG93 floppy controller and its drive model)

The board run is the last section (build 73, 2026-11-17). Before it, what was proven
was simulation, and the things a future script has to know about `hrdy_fdc` - both
measured, none of them inferred from a datasheet.

## What is in the tree

`rtl/disk/floppy.sv` is the drive: one per slot, on `clk_bus`. It turns the
controller's flux in and out (`fdc_rdata` pulses, `fdc_index` for 500 ticks of a
100 000-tick revolution, `fdc_tr00`/`fdc_wprt` out, STEP/dir in), encodes and
decodes MFM with integer cell counts (`cell_num`/`cell_den`, no `real`), asks the
store side for `{drive, side, track}` on a toggle handshake, and hands over a
written sector with `wr_tgl`/`wr_info`. It patches nothing in the shared upstream
blocks: `hrdy_fdc.v`, `fdd_glue.v` and `vg93_*.v` are driven as they are, and
`tools/check_upstream.sh` stays `OK`.

`sim/tb_floppy.sv` is its customer: the real `hrdy_fdc` + `fdd_glue` + `vg93_*`,
the CPU-side tasks from the upstream `tb_hrdy_fdc.v` with every guard converted to
an edge count, a store model (four track buffers, one per drive and side, plus the
written-sector buffer, both `altsyncram_model`) and a flux decoder that reads back
what the model wrote. `sim/run_tb_floppy.sh` compiles the six upstream speed/CPU
combinations and runs them at the same time; the last line is the verdict.

## Simulation gates

|Gate|Command|Pass condition|Result|
|---|---|---|---|
|Python tools|`python3 -m unittest discover -s tools/tests`|`Ran 104 tests ... OK`|OK|
|Upstream untouched|`tools/check_upstream.sh`|`check_upstream: OK`|OK|
|Stub fails|`sim/run_tb_floppy.sh` against a `floppy` stub with `fdc_tr00` tied high, no flux, no requests|`+CASE=1` fails on the step count, the step period and the track the drive asked for, so the bench really reaches the controller|`FAIL restore (3 checks failed)`, `0 requests`|
|Every case alone|`+CASE=<n>`, one combination|each of the 14 cases prints `PASS <case>`|every case passes in the matrix below, which runs all 14 in each combination; `+CASE=10/12/13` also run alone on 4/225|
|Mutant: tick-gated stream drop|`floppy.sv` with `active` dropped only on a cell tick, `+CASE=12`, 4/225|`side_flip` fails|FAIL: `no byte of the side that was left got 256 want 0`, `the read ends record-not-found got 0 want 1`|
|Mutant: drive C/D as the held drive|`floppy.sv` without `selected` in `stream_on` and without `!no_drive` on the step, `+CASE=13`, 4/225|`no_select` fails|FAIL 6 checks: B's head moved 8 to 11, 1 index, 48554 flux pulses, 3 requests|
|Mutant: no echo check|`floppy.sv` with `trk_ack[8:0] == req_sent` deleted, `+CASE=10`, 4/225|`track_not_ready` fails|FAIL: `and the drive is not streaming got 1 want 0`|
|The matrix|`tools/sim.sh sim/run_tb_floppy.sh`|six times `tb_floppy: PASS`, verdict last|`tb_floppy: PASS`: 14 of 14 cases in each of the six combinations (4/225, 14/675, 8/459, 28/1377, 8/441, 28/1323), 73 min wall, 2026-11-13|

The cases: `restore` (RESTORE at track 0 steps not at all, a SEEK with the target in
`#7F` steps, the return steps 3 ms apart and lands on 0 with TR00), `poll` (the
TR-DOS `#3FD5` loop: 416 clk_bus clocks a turn within 3 % at 7 MHz, no WAIT at
3.5 MHz), `read_sector`, `write_sector` (256 bytes, `wr_info` = drive 0 side 0 track
0 C=0 H=0 R=1 N=1, the flux decoder reads back the mark, the bytes and the CRC),
`read_after_write` (the buffer patched from the capture reads back), `drive_b` and
`swap`, `side1`, `wprt` (the write-protect bit, and no `wr_tgl` at all), `bad_crc`
(RNF **and** CRC error after six turns, nothing written), `track_not_ready` (filler
while the store has nothing, an answer with the wrong echo does not arm the stream,
the right answer does), `side_flip` (the side flips just after an index and the store has not answered:
the read gets nothing, never the sector of the side that was left; after the answer
side 1 reads), `no_select` (with the motor down the step pulses that arrive on a cable
with `FDC_DS == 00` - counted on the wire - are taken by the drive that is held and
never by drive A; with the motor up and #FF bits 1:0 = 1x, drive C/D, nothing streams,
no head moves and no store request goes out), `pend_drop` (a second written field while one waits for its ack
is dropped, and after the answer a new one is offered) and `no_motor`.

## The chip, for whoever writes the next test

* A **SEEK takes its target from the DATA register `#7F`**, not from the sector
  register as a 1793 does. `0x08` RESTORE, `0x10` SEEK, `0x20`/`0x28` STEP,
  `0x30`/`0x38` STEP with the track updated, `0x18` SEEK with head load.
* TurboFDC: **one step every 3 ms** (84 000 clk at 28.125 MHz), and a RESTORE that
  starts at track 0 legitimately produces **no step at all**.
* `hrdy_fdc` ties `.READY(motor)`: **READY is the chip's own head-load output**, so a
  read issued while the head is unloaded ends at once, not-ready. The head is put on
  the track by a RESTORE (or by a command with the head-load bit, `0x18`).
* **A type I command without the head-load bit drops HLD when it ends**, and HLD is the
  chip's READY: after a plain `0x10` SEEK every command issued next ends at once with
  status `8x` (not-ready), having read nothing, and the drive - which only turns under a
  loaded head - shows no index either. Seek with `0x18` and step with `0x28` whenever the
  drive has to keep working after the move.
* `FDC_DS[0] = motor & (#FF bits == 00)`, `FDC_DS[1] = motor & (bits == 01)` and
  `motor` is the head-load line, low between commands - so **a seek steps a drive
  whose select lines are down**. Measured on the wire: a `SEEK` on a freshly selected
  drive emits all five pulses with `FDC_DS == 00` (`no_select` counts them and fails
  if none arrived). A drive model therefore gives the step to the drive it is
  **holding**: demanding the select line to be up means no head ever moves, and
  falling back to drive A walks A's head and asks the store for A's track on every
  head load. What must never happen is a step, or a store request, naming a drive
  nobody chose. The other state with both lines down is the **motor up** one: #FF bits
  1:0 = 1x is drive C or D, which this machine does not have; there nothing streams and
  no step moves a head (found by the second review: the first version streamed the
  held drive as C).
* The drive drops its stream on the **next clock** after a request goes out, not at
  the next cell tick: the request/answer mismatch lasts one clock (the second review
  found the tick-gated drop was effective 1 time in 56, and the bench could not see it
  because its store answered 6 clocks later; `side_flip` now withholds the answer).
* Selecting a drive is not the same as reading it: the drive that answers is the one
  whose select was up when the command started, and between commands that is nobody.
* The store request is **re-asked at the index** the drive stands on: the payload that
  reports a just-issued seek can only be sampled after an index (up to 200 ms).
* A sector that never appears is answered after **six turns of the disk (1199 ms)**,
  with RNF (`10`) or RNF + CRC error (`18`) if an ID was read and did not check.
  Until then the command is simply still running.
* **INTRQ is taken by an access to the status / command register** (`vg93_status.v:14`);
  a peek at `#FF` shows the pin and clears nothing, and one access is not always enough -
  the pin can rise again as the command's last microword ends. The bench therefore takes
  it until it stays taken (`clear_intrq`) before every READ and WRITE.
* **Status bit 7 is not-ready, not busy** (`mr_s || !ready_seen`, and `READY` is the
  head-load line): a status read after a command has ended reads `8x` whatever happened,
  because the head-load has dropped. The answers are the low bits - `0x10` record not
  found, `0x08` CRC error, `0x40` write-protect, `0x01` BUSY - and while a command is in
  flight the status says nothing about the flux, which is what a "did the drive switch to
  another buffer" check has to look at instead.
* The write CRC the chip puts on the wire is CRC-CCITT over 3×`A1`, the data mark and
  the data; the model, the bench's independent decoder and the bytes on the wire agree.
* `altsyncram_model` registers its read address, so a reader must present the address
  one clock before sampling `q_b` (three clocks a byte). A one-clock-short loop returns
  the sector shifted by one byte and looks exactly like a DUT bug.
* Guards in these benches count **edges**, never `$time` differences: 32-bit truncation
  and broken 64-bit time arithmetic in deep Icarus runs make the latter silently never
  fire.

## Budgets

One combination is ~4 s of simulated disk time; ~2.4 s of that is the two reads that have
to fail, because of the six-turn search above (the bench no longer walks to an index that
cannot come while the head is unloaded, which used to add 1.3 s per command). The six combinations run at the same time and take
**73 min of wall time** together (measured 2026-11-13). `run_all` is
its old ≈ 50 min plus the floppy bench.

## Board run (build 73, 2026-11-17)

Board 192.168.1.15, menu core idle at the start (`/tmp/CORENAME` = `MENU`), `menu.rbf`
restored at the end. `Karabas_Profi_20261117a.rbf` is build 73. One MGL per check
(`type="s"` index 4/5 for the drive slots, `type="f"` index 1 for the FDI entry), the
walk is `tools/board/zx.py trdos <mgl>` (GO menu, 4 Down, Enter, no typing), shots are
the daemon's own screenshot (the HDMI capture feed was down, see "Not run").

### Checks

|Row|Pass condition|Result|Shot|
|---|---|---|---|
|TR-DOS boot, auto-run (A)|`boot` prints `trdos ok`, `saved`, report `0 OK, 40:1`|PASS|`trdos-boot-write.png`|
|Write (A)|the card's image gains `out.C`, 256 bytes equal to `0..255`; its SHA-256 differs from the PC copy|PASS (`out.C` read back with `mk_disk.py cat`)|`trdos-boot-write.png`|
|Drive B alone|TR-DOS starts on A, A is empty: a clean error, no hang|PASS: `Disc Error Trk 0 sec 9`|`drive-b-only-disc-error.png`|
|Drive B write|A has a boot that selects `*"B"` and saves; the file lands on B, A's image is unchanged|PASS: `outb.C` (256 bytes) on B, A still `boot.B` only|`drive-b-write.png`|
|Read-only (slot 4, chmod 444)|the SAVE is refused by TR-DOS, the file's SHA-256 is unchanged|PASS: `Read Only Trk 0 sec 2`, hash unchanged|`read-only-write-error.png`|
|FDI download (F1)|a real TR-DOS FDI (`mk_disk.py fdi --from-trd`) boots and runs; a write is refused|PASS: boot ran to line 30, the SAVE hit the forced write-protect; file on the card unchanged|`fdi-boot-write-protected.png`|
|FDI pattern disk (F1, `test.fdi`)|the download and mount do not wedge TR-DOS|PASS: shell prompt `A>`, no `boot` (the fixture has no catalog)|`fdi-pattern-disk-shell.png`|
|Turbo 8x (OSD `Turbo` set on the GO menu, then TR-DOS 128K)|boot, read and write as at 3.5 MHz, no wedge|PASS: `trdos ok`, `saved`, `0 OK, 40:1`; `out.C` on the card is `0..255`|`go-menu-turbo-8x.png`, `turbo8x-boot-write.png`|
|OSD row map|`Tape play/pause` is 15 Downs below `Video`|PASS: 16 Downs land on `Tape previous block`; Floppy A 10, B 11, A FDI 12, B FDI 13, Disk layout 14|`osd-row-map.png`|
|CP/M image (slot 4)|TR-DOS cannot use it: a clean error, no hang|PASS: `Disc Error Trk 0 sec 9`|`cpm-disc-error.png`|

### Findings (traps for the next script and the next fixture)

* **The catalog entry layout in the plan, and so in `mk_disk.trd`, was wrong, and the
  simulation could not see it.** Real TR-DOS: bytes 9-10 start/param (a B file's program
  length), 11-12 length, 13 sector count (one byte), 14 first sector, 15 first track.
  The fixture had track at 9 and left 15 at 0, so on the first board run TR-DOS found no
  `boot` (`first-boot-no-catalog.png`: an empty editor, image untouched). Every bench
  agreed with the fixture because both came from the same text. Fixed in
  `a2488b5`: the one reference that mattered was the real ROM.
* **Plain BASIC `SAVE` goes to the tape.** A TR-DOS command from a program is
  `RANDOMIZE USR 15619: REM : <command>` with keyword tokens (`SAVE` f8, `CODE` af,
  `*` for a drive) and plain digits inside the REM; `USR 15616` opens the shell and does
  not return. `mk_disk.boot_program()` builds that line by hand because `zxtap` writes a
  REM body as text. Typing into the `A>` shell through `zx.type_text` does not work
  (keywords are several cells), so every check is a `boot` program.
* The plan's "boot from B alone" cannot work: TR-DOS reads A first. The B row is a boot
  on A that selects drive B.
* The plan's "FDI fixture's `boot`" did not exist; `mk_disk.py fdi --from-trd` builds a
  real one (`test_fdi_from_trd`).
* `tools/board/mister.py` pointed at the old board address; `MISTER_HOST` now overrides it
  (default `.15`).
* A `chmod 444` file on the card is enough for the read-only row (Main sets the drive
  write-protect from the mode bits). Do not append to such a file as root to "test" it:
  that is exactly what broke the first attempt (a size that is no valid geometry shows as
  `Disc Error`).
* The owner's ffmpeg publisher holds `/dev/video4`, so `mister.Capture` (direct v4l2)
  fails with "Device or resource busy" while the RTSP feed is up, and the feed itself
  answered 404 during the run. Use `mister_shot.sh` when the feed is alive.

### Not run

* **Pentagon vs 48k** (the other half of plan step 8): the Video submenu walk was not
  done. The `tb_floppy` six-combination matrix (DS80, speed, turbo) is the evidence.
* **CP/M with `Disk layout = CP/M`** and booting CP/M itself: no owner-supplied system
  image. `test.cpm` (819200 bytes) is unambiguous for Auto, and TR-DOS gave a clean error
  on it.
* **`.scl` mount:** no owner-supplied `.scl`; the conversion is Main's.
* **`swap` (port `#028B` bit 3):** no TR-DOS utility sets it; the sim case `drive_b` is
  the evidence.
* **Format Track / Write Track:** not implemented (README limitation).
* The drive B check was by write, not by a catalog read; `CAT 1` from a program gave
  `C Nonsense in BASIC` and was not pursued.

### OSD driving notes (second session, capture feed back)

* Left/Right on the gamepad **switch OSD pages** (Core <-> System, which holds `Reset
  settings` and `Save settings`); a value is cycled with `Enter` (Turbo: Off, 2x, 4x, 8x).
  The first `home` after a core load can open the System page; close it and reopen.
* `mister.read_bar` returns `None` on the RTSP frames (the highlight is light pink here,
  not the old bar colour), so the row was read by eye from the shot. The row count itself
  matches `TAPE_ROW = 15` and `mister.ROWS`.
* After a turbo change the picture is black with speckle for a few seconds (the video
  resync); a screenshot 10 s later is clean.
* `mister.Capture` (direct v4l2) cannot open the card while the owner's ffmpeg publisher
  runs; use `MiSTer_docs/tools/mister_shot.sh` for the RTSP feed.

### Gates

`python3 -m unittest discover -s tools/tests`: 118 tests OK. `tb_fdd_img` PASS after the
catalog fix. `sim/run_all.sh` (before the fixture fix, which touches no RTL): 23 passed,
0 failed. Build 73: exit 0, `check_timing` OK, worst setup slack +0.209 ns (`pll_hdmi`),
77 % ALM.
