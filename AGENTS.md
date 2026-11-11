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
| Build | `tools/build.sh` → `build/logs/buildNN.log` | Ends `build: exit N`; must be `exit 0`, which includes `check_timing: OK` (negative slack, a missing generated clock, an ignored `332174/332049/332060` sdc line, a `10236`/`10541` implicit net in our sources). Numbering continues from the last build (47 as of 2026-11-09). |
| Revert the qsf | `git checkout -- Karabas_Profi.qsf` | Quartus rewrites `LAST_QUARTUS_VERSION` on every compile. |
| Simulations | `tools/sim.sh sim/run_tb_*.sh` | Runs in image `karabas-sim:1` (repo at `/work`). Every testbench prints exactly one final `<tb>: PASS` / `<tb>: FAIL <reason>` and exits non-zero on failure. |
| All simulations | `tools/sim.sh sim/run_all.sh` | Ends `run_all: N passed, 0 failed` (N = 19 today, one per `sim/run_tb_*.sh`). |
| Python tests | `python3 -m unittest discover -s tools/tests` | 86 tests. `tests/` holds only the `.bas` sources for the tape fixtures — there are no python tests there. |
| Upstream gates | `tools/check_upstream.sh`, `tools/elab_upstream.sh` | Tripwire for files we replace, and elaboration of the rewritten upstream. |

Simulation runtimes, so a long run is not mistaken for a hang:

- `tb_mcu_emu` ≈ 10 min; `tb_tape_play` ≈ 35 min — it plays the test tapes in simulation
  time, one 44.1 kHz sample per ≈638 clocks (28.125 MHz ÷ 44.1 kHz); everything else is
  seconds. Budget `run_all` at ≈ 50 min.
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

Typing, if it has to be done (`load`): `text_cells()` counts character cells on a screenshot
and the key is pressed again until the line grows, and both shift keys are tried for `"` (PC
`shift` = ZX SYMBOL SHIFT, so `shift+P` = `"`). Do not type blind and press `Enter`.

Why it is written down: the remote daemon **drops about one press in five and can deliver a
press seconds late**, so every step holds keys 0.3 s (`Remote.press`, not `key`'s 45 ms `tap`)
and verifies the effect — `read_bar()` for the OSD (`(top - 174)/16` on the 960×540 grid, 10
= `Tape play/pause`), `text_cells()` for typing, a saved screenshot for everything else.
Never "I sent it, therefore it happened".

- Menu arrows and OSD steps come from the **gamepad** (the keyboard path drops repeats above
  turbo 1x); activations are a keyboard `Enter`, including OSD trigger items.
- OSD: the gamepad's `home` (`BTN_MODE`) toggles it; `KEY_HOME`/`KEY_F12` stopped working
  after a `cold_reboot`. The cursor starts on `Video` on a fresh core load, and `Up` on
  `Video` wraps to the bottom of the page. Count `Down` presses on the **build that is
  loaded**: rows change with CONF_STR. Build 54+: 8 `IDE 0`, 9 `IDE 1`, 10 `Tape play/pause`,
  11 previous block, 12 next block, 13 `Joystick L`; builds 39-47 (no storage rows): 8 `Tape
  play/pause`. Group headers (`Video`, `MT32-pi`) are one row each and open inline; the blank
  line between pages is not selectable. Never `Enter` a file row (`Tape`, `SD Card`, `IDE 0/1`):
  it opens the OSD's file browser and the OSD is hard to bring back to a known state.
- A converted tape is **paused after mounting**: the loader waits forever with a flat border.
  Fire `Tape play/pause`. At turbo off the border shows the tape signal — stripes while
  playing, solid while paused, a lead-in again after a block jump — so play/pause and block
  seek are checkable without audio; at 8x a frame is too coarse to show it.
- Parallel mounts: MGL files in `/media/fat/games/Karabas_Profi/` with absolute `<file
  type="s" index="N" path="..."/>`, N = 0 tape, 1 SD card, 2 IDE 0, 3 IDE 1. OSD options
  without the OSD: the 16-byte little-endian `/media/fat/config/Karabas_Profi.CFG` (ROM bank,
  turbo, DivMMC), then reload the core; leave it at all zeros when done.

### Screens

- `Remote.screen(path)` — the MiSTer screenshot API, 1440×1080: the ZX picture only, **no
  OSD and no border**, and the only independent view of what the machine's video generator is
  doing. It answers HTTP 500 for a second or two while a core reloads.
- `Capture.frame(path)` — the HDMI card, the only view **with the OSD**: one `ffmpeg` grab of a
  single frame off `/dev/video4` (`video` group, ≈1.5 s, no sudo, no v4l2loopback). ~1 s of
  latency, so the grab settles first and retries while the frame is all black. The old
  long-lived `/tmp/live.jpg` feeder is gone: a frozen file there produced wrong conclusions
  twice (an OSD that "would not open", a tape "stuck on stripes").

While the card has **no signal** (every grab a uniform `(7,7,7)` frame - the cable or the
source is off, nothing a script can fix) the OSD cannot be seen at all, and the MiSTer
screenshot API does not contain it either. Then the OSD's state is *unknowable*: a screen
that looks like idle BASIC may have the OSD open on top of it, eating every key. Work by
effect only - fire, and read the machine's picture: `Program: <name>` and the program's own
output are the proof. If several fires change nothing, check the input path before the
software: after an hour of scripted presses the ZX stopped taking keys altogether (the
remote daemon kept delivering, the machine ignored it) and only a `system cold_reboot`
brought it back; the network needs ≈2 min after that.

## Results documents

- One per stage: `docs/dev/stageN-results.md`, with the build number, how the run was
  driven, a checks table (pass condition + evidence), findings, and the gates. Screenshots
  in `docs/dev/stageN-shots/`, every shot referenced from the document and no orphans.
- Findings state what a future script must know, including the traps that wasted a run.