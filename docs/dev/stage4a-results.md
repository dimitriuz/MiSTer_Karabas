# Stage 4a board results (tape files)

Board: DE10-Nano MiSTer at 192.168.1.13. Dates: 2026-11-08/09.

| build | what it was |
|---|---|
| 39 | first import of the ZX players (`tape.sv`, `tzxplayer.vhd`) |
| 40 | OSD trigger pulses held for 16 clocks |
| 41 | data-block lead-in raised to 8064 pulses |
| 42 | debug: `tape_audio` on `AUDIO_L`, to decode the HDMI capture |
| 46 | TAP/TZX streamed through `rtl/tape/tape_conv.sv` (this stage's fix) |
| 47 | block navigation for the converted stream (`Tape previous/next block`) |

How it was driven: `load_core` with an MGL per tape (absolute `<file>`
paths, Main resolves relative paths against the core's game dir), the
16-byte status file `/media/fat/config/Karabas_Profi.CFG` for ROM bank and
turbo, and three input paths:

- the Karabas GO menu reads the Kempston joystick: a virtual gamepad
  (MiSTer Companion remote, `{"type":"controller",...}`) steps the highlight;
- the XT keyboard (same daemon, `{"type":"keyboard",...}`) presses Enter to
  activate a menu item;
- the MiSTer OSD is driven from the gamepad (Home opens it, the D-pad
  moves, Enter fires a trigger item, F12 closes it) and watched on the HDMI
  capture card, because MiSTer's own screenshots do not include the OSD. The
  card's feed is one ffmpeg into a v4l2loopback (`/dev/video10`) with two
  outputs: an `xv` window for the owner and `/tmp/live.jpg` for the scripted
  captures; a single reader is all the loopback supports.

Screenshots are in `stage4a-shots/`.

## Checks (build 47)

Every row was run on build 47, the build that ships this stage; build 46 ran
the same tapes with the same converter before block navigation was added.

| Check | Result | Evidence |
|---|---|---|
| `hello.tap`, `LOAD ""`, turbo off | PASS | `Program: hello`, `tape ok` (`hello-tap-turbo-off.png`) |
| the same, turbo 2x | PASS | `tape ok` |
| the same, turbo 8x | PASS | `tape ok`; the tape's own run counter reaches 80 at 8x against 29 at 1x (`hello-tap-8x.png`) |
| `hello.tzx` at 8x | PASS | `tape ok` (`hello-tzx-8x.png`) |
| `hello.csw` at 8x | PASS | `tape ok` (`hello-csw-8x.png`) |
| `sound.tap` | PASS | loads and runs; lists `1 AY0 / 2 AY1 / 3 FM / 4 SAA / 5 OPL / 6 COVOX`, then `STOP statement, 70:1` (`sound-tap-47.png`). The owner heard every one on the earlier build, whose converter output is the same stream |
| `gsquery.tap` at 8x | PASS | `GS status 126`, `Pages 62 err 0` (`gsquery-8x.png`): all 62 General Sound RAM pages checked, no errors |
| `Tape play/pause` | PASS | playing, the border shows the tape signal (cyan/red stripes, `play-border-stripes.png`); fired again it leaves a solid border with the load frozen (`pause-border-solid.png`); a third firing resumes the stripes and the load (`resume-border-stripes.png`). The OSD rows themselves are `osd-tape-items.png`; a mounted tape that is not playing shows the bare loader screen (`tape-loader.png`) |
| `Tape next block` | PASS | skips the header block of `gsquery.tap` (the ROM never prints `Program: gsquery`, `next-block-skipped-header.png`); with `sound.tap` playing, the border leaves its solid data pattern and shows the second block's lead-in (`next-prev-play-border.png` -> `next-block-pilot.png`) |
| `Tape previous block` | PASS | with `sound.tap` playing, the border again shows a lead-in: the block is replayed from its first byte (`prev-block-pilot.png`) |
| LED | not tested | the owner's case hides the USER LED |
| line-in | not tested | no cassette or other audio source on the bench |

## Build 47

`build: exit 0`, `check_timing: OK`. Fitter: 20,260 / 41,910 ALMs (48 %),
27,604 registers, 1,950,234 / 5,662,720 block memory bits (34 %), 42 / 112
DSP (38 %).

Worst slacks (TimeQuest summary, all positive): hold
`pll_hdmi ... output_counter` 0.189 ns; setup `clk_mem112` 0.515 ns,
`clk_mem96` 1.997 ns, `clk_bus28` 8.371 ns, `clk_bus24` 9.851 ns; the
bus28/bus24 removal/recovery paths 1.007 / 1.498 ns. `check_timing.py`
also confirms the four generated clocks were created and no 332174/332049/
332060 sdc warning or 10236/10541 implicit-net warning reaches our sources.

## Simulation gates

| Gate | Result |
|---|---|
| `python3 -m unittest discover -s tools/tests` | `Ran 75 tests ... OK` |
| `tools/check_upstream.sh` | `check_upstream: OK` |
| `tools/sim.sh sim/run_tb_conv.sh` | `tb_conv: PASS` (TAP and TZX each reproduce `zxtap.py`'s `hello.csw`: 17037 bytes identical) |
| `tools/sim.sh sim/run_tb_tape_play.sh` | `tb_tape_play: PASS` (`tap_decode`, `tzx_decode`, `csw_decode`, `ce_1in8_pilot`, `nav` all ok) |
| `tools/sim.sh sim/run_all.sh` | `run_all: 16 passed, 0 failed` |

`tb_tape_play` decodes both TAP blocks out of the player's own
`audio_out` for TAP, TZX and CSW mounts (`tap_decode`, `tzx_decode`,
`csw_decode`, byte for byte against the TAP), checks the turbo-off ratio
(`ce_1in8_pilot`), and fires `prev`/`next` mid-tape and counts lead-in
pulses afterwards (`nav_start`, `nav_next`, `nav_prev`). The run is slow
by nature: the CSW player advances one 44.1 kHz sample per 635 clocks, so
playing the three test tapes in simulation time takes about 35 minutes;
`run_all` budgets for it.

## Why TAP and TZX go through a converter

The imported players failed on this machine (builds 39-41, 2026-11-08):

- `hello.csw` loaded at every turbo; `hello.tap` and `hello.tzx` loaded the
  header (`Program: hello`) and died in the data block with
  `R Tape loading error, 0:1`.
- The failure was in the players, not the file path: `tb_tape_play` decoded
  both blocks correctly from the same bytes, and a debug build (42) that put
  `tape_audio` on `AUDIO_L` decoded the board's own TAP waveform off the
  capture card byte for byte (`00 00 68 65 6c 6c 6f ... 48` for the header,
  `ff 00 0a ... 0d 66` for the data). The ROM read a correct waveform and
  still raised the error, while the CSW player with the same bytes loaded.

So the TAP and TZX players are no longer used for playback:
`rtl/tape/tape_conv.sv` streams a mounted TAP or TZX through the CSW
player that already worked. It writes the same 32-byte CSW v1 header that
`zxtap.py` writes, then one RLE pulse list per block (8064/8063-pulse
lead-in, sync, two bytes per bit, the block's pause), so the player sees
exactly the file `zxtap.py` would have produced. `sim/tb_conv.sv` mounts
`hello.tap` and `hello.tzx` and compares the converter's output with
`zxtap.py`'s `hello.csw`: 17037 bytes identical for both.

Consequences, recorded in the README:

- the players' own TAP/TZX decoders (`tape.sv` mode 0 and `tzxplayer.vhd`)
  no longer reach the hardware; the imported files stay for reference and
  are still compiled;
- TZX support covers standard-speed (0x10) blocks; any other block type
  ends the tape where it starts;
- a converted tape reports itself as unmounted when it reaches the end
  (`tape_ready` drops), so it must be mounted again before replaying;
- block navigation moved with it: `tape_conv` remembers each block's first
  and last source byte, `prev`/`next` jump there and `blk_seek` tells the
  player to restart its RLE parse at the new block. `tb_tape_play: nav`
  checks that the pulses after a jump are the new block's pilot.

## Findings

1. **Keyboard input to the core is unreliable above turbo 1x; the joystick
   is not.** The Karabas GO menu follows the Kempston joystick at every
   turbo setting; the Profi XT keyboard path does not. At 2x, six injected
   `Down` presses landed on `Run TR-DOS 48K` instead of `Run Sinclair 128K`;
   at 8x two to four of six presses were lost. Every arrow press on the
   board is therefore a gamepad press, and only single `Enter` activations
   come from the keyboard. This is the input path, not the tape player:
   the same tapes load at 8x once the menu is navigated this way.
2. **The OSD trigger items need the keyboard, not the gamepad.** Pressing
   the gamepad's OK on `Tape play/pause` brings up MiSTer's hint line
   ("item. Press Esc or F12 to exit") but does not toggle the tape; a
   keyboard `Enter` on the same row does.
3. **The OSD switches to the System page when Up is pressed on the first
   row.** A scripted "20 x Up to be sure" walks onto the System page, where
   the same key counts move through `Button/key remap`, `Video processing`,
   `Save settings`; one such sequence changed `Video processing` and the
   HDMI picture went away until it was set back. Scripts must clamp at the
   first row and check the page after every step. The core page's cursor
   also starts on `Video` every time the OSD opens (it does not remember
   the last row), and Up on `Video` wraps to the bottom of the page
   (`Exit`, `Reset`); a script that assumed the last row was still
   selected fired `Reset` and rebooted the core.
   The cursor is readable on the capture as the row with a white
   background, but the OSD scales with the video mode, so row positions
   from one mode do not hold in another; count keys from `Video` instead.
4. **The capture card has about a second of latency and drops frames.**
   Verifying a key press needs a settle delay and the *last* non-black
   frame, not the brightest: designs that picked the brightest frame of a
   two-second window verified the screen from before the press and produced
   several false "the item did nothing" results during this run.
5. **The tape signal is visible on the border at 1x** (the ULA's border
   follows the EAR level), which makes play/pause and block seek verifiable
   without audio: stripes while playing, solid while paused, and the stripe
   cadence returns to the lead-in after a block jump. At 8x one frame is
   too coarse to show a pattern.
6. **The Profi ROM consumes most of the lead-in**, so a 58-byte TAP
   finishes about a second after the player starts, at 1x. Anything that
   needs to be observed mid-load (play/pause, block seek) has to use the
   bigger tapes (`sound.tap`, `gsquery.tap`), or the OSD has to stay open
   and fire the item twice, one key press apart.
7. `hello.tap`, `hello.tzx` and `hello.csw` load at turbo off, 2x and 8x.
   The player's clock enable is the CPU's own T-state enable, so the turbo
   setting is transparent to the ROM's loader.
8. **A freshly mounted tape stays paused**, so `LOAD ""` shows the
   `Tape Loader` screen with no border stripes and waits forever until
   `Tape play/pause` is fired; there is no timeout and no error. That is
   the intended behaviour (`tape_ready` parks `play_pause = 1`), but it
   reads as a hang: a capture of a flat grey border on the loader screen
   means "not playing", not "the tape is broken". Scripts must fire
   play/pause after mounting.

## Board setup left in place

- `/media/fat/_Computer/Karabas_Profi_build4*.rbf` (39-42, 46, 47) and
  `/media/fat/games/Karabas_Profi/b4*-*.mgl`, one per tape and format.
- `/media/fat/config/Karabas_Profi.CFG` left at all zeros (ROM bank ROMain,
  turbo off, no tape triggers).