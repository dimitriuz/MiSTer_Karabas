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
python3 tools/prepare_upstream.py # regenerate build/upstream + upstream.qip
tools/check_upstream.sh           # tripwire: upstream files vs SHA256SUMS
tools/build.sh                    # the one-command build: prepare_upstream + check_upstream + qbuild,
                                  # ends with `build: exit <code>`
python3 tools/build_boot_rom.py   # releases/boot.rom from upstream's src/roms (committed; --check verifies)
tools/sim.sh <command>            # run <command> in the karabas-sim:1 image (GHDL, Icarus, repo at /work);
                                  # builds tools/sim/Dockerfile into karabas-sim:1 on first use
tools/sim.sh sim/run_all.sh       # every simulation testbench, ends `run_all: N passed, 0 failed`
python3 -m unittest discover -s tools/tests -v  # the python tools' tests
tools/elab_upstream.sh            # upstream gate: quartus_map --analysis_and_elaboration of top `profi`
tools/check_upstream.sh           # upstream-change tripwire for the files we replace
tools/qbuild.sh . Karabas_Profi   # just the Quartus compile of the MiSTer core in raetro/quartus:17.0
```

`build.sh` runs `tools/check_timing.py` on the TimeQuest reports after the compile and
fails the build on a negative slack or a missing `clk_bus28`/`clk_bus24` bus clock
(Quartus itself exits 0 with timing unclosed; only warnings mark an sdc clock that
stopped resolving).

A full compile takes 10-20 minutes, so launch it detached and poll the log:
`setsid nohup tools/build.sh </dev/null >build/logs/build.log 2>&1 &`, then watch for the
`build: exit <code>` line. Quartus 17 rewrites `LAST_QUARTUS_VERSION` in the `.qsf` on every
run; revert it afterwards:

```
sed -i 's/^set_global_assignment -name LAST_QUARTUS_VERSION.*/set_global_assignment -name LAST_QUARTUS_VERSION "17.0.2 Standard Edition"/' Karabas_Profi.qsf
```

## Installing

Copy to the SD card of the MiSTer (the core appears under the `Computer` menu):

```
output_files/Karabas_Profi.rbf        ->  /media/fat/_Computer/Karabas_Profi_YYYYMMDD.rbf
releases/boot.rom                     ->  /media/fat/games/Karabas_Profi/boot.rom
```

`boot.rom` is the ROM image the core's MCU emulation streams into the machine at
start (offsets per `tools/build_boot_rom.py`); MiSTer downloads it as ioctl index 0.

## OSD items

The machine's own switches (ROM Bank, Turbo, PSG Mix, Covox, joysticks, DivMMC,
Keyboard, Pause, VSync 50/60 Hz, GS Reset, NMI, Reset) travel over the emulated
MCU SPI link - the table of indices and status bits is `rtl/host/osd_items.svh`.
MiSTer-side: Aspect ratio and Scandoubler Fx (None, HQ2x, CRT filters) on the
Video page; `boot.rom` is loaded automatically at core start.

## Mouse, joysticks and RTC

The board's MCU sends more than the keyboard and the OSD switches over the
SPI link; the emulation feeds the same frames:

- **Mouse**: the MiSTer PS/2 mouse reaches the machine the way the board's
  USB mouse does - through the Profi's Kempston-mouse ports (0A-0C) and
  upstream's serial-mouse emulation. Movement is relative (the PS/2 packet);
  the wheel and the three buttons travel too.
- **Joysticks**: `J1` with A, B, C, X, Y, Z, Start and Mode; the OSD picks
  the type of each port (Kempston, Sinclair 1/2, cursor keys, QAOPM/QAOPS).
- **RTC**: the time comes from MiSTer's clock (the HPS sends it about once a
  minute); the core keeps it ticking in the FPGA, second by second, between
  those updates, and sends it every 500 ms and once right after the first
  HPS time update. The MC146818A's BCD/binary mode follows the register B
  the machine writes; other CPU writes of time or CMOS are ignored -
  MiSTer's clock is the time source. The CMOS bytes start as FF on every
  core load: persistent CMOS comes with stage 4's storage.


Simulation tests run through `tools/sim.sh` (GHDL with `--std=93c -fsynopsys`, Icarus with
`-g2012`); `sim/run_all.sh` runs all of them.

## Known limitations (stage 1)

- CPU turbo runs without memory wait states (no-wait SDRAM controller).
- General Sound is disabled.
- No disks or tape yet.
- 80-column (DS80) mode: the pixel enable runs at a 9/9/10 cadence of the
  112.5 MHz video clock, so the analog scandoubler may duplicate pixels;
  HDMI is unaffected.
- DS80 mode switches at runtime: switching between the Profi menu (DS80) and the Spectrum modes, through the menu and through reset, works on the board; arbitrary software toggling is not separately tested.
