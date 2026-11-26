# Karabas Profi for MiSTer

A [MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) (DE10-Nano) port of Andy Karpov's
[karabas-go-core-profi](https://github.com/andykarpov/karabas-go-core-profi): the
**Karabas Pro+ (Profi)**, a Russian ZX Spectrum / Pentagon-class home computer with TR-DOS,
CP/M, 512x240 text-friendly video, a stack of sound chips and real disk drives.

## What you get

- **Machine**: Z80 with Profi paging, Pentagon or 48k timing, up to 8x turbo.
- **Video**: Spectrum modes and the Profi 512x240 mode, HDMI and analog, scandoubler and CRT filters.
- **Sound**: TurboSound FM (2x AY), SAA1099, OPL2, General Sound card, Covox, MIDI out
  (MidiLink or an mt32-pi on the USER port).
- **Storage**: two IDE hard disks, an SD card for esxDOS (DivMMC), two floppy drives
  (TRD, SCL, FDI, UDI, TD0 images), tape (TAP, TZX, CSW).
- **Extras**: mouse, joysticks, real-time clock from MiSTer, serial port for ZiFi/ESP software.

## Installing

1. Copy two files from [`releases/`](releases) to the MiSTer SD card:

   | From this repo | To the SD card |
   |---|---|
   | `Karabas_Profi_20261126.rbf` | `/media/fat/_Computer/` |
   | `boot.rom` | `/media/fat/games/Karabas_Profi/` |

   **Replace `boot.rom` too.** This release has a new `boot.rom` (esxDOS 0.9.0 in the DivMMC
   ROM; the other ROMs are unchanged). The core also starts with the old one, but then esxDOS
   stays at 0.8.9.

2. Put your disk, tape and hard-disk images in `/media/fat/games/Karabas_Profi/`. The OSD
   file browser opens there.
3. Start **Karabas_Profi** from the `Computer` menu.

### Update your esxDOS SD image too

The core's DivMMC ROM is now esxDOS 0.9.0, and it will not start with the system files of
0.8.x. On the SD image you mount under `SD Card`, replace the `SYS` folder and copy the `BIN`
folder of [esxdos090.zip](https://www.esxdos.org/files/esxdos090.zip) to the root (the system
commands live in `SYS/BIN` now). The shipped `SYS/CONFIG/ESXDOS.CFG` has `LFN=1` (long file
names). For the clock, add the 0.9.0 `RTC.SYS` from
[karabas-go software/esxdos](https://github.com/andykarpov/karabas-go/tree/master/software/esxdos)
to `SYS`. An `NMI.SYS` or `RTC.SYS` made for an older esxDOS must be rebuilt.

### What is new in 20261126

- **TZX tapes load.** TAP and TZX now play through the original ZX Spectrum core engines, so
  turbo, pure-tone and the other TZX blocks work, not only standard-speed ones. The old
  "R Tape loading error" and the hang at the end of a load were the tape signal switching
  to the line-in one byte early.
- **A TAP keeps playing between blocks**, no play/pause press per block.
- `Tape previous block` and `Tape next block` work for TZX only.

### What is new in 20261123

- **SDRAM reads fixed.** The previous release could fail to start (ROMain stayed blank) on
  some boards: its read of the SDRAM sampled the data before the chip had put it on the
  bus, and whether that worked depended on how the compiler placed the logic. The read is
  now timed against the chip's real data window and the build is checked for it.
- **Upstream update** (Karabas Go core, 2026-11-20): esxDOS 0.9.0, the RTC for esxDOS
  (Gluk ports and the ZX Next I2C clock) and a **tape monitor** (`Tape` page).
- **`Tape` page**: file, play/pause, previous and next block, and `Tape monitor` (`Off`,
  `In`, `Out`, `Both`: hear the tape input and/or the output).
- **`MT32-pi` page** with the options of the other MiSTer cores: `Show Info`, `LCD Type`
  (Auto, SSD1306, SH1106, HD44780) and `HD44780 Size`, `Synth` (Munt, FluidSynth, EmuSC,
  Nuked SC-55, MU50), `Munt ROM`, `SoundFont` 0 to 15 and `Reset Hanging Notes`. EmuSC,
  Nuked SC-55 and MU50 need the [ckeisc/mt32-pi](https://github.com/ckeisc/mt32-pi)
  firmware; a stock mt32-pi plays them as FluidSynth.

## Using it

### Loading things

Open the OSD (F12) and pick an image from the main page:

| Item | What it takes |
|---|---|
| `Floppy A` / `Floppy B` | `.trd`, `.scl`, `.img`. Changes are saved back to `.trd` and `.img` files. |
| `Floppy A (raw)` / `Floppy B (raw)` | `.fdi`, `.udi`, `.td0`, `.scl`, also inside a zip. Use these for protected games. They are read-only: writes last until you load another image or reload the core. |
| `Disk layout` | `Auto`, `TR-DOS` or `CP/M`. Leave on `Auto` unless an image is misdetected. |
| `IDE 0` / `IDE 1` | Hard-disk images (`.hdf`). Read-write. |
| `SD Card` | A raw SD image (`.vhd`) for esxdos. Read-write. **It must be FAT32.** A FAT16 image is ignored by the Karabas ROM. |
| `Tape` | A page: `.tap`, `.tzx`, `.csw` and the tape controls (see Tape). |

A TR-DOS disk with a `boot` program starts directly from the GO menu's `Run TR-DOS 128K`.

### Tape

Open the `Tape` page of the OSD. Mounting a tape starts it paused. Use `Tape play/pause`,
`Tape previous block` and `Tape next block`; `Tape monitor` lets you hear the tape signal. The `Turbo` setting also speeds up tape loading. Large TZX files mount
instantly. TAP and TZX play through the original ZX Spectrum core engine, so turbo, pure-tone and other TZX blocks work. `Tape previous block` and `Tape next block` work for TZX only. Once a tape has played
to the end, mount it again to replay it.

### Machine settings

`ROM Bank`, `Mode` (Pentagon or 48k timing), `Turbo`, `DivMMC`, `Pause`, `PSG Mix`, `Covox`,
`Keyboard`, joystick types, `VSync 50/60 Hz`, `GS Reset`, `NMI` and `Reset`. The `Video` page
has aspect ratio and the scandoubler/CRT filters.

### Keyboard shortcuts

MiSTer keeps F12 for its own menu, so the core has its own hotkeys (either Ctrl and either Alt):

| Keys | Does |
|---|---|
| `Ctrl+Alt+Del` | Reset |
| `Ctrl+Alt+End` | NMI |
| `Ctrl+Alt+PgUp` | Cycle Turbo: Off, 2x, 4x, 8x |

### Mouse, joysticks, clock

- **Mouse**: a regular USB/PS/2 mouse works as a Kempston mouse, and as a serial mouse for the
  CP/M driver (Profi video mode).
- **Joysticks**: pick the type for each port (Kempston, Sinclair 1/2, cursor keys, QAOPM/QAOPS).
  On Sinclair and cursor types, button B fires.
- **Clock**: the time comes from MiSTer. Writes by the machine are ignored, and the CMOS memory
  starts empty on every core load.

### Sound and MIDI

All the sound chips are on by default. `GS Reset` restarts the General Sound CPU.

For MIDI, either set `UART mode` to `MIDI` and choose a target in MiSTer's MidiLink menu
(mt32-pi over the network, MUNT, FluidSynth, a USB MIDI adapter), or connect an mt32-pi to the
USER port and use the `MT32-pi` page. With an mt32-pi on the USER port, set
`mister = on` and `output_device = i2s` in its `mt32-pi.cfg`.

### Serial port (ZiFi, ESP, WiFi software)

The machine's serial channels share MiSTer's UART. The OSD item `Serial channel` picks which
one gets it: `ESP` (default) or `USB` (fixed 115200). MiSTer's `UART mode` must be `None`,
`PPP` or `Console`, with `Baud` matching the software's speed. Flow control is up to the
software.

## Known limitations

- At 8x turbo every memory read takes one extra T-state (so about 20 % slower than an
  ideal 28 MHz); 2x and 4x have no memory wait states.
- Floppy `Format Track` and raw `Write Track` are not implemented. The drive holds up to 84
  tracks and 32 sectors per track. CP/M images need their owner reference filled to boot
  (`tools/mk_disk.py reffrom`).
- In the 512x240 mode the analog scandoubler may duplicate pixels. HDMI is fine.

## Building from source

You need Docker and the submodules (`git submodule update --init --recursive`). Nothing else
is installed locally.

```
tools/build.sh                    # full build (10-20 min); ends with "build: exit <code>"
tools/sim.sh sim/run_all.sh       # all simulation tests
```

The result is `output_files/Karabas_Profi.rbf`. The upstream sources are never edited: a
script prepares a patched copy for Quartus 17. Developer notes, rules and per-stage evidence
are in `AGENTS.md` and `docs/dev/`.

## Credits

The core is Andy Karpov's. This port adds the MiSTer side: memory, video, disks, tape, sound
routing, serial and the OSD.
