# AGENTS.md — working in MiSTer_Karabas

Instructions for agents (and humans) changing this repository. Read these with:

- `docs/superpowers/specs/2026-11-02-karabas-profi-mister-port-design.md` — what the port
  must do (the authority when documents disagree);
- `docs/superpowers/plans/*.md` — the stage being built, task by task;
- `docs/dev/stageN-results.md` — what was verified on the board, and why things are the way
  they are. Every gotcha in this file comes from one of those files.

`README.md` is user-facing (features, OSD, files, limitations). This file is process.

## Hard rules

- **`upstream/` and `sys/` are never edited.** Upstream text is changed only by an
  exact-once rewrite in `tools/prepare_upstream.py`, and every rewrite has a unit test in
  `tools/tests/test_prepare_upstream.py`. `build/upstream/` is generated;
  `tools/check_upstream.sh` must stay `OK`.
- Never patch the shared upstream machine blocks (`gs.v`, `gs_top.v`, `turbosoundfm.v`,
  `saa1099`, `opl2_top`, `audio_mixer.v`, T80). Extend them from the MiSTer side
  (spec §5.1).
- `Karabas_Profi.sv` has `` `default_nettype none ``: declare every wire. An undeclared
  identifier becomes a 1-bit net and the build's 10236/10541 gates fail on purpose.
- Python tools: standard library only. Tests are `unittest` modules under `tools/tests/`.
- Never weaken a constraint, a test or a gate to make a build pass. A feature that is not
  there is reported as missing, not hidden behind a tolerance.

## Toolchain

| What | Command | Notes |
|---|---|---|
| Build | `tools/build.sh` → `build/logs/buildNN.log` | Ends `build: exit N`; must be `exit 0`, which includes `check_timing: OK` (negative slack, a missing generated clock, an ignored `332174/332049/332060` sdc line, a `10236`/`10541` implicit net in our sources). Numbering continues from the last build (90 as of 2026-11-19, seed 7: SDRAM read path +1.215 ns, hotkeys, SCL; builds 77, 79, 81, 82, 85 and 88 passed the old timing gate and read garbage from the SDRAM because its pins were unconstrained - fixed in the sdc from build 89, see docs/dev/sdram-timing.md; still boot every RBF on the board before trusting it). |
| Revert the qsf | `git checkout -- Karabas_Profi.qsf` | Quartus rewrites `LAST_QUARTUS_VERSION` on every compile. |
| Simulations | `tools/sim.sh sim/run_tb_*.sh` | Runs in image `karabas-sim:1` (repo at `/work`). Every testbench prints exactly one final `<tb>: PASS` / `<tb>: FAIL <reason>` and exits non-zero on failure. |
| All simulations | `tools/sim.sh sim/run_all.sh` | Ends `run_all: N passed, 0 failed` (N = 30 today, one per `sim/run_tb_*.sh`). |
| Python tests | `python3 -m unittest discover -s tools/tests` | 147 tests. `tests/` holds only the `.bas` sources for the tape fixtures — there are no python tests there. |
| Upstream gates | `tools/check_upstream.sh`, `tools/elab_upstream.sh` | Tripwire for files we replace, and elaboration of the rewritten upstream. |

Simulation runtimes, so a long run is not mistaken for a hang:

- `tb_mcu_emu` ≈ 10 min; `tb_tape_play` ≈ 35 min — it plays the test tapes in simulation
  time, one 44.1 kHz sample per ≈638 clocks (28.125 MHz ÷ 44.1 kHz); `tb_floppy` runs its six speed combinations at the same
  time and takes ≈ 1 h 15 min of wall time in total (measured 2026-11-13: 73 min; the disk spins in
  real time and two reads that have to fail cost 2.4 s of simulated time each). Budget
  `run_all` at ≈ 50 min plus that hour.
- The GHDL netlist `build/sim/tzxplayer_syn.v` is cached and rebuilt only when
  `sim/run_tb_tape_play.sh` changes.
- Testbenches that wait on a signal must be guarded by an **edge count**, not by a `$time`
  difference: 64-bit time arithmetic in deep Icarus runs silently never fires.

## One plan task, start to finish

1. Read the task and the spec section it cites.
2. Write the failing check first (unit test or a testbench case); run it, see it fail.
3. Implement.
4. Gates: unit tests, `check_upstream`, the task's testbenches, `run_all`.
5. If RTL changed: full build (step 5 of every plan), then revert the qsf.
6. Board check for anything user-visible (see Board below).
7. Record it in `docs/dev/stageN-results.md`: a checks table with the pass condition and a
   screenshot, findings, gates, and the build number that shipped.
8. Commit.

Tick the plan's own checkboxes as steps land; the plan is the tracker, the results doc is
the evidence.

## Commits

`area: what changed`, areas `tools`, `sim`, `tape`, `clock`, `mem`, `host`, `sound`, `top`,
`docs`. Commit messages end with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

One concern per commit where it is possible (RTL + top, sim, docs), each self-consistent.

## The board (192.168.1.13)

`ssh -o BatchMode=yes root@192.168.1.13` works without a password. **Drive the board with
`tools/board/`** (stdlib + PIL, runs on this host): `mister.py` is the transport (the MiSTer
Companion Remote WebSocket `ws://192.168.1.13:9191/remote/v1`, plus the two screen views) and
`zx.py` is the verified recipe. Never use ad-hoc `uinput` scripts: they wedge the MiSTer input
thread after a while (menu still responds, the ZX stops seeing keys, only a reboot fixes it).

### The recipe (`tools/board/zx.py`)

| step | command | what it does |
|---|---|---|
| 1 | `python3 tools/board/zx.py boot <mgl>` | `load_core`, wait for a picture (default = tape slot 0, IDE 0 = slot 2) |
| 2 | `… 128menu` | gamepad 6 × `down`, keyboard `Enter` = `Run Sinclair 128K`; the 128 ROM's menu appears with **`Tape Loader` highlighted** |
| 3 | `… loader` | `Enter`: the loader takes the tape's **first file** — no typing, no `LOAD ""` |
| 4 | `… tape` | gamepad `home` opens the OSD, walk to `Tape play/pause` with a bar check per press, keyboard `Enter` fires it |
| — | `python3 tools/board/zx.py all <mgl>` | 1-4 in one run, ≈2 min |
| — | `… basic`, `… load` | step one down into `128 BASIC`, type `LOAD ""` there, one verified key at a time |

The **loader path needs no typing** - that is the point of it. The typed path (`load`, the
`LOAD ""` line in 128 BASIC) exists as a fallback and its key spelling is known: `L O A D
SPACE`, then `shift+P` twice (PC `shift` = ZX SYMBOL SHIFT, so `shift+P` = `"`), then
`Enter`. Its *verification* is not: `text_cells()` counts the widest dark run of the editor
band, and on build 70 the count jumps with whatever else is on the screen, so a dropped key
cannot be told from a measurement artefact (2026-11-11). Until the picture is measured
properly (a fixed band over the editor's first line), read the typed line on a screenshot
instead of trusting the counter.

Why it is written down: the remote daemon **drops about one press in five and can deliver a
press seconds late**, so every step holds keys 0.3 s (`Remote.press`, not `key`'s 45 ms `tap`)
and verifies the effect — `read_bar()` for the OSD (`(top - 174)/16` on the
960×540 grid, and on the build that is loaded row 9 = `Tape play/pause` since
build 77, counted from the first item), `text_cells()` for typing, a saved screenshot for everything else.
Never "I sent it, therefore it happened".

- Menu arrows and OSD steps come from the **gamepad** (the keyboard path drops repeats above
  turbo 1x); activations are a keyboard `Enter`, including OSD trigger items.
- OSD: the gamepad's `home` (`BTN_MODE`) toggles it; `KEY_HOME`/`KEY_F12` stopped working
  after a `cold_reboot`. The cursor starts on the first item on a fresh core load (`IDE 0` since
  build 77, `Video` before it), and `Up` on the first item wraps to the bottom of the page.
  Count `Down` presses on the **build that is loaded**: rows change with CONF_STR. **Build
  77+ (images first, then settings by type)**: 0 `IDE 0`, 1 `IDE 1`, 2 `SD Card`,
  3 `Floppy A (TRD)`, 4 `Floppy B (TRD)`, 5 `Floppy A (raw)`, 6 `Floppy B (raw)`, 7 `Disk layout`,
  8 `Tape`, 9 `Tape play/pause`, 10 previous block, 11 next block, 12 `ROM Bank`,
  13 `Mode`, 14 `Turbo`, 15 `DivMMC`, 16 `Pause`, 17 `Joystick L`, 18 `Joystick R`,
  19 `Keyboard`, 20 `PSG Mix`, 21 `Covox`, 22 `MT32-pi`, 23 `Video`, 24 `Serial channel`,
  25 `GS Reset`, 26 `NMI`, 27 `Reset` (checked on a capture, build 78: 14 `Down` = `Turbo`, 26 = `NMI`; the page scrolls, so
  the pixel arithmetic `(top - 174)/16` no longer gives the row: count presses). Builds 74-76 counted from
  `Video`: 8 `IDE 0`, 9 `IDE 1`, 10-13 the floppies and FDI entries, 14 `Disk layout`,
  15 `Tape play/pause`, 18 `Serial channel`, 19 `Joystick L`; build 73 had no serial row;
  builds 54-72: 10 `Tape play/pause`, 11 previous block, 12 next block, 13 `Joystick L`;
  builds 39-47 (no storage rows): 8 `Tape play/pause`. Group headers (`Video`, `MT32-pi`) are one row
  each and open inline; the blank line between pages is not selectable. Never `Enter` a
  file row (`Tape`, `SD Card`, `IDE 0/1`, `Floppy A/B`, the FDI entries):
  it opens the OSD's file browser and the OSD is hard to bring back to a known state.
- A converted tape is **paused after mounting**: the loader waits forever with a flat border.
  Fire `Tape play/pause`. At turbo off the border shows the tape signal — stripes while
  playing, solid while paused, a lead-in again after a block jump — so play/pause and block
  seek are checkable without audio; at 8x a frame is too coarse to show it.
- Parallel mounts: MGL files in `/media/fat/games/Karabas_Profi/` with absolute `<file
  type="s" index="N" path="..."/>`, N = 0 tape, 1 SD card, 2 IDE 0, 3 IDE 1, 4 floppy A,
  5 floppy B (stage 4c). OSD options
  without the OSD: the 16-byte little-endian `/media/fat/config/Karabas_Profi.CFG` (ROM bank,
  turbo, DivMMC), then reload the core; leave it at all zeros when done.

### Screens

- `Remote.screen(path)` — the MiSTer screenshot API, 1440×1080: the ZX picture only, **no
  OSD and no border**, and the only independent view of what the machine's video generator is
  doing. It answers HTTP 500 for a second or two while a core reloads.
- `Capture.frame(path)` — the HDMI card, the only view **with the OSD**: one `ffmpeg` pass off
  `/dev/video4` (`video` group, ≈4 s, no sudo, no v4l2loopback), `-t 2.2 -update 1` so the
  last written frame wins. **The card needs about two seconds before it delivers picture**:
  `-frames:v 1` (and 3) returns a uniform `(7,7,7)` frame, and so does any window under
  ≈2 s (measured: 7.0 at 1.2 s, 96.4 at 2.2 s). A black frame is therefore not proof that
  the card has no signal. The old long-lived `/tmp/live.jpg` feeder is gone: a frozen file
  there produced wrong conclusions twice (an OSD that "would not open", a tape "stuck on
  stripes"). The v4l2loopback, when it is wanted, is `/dev/video6` on this host (the module
  is loaded with `video_nr=-1`), not `/dev/video10`; there is no `share-capture.sh`.

**The OSD is visible on the card and nowhere else.** If the card is not readable, its state
cannot be decided from the MiSTer screenshot: a screen that looks like the idle `Tape
Loader` or `128 BASIC` may have the OSD open on top of it, eating every key. `Home` and
`F12` both *toggle* it, so an odd number of presses - including one the daemon dropped -
leaves it open, and every later walk then piles its presses into it (2026-11-11: three
fires in a row changed nothing, and the card showed the cursor sitting on `Tape *.TAP,TZX,CSW`
with that row's file browser open). A walk is evidence only once its **effect** is seen;
reload the core to close the OSD rather than pressing `Home` again and hoping for the right
parity.

## Results documents

- One per stage: `docs/dev/stageN-results.md`, with the build number, how the run was
  driven, a checks table (pass condition + evidence), findings, and the gates. Screenshots
  in `docs/dev/stageN-shots/`, every shot referenced from the document and no orphans.
- Findings state what a future script must know, including the traps that wasted a run.