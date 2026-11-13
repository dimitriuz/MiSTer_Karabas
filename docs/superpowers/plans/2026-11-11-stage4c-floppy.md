# Stage 4c: Floppy Drives on the VG93 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two emulated 300 rpm double-density floppy drives on the Profi's existing VG93 controller: TRD and raw CP/M images read/write through two new OSD disk slots, SCL read-only through Main's conversion, FDI read-only through per-drive file-load entries. TR-DOS boots from a mounted TRD and runs its `boot` file; a SAVE through TR-DOS changes the image on the card.

**Architecture:**
- **Controller: untouched.** `profi.vhd` already instantiates `hrdy_fdc` with `ENABLE_FDD => 1` and exposes every drive pin (`FDC_DRIVE/MOTOR/DIR/STEP/WDATA/WGATE/SIDE_N` out, `FDC_INDEX/TR00/WPRT/RDATA` in, `build/upstream/src/rtl/profi.vhd:171-181`); the top ties them off today (`Karabas_Profi.sv:425-435`). Stage 4c replaces the tie-offs with a MiSTer drive model. The only upstream text change is one pure addition: `FDC_SWAP_O`, because `fdc_swap` (port `#028B` bit 3) is assigned at `profi.vhd:1802` but has no consumer upstream — the swap happens in the MiSTer drive, the VG93 itself is not patched (spec §2).
- **Drive model** (`rtl/disk/floppy.sv`, `clk_bus`): head position per drive, index every 200 ms, MFM read stream from a per-drive track buffer, MFM write decoder. Channel-bit cadence is an exact integer accumulator (no real arithmetic, no `$time` — the deep-Icarus traps in AGENTS.md): `acc += NUM; if (acc >= DEN) { acc -= DEN; tick; }` with `NUM/DEN = 4/225` at 28.125 MHz (56.25 clk/cell) and `14/675` at 24.107142 MHz (48.2142857 clk/cell); the bench drives other pairs for the ±2 % speed cases. One byte = 16 ticks; 6250 bytes = 100 000 ticks = 200 ms = 300 rpm (Main's `FTrackLength = 6250`).
- **Track-at-a-time, not whole-image in BRAM.** A TRD is 640 KB, a CP/M image 800 KB; the fitter has ~3.7 Mbit of block RAM free (`build/output_files/Karabas_Profi.fit.summary`, build 70: 1 966 618 / 5 662 720 bits). Each drive gets one 8192×9 track buffer (byte + sync flag, `altsyncram` dual-clock as in `img_src`): written by the store on `gs_clk`, read by the drive on `clk_bus`. While the requested track is not built the drive streams filler `0x4E` — an unformatted track, the VG93 answers RNF and TR-DOS retries; the index keeps pulsing, nothing stalls.
- **Whole images in DDR3** (`rtl/disk/fdd_store.sv`, `gs_clk`): byte base `0x3800_0000 + drive*2 MiB`, `ddr_addr = {4'b0011, 1'b1, 5'd0, drive, offset[20:3]}`, `burstcnt = 1`, per-byte writes with `ddr_be = 1 << offset[2:0]` — exactly `gs_mem`'s board-proven write shape. **Deviation from spec §5.5's word "SDRAM":** the machine's 2 MiB SDRAM is fully allocated to the CPU's no-wait window (§5.3) and its loader port B is owned by the ROM loader in `rtl/replaced/memory.vhd`; widening it would touch the CPU path. DDR3 above the GS window (`0x3000_0000`, 2 MiB) is free — the ZX core uses the top of the 1 GB the same way. Recorded here and in the results document, as the `ide_mux` deviation was in 4b.
- **One new DDR3 master needs an arbiter** (`rtl/mem/ddr_arb.sv`, `gs_clk`): `gs_mem` is the sole master today. GS has priority — the GS CPU stalls on `wait_n` while a floppy transaction runs; the floppy side can wait a revolution. Both masters share `DDRAM_CLK = gs_clk`, so the arbiter has no CDC.
- **Host path** (`rtl/disk/fdd_src.sv`, `clk_sys`): hps_io disk slots 4/5, the `img_src` mount-settle pattern verbatim (Main sends the `0x1c` mount pulse *before* the `0x1d` size words in one burst — latch on the fall after the size settles, the build-55/61-64 lesson), geometry from size + an OSD override, sector fill into the store, dirty 512-byte block drain back out through `sd_wr`, and the FDI ioctl download (indices 1/2) with header parse. `ioctl_wait` is OR'd with `mcu_emu`'s at the top; the two never overlap (index 0 vs 1/2).
- **Crossings are the proven patterns only:** toggle handshakes with two-flop synchronisers (`img_src`, `gs_mem`'s loader port, `tape_src`) and dual-clock `altsyncram` (`img_src`). No new FIFO code. The existing `set_clock_groups` already cut `gs_clk`↔`clk_bus` and `gs_clk`↔`clk_sys` (`Karabas_Profi.sdc:104-128`); no SDC change is expected, `check_timing` proves it.
- **Write path: Write Sector only.** The drive latches the last ID field (C,H,R,N) decoded before `WGATE` rises, decodes the written MFM (3×A1 sync `0x4489`, `FB`/`F8` mark, `128<<N` data bytes, CRC16 CCITT-FFFF), and on a good CRC hands the sector to the store, which patches the track buffer in place (data + recomputed CRC), writes the bytes to DDR, and drains the affected 512-byte image blocks to the file. **Format Track / Write Track are out of scope** — TR-DOS `FORMAT` will fail; documented in README and the results doc. FDI writes patch the DDR copy only (volatile, lost on reload/power-off) — the spec's "writes kept until the image is replaced", with DDR3 standing in for SDRAM.

**Tech Stack:** SystemVerilog (`rtl/`, `Karabas_Profi.sv`, `iverilog -g2012`), VHDL (`profi.vhd` rewrites through `tools/prepare_upstream.py`, Quartus 17.0), Python 3 stdlib (`tools/mk_disk.py`, `tools/zxtap.py`), MiSTer framework files in `sys/` used as they are.

**Spec:** `docs/superpowers/specs/2026-11-02-karabas-profi-mister-port-design.md` §5.5 (floppy), §5.3 (memory map), §2 (no Main_MiSTer patch, VG93 untouched).

## Global Constraints

- Agent process rules — toolchain, gate commands, build numbering, the board driving recipe and commit format — are in `AGENTS.md` at the repository root; read it before the first task.
- Never edit `upstream/` or `sys/`. Upstream text changes only as exact-once rewrites in `tools/prepare_upstream.py`, each with a unit test asserting the exact new text. This plan adds exactly two rewrites (the `FDC_SWAP_O` port and its assignment).
- `Karabas_Profi.sv` has `` `default_nettype none ``: declare every new wire. An implicit net fails `check_timing` (10236/10541).
- hps_io disk slots: `VDNUM` 4 → 6, `BLKSZ = 2`, all `sd_blk_cnt = 0`, `sd_buff_addr` low 9 bits are the sector offset. Slot ordinals follow the `S`-item order: 0 tape, 1 SD card, 2 IDE 0, 3 IDE 1, **4 floppy A, 5 floppy B**.
- No real arithmetic and no `$time` differences in testbench guards — edge counting only (AGENTS.md, the learned Icarus lessons). The drive's write decoder measures WDATA intervals with an integer `clk_bus` counter for the same reason.
- `tools/mk_disk.py` and its tests use the Python standard library only. Sim fixtures are generated on the host by the runner before `iverilog` (the `run_tb_tape_play.sh` precedent); the sim image has python3.
- Every task leaves `python3 -m unittest discover -s tools/tests` (94 tests today) and `tools/sim.sh sim/run_all.sh` (`run_all: N passed, 0 failed`, 19 today; this plan adds three → 22) OK.
- Tasks that change RTL end with a full build: `setsid nohup tools/build.sh </dev/null >build/logs/buildN.log 2>&1 &`, polled until `build: exit` → must be `build: exit 0` (includes `check_timing: OK`), then `git checkout Karabas_Profi.qsf`. Numbering continues from build 70: the first build of this plan is `build71.log`.
- Board checks are driven by the controller once the owner grants the board: the `mister-karabas-board` skill for input, `AGENTS.md` for the capture path and the OSD traps, `docs/dev/stage4a-results.md` for the boot flow. Implementer agents do not ssh to the MiSTer. Anything untestable without owner hardware/files is recorded as **closed untested**, never as PASS.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit areas: `tools`, `sim`, `disk`, `mem`, `top`, `docs`.

## Review Focus

1. **A track that is not built yet.** Mount, step or side change while the store is still filling or building. Expected: the drive streams `0x4E` filler, the index keeps pulsing, the VG93 reports RNF, TR-DOS retries; once the ack echoes the *current* `{drive, side, track}` the buffer is read from the next index. A stale ack (echo mismatch) is ignored. Test: `tb_floppy` case `track_not_ready`, `tb_fdd_img` case `request_while_filling`.
2. **A write the user believes is safe.** Read-only mount (SCL converts to a temp TRD with `writable = 0`, or a chmod-444 file): `img_readonly` latched per mount drives `FDC_WPRT`, the VG93 refuses the write, the file's SHA-256 on the card is unchanged. A write with a bad data CRC is dropped by the drive (no store handshake). Test: `tb_floppy` `wprt`/`bad_crc`, `tb_fdd_img` `readonly`, Task 6 board row compares SHA-256.
3. **Mount, eject or swap mid-transfer.** The 4b lesson: Main's `0x1c` precedes `0x1d` in one burst; a size sampled on the rise reads 0 and the image looks ejected. Expected: settle-then-cross, in-flight fill/drain dropped, dirty bitmap cleared, the next track request builds from the new image. Test: `tb_fdd_img` `mount_order`, `eject_mid_fill`, `remount_mid_drain` (the bench drives Main's order and fails with the settle removed).
4. **The GS CPU behind the arbiter.** GS reads/writes while the floppy hammers DDR3. Expected: GS wins every idle grant, no GS request waits longer than one floppy transaction, no read data lost, the `ddram_model` contract checks stay silent. Test: `tb_ddr_arb` `gs_priority`, `tb_fdd_img` `gs_traffic_during_build`.
5. **Speed and clock matrix.** ±2 % disk speed, DS80 (24.107 MHz), turbo off/8x — the upstream test matrix. Expected: the separator tracks, every byte of every sector arrives, the TR-DOS poll loop keeps its 3.5 MHz period in turbo and never waits at 3.5 MHz. Test: `tb_floppy` run with the six `(DS80, SPEED, TURBO)` combinations of `run_fdc_sim.sh`.
6. **Geometry ambiguity.** 409600 bytes is both TRD-50 and CP/M-40. Expected: Auto picks by the rule below, the OSD `Disk layout` item overrides, a wrong guess is visible as RNF/garbage and fixable without a rebuild. Test: `tb_fdd_img` `geometry_auto`, `geometry_override`.

---

## File Structure

| File | Task | Responsibility |
|---|---|---|
| `tools/mk_disk.py`, `tools/tests/test_mk_disk.py` | 1 | TRD (with TR-DOS ID sector, catalog, `boot`), raw CP/M, FDI writers; `trd_ls`/`trd_read`; the reference track builder the sim compares against |
| `rtl/mem/ddr_arb.sv` (new), `sim/tb_ddr_arb.sv`, `sim/run_tb_ddr_arb.sh` (new), `sim/models/ddram_model.sv` | 2 | two-master DDR3 arbiter, GS priority; the model grows the FDD window |
| `rtl/disk/floppy.sv` (new), `sim/tb_floppy.sv`, `sim/run_tb_floppy.sh` (new) | 3 | the drive model against the **real upstream `hrdy_fdc`** |
| `rtl/disk/fdd_store.sv`, `rtl/disk/fdd_src.sv` (new), `sim/tb_fdd_img.sv`, `sim/run_tb_fdd_img.sh` (new), `sim/models/hps_disk_model.sv` | 4 | image store + track builder + write-back; slot fill, geometry, FDI download, dirty drain |
| `tools/prepare_upstream.py`, `tools/tests/test_prepare_upstream.py` | 5 | the `FDC_SWAP_O` port + assignment rewrites |
| `Karabas_Profi.sv`, `files.qip`, `rtl/host/mount_settle.sv`, `sim/tb_mount_settle.sv`, `tools/board/zx.py`, `AGENTS.md`, `README.md` | 5 | slots 4/5, F1/F2, layout item, `VDNUM = 6`, FDC wiring, OSD row re-derivation |
| `docs/dev/stage4c-results.md` (new), `docs/dev/stage4c-shots/*.png` | 6 | board results |

---

### Task 1: `mk_disk.py` — TRD/CP/M/FDI images and the reference track

**Files:**
- Modify: `tools/mk_disk.py`, `tools/tests/test_mk_disk.py`

**Interfaces:**
- Produces (importable, plus a CLI):
  - `trd(path: Path, tracks: int = 80, files: list[tuple[str, str, bytes]] | None = None) -> None` — `tracks*2*16*256` bytes. Track 0 side 0 sector 9 is the TR-DOS ID sector exactly as Main's `formatTRDOS` builds it (`DiskImage.cpp:1179-1290`): data offset `0xE1` first free sector = 0, `0xE2` first free track = 1, `0xE3` = `0x16` (80trk DS), `0xE4` file count, `0xE5` free sectors u16 LE = `tracks*2*16 - 16`, `0xE7` = `0x10` (TR-DOS id), `0xF4` deleted count, `0xF5..0xFC` disk name `"MiSTer    "`, rest 0. Catalog: track 0 side 0 sectors 1-8, 16-byte entries — name[8] space-padded, type at 8 (`B`/`C`), start track at 9, start sector at 10, length in bytes u16 LE at 11, length in sectors u16 LE at 13, byte 15 = 0. File data starts at track 1 side 0 sector 1, allocated sequentially (a file may span sides; allocation order is track-major, side-minor, sector 1..16). `files` entries are `(name, type, payload)`.
  - `BOOT_SRC` constant and the default `boot` file: `10 PRINT "trdos ok"` / `20 FOR I=0 TO 255: POKE 25000+I,I: NEXT I` / `30 SAVE "out" CODE 25000,256` / `40 PRINT "saved"`, type `B`, payload = `zxtap.tokenize_program(BOOT_SRC)` (the TAP data-block payload — TR-DOS `B` files store the same tokenised bytes; the board run proves auto-run, and if the ROM disagrees the SAVE routine in `boot.rom` is the authority and the fix is a finding). TR-DOS auto-runs a file named `boot` at startup — that is why Main's SCL conversion needs no typing, and why this plan's board read/write rows need none either.
  - `cpm(path: Path, tracks: int = 80) -> None` — `tracks*2*5*1024` bytes, deterministic pattern `(i*7+3)&0xFF` per track (no CP/M system: booting CP/M needs an owner-supplied image, Task 6).
  - `fdi(path: Path, tracks: int = 80, sides: int = 2, layout: str = "trd") -> None` — FDI header: `"FDI"`, version 0 at 3, u16 LE cyl at 4, sides at 6, `off_text` at 8 (= `0x0E + size_ext + table_size`, no text), `off_data` at 0x0A, `size_ext` = 0 at 0x0C; track table at 0x0E, per track u32 LE `DataOffset` (relative to `off_data`) + u16 reserved 0 + u8 sector count; per sector 7 bytes: C,H,R,N,flags + u16 LE offset relative to the track's data. `layout="trd"`: 16×256, **H = side** (deliberately different from TRD's H = 0, so the sim proves the table is really used); `layout="wide"`: track 0 gets 8×512 (N=2) and one sector with flags `0x40` (no data), the rest 16×256. Sector size = `128 << N`, N=0 → 128 (Main `readFDI`, `DiskImage.cpp:1490-1730`).
  - `trd_ls(path) -> list[tuple[str, str, int]]`, `trd_read(path, name) -> bytes` — catalog reader for the board write verification.
  - `reftrack(path: Path, track: int, side: int, sectors: list[tuple[int,int,int,int,bytes]], cpm: bool = False) -> None` — the reference 6250-byte track as hex, one byte per line, plus a second file `<path>.sync` (one `0`/`1` per line): per sector 10×`4E`, 12×`00`, 3×`A1`(sync)+`FE`+C,H,R,N+CRC16, 22×`4E`, 12×`00`, 3×`A1`(sync)+`FB`+data+CRC16, 60×`4E`; pad `4E` to 6250. CRC = CCITT-FFFF over the three A1s + mark + payload (`MakeVGCRC`, poly `0x1021`), high byte first. TRD ID fields use **H = 0 on both sides** (Main: "head (TR always 0)"); `cpm=True` uses H = side and 5×1024. This is the byte-exact oracle for `tb_fdd_img`'s track builder.
  - CLI: `mk_disk.py trd OUT [--tracks N] [--boot]`, `cpm OUT [--tracks N]`, `fdi OUT [--layout trd|wide]`, `ls IMG`, `cat IMG NAME`, `reftrack OUT --track T --side S [--cpm]`.
- Consumes: `tools/zxtap.py:tokenize_program` (exists).

- [ ] **Step 1: Tests first** in `tools/tests/test_mk_disk.py`:
  - `test_trd_geometry`: size = `tracks*8192`; ID sector fields at the offsets above (free sectors = `tracks*32-16`).
  - `test_trd_catalog`: `trd(files=[("boot","B",b"...")])` → `trd_ls` names it, `trd_read` returns the payload; a file longer than one track spans into side 1 in allocation order.
  - `test_boot_payload`: the default `boot` file's payload equals `zxtap.tokenize_program(BOOT_SRC)`.
  - `test_cpm_geometry`: size = `tracks*10240`, pattern byte 15 = `(15*7+3)&0xFF`.
  - `test_fdi_header`: `"FDI"`, cyl/sides, `off_data` = header + table size; track 0's `DataOffset` = 0; sector entries parse back (C,H,R,N,flags,offset); `wide` layout has N=2 and a `0x40` sector.
  - `test_reftrack_crc`: a one-sector reference track's ID and data CRCs equal a hand-computed CCITT-FFFF vector (the upstream bench's `crc_byte` is the oracle); sync flags are 1 exactly at the six A1 positions; total length 6250; TRD H=0 on side 1, CP/M H=side.
  - `test_trd_read_missing`: `trd_read(path, "nope")` raises `KeyError`.
- [ ] **Step 2: Run** `python3 -m unittest tools.tests.test_mk_disk -v` → the new tests FAIL.
- [ ] **Step 3: Implement** the writers and readers; run → all pass (94 + new).
- [ ] **Step 4: Fixtures.** `python3 tools/mk_disk.py trd build/disk/test.trd --boot`, `cpm build/disk/test.cpm`, `fdi build/disk/test.fdi`, `fdi build/disk/wide.fdi --layout wide`; `ls`/`cat` round-trip the `boot` file.
- [ ] **Step 5: Commit** `tools: TRD, CP/M and FDI images, and the reference track builder`.

### Task 2: `ddr_arb` — the second DDR3 master

**Files:**
- Create: `rtl/mem/ddr_arb.sv`, `sim/tb_ddr_arb.sv`, `sim/run_tb_ddr_arb.sh`
- Modify: `sim/models/ddram_model.sv`

**Interfaces:**
- Produces:
```systemverilog
module ddr_arb (
    input  wire        clk, reset,          // gs_clk
    // master 0: gs_mem (priority)
    input  wire        g_req,               // rd | we, held until served
    input  wire [28:0] g_addr, input wire [63:0] g_din, input wire [7:0] g_be,
    input  wire        g_rd, g_we,
    output wire        g_busy, output wire [63:0] g_dout, output wire g_dout_ready,
    // master 1: fdd_store
    input  wire        f_req,
    input  wire [28:0] f_addr, input wire [63:0] f_din, input wire [7:0] f_be,
    input  wire        f_rd, f_we,
    output wire        f_busy, output wire [63:0] f_dout, output wire f_dout_ready,
    // DDR3 (sys/emu_ports.vh DDRAM_*)
    output wire        ddr_rd, ddr_we,
    output wire [28:0] ddr_addr, output wire [63:0] ddr_din, output wire [7:0] ddr_be,
    output wire [7:0]  ddr_burstcnt,
    input  wire        ddr_busy, input wire [63:0] ddr_dout, input wire ddr_dout_ready
);
```
  - Grant FSM: IDLE → GS when `g_req`, else FDD when `f_req`. The owner's signals mux to DDR3; the other master sees `busy = 1` (it holds its request, as `gs_mem` already does). A write grant releases on the accept edge (`!ddr_busy`); a read grant releases on `ddr_dout_ready`. `ddr_burstcnt = 1` always. One transaction in flight, no reordering. Reset (PLL lock, never the OSD reset — aborting an Avalon transaction mid-flight breaks the protocol, the `gs_mem` rule) returns to IDLE.
- `ddram_model.sv` changes (backward compatible): `parameter integer WORDS = 786432` and `parameter [8*16-1:0] FAIL_TAG = "tb_gs_mem"`; the address check accepts the GS region (`addr[28:18] == {4'b0011, 7'd0}`, index `addr[17:0]`) **and** the FDD region (`addr[28:19] == {4'b0011, 1'b1, 5'd0}`, index `262144 + addr[18:0]`); anything else stays fatal. `mem` grows to `WORDS`; the fatal prefix uses `FAIL_TAG`. `tb_gs_mem` keeps the defaults and must stay green unchanged.
- Consumes: nothing from Task 1.

- [ ] **Step 1: The bench first**, `sim/tb_ddr_arb.sv` (DUT + `ddram_model` with `FAIL_TAG = "tb_ddr_arb"`), a GS master task and an FDD master task, each doing reads/writes with the `gs_mem` hold-until-served protocol. Cases: `gs_only`, `fdd_only`, `gs_priority` (FDD streams back-to-back reads while GS issues one read per 200 clk — every GS read completes within one FDD transaction + latency, data correct), `alternating_writes` (both write disjoint lines, byte enables verified), `reset_idle`. Guard every wait with an edge count.
- [ ] **Step 2: Run** `tools/sim.sh sim/run_tb_ddr_arb.sh` against a stub (grant stuck at GS) → FAIL on `fdd_only`.
- [ ] **Step 3: Implement** `ddr_arb.sv`; extend `ddram_model.sv`; run → PASS; `tools/sim.sh sim/run_tb_gs_mem.sh` stays green (the model's default path is untouched).
- [ ] **Step 4: Commit** `mem: ddr_arb, a second DDR3 master with GS priority`.

### Task 3: `floppy.sv` — the drive model against the real VG93

**Files:**
- Create: `rtl/disk/floppy.sv`, `sim/tb_floppy.sv`, `sim/run_tb_floppy.sh`

**Interfaces:**
- Produces:
```systemverilog
module floppy (
    input  wire        clk, reset,          // clk_bus
    input  wire        ds80,                // synchronised at the top (vmode[3])
    input  wire        swap,                // profi FDC_SWAP_O, synchronised
    input  wire [15:0] cell_num, cell_den,  // cadence; top wires 4/225 or 14/675 by ds80
    // profi drive pins (active high at the boundary)
    input  wire [1:0]  fdc_drive,           // one-hot {B,A}, motor-gated upstream
    input  wire        fdc_motor, fdc_step, fdc_dir, fdc_side_n,
    input  wire        fdc_wgate, fdc_wdata,
    output reg         fdc_rdata, fdc_index,
    output wire        fdc_tr00, fdc_wprt,
    input  wire [1:0]  wprt,                // per-drive readonly, synchronised
    // store side (gs_clk), toggle handshakes
    output reg         trk_req_tgl,
    output reg  [8:0]  trk_req,             // {drive, side, track[6:0]}
    input  wire        trk_ack_tgl,
    input  wire  [9:0]  trk_ack,            // {ready, drive, side, track[6:0]}
    // track buffers: port B read here, port A written by the store
    output wire [12:0] trk_addr_a, trk_addr_b,
    input  wire  [8:0] trk_q_a, trk_q_b,    // {sync, byte}
    // written sector: one shared 1024x8 buffer, port A written here
    output reg         wr_tgl,
    output reg  [35:0] wr_info,             // {drive, side, track[6:0], C, H, R, N[2:0]}
    input  wire        wr_ack_tgl,
    output wire [9:0]  wr_addr, output wire [7:0] wr_data, output wire wr_we
);
```
  - **Read stream.** Per drive: `track[6:0]` (0..83, clamped), index counter (100 000 cell ticks per revolution, `fdc_index` high for the first 500 ticks ≈ 1 ms), byte counter 0..6249 reset at index. On a cell tick every 16th tick advances the byte; the MFM encoder shifts 16 channel bits per byte (`sync` → `0x4489`, else clock bit = `!prev && !bit`, the upstream bench's encoder verbatim); a channel 1 raises `fdc_rdata` for 8 `clk` (≥ 2 samples for `fdd_glue`'s filter; the falling edge of `/RDATA` is the flux). `fdc_rdata`/`fdc_index` are gated by `fdc_motor` and the selected drive. Track request on step/side/select/mount: `trk_req_tgl` toggles with `{drive, side, track}`; only an ack whose echo matches the current request and `ready = 1` switches the stream from filler `0x4E` to the buffer, at the next index. `fdc_tr00 = (track == 0)` of the selected drive; `fdc_wprt = wprt[selected]`. `swap` exchanges the A/B select mapping (and only that).
  - **Write decoder.** Free-running integer interval counter: on `posedge fdc_wdata` while `fdc_wgate`, `n = (dt_clk + HALF) / CELL_CLK` with `CELL_CLK/HALF = 56/28` (28 MHz) or `48/24` (DS80) — the FDC's write cell is 1.991 µs, the rounding window is ±28 clk, no real arithmetic. Shift `n` cells into a 48-bit register (the upstream bench's decoder shape); 3×`0x4489` → sync; next byte `FE` → ID field (C,H,R,N + 2 CRC, checked), `FB`/`F8` → data (`128<<N` bytes + 2 CRC, checked; N > 3 rejected — the buffer is 1024). The **last good ID before `WGATE` rises** is the write target. On `WGATE` fall with a complete, CRC-good data field: fill the write buffer, toggle `wr_tgl` with `wr_info`; the next write is not captured until `wr_ack_tgl` answers (back-to-back sectors are 12.5 ms apart at 16×256; the store's patch budget is < 1 ms — Task 4 proves it). Bad CRC: drop silently, the VG93 reports the error to the CPU itself.
  - The read stream keeps running during `WGATE` (the FDC reads IDs to find the sector); after the store patches the buffer the next revolution reads the new data.
- Consumes: the track-buffer and write-buffer `altsyncram` instances live **in the store** (Task 4); this module only drives their ports. In `tb_floppy` the bench instantiates `altsyncram_model` buffers and preloads them.
- The runner compiles the real controller: `iverilog -g2012 -I upstream/karabas-go-core-profi/src/rtl/vg93` over `sim/tb_floppy.sv`, `sim/models/altsyncram_model.sv`, `rtl/disk/floppy.sv`, and `upstream/.../vg93/{hrdy_fdc.v,fdd_glue.v,vg93_*.v}`; it copies `vg93-microcode-rom.hex` next to the `.vvp` and runs `vvp` from that directory (`vg93_urom.v` does `$readmemh("vg93-microcode-rom.hex")` relative to cwd — the `run_fdc_sim.sh` precedent).

- [x] **Step 1: The bench first**, `sim/tb_floppy.sv`: DUT `floppy` + real `hrdy_fdc`, the CPU-side tasks (`io_wr`, `io_rd`, `wait_intrq`) copied from `upstream/.../src/sim/tb_hrdy_fdc.v` with the guards converted to edge counts, a bench store model (acks track requests with `ready`, captures `wr_info`/write buffer), and the reference track builder (the upstream bench's `build_track`, one 256-byte sector) preloading drive A's buffer. Parameters `DS80`, `TURBO`, and `CELL_NUM/CELL_DEN` driven by the runner. Cases, each `PASS <case>` / `FAIL <case> <reason>`, verdict `tb_floppy: PASS`:
  - `restore`: from track 3, command `0x08` → 3 steps ≈ 3 ms apart (TurboFDC), track 0, status busy=0 TR00=1.
  - `poll`: the TR-DOS `#3FD5` loop (64 reads of `#FF`, 47 T between) — turbo: period within 3 % of `(47+5)*8` clocks; turbo off: zero WAIT clocks.
  - `read_sector`: sector 1 → 256 bytes equal the reference, status 0.
  - `write_sector`: 256 bytes `0xFF - i*3` → status 0, the bench store's captured bytes + CRC equal what was sent, `wr_info` carries C=0,H=0,R=1,N=1.
  - `read_after_write`: the bench patches the buffer from the captured sector (as the store will) → the next read returns the new bytes.
  - `drive_b`: `#FF` select B → drive B's buffer (different pattern) reads back; `swap=1` → selecting A reads B's buffer and vice versa.
  - `side1`: `#FF` bit 4 = 0 → side 1's buffer reads back (TRD H=0 convention: the ID's H byte is 0 on both sides).
  - `wprt`: `wprt=1` → Write Sector ends with the write-protect status bit, no `wr_tgl`.
  - `bad_crc`: the bench pre-corrupts one ID CRC byte in the buffer → the FDC reports RNF, no write captured.
  - `track_not_ready`: store model answers `ready=0` → the stream is `0x4E` filler, a read ends RNF, index still pulses; then `ready=1` with the matching echo → the next revolution reads the sector.
  - `no_motor`: motor off → no index, no flux.
- [x] **Step 2: Run** `tools/sim.sh sim/run_tb_floppy.sh` against a stub `floppy` (outputs tied) → FAIL on `restore` (no steps), proving the bench reaches the real controller.
- [x] **Step 3: Implement** `floppy.sv`; run until every case passes.
- [x] **Step 4: The matrix.** The runner loops the six upstream combinations — `(DS80, SPEED, TURBO)` = `(0,1.0,1) (1,1.0,1) (0,1.02,1) (1,0.98,1) (0,1.0,0) (1,1.0,0)` — as cell pairs `4/225`, `14/675`, `8/459`, `28/1377`, `8/441`, `28/1323` (56.25×1.02 = 57.375 = 459/8; 48.2142857×0.98 = 47.25 = 1323/28). All six print `tb_floppy: PASS`; the script's verdict is the last line.
- [x] **Step 5: Commit** `disk: floppy drive model, proven against the real hrdy_fdc`.

### Task 4: `fdd_store` + `fdd_src` — the image path end to end

**Files:**
- Create: `rtl/disk/fdd_store.sv`, `rtl/disk/fdd_src.sv`, `sim/tb_fdd_img.sv`, `sim/run_tb_fdd_img.sh`
- Modify: `sim/models/hps_disk_model.sv` (memory 512 KB → 1 MB per slot: a TRD is 640 KB; `idx` widens to `[10:0]`, the `pos` byte index to `[19:0]`, `mem` to `[0:1][0:1048575]`; `tb_img_src`/`tb_sd_spi` stay green)

**Interfaces:**
- `fdd_store` (gs_clk) — DDR3 master through `ddr_arb`, track builder, write-back:
  - Fill port from `fdd_src`: toggle handshake, payload `{addr[21:0], data[7:0]}`; `addr[21] = 0` → image byte at `drive_base + addr[20:0]` (per-byte DDR write, `be = 1 << addr[2:0]`), `addr[21] = 1` → FDI table byte. A `config` handshake carries `{drive, kind[1:0] (TRD/CPM/FDI), tracks[6:0], sides}` before the first byte; a `ready` handshake after the last byte enables track building. Mount/eject clears the drive's state (dirty bitmap, pending request).
  - FDI table RAM per drive: 160 tracks × 32 sectors × 6 bytes `{C,H,R,N,flags,offset[15:0]}` plus per-track `{DataOffset[31:0], count[4:0]}` (single-clock `gs_clk` array; ~48 M10K for both drives — the budget has ~270 free). Tracks capped at 84, sides at 2, sectors per track at 32 (documented; Main itself rejects tracks that do not fit 6250 bytes).
  - Track builder: on a matching `trk_req`, read the track's sectors from DDR (TRD: 16×256 at `((track*2+side)*16 + sec)*256`; CP/M: 5×1024 at `((track*2+side)*5 + sec)*1024`; FDI: table offsets), format the 6250-byte track exactly as `reftrack` (gaps 10/12/22/12/60, 3×A1 sync, CRC16), write the track buffer (port A), record each sector's `{buf_offset[12:0], file_offset[20:0], N}` in a 32-entry position table, then ack `{ready=1, echo}`. TRD ID fields H=0 both sides; CP/M and FDI H as the table says.
  - Write-back: on `wr_tgl`, read the write buffer (port B), find the sector in the position table (TRD/CP/M by R; FDI by C,H,R,N match), patch the track buffer's data + recomputed CRC, write the bytes to DDR at `file_offset`, mark the touched 512-byte blocks dirty (TRD 256-byte sectors: one block; CP/M 1024: two), ack. FDI drives skip the drain (writes stay in DDR).
  - Drain: pop a dirty block, read 512 B from DDR into the drain buffer (port A, gs_clk), toggle `{drive, block[10:0]}` to `fdd_src`; on its ack clear the bitmap bit. One block in flight.
  - Buffers (all `altsyncram`, the `img_src` defparam shape): 2× track 8192×9 (A: gs_clk store, B: clk_bus drive), 1× write 1024×8 (A: clk_bus drive, B: gs_clk store), 1× drain 512×8 (A: gs_clk store, B: clk_sys `fdd_src`).
- `fdd_src` (clk_sys) — the host path:
  - Slots 4/5 (`img_mounted[1:0]`, `img_size`, `img_readonly`, `sd_*`), the `img_src` settle pattern verbatim: event bits accumulate while `img_mounted` is high, the payload crosses once `img_size` is unchanged for 1024 clk; `img_readonly` latched per drive at the same moment → `wprt` (synchronised to clk_bus at the top).
  - Geometry: `tracks_trd = size/8192`, `tracks_cpm = size/10240`. **Auto:** TRD when `size % 8192 == 0 && tracks_trd <= 84`, else CP/M when `size % 10240 == 0 && tracks_cpm <= 84`, else no image. (655360 → TRD-80; 819200 → 100 > 84 → CP/M-80; 409600 → TRD-50, the ambiguous case the OSD item fixes.) `status[35:34]`: 0 Auto, 1 force TRD, 2 force CP/M. A size that fits neither → the drive behaves as no image.
  - Fill: read 512-byte sectors via `sd_rd` into a dual-clock buffer, push bytes through the fill handshake; then `ready`. Eject/remount mid-fill drops the transfer (the 4b rule).
  - Drain: on the store's block handshake, `sd_wr` with `lba = block`, stream 512 bytes from the drain buffer (clk_sys port), ack.
  - FDI download: `ioctl_download && ioctl_index inside {1,2}` (F1 → 1, F2 → 2; `ioctl_index[15:6]` is the extension subindex, 0 for the single FDI extension; boot.rom is index 0 and stays with `mcu_emu`). Parse the header (first 14 bytes + `size_ext`), emit table writes, then stream the data area (`off_data` onward) as image bytes; `ioctl_wait` raised while a byte is pending, dropped when idle (the `mcu_emu` ownership rule). A malformed header (bad magic, cyl/sides 0 or > 256, offsets past the file) aborts the download with `ioctl_wait` low — the drive stays empty, no hang.
- Consumes: `ddr_arb` (Task 2), `floppy`'s store-side interface (Task 3), `reftrack` fixtures (Task 1).

- [ ] **Step 1: The bench first**, `sim/tb_fdd_img.sv`: `fdd_src` + `fdd_store` + `ddr_arb` + `ddram_model` (`FAIL_TAG = "tb_fdd_img"`, `BUSY_PCT = 20` in one run) + `hps_disk_model` (slots a/b = floppy A/B) + a bench drive model (track requests, write-buffer fills, the Task 3 interface) + a GS traffic generator. Fixtures generated by the runner on the host: `test.trd` (with `boot`), `test.cpm`, `test.fdi`, `wide.fdi`, and `reftrack` hex for TRD track 0 side 0, TRD track 5 side 1, CP/M track 3 side 1, FDI track 0 side 1. The bench drives mounts in **Main's order** (`mount(bits, size)`: pulse first, size words after, then fall — the `tb_img_src` task). Cases:
  - `geometry_auto`: 655360 → TRD-80; 819200 → CP/M-80; 409600 → TRD-50; 12345 → no image.
  - `geometry_override`: 409600 with `status[35:34] = 2` → CP/M-40.
  - `trd_track_exact`: after fill+ready, request track 0 side 0 → the track buffer equals `reftrack` byte-for-byte including sync flags; same for track 5 **side 1** (H=0 in the IDs).
  - `cpm_track_exact`: CP/M track 3 side 1, 5×1024, H=1.
  - `fdi_track_exact`: FDI track 0 side 1 (H=1 from the table, not from the side); `wide.fdi` track 0: 512-byte sectors and the `0x40` no-data sector (ID only, no data mark).
  - `write_back`: bench writes sector R=3 track 2 side 0 (256 B) → the track buffer's data+CRC patched, DDR bytes at the TRD offset equal the new data, one dirty block drained, `hps_disk_model.mem` holds it; a CP/M 1024-byte write drains two blocks.
  - `fdi_write_volatile`: a write on an FDI drive patches DDR, no `sd_wr` ever.
  - `readonly`: `img_readonly = 1` at mount → `wprt` high, no drain.
  - `mount_order`: the bench asserts the crossed size is non-zero on the first fill byte; a rise-sampled design fails here.
  - `eject_mid_fill`, `remount_mid_drain`: mount pulse with size 0 / a new image mid-transfer → no hang, the next request builds from the new image, dirty state cleared.
  - `request_while_filling`: a track request before `ready` → ack `ready=0`; after ready → the exact track.
  - `gs_traffic_during_build`: GS reads/writes throughout a track build → all GS data correct (arbiter priority under real load).
  - `fdi_download`: the FDI fixture through the ioctl path (byte strobes with `ioctl_wait` backpressure, index 1) → table + image correct, a second download on index 2 fills drive B; a truncated header aborts cleanly.
- [ ] **Step 2: Run** `tools/sim.sh sim/run_tb_fdd_img.sh` against stubs → FAIL on `trd_track_exact`.
- [ ] **Step 3: Implement** `fdd_store.sv`, then `fdd_src.sv`; run until every case passes; `tools/sim.sh sim/run_tb_img_src.sh` and `sim/run_tb_sd_spi.sh` stay green (the model grew).
- [ ] **Step 4: Commit** `disk: fdd_store and fdd_src, the floppy image path`.

### Task 5: the core — `FDC_SWAP_O`, slots 4/5, F1/F2, the OSD

**Files:**
- Modify: `tools/prepare_upstream.py` (`PROFI_REWRITES`), `tools/tests/test_prepare_upstream.py`
- Modify: `Karabas_Profi.sv`, `files.qip`, `rtl/host/mount_settle.sv`, `sim/tb_mount_settle.sv`, `tools/board/zx.py`, `AGENTS.md`, `README.md`

**Interfaces:**
- The two rewrites, exact text (anchors are the *rewritten* text, so they append after the stage-4a entries in `PROFI_REWRITES`):
  - port: old `"\tGSL_TGL : out std_logic;\n\tENA_CPU_O : out std_logic;"` → same + `"\n\tFDC_SWAP_O : out std_logic;"`
  - assignment: old `"MIDI_RESET_N <= not reset;\nCLK_GS_O <= clk_gs;\nENA_CPU_O <= ena_cpu;"` → same + `"\nFDC_SWAP_O <= fdc_swap;"`
- Top wiring:
  - `CONF_STR`: after `S3,HDFIMGVHD,IDE 1;` add `"S4,TRDIMGSCL,Floppy A;"`, `"S5,TRDIMGSCL,Floppy B;"`, `"F1,FDI,Floppy A FDI;"`, `"F2,FDI,Floppy B FDI;"`, `"O[35:34],Disk layout,Auto,TR-DOS,CP/M;"` (bits 34/35 are free; the type string is three 3-letter groups, Main matches extensions case-insensitively; SCL mounts arrive as Main's converted temp TRD with `img_readonly = 1`).
  - `hps_io #(.VDNUM(6))`; disk arrays widened to `[5:0]` / `[6]`, `sd_blk_cnt[4] = sd_blk_cnt[5] = 0`, `sd_wr[0]` stays 0; `img_readonly` latched per drive inside `fdd_src`.
  - `mount_settle`: `mounted[3:0]` → `[5:0]`, `disk_mount = |(mounted[5:1] & ~prev_mounted[5:1])`; `tb_mount_settle` widened with a slot-4/5 case.
  - `ioctl_wait`: `wire mcu_ioctl_wait, fdd_ioctl_wait; assign ioctl_wait = mcu_ioctl_wait | fdd_ioctl_wait;` (mcu_emu owns index 0, fdd_src 1/2 — never both).
  - FDC pins: the tie-offs at `Karabas_Profi.sv:425-435` become wires to `floppy u_floppy` (`.clk(clk_bus)`, `.reset(profi_areset)`, `.ds80(ds80_s)` — `vmode[3]` through a two-flop synchroniser, ruling R10 — `.swap(fdc_swap_s)` likewise, `.cell_num/.cell_den` = `ds80_s ? 14/675 : 4/225`, `.wprt(fdd_wprt_s)`); `.FDC_SWAP_O(fdc_swap)` on profi. `fdd_store` on `gs_clk` behind `ddr_arb` (GS master 0, store master 1); `fdd_src` on `clk_sys` with slots 4/5, the ioctl path and the layout override `status[35:34]` (two-flop synchronised into clk_sys — status is quasi-static, the existing rule).
  - `files.qip`: the five new SV files under a stage-4c comment block.
- **OSD row arithmetic (re-derive, never trust the old numbers):** CONF_STR gains 5 selectable rows (S4, S5, F1, F2, Disk layout) after IDE 1 and before `Tape play/pause`. On build 70 `Tape play/pause` was 10 Down from `Video`; on the new build it is **15**, prev/next block 16/17, Joystick L 18. `tools/board/zx.py`: `TAPE_ROW = 15` with a comment naming the build; the `tape`/`fire_tape` walks use it. AGENTS.md's OSD paragraph gains the new map next to the build-54 one. The first board run re-reads the map from a capture before trusting any count (the AGENTS.md rule).
- `zx.py` gains a TR-DOS flow (no typing): `MENU_TO_TRDOS_128 = 4` on the GO menu (`Loading CP/M system` 0, `Loading IS-DOS` 1, `Loading boot` 2, `Run TR-DOS 48K` 3, `Run TR-DOS 128K` 4, `Run Sinclair 48K` 5, `Run Sinclair 128K` 6, `Test&Tools Menu` 7 — `docs/dev/stage1-shots/romain-menu-50hz.png`), `trdos <mgl>` = boot + settle + 4 Down + Enter, then wait for the `boot` program's output (`changed()` on the program area). `tools/tests/test_board_drive.py` gains the constant/walk-shape tests in its existing style.

- [ ] **Step 1: The rewrite tests first** in `tools/tests/test_prepare_upstream.py`: `test_profi_fdc_swap_port` (the exact port block appears once, after `ENA_CPU_O`) and `test_profi_fdc_swap_assign` (the exact assignment block once). Copy the anchors from the *rewritten* profi text (`m.apply_profi_rewrites` of the real upstream file, as `test_profi_sdc_ports` does).
- [ ] **Step 2: Run** those two → FAIL; add the rewrites; run → PASS; `tools/check_upstream.sh` → OK; `tools/elab_upstream.sh` → OK.
- [ ] **Step 3: The top.** Wire everything above; `mount_settle` + its bench; `zx.py` + its tests; AGENTS.md row map.
- [ ] **Step 4: Gates.** `python3 -m unittest discover -s tools/tests`; `tools/sim.sh sim/run_all.sh` → `run_all: 22 passed, 0 failed`.
- [ ] **Step 5: Build 71.** `setsid nohup tools/build.sh </dev/null >build/logs/build71.log 2>&1 &`, poll `build: exit 0`, then `git checkout -- Karabas_Profi.qsf`. Record the fitter summary (block RAM and M10K counts — the track/table buffers are the budget risk) and per-clock slack in the commit body. If `check_timing` fails on a new path, fix the path (register it, or cut it only if the crossing is one of the designed ones) — never weaken the gate.
- [ ] **Step 6: README.** Files/features gain the two floppy slots, the FDI entries and the layout item; `Known limitations` gains: Format Track/Write Track unsupported, FDI read-only from the file (writes volatile in DDR3), CP/M boot needs an owner image, tracks ≤ 84 / sectors per track ≤ 32.
- [ ] **Step 7: Commit** `top: floppy drive slots, FDI entries and the VG93 drive wiring` with the build number and gate results in the body.

### Task 6: Board run

**Files:**
- Create: `docs/dev/stage4c-results.md`, `docs/dev/stage4c-shots/*.png`
- Modify: `README.md` (whatever the run proves or contradicts)

**Interfaces:**
- Consumes: build 71's rbf, `build/disk/test.trd` (with `boot`), `test.cpm`, `test.fdi`, `wide.fdi`; `tools/board/zx.py trdos`; the capture card (`Capture.frame`, ~2.2 s — a black grab is not "no signal").
- The FDC ports are decoded only when TR-DOS is active (`dos_act = 1`) or CP/M (`cpm = 1`) — `profi.vhd:2200-2210`; a probe from 128 BASIC cannot see them. Every row below runs from the GO menu's `Run TR-DOS 128K` (4 Down + Enter), which needs no typing.

- [ ] **Step 1: Board prep.** Copy `build/output_files/Karabas_Profi.rbf` (build 71) to `/media/fat/_Computer/Karabas_Profi_20261111b.rbf`; `test.trd`, `test.cpm`, `test.fdi`, `wide.fdi` to `/media/fat/games/Karabas_Profi/`. One MGL per check: `<file type="s" index="4" path="...test.trd"/>` (slot 5 for drive B). Re-read the OSD row map from a capture before any walk.
- [ ] **Step 2: TR-DOS boot + auto-run.** `zx.py trdos run-trd.mgl` with `test.trd` on slot 4 → the `boot` program prints `trdos ok` then `saved` (shots). This proves: mount → geometry → track build → MFM read → the VG93 → TR-DOS catalog → BASIC auto-run, end to end.
- [ ] **Step 3: Write row.** The same boot's `SAVE "out" CODE 25000,256` writes through the drive; fetch the image back (`scp`) and `python3 tools/mk_disk.py cat test.trd out` returns the 256-byte pattern `(i)&0xFF`; the SHA-256 differs from the PC copy; the catalog lists `out`. Then a second boot reads it back (TR-DOS `LOAD "out" CODE` needs typing — instead verify with `trd_read` on the PC, which is the same bytes the drive served).
- [ ] **Step 4: Drive B.** `test.trd` on slot 5 only → the same boot runs from B:. `swap` (port `#028B` bit 3) is exercised only if a TR-DOS utility sets it; otherwise the row is **closed untested** with the sim evidence (`tb_floppy drive_b`) cited.
- [ ] **Step 5: Read-only row.** `chmod 444` a copy of `test.trd` on the card, mount, boot, let `boot` attempt its SAVE → TR-DOS reports the write error, the file's SHA-256 is unchanged. SCL: if the owner supplies a `.scl`, mount it (Main converts to a temp TRD, `img_readonly = 1`) and boot; otherwise **closed untested** (the conversion is Main's, proven by its source).
- [ ] **Step 6: FDI rows.** OSD `Floppy A FDI` → `test.fdi` (F1, ioctl index 1), then TR-DOS boot → the catalog reads (the FDI fixture's `boot` file); `wide.fdi` loads without error (512-byte sectors read via TR-DOS `LOAD` needs typing — the sim's `fdi_track_exact` is the evidence, the board row proves the download path and a boot). A write attempt on FDI: the file on the card is unchanged (volatile DDR writes).
- [ ] **Step 7: CP/M row.** `test.cpm` on slot 4 with `Disk layout = CP/M` → the drive reads (TR-DOS cannot use a CP/M disk; the row proves geometry + track build via a TR-DOS read attempt that must fail cleanly with RNF, not hang). Booting CP/M itself needs an owner-supplied system image: **closed untested** unless the owner provides one.
- [ ] **Step 8: Turbo/speed rows.** The boot row repeated at turbo 8x and with `Mode = Pentagon` vs `48k` (DS80 follows the video mode register) — the sim matrix is the primary evidence; the board rows prove the synchronised `ds80`/cadence switch does not wedge a running TR-DOS.
- [ ] **Step 9: Results.** `docs/dev/stage4c-results.md` in the stage-4b shape: how it was driven, the checks table (pass condition + shot per row), findings (the traps a future script must know), gates (tests, `run_all: 22`, build 71), the DDR3-vs-SDRAM deviation, the Format-Track limitation, and every **closed untested** row with its reason. Shots in `docs/dev/stage4c-shots/`, every shot referenced, no orphans.
- [ ] **Step 10: Commit** `docs: stage 4c board results`.

---

## Verification Summary

| Gate | Command | Pass |
|---|---|---|
| Python | `python3 -m unittest discover -s tools/tests` | all pass (94 + new) |
| Upstream rewrites | `tools/check_upstream.sh` | `OK` |
| Upstream elaboration | `tools/elab_upstream.sh` | exit 0 |
| Simulations | `tools/sim.sh sim/run_all.sh` | `run_all: 22 passed, 0 failed` |
| Build | `build/logs/build71.log` | `build: exit 0`, `check_timing: OK` |
| Board | `docs/dev/stage4c-results.md` | every row PASS or closed untested with reason |