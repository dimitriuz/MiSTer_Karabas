# Stage 4a board results (tape files)

Board: DE10-Nano MiSTer at 192.168.1.13. Dates: 2026-11-08/09. Builds 39
(original import), 40 (trigger hold), 41 (8064 data pilots); the final
non-debug core is build 41 (commit b1fdc7d, top 631cec8).

How it was driven: `load_core` with an MGL per tape (absolute `<file>`
paths, Main resolves relative paths against the core's game dir), the
16-byte status file for ROM bank/turbo, uinput keys (`mkeys2.py`), the
OSD triggers, `screenshot`, and - for the open issue - the HDMI capture
card on `/dev/video4` plus its USB audio (`hw:3,0`) with a temporary
debug build (42) that put `tape_audio` on `AUDIO_L`. The OSD row order
from the capture: Video, MT32-pi, ROM Bank, Turbo, PSG Mix, Covox,
Tape, Tape play/pause, Tape previous block, Tape next block, ... (0-based
play/pause = 7; Reset = 18; Exit = 19).

## Checks

| Check | Result | Evidence |
|---|---|---|
| `hello.csw` at Turbo Off | PASS | "tape ok", `0 OK, 20:1`; 8064-pulse data pilot |
| `hello.csw` at Turbo 8x | PASS | same, 8x |
| `hello.tap` at Turbo Off / 8x | **FAIL** | header loads ("Program: hello"), data block ends in `R Tape loading error, 0:1` |
| `hello.tzx` at Turbo Off / 8x | **FAIL** | same |
| `gsquery.tap` at 8x (plan) | **BLOCKED** by the TAP failure | `gsquery.csw` at 8x: "GS status 126", "pages 62 err 0" |
| `sound.csw` (six chips) | PASS | owner heard all six; SAA confirmed separately at Turbo Off with a 4 s tone |
| play/pause OSD item | PASS | two screenshots 5 s apart are byte-identical while paused; the resumed load completes |
| previous/next block | **CSW has none** (upstream CSW path has no block navigation); TAP/TZX blocked | - |
| LED_USER while playing | not observable | the owner's setup has no visible USER LED |
| line-in | not tested | no cassette/audio source |

## Findings

1. **MGL paths are relative to the core's game dir.** Main's MGL loader
   resolves a `<file path>` without a leading `/` against `HomeDir()`
   (`/media/fat/games/Karabas_Profi`), so `games/Karabas_Profi/x.tap`
   never mounted. Absolute paths mount; `/tmp/CURRENTPATH` confirms it.
2. **OSD trigger pulses were one clk_bus clock.** `tape.sv` samples
   `pause/prev/next` only on `ce` (the CPU T-state enable, one clk_bus in
   eight at Turbo Off), so the pulses were usually missed. Build 40 holds
   them for 16 clocks; the tape starts at every Turbo setting.
3. **The Profi ROM needs a longer data-block lead-in.** With standard
   pilots the data block fails: CSW 3223 and 0.8 s gap, tzxplayer 4031,
   TAP 3220; CSW 4000 loaded (marginal), 8064 and 50000 loaded. Both
   imported players' data lead-in is now 8064 (tape.sv adds the 4844 for
   every block; tzxplayer's NORMAL_PILOT_PULSES), and `zxtap.py` writes
   8064 for CSW. This is the one documented deviation from the verbatim
   ZX players (files.qip, README).
4. **TAP/TZX still fail the data block on hardware (open).** The player
   logic is correct: `tb_tape_play` decodes both blocks for TAP
   (`tap_decode: ok`) and TZX (`tzx_decode: ok`, `tb_tape_play: PASS`).
   The HDMI capture of build 42 decodes the board's actual TAP waveform
   byte-for-byte for both blocks (header `00 00 68 65 6c 6c 6f ... 48`,
   data `ff 00 0a ... 0d 66`), and the video shows the ROM's border
   flickering through the data block, so the ROM reads a correct
   waveform and still raises `R Tape loading error`. The CSW player with
   the same bytes and exact (65535 Hz) timing loads. This is a ROM/player
   timing interaction in the block players, not the byte source; the
   next step is a ROM-level or logic-analyzer trace (or replacing the
   block players with a TAP/TZX-to-CSW stream converter that uses the
   working CSW path).

## Board setup left in place

- `/media/fat/games/Karabas_Profi/` holds build 39/40/41/42 RBFs, the
  nine test tapes, the MGLs (absolute paths), and the debug variants
  (`hello50k.*`, `hello0.csw`, `hello-exact.csw`, `stdtest.tap`, ...).
- `MiSTer.ini` is restored from `MiSTer.ini.before-karabas-tape`
  (`debug` off, `log_file_entry=0`).