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
| All simulations | `tools/sim.sh sim/run_all.sh` | Ends `run_all: N passed, 0 failed` (N = 16 today). |
| Python tests | `python3 -m unittest discover -s tools/tests` | 75 tests. `tests/` holds only the `.bas` sources for the tape fixtures — there are no python tests there. |
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

`ssh -o BatchMode=yes root@192.168.1.13` works without a password. Drive input with the
**`mister-karabas-board` skill** (MiSTer Companion Remote, `ws://192.168.1.13:9191/remote/v1`,
`{"type":"controller"|"keyboard"|"system",...}`). Never use ad-hoc `uinput` scripts: they
wedge the MiSTer input thread after a while (menu still responds, the ZX stops seeing keys,
only a reboot fixes it).

- Load a core: `echo "load_core /media/fat/_Computer/Karabas_Profi_buildNN.rbf" > /dev/MiSTer_cmd`,
  wait ≈ 10 s.
- Per-tape mounts: MGL files in `/media/fat/games/Karabas_Profi/`, absolute `<file
  type="s" index="0" path="..."/>`; tapes live in the same directory.
- OSD options without the OSD: 16-byte little-endian status file
  `/media/fat/config/Karabas_Profi.CFG` (ROM bank, turbo, trigger bits), then reload the
  core. Leave it at all zeros when done.
- The OSD is **not** in MiSTer's own screenshots. Watch it on the capture card instead
  (`/tmp/live.jpg`, helper `/tmp/cap.py`): ~1 s of latency and dropped frames, so verify with
  the *last* non-black frame of a settle window.

Input and OSD behaviour that has bitten every scripted run:

- Menu arrows come from the **gamepad** (keyboard repeats are lost above turbo 1x);
  activations are a keyboard `Enter`.
- OSD: Home opens, F12 closes. The cursor starts on `Video` every time and Up on `Video`
  wraps to the bottom of the page (`Exit`, `Reset`) — never "press Up until sure". From
  `Video`, 7 x Down is `Tape play/pause`, 8 `Tape previous block`, 9 `Tape next block`.
- OSD trigger items fire with a keyboard `Enter`; the gamepad's OK does not.
- A converted tape is **paused after mounting**: the ROM's `Tape Loader` screen waits
  forever with a flat border. Fire `Tape play/pause`. At turbo off the border shows the tape
  signal — stripes while playing, solid while paused, a lead-in again after a block jump —
  which makes play/pause and block seek checkable without audio; at 8x a frame is too
  coarse to show it.

Capture path on this host: HDMI card `/dev/video4` → v4l2loopback `/dev/video10` → one
ffmpeg (service `v10share`) that writes `/tmp/live.jpg` at 10 fps. **Exactly one reader** may
hold `/dev/video10`; a second one gets `Device or resource busy`, and the `xv` output fails on
this X session (`Not yet implemented in FFmpeg`). `/tmp/share-capture.sh` reloads the
loopback so several readers fit, but it needs the sudo password.

## Results documents

- One per stage: `docs/dev/stageN-results.md`, with the build number, how the run was
  driven, a checks table (pass condition + evidence), findings, and the gates. Screenshots
  in `docs/dev/stageN-shots/`, every shot referenced from the document and no orphans.
- Findings state what a future script must know, including the traps that wasted a run.