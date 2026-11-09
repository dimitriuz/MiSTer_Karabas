# Stage 1 — Skeleton and boot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this project the implementer of every task is the owner's local model through `omp` (see Global Constraints); the controller (Claude) dispatches, reviews and runs the board task.

**Goal:** A MiSTer RBF that runs the unmodified upstream Profi machine, loads its ROMs from `boot.rom`, shows the ROMain menu over HDMI, takes the MiSTer keyboard, and boots all four ROM banks.

**Architecture:** Upstream (`upstream/karabas-go-core-profi`, pinned submodule) is copied to `build/upstream/` by `tools/prepare_upstream.py`, which makes it Quartus-17-compatible mechanically (no patches). Two upstream files are replaced by MiSTer versions with the same entity and ports: `clock.vhd` (Cyclone V PLL, glitch-free 28/24 MHz bus clock mux, gated pixel clock) and `memory.vhd` (main memory in SDRAM behind an SRAM-like bridge). The board MCU is emulated by `mcu_emu`, an SPI master that speaks the karabas-go-firmware link protocol to upstream's own `kg_mcu` on `profi`'s `MCU_*` pins: ROMs from `boot.rom`, OSD switches from MiSTer `status`, keyboard as USB HID reports converted from MiSTer PS/2 events. `Karabas_Profi.sv` (the MiSTer `emu` module) instantiates `profi` and the MiSTer framework.

**Tech Stack:** VHDL-93 and Verilog-2005/SystemVerilog (Quartus Prime 17.0.2 Lite, Docker image `raetro/quartus:17.0`), GHDL 5 and Icarus Verilog 12 in a local Docker image `karabas-sim:1`, Python 3 tools with `unittest`.

**Spec:** `docs/superpowers/specs/2026-11-02-karabas-profi-mister-port-design.md` (§5.1–5.4, §5.10, §6 stage 1). Read §5.10 first: it records why this plan has no patches.

## Global Constraints

- Agent process rules — toolchain, gate commands, build numbering, the board
  driving recipe and commit format — are in `AGENTS.md` at the repository root;
  read it before the first task.
- Upstream pins: `upstream/karabas-go-core-profi` at `01dcd6c08a4b9e536103396ab2f2f29b44e8d035` (URL `https://github.com/andykarpov/karabas-go-core-profi.git`), with its submodule `modules/` at `2b9776e (the gitlink recorded by core-profi@01dcd6c; full hash from `git -C upstream/karabas-go-core-profi ls-tree HEAD modules`)` (karabas-go-modules). Clone recursively. Nothing under `upstream/` is ever edited.
- MiSTer framework: `sys/` copied unmodified from `https://github.com/MiSTer-devel/Template_MiSTer` at `76dd8f5c509a2237b8e707773032a31df5905048`; record the commit in `sys/TEMPLATE_COMMIT`. Never edit `sys/`.
- Reference repos, read-only: `~/repo/ZX-Spectrum_MISTer` (branch `master` @ `756fd4b`), `~/repo/MiSTer_pico-speccy`. Copies from them keep their licence header and name the source commit in a comment.
- Quartus: `tools/qbuild.sh . Karabas_Profi` (Docker `raetro/quartus:17.0`), launched detached (`setsid nohup … >build/logs/qbuild.log 2>&1 &`), never two builds at once. Revert `LAST_QUARTUS_VERSION` in `Karabas_Profi.qsf` after every build (`git checkout -p` or the sed in Task 1's README note).
- Simulation: everything runs in Docker image `karabas-sim:1` through `tools/sim.sh <command…>` (repo mounted at `/work`, host uid). GHDL with `--std=93c -fsynopsys` for VHDL (upstream uses `std_logic_unsigned`); `iverilog -g2012` for Verilog/SV.
- Every simulation test prints exactly one final line `<tb_name>: PASS` or `<tb_name>: FAIL <reason>` and exits non-zero on failure; `sim/run_all.sh` runs all of them and ends with `run_all: N passed, 0 failed`.
- Python tools: Python 3 stdlib only; tests are `unittest` modules under `tools/tests/`, run by `python3 -m unittest discover -s tools/tests -v`.
- Clock frequencies (from the 50 MHz MiSTer clock, one PLL, VCO 675 MHz): `clk_28` = 28.125 MHz (`/24`), `clk_24` = 24.107143 MHz (`/28`), `clk_sdr` = 112.5 MHz (`/6`). `clk_sys` (hps_io, `mcu_emu`, `ps2_hid`) = the MiSTer `CLK_50M` input (50 MHz), not a PLL output. `clk_bus` = `clk_28` when `DS80 = '0'`, `clk_24` when `DS80 = '1'`.
- `profi` generics in this stage: `ENABLE_FDD => 1, ENABLE_GS => 0, ENABLE_OPL3 => 1, ENABLE_SAA => 1, ENABLE_SERIAL_MOUSE => 1, NUM_KEYS => 4, USE_T80s => 1, BURST_MAX_MHZ => 0, SOFTSW_LAYOUT => 0`.
- MCU link (karabas-go-firmware `docs/protocol.md`, quoted where used): SPI mode 0, MSB first, 24-bit frames `CMD ADDR DATA` with `MCU_CS_N` low around each frame. `mcu_emu` SCK = `clk_sys`/4 (12.5 MHz; the firmware uses 16 MHz), `MCU_CS_N` high for at least 32 `clk_sys` clocks (640 ns ≥ `kg_mcu`'s 3-clock chip-select filter) between frames: 2.56 µs per frame, about 1 s for `boot.rom`.
- `boot.rom` layout (built by `tools/build_boot_rom.py` from upstream `src/roms/`): offset `0x00000` ROMain_ramdisk_D.rom (64 KiB), `0x10000` bios_pqdos.rom (64 KiB), `0x20000` FDImageGO.rom (64 KiB), `0x30000` ROMain_fatall_ramdisk_D.rom (64 KiB), `0x40000` esxdos089.bin (8 KiB, padded with `0xFF` to 64 KiB), `0x50000` gs105b.rom (32 KiB). Total `0x58000` bytes. ROM loader address for a byte at offset `o`: `o < 0x50000` → `0x00100000 + o`; else `0x80000000 + (o - 0x50000)` (these are `core.json`'s addresses).
- Known limitations allowed at the end of stage 1 (list them in `README.md`): CPU turbo above 7 MHz may crash (the SDRAM bridge has no wait path yet; stage 2); General Sound disabled; no RTC, mouse, joysticks, disks, tape; MiSTer analog-VGA scandoubler in the 80-column mode untested.
- Commit messages: `area: what changed` (areas: `tools`, `sim`, `clock`, `mem`, `host`, `top`, `docs`), each ending with the two attribution lines given by the controller in the dispatch.

## Review Focus

1. **Bus clock switch while the CPU runs** (software toggles `#DFFD` bit 7 in a tight loop): the bus clock must never produce a pulse shorter than the half period of `clk_28` (17.7 ns) and must settle on the new frequency. → Task 2 `tb_clock` `switch_storm`.
2. **A byte written and read back immediately** (CPU `LD (HL),A : LD B,(HL)`, and the ROM loader followed at once by a CPU read of the same address after reset): the read must return the new byte, not a stale cached word. → Task 3 `tb_sram_bridge` `write_then_read_same_addr`.
3. **Keys held through a seventh key, and E0-prefixed keys** (cursor keys vs. keypad digits, right Ctrl/Alt): the HID report keeps the first six keys, and a release of an extended key releases the right usage. → Task 4 `tb_ps2_hid` `seven_keys` and `extended_vs_keypad`.
4. **An OSD change during ROM loading, and a ROM bank change right after boot**: no switch frame may be lost or sent before `INIT_DONE`; the last value must win. → Task 5 `tb_mcu_emu` `switch_during_load`.
5. **A missing `boot.rom`**: the machine must stay in reset with the screen black, not run garbage. → Task 5 `tb_mcu_emu` `no_boot_rom_stays_busy`.

---

### Task 1: Repository skeleton, toolchain and Quartus-compatible upstream

**Files:**
- Create: `.gitignore` (`build/`, `output_files/`, `db/`, `incremental_db/`, `*.rbf`, `*.qws`, `__pycache__/`), `README.md` (one-paragraph project description + "Building" section), `upstream/karabas-go-core-profi` (submodule, recursive), `sys/` (copy, see Global Constraints), `sys/TEMPLATE_COMMIT`
- Create: `tools/sim/Dockerfile`, `tools/sim.sh`, `tools/qbuild.sh` (copy of `~/repo/MiSTer_pico-speccy/tools/qbuild.sh`, unchanged except the usage line), `tools/prepare_upstream.py`, `tools/elab_upstream.sh`, `tools/check_upstream.sh`, `tools/upstream-pins.txt`, `rtl/compat/unisim_vcomponents.vhd`
- Test: `tools/tests/test_prepare_upstream.py`

**Interfaces:**
- Produces: `build/upstream/` (generated, gitignored) mirroring `upstream/karabas-go-core-profi/src/rtl/**` under `build/upstream/src/rtl/` and `modules/rtl/**` under `build/upstream/modules/rtl/`; `build/upstream/upstream.qip` (Quartus file list for the core profile); `build/upstream/STAMP` (both upstream commit hashes). CLI: `python3 tools/prepare_upstream.py [--profile core|elab] [--out build/upstream]`.
- Produces: library `unisim` with an empty package `vcomponents` (`rtl/compat/unisim_vcomponents.vhd`, added to Quartus with `-library unisim`).
- Produces: `tools/sim.sh <cmd…>` → runs `<cmd…>` in `karabas-sim:1` at `/work`; builds the image from `tools/sim/Dockerfile` if missing.

- [ ] **Step 1: Submodule, `sys/`, ignore file, sim image.** `git submodule add https://github.com/andykarpov/karabas-go-core-profi.git upstream/karabas-go-core-profi`, check out the pinned commit, `git submodule update --init --recursive`, verify `git -C upstream/karabas-go-core-profi/modules rev-parse HEAD` prints the pinned modules commit (if the superproject pin differs, stop and report NEEDS_CONTEXT). Copy Template_MiSTer `sys/` at its pin. `tools/sim/Dockerfile`: `FROM debian:trixie`, `apt-get install -y ghdl iverilog python3 make`; image tag `karabas-sim:1`. Run `tools/sim.sh sh -c 'ghdl --version | head -1; iverilog -V 2>&1 | head -1'` — expected: `GHDL 5.…` and `Icarus Verilog version 12.…`.

- [ ] **Step 2: Write the failing tests `tools/tests/test_prepare_upstream.py`.** They run the tool into a temp dir and assert:
  - `test_component_rewrite`: in the output `src/rtl/profi.vhd` there is no `entity work.kg_mcu`, `entity work.kg_soft_switches`, `entity work.hdf_ata`, … for **every** Verilog module instantiated directly from VHDL (list computed by the test the same way: VHDL `entity work.X` where `X` is a Verilog `module X` and not a VHDL `entity X`; at the pinned upstream that is the 17 names `audio_mixer dot_matrix gs_top hdf_ata hrdy_fdc img_sdc kg_cursor kg_fifo kg_mcu kg_pix_doubler kg_sdpram kg_soft_switches kg_sprom opl2_top saa1099 turbosound zc_spi`), and each file that instantiates one contains exactly one `component <name>` declaration for it (files that already declare it, e.g. `opl2_top` in `profi.vhd`, keep theirs and get no second one).
  - `test_component_ports_have_defaults`: every `in` port of a generated component has a default (`:= '0'`, `:= '1'`, `(others => '0')` or `(others => '1')`), and Verilog defaults that are all-ones become `'1'`/`(others => '1')`.
  - `test_sized_literal_generics`: the generated `hdf_ata` component has `DEF_HEADS : integer := 16` and `DEF_SPT : integer := 63`; vector-typed parameters (`kg_soft_switches`' `INIT`) are omitted.
  - `test_uart_library`: `upstream.qip` lists `uart.v` with `-library zxuno` and every other file in `work`.
  - `test_init_paths`: the output `icons.vhd` has `INIT_FILE => "build/upstream/src/rtl/osd/icons.bit"`, `vg93_urom.v` has `` `define VG93_ROM_FILE "build/upstream/src/rtl/vg93/vg93-microcode-rom.hex" `` and `saa1099.v` reads `"build/upstream/src/rtl/sound/saa1099_compressor_lut.hex"`, and those three files exist in the output.
  - `test_core_profile_excludes`: `upstream.qip` (core profile) contains none of `rtl/clock/clock.vhd`, `rtl/memory/memory.vhd`, `rtl/memory/sdram.vhd`, `modules/rtl/clk/kg_pll.v`, `rtl/karabas_go_top.vhd`, `rtl/hdmi/hdmi_frame.v`, `modules/rtl/audio/kg_pcm5102.v`; the elab profile keeps `memory.vhd` and `sdram.vhd` and excludes the rest.
  - `test_file_order`: files appear in the order of `src/karabas_go.prj`.

  Run `python3 -m unittest tools.tests.test_prepare_upstream -v` — expected: FAIL (tool missing).

- [ ] **Step 3: Implement `tools/prepare_upstream.py`.** Start from `docs/superpowers/plans/stage1-assets/compize_proto.py`: the spike prototype that, applied to a flat copy of upstream, made Quartus 17 analysis and elaboration of `profi` pass. Keep its rules (comment stripping, ANSI header parse, `integer`/`string` generics, vector parameters skipped, input defaults, skip already-declared components) and add: directory-preserving copy, the qip writer from `karabas_go.prj` order (`vhdl work "x"` → `VHDL_FILE`, `verilog work "x"` → `VERILOG_FILE`; `../modules/` → `build/upstream/modules/`), the two exclusion profiles, the three init-path rewrites, `STAMP`. A Verilog port the parser cannot read is an error naming the module and the port text — never a silent skip. Run the tests — expected: PASS.

- [ ] **Step 4: `tools/elab_upstream.sh` — the upstream gate.** It runs `prepare_upstream.py --profile elab --out build/elab/upstream`, writes `build/elab/elab.qpf/.qsf` (family Cyclone V, device `5CSEBA6U23I7`, top `profi`, the unisim stub, the generated qip, and a generated `clock` stub: upstream `clock.vhd`'s entity copied verbatim with an architecture that drives every clock output from `CLK`, every enable `'1'`, `ARESET` `'0'`), and runs `quartus_map elab --analysis_and_elaboration` in `raetro/quartus:17.0`. Last line `elab_upstream: exit <code>`. Run it — expected: `elab_upstream: exit 0` (the spike's result; it takes about 3 minutes).

- [ ] **Step 5: `tools/check_upstream.sh` and `tools/upstream-pins.txt`.** Pins: `sha256  src/rtl/clock/clock.vhd`, `sha256  src/rtl/memory/memory.vhd` (computed from the pinned upstream). The script fails with `check_upstream: <file> changed upstream — re-port rtl/replaced/<file>` when a hash differs, and fails when `src/rtl/profi.vhd` contains `clk_adc` on any lines other than exactly three (its signal declaration, `CLK_ADC => clk_adc`, `ADC_CLK <= clk_adc`) — Task 2 uses `CLK_ADC` as the pixel-enable carrier. Expected now: `check_upstream: OK`.

- [ ] **Step 6: Commit.** `git add -A && git commit` with message `tools: upstream submodule, sys/, sim image, Quartus-compatible upstream copy`.

---

### Task 2: Clock generator for Cyclone V (`rtl/replaced/clock.vhd`)

**Files:**
- Create: `rtl/pll.v`, `rtl/pll/pll_0002.v`, `rtl/pll/pll_0002.qip`, `rtl/pll.qip` (from Template_MiSTer `rtl/pll*`, re-parameterised)
- Create: `rtl/clk/clkmux2.vhd`, `rtl/clk/clkgate.vhd`, `rtl/replaced/clock.vhd`
- Test: `sim/tb_clock.vhd`, `sim/models/pll_model.vhd`, `sim/run_tb_clock.sh`

**Interfaces:**
- Consumes: upstream `clock` entity port list (unchanged, `upstream/…/src/rtl/clock/clock.vhd` lines 15–55 at the pin).
- Produces: entity `clock` (same ports). Mapping: `CLK_BUS` = glitch-free mux of `clk_28`/`clk_24` selected by `DS80`; `CLK_GS` = `clk_28`; `CLK_SDR` = `clk_sdr` (112.5 MHz); `CLK_RGB` = `CLK_BUS` gated by `ENA_RGB`; `CLK_VGA` = `CLK_BUS`; **`CLK_ADC` = `ENA_RGB` (a data signal: the pixel enable for the MiSTer top)**; `CLK_12`, `CLK_8` = `'0'`; `ARESET` = `not locked`; all `ENA_*`/`CE_*` exactly as upstream.
- Produces: `pll` module (Verilog): `refclk`, `rst`, `outclk_0` (28.125), `outclk_1` (24.107143), `outclk_2` (112.5), `locked`.
- Produces: entity `clkmux2` (`clk0, clk1 : in std_logic; sel : in std_logic; clk_out : out std_logic`) — glitch-free: two branches, each with a 2-stage synchroniser on the **falling** edge of its own clock, enable of one branch only after the other has turned off, `clk_out = (clk0 and en0) or (clk1 and en1)`. Entity `clkgate` (`clk, en : in std_logic; gclk : out std_logic`): `en` registered on the falling edge of `clk`, `gclk = clk and en_r`.

- [ ] **Step 1: Write the failing test `sim/tb_clock.vhd`** (GHDL; `sim/models/pll_model.vhd` is a sim-only `pll` entity producing 28.125/24.107143/112.5 MHz with `locked` after 1 µs). Cases, each printing its name on success:
  - `freq_28`: `DS80 = '0'` → 100 consecutive `CLK_BUS` periods each 35.555 ns ± 0.01 ns.
  - `freq_24`: `DS80 = '1'` → periods 41.481 ns ± 0.01 ns.
  - `switch_storm`: toggle `DS80` every 173 ns for 20 µs; no `CLK_BUS` high or low phase shorter than 17.7 ns; after the last toggle the period settles within 4 periods.
  - `rgb_enable`: `DS80 = '0'` → `CLK_ADC` is high on exactly one of every 4 `CLK_BUS` cycles and `CLK_RGB` has exactly one rising edge per 4 `CLK_BUS` cycles, coinciding with a `CLK_BUS` rising edge; `DS80 = '1'` → one of every 2.
  - `cpu_enable`: for `TURBO` = `"00","01","10","11"`, `ENA_CPU` is high on 1 of 8, 1 of 4, 1 of 2, every `CLK_BUS` cycle.
  - `areset`: `ARESET = '1'` until the model's `locked`, then `'0'`.

  Run `tools/sim.sh sim/run_tb_clock.sh` — expected: FAIL (entity `clock` missing).

- [ ] **Step 2: Implement.** `rtl/replaced/clock.vhd` = upstream `clock.vhd` at the pin with only these changes: drop `library unisim`; replace `kg_pll` + `BUFGMUX` + `BUFGCE` (upstream lines with `U2`, `U9`, `U10`) by `pll` (component), `clkmux2`, `clkgate`; `CLK_ADC <= ENA_RGB`; `CLK_12 <= '0'; CLK_8 <= '0'`. Every enable process stays byte-identical (the reviewer diffs it against upstream). First line comment: `-- Replaces upstream src/rtl/clock/clock.vhd @ 01dcd6c (tools/upstream-pins.txt); keep the enable logic identical.` PLL: Template's `pll_0002.v` with `reference_clock_frequency "50.0 MHz"`, `number_of_clocks 3`, the three output frequencies above, phase 0. Run the test — expected: `tb_clock: PASS`.

- [ ] **Step 3: Commit.** `clock: Cyclone V clock generator with glitch-free 28/24 MHz bus clock`.

---

### Task 3: Main memory in SDRAM (`rtl/replaced/memory.vhd`, `rtl/mem/`)

**Files:**
- Create: `rtl/mem/sdram.sv` (copy of `~/repo/ZX-Spectrum_MISTer/rtl/sdram.sv` @ `756fd4b`, unchanged), `rtl/mem/sram_bridge.vhd`, `rtl/replaced/memory.vhd`
- Test: `sim/tb_sram_bridge.vhd`, `sim/models/sdram_model.vhd`, `sim/run_tb_sram_bridge.sh`

**Interfaces:**
- Consumes: upstream `memory` entity port list (unchanged); `sdram` module ports as in `rtl/mem/sdram.sv` (rising edge of `rd`/`we` starts an access, `addr`/`din` held until `ready` returns high; reads of the same 16-bit word are served from its register).
- Produces: entity `sram_bridge`:
  ```
  clk_bus  : in  std_logic;
  clk_sdr  : in  std_logic;
  reset    : in  std_logic;                     -- ARESET
  rd_req   : in  std_logic;                     -- level: a CPU read wants addr
  wr_stb   : in  std_logic;                     -- one clk_bus clock: write din to addr
  addr     : in  std_logic_vector(20 downto 0); -- byte address in the 2 MiB SRAM map
  din      : in  std_logic_vector(7 downto 0);
  dout     : out std_logic_vector(7 downto 0);  -- clk_bus domain, data of the last completed read
  -- to sdram (clk_sdr domain)
  sd_addr  : out std_logic_vector(24 downto 0);
  sd_din   : out std_logic_vector(7 downto 0);
  sd_rd    : out std_logic;
  sd_we    : out std_logic;
  sd_dout  : in  std_logic_vector(7 downto 0);
  sd_ready : in  std_logic
  ```
  Behaviour: writes are queued (toggle handshake into `clk_sdr`) and complete in order; a read is issued whenever `rd_req = '1'` and `addr` differs from the address of the data in `dout`, or that data was invalidated by a write to the same address; a write always wins over a pending read. SDRAM address = `"0000" & addr` (main map at SDRAM byte 0).
- Produces: entity `memory` (same ports as upstream). Upstream logic kept identical (page mapping, DivMMC, contention, both video RAM copies, loader routing); the physical layer replaced: `sram_bridge` + `sdram` behind `port1` (`rd_req = not N_MREQ and not N_RD and not loader_act`, `wr_stb = port1_wr`, `addr = port1_a`, `din = port1_di`, `DO = dout`); `MA <= (others => '0')`, `MD <= (others => 'Z')`, `N_MRD/N_MWR <= "11"`; the GS controller (`U_SDRAM` and its state machine) removed, `GS_DO <= x"FF"`, `GS_WAIT_N <= '1'` (stage 3 restores GS); `SDR_*` driven by `sdram` (`SDR_DQM <= SDRAM_DQMH & SDRAM_DQML`). The Verilog `sdram` and `kg_sdpram` are instantiated through component declarations written in the file. First-line comment as in Task 2, naming `memory.vhd`.

- [ ] **Step 1: Write the failing test `sim/tb_sram_bridge.vhd`.** `sdram_model.vhd`: a VHDL entity `sdram` with `sdram.sv`'s client ports (`init, clk, addr, dout, din, we, rd, ready`), a 2 MiB byte array, `ready` low for 9 clocks per access, honouring the edge-start rule. `clk_bus` 28.125 MHz and 24.107 MHz runs, `clk_sdr` 112.5 MHz. Cases:
  - `read_after_reset`: preload model bytes; a read held for 16 `clk_bus` clocks (the 3.5 MHz CPU's MREQ) returns the byte; `dout` valid no later than 12 `clk_bus` clocks after `rd_req` rises.
  - `write_then_read_same_addr`: `wr_stb` at A with `0x5A`, the next `clk_bus` clock `rd_req` at A → `dout = 0x5A` within 16 clocks; the model holds `0x5A`.
  - `loader_burst`: 4096 writes, one every 128 `clk_bus` clocks (the ROM loader's pace) at consecutive addresses → model content equals the written bytes.
  - `addr_change_rereads`: `rd_req` stays high while `addr` changes twice → `dout` follows both.
  - `both_clocks`: all of the above at `clk_bus` 24.107 MHz too.

  Run `tools/sim.sh sim/run_tb_sram_bridge.sh` — expected: FAIL.

- [ ] **Step 2: Implement `rtl/mem/sram_bridge.vhd` and `rtl/replaced/memory.vhd`.** Run the test — expected: `tb_sram_bridge: PASS`. `sim/run_tb_sram_bridge.sh` also runs `ghdl -a` on `rtl/replaced/memory.vhd` (its `kg_sdpram` and `sdram` are components, so it analyses alone) — expected: no errors.

- [ ] **Step 3: Commit.** `mem: SDRAM main memory behind an SRAM-like bridge`.

---

### Task 4: PS/2 to USB HID keyboard reports (`rtl/host/ps2_hid.sv`)

**Files:**
- Create: `tools/gen_ps2_hid.py`, `tools/data/ev2ps2.txt`, `tools/data/hid_keyboard.txt`, `rtl/host/ps2_hid_table.svh` (generated, committed), `rtl/host/ps2_hid.sv`
- Test: `tools/tests/test_gen_ps2_hid.py`, `sim/tb_ps2_hid.sv`, `sim/run_tb_ps2_hid.sh`

**Interfaces:**
- Produces: module `ps2_hid(input clk, input reset, input [10:0] ps2_key, output reg [55:0] report, output reg changed)`. `ps2_key` is hps_io's: bit 10 toggles per event, bit 9 = pressed, bit 8 = E0-extended, bits 7..0 = set-2 code. `report[7:0]` = modifiers (bit 0 LCtrl, 1 LShift, 2 LAlt, 3 LGUI, 4 RCtrl, 5 RShift, 6 RAlt, 7 RGUI); `report[15:8]` … `report[55:48]` = key usages 1–6 in press order, `0x00` when free; `changed` is one clock when `report` changes.
- Produces: `ps2_hid_table.svh` — a `function automatic [7:0] ps2_to_hid(input ext, input [7:0] code)` returning the HID usage (`0x00` = unknown), with modifiers returned as usages `0xE0`–`0xE7`.

- [ ] **Step 1: Data files.** `tools/data/ev2ps2.txt`: the `ev2ps2[]` table of Main_MiSTer `input.cpp` @ `afb917fce1f3089e3d242331ddae6456ac0da8e4` (`https://raw.githubusercontent.com/MiSTer-devel/Main_MiSTer/afb917fce1f3089e3d242331ddae6456ac0da8e4/input.cpp`, the `static const int ev2ps2[]` initialiser), saved verbatim with a header naming the source. `tools/data/hid_keyboard.txt`: the `hid_keyboard[256]` table of Linux `drivers/hid/hid-input.c` at tag `v6.6` (`https://raw.githubusercontent.com/torvalds/linux/v6.6/drivers/hid/hid-input.c`), verbatim, with a header naming the source.

- [ ] **Step 2: Write the failing test `tools/tests/test_gen_ps2_hid.py`.** The generator joins the two tables on the Linux keycode (HID usage u → Linux key k = `hid_keyboard[u]` → PS/2 = `ev2ps2[k]`, with `EXT` → ext = 1, flag bits like `RCTRL`/`RALT`/`LED` stripped). Assertions on the resulting map `(ext, code) → usage`: `(0,0x1C) → 0x04` (A), `(0,0x5A) → 0x28` (Enter), `(1,0x5A) → 0x58` (keypad Enter), `(1,0x75) → 0x52` (Up), `(0,0x75) → 0x60` (keypad 8), `(0,0x14) → 0xE0` (LCtrl), `(1,0x14) → 0xE4` (RCtrl), `(1,0x11) → 0xE6` (RAlt), `(0,0x07) → 0x45` (F12), `(0,0x76) → 0x29` (Esc); no `(ext, code)` maps to two usages (when both tables give two, the lower usage wins and the test lists the collisions, which must be empty for usages `0x04`–`0x65` and `0xE0`–`0xE7`); the generated `.svh` is byte-identical to the committed one. Run — expected: FAIL.

- [ ] **Step 3: Implement `tools/gen_ps2_hid.py`** (writes `rtl/host/ps2_hid_table.svh`). Run tests — expected: PASS.

- [ ] **Step 4: Write the failing test `sim/tb_ps2_hid.sv`.** Cases: `press_release_a` (report byte 1 = `0x04`, then `0x00`; `changed` pulses twice); `modifiers` (LShift, RAlt → `report[7:0] = 0x42`); `seven_keys` (press A–G: keys 1–6 hold A–F, G ignored; release B → slots compact to A,C,D,E,F and G is **not** added later); `extended_vs_keypad` (E0 75 press → `0x52`, release of plain 75 does not release it); `repeat_press_ignored` (typematic repeats of a held key change nothing, `changed` stays low). Run `tools/sim.sh sim/run_tb_ps2_hid.sh` — expected: FAIL.

- [ ] **Step 5: Implement `rtl/host/ps2_hid.sv`.** Run — expected: `tb_ps2_hid: PASS`.

- [ ] **Step 6: Commit.** `host: PS/2 to USB HID boot report converter with a generated key table`.

---

### Task 5: MCU emulator (`rtl/host/mcu_spi_master.sv`, `rtl/host/mcu_emu.sv`)

**Files:**
- Create: `rtl/host/mcu_spi_master.sv`, `rtl/host/mcu_emu.sv`, `rtl/host/osd_items.svh` (the switch table below as SystemVerilog constants and a function `status → value` per index; Task 6 includes it too)
- Test: `sim/tb_mcu_emu.sv`, `sim/run_tb_mcu_emu.sh` (compiles upstream `kg_mcu.v` and its `kg_*` submodules from `build/upstream/modules/rtl/mcu/` plus `kg_soft_switches.v`, `kg_fifo.v` unchanged)

**Interfaces:**
- Consumes: `ps2_hid` (Task 4) `report`/`changed`.
- Produces: module `mcu_spi_master #(parameter DIV = 4, parameter GAP = 32) (input clk, input reset, input [23:0] tx, input start, output reg busy, output reg [23:0] rx, output reg rx_valid, output reg spi_cs_n, output reg spi_sck, output reg spi_mosi, input spi_miso)` — one 24-bit frame per `start`, mode 0, MSB first, SCK = `clk`/`DIV`, CS high ≥ `GAP` clocks after each frame.
- Produces: module `mcu_emu`:
  ```
  #(parameter TRIGGER_CLKS = 5000000,   // 100 ms at clk_sys = 50 MHz
    parameter NOP_CLKS     = 5000)      // a NOP poll every 100 us when idle
  (input clk, input reset,              // clk_sys; reset = power-on only
   // boot.rom download (hps_io ioctl, index 0)
   input ioctl_download, input [15:0] ioctl_index, input ioctl_wr,
   input [26:0] ioctl_addr, input [7:0] ioctl_dout, output reg ioctl_wait,
   // OSD
   input [127:0] status, input osd_reset,          // osd_reset: level, OSD Reset or the MiSTer button
   // keyboard
   input [55:0] kb_report, input kb_changed,
   // link to profi
   output spi_cs_n, output spi_sck, output spi_mosi, input spi_miso,
   output reg [23:0] last_reply, output reg reply_valid)   // for later stages; ignored now
  ```
  Start sequence (protocol.md §3, without CAPS, OSD font and build ids): wait for `ioctl_download` with `ioctl_index == 0`; `FD 00 00` (INIT_START); `F9 00 01` (HW_SETUP board = Go); `08 00 01` (ROMLOADER on); for every `ioctl_wr` byte: `06 i bank_i` frames (i = 0,1,2) for address bits 15..8, 23..16, 31..24 whenever they differ from the last sent, then `07 a7..0 byte` (address per the `boot.rom` mapping in Global Constraints), holding `ioctl_wait` until the frames are out; at the end of the download `08 00 00`; then all 14 switch frames (`05 index value`, indices 0–8 and 10–14, per the table below); `01 i 00` for i = 0..6; `FE 00 00` (INIT_DONE). Run loop, in priority order: a changed switch value → its `05` frame; `kb_changed` → the seven `01 i report_byte_i` frames; a trigger rising edge → `05 idx 01`, and `05 idx 00` after `TRIGGER_CLKS`; otherwise `FF 00 00` every `NOP_CLKS`. Replies (`rx` with `rx_valid`) whose command is not `FF` go to `last_reply`/`reply_valid`. A second `boot.rom` download repeats the start sequence.

  Switch table (index: `status` field → value sent; options listed in CONF_STR order, Task 6 builds the CONF_STR from the same table — keep them in one place, `rtl/host/osd_items.svh`, included by both):

  | idx | item | status | value |
  |---|---|---|---|
  | 0 | ROM Bank | `[2:1]` | field |
  | 1 | Covox | `[3]` | `~field` (CONF_STR `On,Off`) |
  | 2 | PSG Mix | `[6:4]` | `(field + 1) % 6` (CONF_STR `AY ACB,AY Mono,YM ABC,YM ACB,YM Mono,AY ABC`) |
  | 3 | VSync | `[7]` | field |
  | 4 | Turbo | `[9:8]` | field |
  | 5 | Joystick L | `[12:10]` | field (≤ 5) |
  | 6 | Joystick R | `[15:13]` | `(field + 1) % 6` (CONF_STR `Sinclair1,Sinclair2,Cursor,QAOPM,QAOPS,Kempston`) |
  | 7 | DivMMC | `[16]` | field |
  | 8 | HDD | — | constant 1 (Image; no CF card on MiSTer) |
  | 10 | Keyboard | `[17]` | field |
  | 11 | Pause | `[18]` | field |
  | 12 | GS Reset | `[19]` trigger | pulse |
  | 13 | NMI | `[20]` trigger | pulse |
  | 14 | Reset | `osd_reset` | pulse |

- [ ] **Step 1: Write the failing test `sim/tb_mcu_emu.sv`.** Instantiate `mcu_emu` (with `TRIGGER_CLKS = 2000`, `NOP_CLKS = 200`), upstream `kg_mcu` with `profi.vhd`'s generics (`BURST_MAX_MHZ 0, CS_FILTER 3, ENABLE_RTC 1, ENABLE_UART 1, ENABLE_MATRIX 1, ENABLE_DEBUG 0, ENABLE_IMG 1, ENABLE_FILE 0, ENABLE_FT 0, ENABLE_SD2 0`) on its own `clk_bus` (28.125 MHz; `clk_sys` 50 MHz, unrelated phase), and upstream `kg_soft_switches #(.N(15))` fed by `kg_mcu`'s `SOFTSW_COMMAND`, wired as in `profi.vhd`. A behavioural ioctl source plays a 0x58000-byte pseudo-random `boot.rom` (seeded) — 100 µs simulated per KiB is fine. Cases:
  - `rom_load`: every `ROMLOAD_WR` of `kg_mcu` is recorded; the recorded (address, byte) list equals the Global-Constraints mapping of the source, in order, with no duplicates; `ROMLOADER_ACTIVE` is 1 from before the first write to after the last.
  - `init_and_busy`: `kg_mcu` `BUSY` is 1 until after the last switch frame, then 0.
  - `switches`: with `status` set to a vector that exercises every row of the table (ROM Bank 3, Covox field 0, PSG field 5, Turbo 2, Joystick R field 5, …), every `kg_soft_switches` register 0–14 holds the table's value after INIT_DONE; changing `status[2:1]` to 1 afterwards changes register 0 to 1 within 50 µs.
  - `switch_during_load`: `status` changes twice while the ROM streams; after INIT_DONE the registers hold the last value, and no `05` frame was sent before the ROMLOADER-off frame.
  - `keyboard`: `kb_report = {8'h00,8'h00,8'h00,8'h00,8'h00,8'h04,8'h02}` with `kb_changed` → `kg_mcu` `KB_STATUS = 0x02`, `KB_DAT0 = 0x04`, others 0, within 50 µs.
  - `reset_trigger`: `osd_reset` high for one clock → register 14 = 1, then 0 after `TRIGGER_CLKS`.
  - `no_boot_rom_stays_busy`: no download for 2 ms → `BUSY` stays 1 and no frame was sent (`spi_cs_n` never went low).

  Run `tools/sim.sh sim/run_tb_mcu_emu.sh` — expected: FAIL. If an upstream module does not compile in Icarus 12, report BLOCKED with the error; do not edit upstream.

- [ ] **Step 2: Implement `mcu_spi_master.sv`, `osd_items.svh`, `mcu_emu.sv`.** Run — expected: `tb_mcu_emu: PASS`.

- [ ] **Step 3: Commit.** `host: MCU link emulator — boot.rom, OSD switches and keyboard over the Karabas protocol`.

---

### Task 6: MiSTer top, Quartus project and boot.rom (`Karabas_Profi.sv`)

**Files:**
- Create: `Karabas_Profi.sv`, `Karabas_Profi.qpf`, `Karabas_Profi.qsf`, `Karabas_Profi.sdc`, `files.qip`, `rtl/video/vblank_gen.sv`, `tools/build_boot_rom.py`, `tools/build.sh`
- Modify: `README.md` (Building, Installing, Known limitations)
- Test: `sim/tb_vblank_gen.sv`, `sim/run_tb_vblank_gen.sh`, `tools/tests/test_build_boot_rom.py`, `sim/run_all.sh`

**Interfaces:**
- Consumes: everything above; Template_MiSTer `Template.sv` / `Template.qsf` as the pattern for the `emu` module, the qsf/qpf and the `sys` hookup.
- Produces: module `vblank_gen(input clk, input ce, input hs, input vs, input blank, output reg vblank)` — counts lines (HS rising) from VS rising; per frame records the first and last line that had any `ce` clock with `blank = 0`; `vblank` = current line < first or > last **of the previous frame** (all 0 during the first frame).
- Produces: `tools/build_boot_rom.py [--roms upstream/karabas-go-core-profi/src/roms] [--out releases/boot.rom] [--check FILE]` — writes/verifies the Global-Constraints layout; `--check` prints `boot.rom: OK sha256=<hex>`.
- Produces: `tools/build.sh` = `python3 tools/prepare_upstream.py && tools/check_upstream.sh && tools/qbuild.sh . Karabas_Profi`, last line `build: exit <code>`.

`Karabas_Profi.sv` wiring (the decisions the template does not make):
- Clocks: the only PLL is inside `clock` (Task 2), below `profi`. `emu` takes `clk_bus = profi.CLK_BUS` and `clk_sdr = profi.CLK_SDR` from `profi`'s ports. `clk_sys` (for `hps_io`, `mcu_emu`, `ps2_hid`) is **`CLK_50M` itself** — no second PLL. Every path between `clk_sys` and the machine is asynchronous by design (the SPI link into `kg_mcu`, quasi-static OSD bits into `video_mixer`).
- `CLK_VIDEO` = `profi.CLK_BUS`; `ce_pix` = `profi.ADC_CLK` (= `ENA_RGB`, Task 2). `video_mixer #(.LINE_LENGTH(1024), .GAMMA(1))` with `R/G/B` = each 3-bit component of `profi.RGB` (`RGB[8:6]` R, `[5:3]` G, `[2:0]` B) widened to 8 bits as `{c, c, c[2:1]}`; `HSync = ~RGB_HS`, `VSync = ~RGB_VS` (upstream syncs are active low); `HBlank = RGB_BLANK`; `VBlank` from `vblank_gen`; `scandoubler` = `forced_scandoubler | (status scandoubler-fx ≠ 0)`; `hq2x` = fx == 1.
- `VIDEO_ARX/ARY` = 4:3 unless the Aspect item says full screen (template pattern). Audio: `AUDIO_L/R = profi.AUDIO_L/R`, `AUDIO_S = 1`, `AUDIO_MIX = 0`.
- SDRAM: `profi.SDR_*` → `SDRAM_A, SDRAM_BA, SDRAM_DQ, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS`, `{SDRAM_DQMH, SDRAM_DQML} = SDR_DQM`, `SDRAM_nCS = 0`, `SDRAM_CKE = 1`, `SDRAM_CLK` from an `altddio_out` of `clk_sdr` (copy the block at the end of `rtl/mem/sdram.sv`).
- `profi` unused inputs: `UART_RX = 1`, `SD_DO = 1`, `SD_DET_N = 1`, `TAPE_IN = 0`, `ADC_L/R = 0`, `ESP_L/R = 0`, `MCU_IO = "0000"`, `MCU_BURST_CS_N = 1`, `FDC_INDEX/TR00/WPRT/RDATA = 0` (active-high inputs at the `profi` boundary: no drive), `MD`/`WD` left open (`inout`). `profi.MCU_*` ↔ `mcu_emu` spi pins.
- `LED_USER = 0`, `LED_DISK = 0`, `LED_POWER = 0` in this stage.
- CONF_STR (status bit allocations from Task 5's table; `osd_items.svh` also used here):
  ```
  "Karabas_Profi;;",
  "-;",
  "P1,Video;",
  "P1O[22:21],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
  "P1O[25:23],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
  "P1O[7],VSync,50 Hz,60 Hz;",
  "-;",
  "O[2:1],ROM Bank,ROMain,PQ-DOS,FDImage,FATALL;",
  "O[9:8],Turbo,Off,2x,4x,8x;",
  "O[6:4],PSG Mix,AY ACB,AY Mono,YM ABC,YM ACB,YM Mono,AY ABC;",
  "O[3],Covox,On,Off;",
  "O[12:10],Joystick L,Kempston,Sinclair1,Sinclair2,Cursor,QAOPM,QAOPS;",
  "O[15:13],Joystick R,Sinclair1,Sinclair2,Cursor,QAOPM,QAOPS,Kempston;",
  "O[16],DivMMC,Off,On;",
  "O[17],Keyboard,Profi XT,Spectrum;",
  "O[18],Pause,Off,On;",
  "-;",
  "T[19],GS Reset;",
  "T[20],NMI;",
  "R[0],Reset;",
  "V,v",`BUILD_DATE
  ```
  `osd_reset` = `status[0] | buttons[1] | RESET`.

- [ ] **Step 1: Write the failing tests.** `tools/tests/test_build_boot_rom.py`: output size `0x58000`; bytes at each offset equal the source files; `0x42000`–`0x4FFFF` are `0xFF`; `--check` on the output prints `OK` and on a one-byte-modified copy exits 1. `sim/tb_vblank_gen.sv`: a synthetic 312-line frame (448 clocks/line, `ce` every 4th clock, blank outside lines 48–287 and outside clocks 64–383) → in the second and later frames `vblank` is 1 exactly on lines 0–47 and 288–311; a switch to a 320-line frame with active 40–279 is tracked one frame later. `sim/run_all.sh` runs every `sim/run_tb_*.sh`. Run — expected: FAIL.

- [ ] **Step 2: Implement `vblank_gen.sv` and `build_boot_rom.py`.** Run — expected: PASS.

- [ ] **Step 3: Implement the Quartus project and `Karabas_Profi.sv`** per the wiring above. `files.qip`: `rtl/compat/unisim_vcomponents.vhd -library unisim`, `build/upstream/upstream.qip`, `rtl/pll.qip`, `rtl/replaced/*.vhd`, `rtl/clk/*.vhd`, `rtl/mem/*`, `rtl/host/*.sv`, `rtl/video/*.sv`, `Karabas_Profi.sv`. `Karabas_Profi.sdc`: `derive_pll_clocks`, `derive_clock_uncertainty`; `create_generated_clock` for the `clkmux2` output twice (`-name clk_bus28 -source` the PLL's `outclk_0`; `-name clk_bus24 -source` `outclk_1 -add`), the `clkgate` output from each (`clk_rgb28`, `clk_rgb24`), and the `mcu_spi_master` SCK register (`-divide_by 4` of `CLK_50M`, `-name mcu_sck`); `set_clock_groups -logically_exclusive -group {clk_bus28 clk_rgb28} -group {clk_bus24 clk_rgb24}`; `set_clock_groups -asynchronous -group {CLK_50M} -group {outclk_0 clk_bus28 clk_rgb28 clk_bus24 clk_rgb24} -group {outclk_1} -group {outclk_2} -group {mcu_sck}` (use the clock names `derive_pll_clocks` and `sys` actually create; list them from `Karabas_Profi.sta.rpt` "Clocks" after the first build) (every crossing between them is synchronised by design: `kg_mcu`'s chain, `sram_bridge`'s handshake). Keep `sys`'s own constraints. Build: `setsid nohup tools/build.sh </dev/null >build/logs/build.log 2>&1 &` and wait for `build: exit` in the log.
  Expected: `build: exit 0`, `output_files/Karabas_Profi.rbf` exists; `output_files/Karabas_Profi.sta.summary` has no negative slack in any setup or hold row (grep `Slack : -` → nothing). If timing fails, report DONE_WITH_CONCERNS with the failing paths from `Karabas_Profi.sta.rpt` (the 20 worst), do not loosen constraints.

- [ ] **Step 4: README.** Building (`tools/build.sh`), installing (`Karabas_Profi_YYYYMMDD.rbf` → `/media/fat/_Computer/`, `releases/boot.rom` → `/media/fat/games/Karabas_Profi/boot.rom`), the OSD items, and the Known limitations of the Global Constraints. Revert `LAST_QUARTUS_VERSION` in the qsf.

- [ ] **Step 5: Commit.** `top: MiSTer top, Quartus project, boot.rom builder`.

---

### Task 7 (controller and owner): board bring-up

Not dispatched to omp. The controller asks the owner for the board (IP to confirm) and runs:

- [ ] Copy the RBF and `boot.rom` (`scp -O`), load the core.
- [ ] ROMain menu on screen at 50 Hz, then 60 Hz (VSync item). Screenshot both.
- [ ] Keyboard: menu navigation with cursor keys, Enter; a BASIC line typed in 128 BASIC (`10 PRINT 1`, `RUN`).
- [ ] ROM Bank PQ-DOS, FDImage, FATALL each boot (screenshot; the core resets on change).
- [ ] OSD Reset and the MiSTer reset button reset the machine.
- [ ] Turbo 2x works; 4x/8x recorded as known limitation if they crash.
- [ ] Record results in `docs/dev/stage1-results.md`, commit.
