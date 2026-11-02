# MiSTer Karabas_Profi

A [MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) (DE10-Nano, Cyclone V) port of Andy
Karpov's [karabas-go-core-profi](https://github.com/andykarpov/karabas-go-core-profi) core —
the "Karabas Pro +" (Profi) home computer: a T80 machine with Profi paging, Spectrum/Pentagon
and 512x240 (DS80) video, TurboSound FM + SAA1099 + OPL2 + General Sound audio, VG93 FDC,
Profi IDE, RTC and more. The upstream sources are kept as a git submodule
(`upstream/karabas-go-core-profi`, with its `modules/` submodule) and are **never edited**:
`tools/prepare_upstream.py` generates `build/upstream/` from them — a directory-preserving
copy with the source rewrites Quartus 17 needs (VHDL instantiations of Verilog modules
become component instantiations, init-file paths fixed, vendor library stubs), plus the
`upstream.qip` file list; `tools/elab_upstream.sh` proves the copy still elaborates and
`tools/check_upstream.sh` fails when upstream changes a file we replace. The MiSTer side
(`sys/`, replaced RTL under `rtl/`, the `Karabas_Profi` top level) consumes that copy.

## Building

Prerequisites: Docker, and both upstream submodules
(`git submodule update --init --recursive`). All builds run in Docker; no local Quartus or
GHDL install is needed.

```
tools/sim.sh <command>          # run <command> in the karabas-sim:1 image (GHDL, Icarus, repo at /work);
                                # builds tools/sim/Dockerfile into karabas-sim:1 on first use
python3 tools/prepare_upstream.py            # core profile -> build/upstream/ + upstream.qip
tools/elab_upstream.sh          # upstream gate: quartus_map --analysis_and_elaboration of top `profi`
tools/check_upstream.sh         # upstream-change tripwire for the files we replace
tools/qbuild.sh . Karabas_Profi # full compile of the MiSTer core in raetro/quartus:17.0
```

`tools/qbuild.sh` runs `quartus_sh --flow compile` in `raetro/quartus:17.0` and ends with the
line `qbuild: exit <code>`. A full compile takes ~12 minutes, so launch it detached and poll
the log: `setsid nohup tools/qbuild.sh . Karabas_Profi >build/logs/qbuild.log 2>&1 &`.
Quartus 17 rewrites `LAST_QUARTUS_VERSION` in the `.qsf` on every run; revert it afterwards:

```
sed -i 's/^set_global_assignment -name LAST_QUARTUS_VERSION.*/set_global_assignment -name LAST_QUARTUS_VERSION "17.0.2 Standard Edition"/' Karabas_Profi.qsf
```

Simulation tests run through `tools/sim.sh` (GHDL with `--std=93c -fsynopsys`, Icarus with
`-g2012`); `sim/run_all.sh` runs all of them.

## Known limitations (stage 1)

- CPU turbo above 7 MHz may crash: the SDRAM bridge has no wait path yet (stage 2).
- General Sound is disabled.
- No RTC, mouse, joysticks, disks or tape yet.
- MiSTer analog-VGA scandoubler in the 80-column (DS80) mode untested.
