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

Agent workflow and hard rules (gates, build numbering, board driving, commits) are in
`AGENTS.md`; the per-stage evidence is under `docs/dev/`.

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
Keyboard, Pause, Mode, VSync 50/60 Hz, GS Reset, NMI, Reset) travel over the
emulated MCU SPI link - the table of indices and status bits is
`rtl/host/osd_items.svh`.
MiSTer-side: Aspect ratio and Scandoubler Fx (None, HQ2x, CRT filters) on the
Video page; the MT32-pi page for a Pi on the USER port; `boot.rom` is loaded
automatically at core start.
The `Serial channel` item on the main page (after the tape items) picks which
of the machine's serial channels owns the HPS UART - see Serial below.
Below `IDE 1` on the main page sit the floppy items - `Floppy A`,
`Floppy B`, `Floppy A FDI`, `Floppy B FDI` and `Disk layout` (see Disks).

`Mode` is the screen timing: Pentagon (the upstream default, 320 lines) or 48k
(the classic 312-line frame with memory contention). It is soft-switch register
15, the one register the Karabas Go layout has no OSD item for (the board
hard-wires it to Pentagon), so the core profile's `profi.vhd` rewrite widens
`kg_soft_switches` to 16 registers and feeds `kb_screen_mode` from it.

## Mouse, joysticks and RTC

The board's MCU sends more than the keyboard and the OSD switches over the
SPI link; the emulation feeds the same frames:

- **Mouse**: the MiSTer PS/2 mouse reaches the machine the way the board's
  USB mouse does - through the Profi's Kempston-mouse ports (0A-0C) and
  upstream's serial-mouse emulation. Movement is relative (the PS/2 packet);
  the wheel and the three buttons travel too.
- **Joysticks**: `J1` with A, B, C, X, Y, Z, Start and Mode; the OSD picks
  the type of each port (Kempston, Sinclair 1/2, cursor keys, QAOPM/QAOPS).
  Upstream maps Sinclair 1 to keys 1-5 and Sinclair 2 to keys 6-0 (left,
  right, down, up, fire); on the Sinclair and cursor types only B fires,
  while A is Kempston bit 5.
- **RTC**: the time comes from MiSTer's clock (the HPS sends it about once a
  minute); the core keeps it ticking in the FPGA, second by second, between
  those updates, and sends it every 500 ms and once right after the first
  HPS time update. The MC146818A's BCD/binary mode follows the register B
  the machine writes; other CPU writes of time or CMOS are ignored -
  MiSTer's clock is the time source. The CMOS bytes start as FF on every
  core load: persistent CMOS comes with stage 4's storage.


Simulation tests run through `tools/sim.sh` (GHDL with `--std=93c -fsynopsys`, Icarus with
`-g2012`); `sim/run_all.sh` runs all of them.

## Sound

The machine's sound is upstream's: TurboSound FM, SAA1099 and OPL2 on the
Z80 side, and the General Sound (GS) card. The GS is enabled: its 2 MB of
sample memory is `rtl/mem/gs_mem.sv`, the low 64 KB in BRAM and the rest in
MiSTer's DDR3 (the `DDRAM_*` port), and it runs on its own fixed 28.125 MHz
clock from the machine PLL. `GS Reset` in the OSD restarts the GS CPU.

### MIDI

The MIDI out is the TurboSound's (AY port A bit 2), as on the ZX 128. It has
two routes:

- **MidiLink (HPS UART)**: set the OSD `UART mode` to `MIDI` (31250 baud),
  then pick the target in MiSTer's MidiLink menu - a remote mt32-pi, MUNT,
  FluidSynth or a USB MIDI adapter. Every other UART mode hands the line to
  the `Serial channel` item (Serial below) - that is how Linux and the machine
  reach each other.
- **mt32-pi on the USER port**: connect the Pi there and use the MT32-pi OSD
  page (`Use MT32-pi`, `Synth`, `Munt ROM`); its I2S audio is mixed into
  AUDIO_L/R. `Use MT32-pi: No` silences only that Pi - the MidiLink route
  keeps carrying the unmuted line.

## Serial (the HPS UART)

The machine's two serial channels share MiSTer's UART (`/dev/ttyS1` for
Linux), and the OSD `Serial channel` item says which one owns the line:
`ESP` (the default) or `USB`. `rtl/host/uart_route.sv` is the router. The item
is MiSTer-side only - the machine never hears about it.

- **ESP (the wires)**: `profi.vhd`'s `UART_TX`/`UART_RX` - the ZiFi or ZXUNO
  port it selects internally - pass through bit by bit with no resampling, so
  **the baud is whatever the software programmes**. MiSTer's
  `UART mode` -> `Baud` has to carry the same speed for the bytes to mean
  anything at the other end. `UART_CTS` is not forwarded (the core has no CTS
  path into the tty and MiSTer ties the port's RTS/CTS low), so **flow control
  stays a software matter**.
- **USB (bytes)**: the ZiFi/EVO USB-RS232 path - the MCU link's `CMD_UART`
  frames between `rtl/host/mcu_emu.sv` and the router - framed 8N1 at a fixed
  **115200**, the standard ZiFi rate. The tty speed is still Main's, so
  `Baud` has to say 115200.

The `UART mode` submenu is Main's fixed list - `config_uart_msg` in
`menu.cpp`: `None`, `PPP`, `Console`, `MIDI`, `Modem`, and `UDP`/`SNI` only
when one of those is already running. For a byte pipe use `None`, the one mode
that leaves the line raw: `PPP` and `Console` give the port to a daemon
(MiSTer's docs: "Linux OS runs PPP or Console daemon on this connection"),
`MIDI` is this core's MidiLink, and `Modem`/`UDP`/`SNI` are MiSTer's own
tunnels, started by Main's `uartmode` script. Main sets the port to the speed
shown under `Baud` (and writes it to `/tmp/UART_SPEED`); the core only ever
looks at the mode number to recognise `MIDI`. MIDI keeps priority over both
channels and is exactly what it was before stage 5: it takes the line
immediately, mid-byte as well, and while it owns it the two channels neither
send nor receive.

`CONF_STR` declares `UART115200:31250,MIDI`. The two numbers are what the
`Baud` submenu offers the non-MIDI connections (115200 as the default, 31250
for slow bit-banged software); MIDI's own speed comes from Main's MIDI list
(31250 by default), never from that list - `user_io.cpp`'s `GetUARTbauds()`
picks `midi_speeds` for mode 3 - so adding them leaves MIDI untouched.

Limits worth knowing (the first four are cases of `sim/tb_uart_route.sv`):

- a channel switch waits for a whole idle frame (~87 us at 115200) of the
  entire port: the machine's TX wire, the HPS line, the level the core drives
  and the deserialiser at rest. A line held low parks the switch.
- `UART_RXD` must idle high before `/dev/ttyS1` is opened for the same
  reason.
- a reset or a channel flip can drop bytes for the same ~87 us, and the reset
  empties the send queue.
- the send queue holds 16 bytes (plus one in the shift register) and drops the
  newest when it is full: nothing ever stalls the machine, and nobody draining
  the line loses data silently.
- `mcu_emu` consumes the ZiFi path's `dll`/`dlm` divisor writes and ignores
  them, so the USB channel is always 115200. Whether ZiFi software needs a
  honoured divisor is a board question, open with stage 5.
- on the board, still unverified: the **first** byte a ZiFi program sends lands
  in an empty queue and has to start the sender itself. `sim/tb_mcu_emu.sv`
  covers that hand-over, the real ROM's first write has not been watched yet.

## Tape

The tape file is MiSTer disk slot 0: pick it with the OSD `Tape` item (the
main page, right after Covox). TAP, TZX and CSW are accepted; the format is
sniffed from the file signature. The file is never loaded into memory: the
core reads it from the SD card through a two-sector cache as the tape
plays, so a large TZX mounts instantly. `Tape play/pause`, `Tape previous
block` and `Tape next block` are OSD trigger items; a freshly mounted tape
starts paused. `Turbo` (the CPU turbo) is also the tape's fast-load rate -
the player's clock enable is the CPU's own enable, one pulse per T-state.

Playback goes through one player, the ZX core's CSW player
(`rtl/tape/tape.sv`, a copy of ZX-Spectrum_MISTer at commit c2c4e6f, with
the data-block pilot raised to 8064 pulses: the Profi ROM consumes the
standard lead-in while loading, and standard-pilot blocks fail on it; and a
`blk_seek` input added, because a converted stream has to drop its RLE
state when `tape_conv.sv` jumps to another block). A
TAP or TZX file is converted on the fly into the CSW byte stream that
player eats (`rtl/tape/tape_conv.sv`): the same 32-byte CSW v1 header that
`zxtap.py` writes, then the RLE pulse list of every block. The import's own
TAP and TZX decoders (`tape.sv` mode 0 and `rtl/tape/tzxplayer.vhd`) failed
the data block on this machine even with a byte-perfect waveform - see
`docs/dev/stage4a-results.md` - so they are compiled only for reference.

Consequences worth knowing: TZX conversion covers standard-speed (0x10)
blocks, and any other block type ends the tape where it starts; a converted
tape reports itself as unmounted once it has played to the end, so mount it
again to replay it; `Tape previous block` and `Tape next block` move
between the blocks of the converted stream, while a plain CSW file has no
block list for them. With no tape playing, a signal on the LTC2308 line-in
header drives the EAR input; the USER LED lights while the tape is playing.

## Disks

Five more MiSTer disk slots sit behind the machine's own disk interfaces;
each is mounted with its OSD item (`S1` `SD Card`, `S2` `IDE 0`, `S3`
`IDE 1`, `S4` `Floppy A`, `S5` `Floppy B`), right below the tape. Slots 1-3
are read-write: a sector the machine writes goes back through hps_io into
the mounted file. Slots 4/5 write back only for `.trd` and `.img` files
(`.scl` mounts are read-only); the FDI entries (`F1`/`F2`) are downloads,
not disk slots, and are read-only.

- **SD card (slot 1, `SD Card`)**: the Z-Controller's SPI bus at the Profi
  boundary (`SD_CS_N`/`SD_CLK`/`SD_DI`/`SD_DO`, `zc_spi` on the Z80 side)
  drives `sys/sd_card.sv`, the MiSTer card model, as an SDHC card whose
  sectors come from hps_io slot 1. This is the path the Profi's DivMMC and
  its esxDOS use (`DivMMC: On`): the image is a raw sector dump (the OSD
  item filters `.vhd`), typically a FAT16 volume.
- **IDE hard disks (slots 2 and 3, `IDE 0`/`IDE 1`)**: the Profi IDE's two
  ATA devices, upstream's `hdf_ata` (CHS and LBA28, one sector per DRQ).
  Its sector engine (`img_sdc` on the Karabas Go, the MCU's file mounter)
  is `rtl/disk/img_src.sv` on the MiSTer side: the engine fetches and stores
  sectors through hps_io slots 2/3, and `profi.vhd` carries its interface
  as the `SDC_*` ports. The HDF's sector 0 holds the geometry as an Amiga
  RDSK block (`mk_disk.py hdf` writes one); without it `hdf_ata` uses 16
  heads and 63 sectors per track. The OSD `HDD` item is fixed to `Image` -
  there is no CF card on the MiSTer, so the HDF is device 0 when mounted
  and device 1 is the second slot.

- **Floppy drives (slots 4 and 5, `Floppy A`/`Floppy B`)**: the VG93 FDC
  inside the machine now drives two drive models (`rtl/disk/floppy.sv`:
  heads, flux cells, index) over a track store in DDR3
  (`rtl/disk/fdd_store.sv`, the second master of the GS memory arbiter).
  A drive answers from the mounted image: `.trd` (TR-DOS, its ID header
  decides), `.img`/`.scl` (no reliable geometry - the `Disk layout` item
  says what they are; an `.scl` arrives as Main's converted temporary TRD,
  read-only) or an FDI stream. The tracks live in DDR3: the image is only
  consulted for the track the head asks for, and a track the machine
  writes is rebuilt in place and goes back into the mounted file. The FDI
  entries (`F1` `Floppy A FDI`, `F2` `Floppy B FDI`) stream an image in
  over the ioctl path instead of mounting it, and are read-only - their
  writes are volatile. `Disk layout` (Auto / TR-DOS / CP/M) overrides the
  geometry guess for images the ID header cannot vouch for. A TR-DOS image
  with a `boot` program starts straight from the GO menu's
  `Run TR-DOS 128K`. `profi.vhd` grows two exports for this: `ENA_CPU_O`
  and `FDC_SWAP_O` (the drive-swap cable), and hps_io gains the two image
  slots.

`tools/mk_disk.py` makes the test images (a FAT16 VHD for the SD slot,
RDSK HDFs for the IDE slots, `.trd` volumes and `.fdi` streams for the
drives) and reads them back (`ls`, `cat`) to verify what the machine wrote.

## Known limitations (stage 1)

- CPU turbo runs without memory wait states (no-wait SDRAM controller).
- Floppy drives (stage 4c): `Format Track` and the raw `Write Track`
  command are not implemented; an FDI image is read-only from the file and
  the machine's writes to it live only in DDR3 until it is re-downloaded;
  a CP/M image needs its owner reference filled (`mk_disk.py reffrom`) to
  boot; the store holds at most 84 tracks and 32 sectors per track.
- 80-column (DS80) mode: the pixel enable runs at a 9/9/10 cadence of the
  112.5 MHz video clock, so the analog scandoubler may duplicate pixels;
  HDMI is unaffected.
- DS80 mode switches at runtime: switching between the Profi menu (DS80) and the Spectrum modes, through the menu and through reset, works on the board; arbitrary software toggling is not separately tested.
