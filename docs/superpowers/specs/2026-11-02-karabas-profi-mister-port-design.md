# Karabas Profi core for MiSTer — design

Date: 2026-11-02. Status: draft for the owner's review (revised after the builder check).

## 1. Intent

Port Andy Karpov's Profi core for the Karabas Go boards
([karabas-go-core-profi](https://github.com/andykarpov/karabas-go-core-profi), "Karabas Pro +")
to the MiSTer (DE10-Nano, Cyclone V). The owner wants **every feature of the original that
makes sense on MiSTer**; the port is done when all of them work. The original is under
active development (`core.json` build 26110101, upstream HEAD `01dcd6c`, 2026-11-01), so the
port follows upstream instead of forking it once.

## 2. Goals, non-goals, anti-goals

**Goals**
1. A MiSTer core, provisionally `Karabas_Profi`, that runs the upstream machine
   (`src/rtl/profi.vhd` and everything under it): T80 at 3.5/7/14/28 MHz (3/6/12/24 MHz in
   80-column mode), Profi paging (`#7FFD`, `#DFFD`, `#1FFD`, `#008B`, `#018B`, `#028B`), CP/M
   mode, 1 MB RAM, Spectrum/Pentagon video and the Profi 512×240 (DS80) mode, the 50/60 Hz
   switch and the screen modes (Pentagon / 48k, upstream `kb_screen_mode`).
2. All upstream sound: TurboSound FM (2× YM2203, jt12), SAA1099, OPL2 (jtopl), General Sound
   with 2 MB, Covox/Soundrive, beeper, tape-in, the mixer with its ABC/ACB/mono and AY/YM modes.
3. All upstream storage, backed by MiSTer images:
   - Beta Disk / Profi FDC: **upstream's own VG93 model** with two emulated drives (A:, B:)
     reading TRD (read/write), raw Profi CP/M images (read/write), SCL (read-only, converted
     by Main_MiSTer) and FDI (read-only for now, any sector layout; §5.5);
   - Profi IDE / NemoIDE through upstream's `hdf_ata`, two HDF slots (master, slave);
   - Z-Controller and DivMMC through an SD card image (VHD).
4. All upstream input: Profi XT and Spectrum keyboard layouts, Kempston mouse with wheel,
   Profi serial mouse, two joysticks with Kempston/Sinclair1/Sinclair2/Cursor/QAOPM/QAOPS.
5. MC146818 RTC, set from MiSTer's clock. Its 256-byte CMOS register file persists across
   power cycles in a MiSTer save file, as upstream persists it in the MCU's EEPROM
   (`core.json` `"eeprom_bank": 1`) — ROMain and the Profi BIOS keep their settings there.
   *(my call)*
6. Serial: the ZXUNO UART, ZiFi and ZXEVO UART APIs reach **the MiSTer Linux side** over the
   framework UART as a plain tty. (The ESP-AT network daemon is a future plan.)
6a. **Tape files (MiSTer addition, owner's request):** TAP, TZX and CSW played in real time
   into the machine's tape input, so the Profi ROM's normal `LOAD ""` works. Upstream has
   only the line-in. ROM-trap instant loading is out of scope.
7. MIDI out (the SAM2695 / TurboSound MIDI path) on the **MiSTer USER port** through the
   framework's `sys/mt32pi.sv`, as in the owner's pico-speccy Plan 4.
8. The OSD offers every upstream `core.json` item with its hotkey (ROM bank, Covox, PSG mix,
   VSync, Turbo, Joystick L/R, Mode, DivMMC, Keyboard, Pause, GS Reset, NMI, Reset) plus the
   usual MiSTer video options (aspect, scandoubler fx, scale).
9. The port tracks upstream: pulling a new upstream commit is a submodule bump plus, at
   worst, a patch rebase.

**Non-goals (dropped as board-specific)**
- The board MCU link itself (`kg_mcu` SPI, burst protocol, flash boot), the dot-matrix
  display (`dot_matrix.v`), FT812 clock, HDMI frame/DVI-only, the DAC drivers
  (`kg_pcm5102`, `kg_sigma_delta_dac`), the I2S ESP audio input and the line-in ADC mix.
- The upstream on-screen overlay (`rtl/osd/overlay.vhd`, `icons.vhd`): MiSTer's OSD replaces
  it; its drive-activity icons become the MiSTer activity LED.
- The physical floppy connector and the CF card slot (both become images, goal 3).
- The "HDD: CF card / Image" switch: on MiSTer both IDE devices are images.

**Future plans (explicitly out of this design)**
- **Read/write FDI:** a small Main_MiSTer patch, offered upstream to MiSTer-devel, that skips
  its FDI→TRD conversion when a core asks for FDI explicitly, so FDI mounts as a normal disk
  slot with write-back (§5.5).
- **Network:** a Linux-side ESP-AT emulator daemon on the core's UART (pico-speccy's
  `AtEmuCore`, a protocol-only ESP-AT emulator, is the candidate to reuse), so the ESP8266
  network software works. It must not require Frontier or edits to `user-startup.sh` without
  the owner's approval.
- ROM-trap instant TAP loading. TD0/UDI as native formats.

**Anti-goals (would be a failure even if it works)**
- Editing anything under `upstream/` in place, or a hand-merged copy of upstream RTL that
  cannot take the next upstream commit.
- Patches to upstream that change behaviour on the Karabas boards. Every patch must be
  behaviour-neutral there (gated by a generic, default = upstream behaviour) and written in
  upstream's style, so it could be offered upstream.
- Regressing upstream's timing guarantees silently (§5.2: 28 MHz without wait states is
  required for "done"; any interim wait state is listed as a known limitation).

## 3. Constraints

- **Toolchain:** Quartus Prime 17.0.2 Lite in Docker image `raetro/quartus:17.0` (the owner's
  proven setup; `alterafpga/quartus-std` needs a licence). Revert `LAST_QUARTUS_VERSION` in
  the `.qsf` after each build. Launch long builds detached (`setsid nohup`).
- **Framework:** `sys/` from current Template_MiSTer, unmodified (copy from the owner's
  `~/repo/ZX-Spectrum_MISTer/sys` if it matches the template).
- **Upstream is VHDL + Verilog-2001 for Xilinx XST** and uses `unisim` primitives
  (`BUFGMUX`, `BUFGCE`, `ODDR2`, `kg_pll`), so those files are replaced, not compiled.
- **Upstream submodules:** `upstream/karabas-go-core-profi` has its own `modules/` submodule
  (karabas-go-modules, `kg_*`, `img_sdc`, `hdf_ata`); clone recursively.
- **Implementation is done by the owner's local model** through `omp`, following
  `~/repo/llm-setup/working-with-the-local-model.md`: plans must be explicit (exact files,
  entity names, port lists, commands, expected output); at most two agents at once, never two
  omp runs; every task is reviewed independently.
- **Board:** the owner's DE10-Nano; ask before every board session (its IP is to be confirmed —
  notes disagree between .13, .15 and .29). Board-side tooling from the ZX fork
  (`tools/mkeys2.py`, `shot2.sh`, `docs/hardware-testing.md` on its `savestate` branch) is reused.
  The OSD and image mounting need a human.
- **ROMs** come from upstream `src/roms/` and are not committed to this repo in modified form;
  `boot.rom` is generated by a script.

## 4. Decided by the owner

| Topic | Decision |
|---|---|
| Scope | All features of the original that make sense on MiSTer; done = all of them work. |
| Floppy formats | All of TRD, SCL, FDI; writes to TRD, and to FDI if possible. |
| Floppy controller | Port upstream's VG93 properly (owner's suggestion, after the FDI finding). |
| FDI | Read-only via a file load now; read/write via a Main_MiSTer patch later. |
| Tape | Support TAP files (owner asked); TZX/CSW come with the same player. |
| Upstream | Follow upstream as a git submodule with a patch series. |
| Serial / network | The UART goes to the Linux side; not used now, network is a nice-to-have for the future. |
| Implementation | Owner's local model through omp, per the guide above. |

## 5. Architecture

```
MiSTer_Karabas/
  upstream/karabas-go-core-profi/   pinned submodule (recursive: modules/)
  patches/NNNN-*.patch              the series, README describing each patch
  tools/apply-patches.sh            upstream -> build/upstream + patches, stamp file
  tools/make-patch.sh               init/export authoring flow (as pico-speccy)
  tools/build_boot_rom.py           boot.rom from upstream src/roms, --check mode
  tools/qbuild.sh                   Quartus in Docker
  rtl/                              MiSTer-side RTL (this repo)
  sys/                              MiSTer framework
  Karabas_Profi.sv, .qpf, .qsf, .sdc, files.qip
  docs/
```

The Quartus file list compiles upstream sources from the **patched copy** in `build/`, minus
the files this port replaces, plus `rtl/`.

### 5.1 Patch strategy (decided here)

Order of preference, to keep the series small and rebasable:

1. **Replace a whole upstream file** with a MiSTer one that keeps the entity name and port
   list, when the ports suffice. Candidates: `rtl/clock/clock.vhd` (Cyclone V PLL instead of
   `kg_pll`/`BUFGMUX`/`BUFGCE`), `rtl/memory/memory.vhd` (MiSTer SDRAM instead of SRAM +
   SDRAM; it already owns the `SDR_*` ports), `rtl/osd/overlay.vhd` (pass-through), and the
   `kg_*` board modules (`kg_sdpram`, `kg_sprom` as Cyclone V inferred RAM/ROM).
2. **A patch to `profi.vhd`** where the MiSTer side needs signals that upstream's ports do not
   carry: the host input/config/disk interface instead of `kg_mcu` (the floppy needs no
   patch: it uses upstream's existing `FDC_*` drive pins, §5.5). Each change sits behind a generic (e.g.
   `PLATFORM_MISTER`, default 0 = upstream behaviour), one topic per patch.
3. Never patch the shared machine blocks (T80, sound chips, video, IDE, DivMMC, ZC) unless a
   real bug forces it; such a fix is a patch offered upstream.

The **MCU replacement** (`rtl/mister_host.*`, name is the builder's) takes `hps_io` and
produces the same internal signals `kg_mcu` produced, so the machine keeps its logic:
- **keyboard:** MiSTer PS/2 `ps2_key` events → USB HID usage codes in the 6-key report shape
  (`KB_STATUS`, `KB_DAT0..5`) that upstream `hid_parser.vhd` consumes unchanged, so the
  Profi XT and Spectrum matrices and the joystick-on-keyboard modes stay upstream's;
- **mouse:** `ps2_mouse` → the `MS_X/Y/Z/B/UPD` deltas `kg_cursor` consumes;
- **joysticks:** MiSTer `joystick_0/1` → the 13-bit `JOY_L/R` format;
- **soft switches:** MiSTer `status` bits → `softsw_regs` with upstream's field layout
  (`SOFTSW_LAYOUT` semantics; trigger items such as GS Reset/NMI/Reset as pulses);
- **ROM loader:** `ioctl` download of `boot.rom` → `ROMLOADER_ACTIVE/ADDR/DATA/WR` at the
  addresses in `core.json` (GS ROM with address bit 31 set);
- **RTC:** MiSTer `RTC` → MC146818 registers (upstream kept the RTC in the MCU, so the
  register file, its CMOS bytes and the `#BF/#FF/#DF/#9F` access move into the core);
- **disk images:** MiSTer `sd_*` block interface → upstream's `sdc_*` sector interface for
  `hdf_ata` (replacing `img_sdc`), plus separate MiSTer slots for the floppies and the SD card;
- **UART:** the USB-RS232 (ZiFi/EVO) channel and the ESP UART (§5.7).

### 5.2 Memory

- SDRAM holds main RAM (1 MB, 64 × 16 KB pages), the ROM banks (4 × 64 KB, plus esxDOS
  8 KB at `#140000`), DivMMC RAM (512 KB at upstream's `#180000`), and General Sound's
  2 MB. Upstream's address map inside its 2 MB SRAM is kept, offset into SDRAM.
- Video RAM stays in BRAM as upstream does (16 KB Spectrum + 64 KB Profi copies written
  alongside CPU writes).
- **Requirement for "done":** upstream's "true turbo 28 MHz with no-wait memory cycles".
  Upstream relies on async SRAM (`memory.vhd`: `port1_rd` is combinational on `ENA_CPU`, a
  read completes inside one 35 ns clock), and GS shares the SDRAM. *(my call)* Stage 1 may
  start on a proven controller (the ZX fork's `sdram.sv`) with wait states at 28 MHz, listed
  as a known limitation; the no-wait controller is its own task in stage 2, and stage 2 is
  not done without it. The controller design and its clock are the builder's choice.
  Other upstream timing behaviour (FDC WAIT after a register write, IDE/ZC/GS WAITs) is kept
  as upstream implements it.
- The DE10-Nano has no SRAM; a second SDRAM board is not required.

### 5.3 Clocks

Upstream switches its bus clock between 28.125 and 24.107 MHz when DS80 changes (BUFGMUX),
with the GS on a fixed 28 MHz and the SDRAM at 84 MHz. The MiSTer port must keep the
resulting CPU and pixel rates in both modes (7 MHz / 12 MHz pixel clock; CPU 3.5…28 / 3…24 MHz;
SAA at 8 MHz; OPL and UART baud rates as upstream computes them from `ds80`). How — a Cyclone V
clock-control block switching two PLL outputs, PLL reconfiguration, or one fast clock with
enables — is the builder's call, recorded in the plan with the reason.

### 5.4 Video and audio

- Upstream's 9-bit RGB, sync, blank and `ACTIVE` go into MiSTer's `video_mixer` with a pixel
  enable at 7 or 12 MHz; MiSTer's scandoubler/scaler replaces upstream's `kg_pix_doubler`
  and HDMI path. Aspect handling must cover both 256-px and 512-px modes.
- Upstream's 16-bit `audio_mixer` output goes to the MiSTer audio output; the mt32-pi I2S
  return (goal 7) is mixed in when present. The ADC/ESP-I2S inputs are tied to zero.
- `TAPE_IN` is the OR/mix of the MiSTer I/O board's ADC line-in (as upstream) and the tape
  file player (goal 6a): the ZX fork's `rtl/tape.sv` + `rtl/tzxplayer.vhd` (TAP, TZX, CSW,
  with its F1/F2/F3 pause/prev/next keys and LED), file data in SDRAM. Turbo loading is
  plain CPU turbo; no ROM traps.

### 5.5 Floppy

**Controller: upstream's, unchanged.** `hrdy_fdc` + `vg93_*` + `fdd_glue` stay as upstream
builds them with `ENABLE_FDD => 1` (the Go layout): port decode (`fdd_cs_n`, `fdd_cs_pff_n`:
the Profi CP/M ports and the Spectrum `#1F/#3F/#5F/#7F/#FF` ports), system port `#FF`, the
WAIT behaviour, TurboFDC, `fdc_swap`. Nothing of it is patched.

**Drives: a MiSTer-side emulated floppy drive** (`rtl/`, name is the builder's) connected to
`profi.vhd`'s existing drive pins, exactly where the Go board's floppy cable is:
- inputs `FDC_DRIVE[1:0]` (A:/B: select, upstream gates them with motor), `FDC_MOTOR`,
  `FDC_STEP`, `FDC_DIR`, `FDC_SIDE_N`, `FDC_WGATE`, `FDC_WDATA`;
- outputs `FDC_RDATA` (flux pulses), `FDC_INDEX`, `FDC_TR00`, `FDC_WPRT`.
It behaves as a 300 rpm double-density drive at 250 kbit/s MFM: head position per drive,
an index pulse per revolution, and a read stream built per track from the image — gaps,
ID fields (C/H/R/N with CRC), data marks, sector data, CRC — so any sector layout the image
describes (TR-DOS 16×256, Profi CP/M 5×1024, …) is a real track to the VG93. On write, it
decodes the MFM written while `FDC_WGATE` is active back to sector data and writes the
sector into the image. Two drives, one image slot each.

Reference for the drive behaviour: upstream's `src/sim/tb_hrdy_fdc.v` already contains a
drive model (MFM track at 250 kbit/s with jitter, index, STEP/DIR, TR00, WDATA decoded
back); its tests run at 28 and 24 MHz and with a disk 2 % off speed. The emulated drive
must pass the equivalent tests against the real `hrdy_fdc`.

**Image formats and how they reach the drive:**

| Format | Slot | Access | Layout source |
|---|---|---|---|
| TRD | disk slot A / B (`sd_*`) | read/write | fixed 16×256, 2 sides, track count from size |
| Raw CP/M image (Profi 5×1024, e.g. 800 KB `.img`) | disk slot A / B | read/write | fixed by size (the builder lists the sizes supported) |
| SCL | disk slot A / B | read-only | Main_MiSTer converts it to a temporary TRD on mount |
| FDI | file-load entry per drive (`ioctl` into SDRAM) | read-only (writes kept in SDRAM until the image is replaced or power-off) | the FDI header's per-track sector table, parsed in the FPGA |

Why FDI goes through a file load: Main_MiSTer converts `.scl`, `.fdi` and `.udi` to a
temporary TRD on every disk-slot mount (`user_io_file_mount` → `x2trd()`, matched by file
extension only), which keeps only TR-DOS layout and discards writes. An `ioctl` file load
(`F` entry) is not converted, so the raw FDI reaches the core. Read/write FDI through a disk
slot waits for the Main_MiSTer patch (future plan, §2).

### 5.6 IDE and SD

- Profi IDE / NemoIDE: upstream `ide_controller` + `hdf_ata` unchanged; `hdf_ata` dev 0 and
  dev 1 both enabled and fed from two MiSTer image slots (`.img .hdf .vhd`). `ide_mux` is
  dropped (no CF card). The second slot is a MiSTer addition (upstream's OSD offers HDF0
  only; dev 1 exists inside `hdf_ata`) replacing the CF card. *(my call)*
- Z-Controller (`#57/#77`) and DivMMC (`#E3/#E7/#EB`) talk SPI to an emulated SD card:
  `sys/sd_card.sv` backed by a VHD image slot, as the ZX core does.

### 5.7 Serial

- The machine has two serial channels (the ESP UART: ZXUNO `#FC3B/#FD3B` registers and the
  ZiFi API; the USB-RS232 channel of ZiFi/EVO) and MiSTer has one UART to Linux. An OSD
  item selects which channel reaches it (default: ESP); on the Linux side it is a plain tty.
  The owner does not use serial today; the network daemon is a future plan (§2).

### 5.8 MIDI

Upstream's `MIDI_TX` (TurboSound MIDI) → 31250-baud line → `sys/mt32pi.sv` on USER_OUT[1],
I2S return mixed into audio. Revised 2026-11-08 (owner: "Mt32-pi should go to usual mister mt32
path, so I can use remote mt32-pi for example via uart/network"): the same line also goes to
`UART_TXD` when the MiSTer UART mode is MIDI (CONF_STR `UART31250,MIDI`), so Main_MiSTer's
MidiLink reaches a remote mt32-pi, MUNT/FluidSynth or USB MIDI. §5.7's serial channels take the
other UART modes in stage 5.

### 5.9 OSD

Note: no upstream soft-switch layout has both VSync and Mode — layout 0 (Go) hard-wires
`kb_screen_mode <= "00"`, layout 1 (Mini) ties `kb_vsync <= '0'` — while `pentagon_video.vhd`
supports all four combinations. The MiSTer host therefore drives the `kb_*` signals directly
(or a new `SOFTSW_LAYOUT` value in the patch); the builder picks, within §5.1.

Upstream items in upstream order and spelling, with MiSTer-side additions (drive A/B, HDD 0/1,
SD image mounts; serial channel select; MiSTer video options). Changing ROM bank or DivMMC
resets the machine, as upstream does. Hotkeys follow `core.json` where MiSTer allows them
(Menu+F1 … in upstream = MiSTer's OSD key combinations, or direct keys if Menu is not
available; the builder records the mapping in the README).

### 5.10 Revision during stage-1 planning (2026-11-02)

Research while planning stage 1 changed two "how" decisions of §5.1; goals are unchanged.

- **The MCU replacement speaks the board link instead of patching `profi.vhd`.** Upstream's
  `kg_mcu` is a decoder of the documented RP2040 ↔ FPGA SPI protocol
  (karabas-go-firmware `docs/protocol.md`: 3-byte frames for keyboard, mouse, joysticks,
  soft switches, ROM loading, RTC, image sectors, UART). The MiSTer side (`mcu_emu`) is an SPI
  master in the FPGA that plays the firmware's part on `profi.vhd`'s existing `MCU_*` pins. So
  input, OSD switches, ROM loading, RTC, HDF sectors and the USB UART need no patch at all.
- **Quartus compatibility is a mechanical build step, not a patch series.** Quartus 17 cannot
  instantiate Verilog modules directly from VHDL (`entity work.kg_sprom` → error 10481) and
  clashes `uart.v`'s `uart_tx/uart_rx` with the VHDL ones. `tools/prepare_upstream.py` copies
  upstream to `build/upstream/` and rewrites those instantiations into component declarations
  (17 modules), puts `uart.v` in its own library, provides an empty `unisim` library, and fixes
  init-file paths. A spike proved the whole upstream machine then passes Quartus 17 analysis and
  elaboration. Real patches (`patches/`) stay the tool for behaviour changes; the patch tooling
  is added by the first plan that needs one.
- Replaced upstream files (`clock.vhd`, `memory.vhd`) are copies of the pinned upstream file
  with only the board-specific part swapped; `tools/check_upstream.sh` fails when upstream
  changes them, so a submodule bump forces a re-port instead of a silent divergence.

## 6. Delivery in stages

Each stage is its own plan, merged only after it works on the board.

1. **Skeleton and boot:** repo, submodule, patch tooling, Quartus project, clocks, SDRAM,
   ROM loading, video, keyboard. Exit: ROMain menu on screen, keyboard works, all four ROM
   banks boot.
2. **Machine completeness:** turbo modes, DS80 512×240, CP/M paging, Pentagon/48k modes,
   VSync, pause, NMI, RTC, mouse (Kempston + serial), joysticks.
3. **Sound:** TurboSound FM, SAA1099, OPL2, GS (2 MB), Covox, beeper, mixer modes; MIDI to
   mt32-pi.
4. **Storage:** the emulated floppy drives on the VG93 (TRD, raw CP/M, SCL, FDI), IDE (two
   HDF), Z-Controller/DivMMC SD image, esxDOS, tape files (TAP/TZX/CSW).
5. **Serial:** both UART channels to the Linux tty, OSD channel select.
6. **Release:** README (features, controls, files, hotkeys), boot.rom script, versioned RBF.

Future: read/write FDI via the Main_MiSTer patch, the ESP-AT network daemon (§2).

## 7. Left to the builder

- Clock implementation (§5.3) and SDRAM controller design (§5.2), within the stated rates.
- Names of MiSTer-side modules and the exact patch boundaries, within §5.1's rules.
- Status-bit allocation in CONF_STR, OSD wording for MiSTer-only items.
- The emulated drive's internals (track buffer in BRAM or built on the fly, write decode),
  within §5.5's behaviour and tests.
- Test approach per stage (simulation where cheap; the board is the final check).
