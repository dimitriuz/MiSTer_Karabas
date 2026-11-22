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
   | `Karabas_Profi_20261120.rbf` | `/media/fat/_Computer/` |
   | `boot.rom` | `/media/fat/games/Karabas_Profi/` |

2. Put your disk, tape and hard-disk images in `/media/fat/games/Karabas_Profi/`. The OSD
   file browser opens there.
3. Start **Karabas_Profi** from the `Computer` menu.

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
| `Tape` | `.tap`, `.tzx`, `.csw`. |

A TR-DOS disk with a `boot` program starts directly from the GO menu's `Run TR-DOS 128K`.

### Tape

Mounting a tape starts it paused. Use `Tape play/pause`, `Tape previous block` and
`Tape next block`. The `Turbo` setting also speeds up tape loading. Large TZX files mount
instantly. Plain TAP and standard-speed TZX blocks are supported. Once a tape has played
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
USER port and use the `MT32-pi` page.

### Serial port (ZiFi, ESP, WiFi software)

The machine's serial channels share MiSTer's UART. The OSD item `Serial channel` picks which
one gets it: `ESP` (default) or `USB` (fixed 115200). MiSTer's `UART mode` must be `None`,
`PPP` or `Console`, with `Baud` matching the software's speed. Flow control is up to the
software.

## Known limitations

- Turbo runs without memory wait states.
- Floppy `Format Track` and raw `Write Track` are not implemented. The drive holds up to 84
  tracks and 32 sectors per track. CP/M images need their owner reference filled to boot
  (`tools/mk_disk.py reffrom`).
- TZX blocks other than standard speed end the tape where they start.
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
