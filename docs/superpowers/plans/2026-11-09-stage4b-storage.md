# Stage 4b: SD Card and IDE Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The machine's Z-Controller / DivMMC read and write an SD card image mounted in the MiSTer OSD, esxDOS runs from it, and the Profi IDE's two HDF devices are backed by two more OSD image slots.

**Architecture:**
- **SD card:** the Profi already drives a real SPI SD card at its boundary (`SD_CS_N`, `SD_CLK`, `SD_DI`, `SD_DO`; `zc_spi` inside `profi`), so the MiSTer side uses the framework's `sys/sd_card.sv` (the ZX core's DivMMC path): one hps_io disk slot, `sdhc = 1`.
- **IDE:** `profi` holds `hdf_ata` (ATA on an image, device 0 and 1) and, upstream, feeds it from `img_sdc` — the board's MCU file mounter. `img_sdc` is replaced by a MiSTer sector engine, `rtl/disk/img_src.sv`, exposed through new `profi` ports (`SDC_*`, the upstream `img_sdc`/`hdf_ata` interface verbatim), and backed by two hps_io disk slots through a 512-byte dual-clock buffer.
- **One request at a time** on the machine side, as upstream: `hdf_ata` runs one command, so the engine serves whichever of the two indices asks, reports `busy`/`done`/`error`/`slot`, and moves the sector bytes the way `img_sdc` did (read: 512 `byte_in_strobe` pulses; write: address out, 2-3 clock data latency back).

**Tech Stack:** SystemVerilog (`rtl/`, `Karabas_Profi.sv`, `iverilog -g2012`), VHDL (`profi.vhd` rewrites through `tools/prepare_upstream.py`, Quartus 17.0), Python 3 stdlib (`tools/mk_disk.py`), MiSTer framework files in `sys/`.

**Spec:** `docs/superpowers/specs/2026-11-02-karabas-profi-mister-port-design.md` §5.6 (IDE and SD), §2 (storage scope), §4 (decisions already made).

## Global Constraints

- Agent process rules — toolchain, gate commands, build numbering, the board driving recipe and commit format — are in `AGENTS.md` at the repository root; read it before the first task.
- Never edit `upstream/` or `sys/`. Upstream text changes only as exact-once rewrites in `tools/prepare_upstream.py`, each with a unit test asserting the exact new text. `sys/sd_card.sv` and `sys/hps_io.sv` are used as they are.
- `Karabas_Profi.sv` has `` `default_nettype none ``: declare every new wire. An implicit net fails `check_timing` (10236/10541).
- hps_io disk slots: `VDNUM` = the number of OSD `S` items, `BLKSZ = 2` (512-byte blocks), all slots `sd_blk_cnt = 0`, `sd_buff_addr` is 14 bits and only its low 9 are a sector offset. Slot ordinals follow the `S`-item order: 0 tape, 1 SD card, 2 IDE 0, 3 IDE 1.
- `tools/mk_disk.py` and its tests use the Python standard library only; `tests/zx/*.bas` are picked up by `tools/make_test_taps.sh` automatically.
- Every task leaves `python3 -m unittest discover -s tools/tests` (75 tests today) and `tools/sim.sh sim/run_all.sh` (`run_all: N passed, 0 failed`, 16 today; this plan adds two) OK.
- Tasks that change RTL end with a full build: `setsid nohup tools/build.sh </dev/null >build/logs/buildN.log 2>&1 &`, polled until `build: exit` → must be `build: exit 0` (includes `check_timing: OK`, the 10236 and 10541 gates), then `git checkout Karabas_Profi.qsf`. Numbering continues from build 47: the first build of this plan is `build48.log`.
- Board checks are driven by the agent once the owner grants the board: the `mister-karabas-board` skill for input, `AGENTS.md` for the capture path and the OSD traps, `docs/dev/stage4a-results.md` for the tape loading flow the run reuses. Anything that needs the owner's ears waits for the owner.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit areas: `tools`, `sim`, `disk`, `top`, `docs`.

## Review Focus

1. **Mount, eject or swap an image while a sector transfer is in flight.** Expected: the in-flight sector is dropped, `hdf_ata` re-examines the new image (sector 0 for the RDSK), and the next command reads the new image, never a mix. Test: Task 2 cases `remount_mid_transfer` and `eject_mid_transfer`.
2. **A slow HPS.** A sector takes milliseconds while the Z80 waits for DRQ. Expected: the ATA command still completes, no byte is lost, no timeout. Test: Task 2 case `slow_hps` (model latency 50 000 clocks).
3. **No image, or device 1 without an image.** Expected: `hdf_ata` reports no device (register reads return 0, commands do not start), never a hang; the SD-side SPI master reads 0xFF and times out as on a real empty slot. Test: Task 2 `no_image`/`dev1_absent`, Task 3 `eject_mid_command`.
4. **An image that is not a whole number of sectors, or smaller than one sector.** Expected: the last sector is zero-padded by the HPS, sectors past the end read as zeros, nothing hangs. Test: Task 2 case `short_image`.
5. **A write that the user believes is safe.** An image mounted read-only still accepts the core's `sd_wr`; the HPS drops it and the file on the card is unchanged. Expected: no corruption, and the result is visible in the results document. Test: Task 5 board check compares the image's SHA-256 before and after a write attempt on a read-only mount.

---

## File Structure

| File | Task | Responsibility |
|---|---|---|
| `tools/mk_disk.py` (new), `tools/tests/test_mk_disk.py` (new) | 1 | FAT16 VHD for the SD slot, RDSK HDF for the IDE slots, and a reader (`ls`/`cat`) to verify board writes |
| `tests/zx/hdf.bas`, `tests/zx/hdfw.bas` (new) | 1 | ATA PIO over the NemoIDE ports, from 128 BASIC: read sector 0, and write/read-back sector 1 |
| `rtl/disk/img_src.sv` (new) | 2 | the machine's sector engine: `SDC_*` (upstream `img_sdc` interface, indices 4/5) over two hps_io disk slots |
| `sim/models/hps_disk_model.sv` (new) | 2 | read/write hps_io sector transport model (slot ack, `sd_buff_*`, latency) |
| `sim/tb_img_src.sv`, `sim/run_tb_img_src.sh` (new) | 2 | `img_src` + `hdf_ata` end to end: IDENTIFY, read, write, mounts, errors |
| `sim/tb_sd_spi.sv`, `sim/run_tb_sd_spi.sh` (new) | 3 | SPI host against `sys/sd_card.sv`: init, CMD17, CMD24, eject mid-command |
| `tools/prepare_upstream.py`, `tools/tests/test_prepare_upstream.py` | 4 | the `profi` `SDC_*` port group, `img_sdc` removed |
| `Karabas_Profi.sv`, `files.qip`, `README.md` | 4 | SD slot, IDE slots, engine, OSD `S1`-`S3`, hps_io `VDNUM = 4` |
| `docs/dev/stage4b-results.md` (new) | 5 | board results, shots in `docs/dev/stage4b-shots/` |

---

### Task 1: `mk_disk.py`, the images, and the ATA test programs

**Files:**
- Create: `tools/mk_disk.py`, `tools/tests/test_mk_disk.py`, `tests/zx/hdf.bas`, `tests/zx/hdfw.bas`

**Interfaces:**
- Produces (importable, plus a CLI):
  - `sd_vhd(path: Path, size_mb: int = 16) -> None` — MBR + one FAT16 partition at LBA 2048 holding `TEST.TXT` (b`sd ok\n`) and `TEST.BAS` (`zxtap.tokenize_program('10 PRINT "sd ok"')`, the same bytes the ZX `LOAD` expects after the header).
  - `hdf(path: Path, sectors: int = 2048) -> None` — sector 0 = an Amiga RDB as `hdf_ata` reads it: `b"RDSK"` at 0, block size 512 big-endian at 4, and big-endian 32-bit cylinders at 64, sectors-per-track at 68, heads at 72, with `spt = 63`, `heads = 16`, `cyl = sectors // 1008` (requires `sectors >= 1008`); sector 1 = `b"KARABAS HDF\n"` then the byte pattern `(i * 7 + 3) & 0xFF`; the rest zeros.
  - `fat_list(path: Path) -> list[tuple[str, int]]`, `fat_read(path: Path, name: str) -> bytes` — reader for the VHD's partition only (finds it through the MBR, no assumption about LBA 2048).
  - CLI: `mk_disk.py sd OUT [--size-mb N]`, `mk_disk.py hdf OUT [--sectors N]`, `mk_disk.py ls IMG`, `mk_disk.py cat IMG NAME`.
- FAT16 layout pinned here (16 MiB default): 32768 sectors, partition start 2048, 30720 sectors in it; BPB bytes/sector 512, sectors/cluster 4, 1 reserved, 2 FATs, 512 root entries (32 sectors), media 0xF8, hidden 2048, drive 0x80, volume label `KARABAS SD `, FS type `FAT16   `, signature 0x55AA; `TEST.TXT` in cluster 2, `TEST.BAS` in cluster 3; sectors/FAT = `ceil((clusters + 2) * 2 / 512)`.
- ATA test program register map (NemoIDE, ports always enabled: `nemoide_en` is hard-wired 1 and the decode needs `CPM = 0`, which 128 BASIC is): 0x10 data low (a read here triggers the next 16-bit IDE read; `IN 0x11` returns the high byte of the same word, `OUT 0x11` latches the high byte before `OUT 0x10` writes the word), 0x30 error/features, 0x50 sector count, 0x70/0x90/0xB0/0xD0 LBA0-3 and DEV, 0xF0 command/status.
- Produces (fixtures): `build/taps/hdf.tap|tzx|csw` and `hdfw.*` from `tools/make_test_taps.sh` (the glob picks the new sources up; 15 files now).

- [x] **Step 1: Tests first** in `tools/tests/test_mk_disk.py` (`sys.path` insertion like `test_zxtap.py`):
  - `test_mbr`: bytes 510-511 are `55 AA`; partition entry 1: type 6, start 2048, length 30720; boot flag 0x80.
  - `test_bpb`: at sector 1 (LBA 2048): `b"\x55\xAA"` at 510, 512 bytes/sector, 2 FATs, 512 root entries, hidden 2048, total 30720, label `KARABAS SD ` at 43.
  - `test_fat_sizes`: the computed sectors/FAT covers `clusters + 2` entries, both FATs identical on disk.
  - `test_file_roundtrip`: `fat_list` names `TEST.TXT`, `TEST.BAS`; `fat_read('TEST.TXT') == b"sd ok\n"`; `fat_read('TEST.BAS') == zxtap.tokenize_program('10 PRINT "sd ok"')`.
  - `test_hdf_geometry`: file size is `sectors * 512`; bytes 0-3 `RDSK`, block size 512; `struct.unpack('>I', ...)` at 64/68/72 gives `cyl, 63, 16` with `cyl == sectors // 1008`; sector 1 starts with `KARABAS HDF` and its byte 15 is `(15 * 7 + 3) & 0xFF`.
  - `test_hdf_too_small`: `hdf(sectors=1000)` raises `ValueError` (cyl would be 0).
  - `test_cat_missing`: `fat_read('NOPE')` raises `KeyError`; the CLI exits non-zero.
- [x] **Step 2: Run** `python3 -m unittest tools.tests.test_mk_disk -v` → FAIL (`ModuleNotFoundError`).
- [x] **Step 3: Implement `tools/mk_disk.py`** (one writer for the BPB/FAT/directory, one for the RDB; the reader walks the MBR, BPB, root directory and the cluster chain).
- [x] **Step 4: The ATA programs.** `tests/zx/hdf.bas` must, on autostart, print `hdf ok RDSK` for a mounted `test.hdf` and `no hdf` without one:
  - select LBA mode device 0 (`OUT 0xD0,0xE0`), count 1, LBA 0 (`OUT 0x50,1`, `OUT 0x70,0`, `OUT 0x90,0`, `OUT 0xB0,0`), poll `IN 0xF0` (bounded loop, ≥1000 iterations) until DRDY (`AND 64`) with no BSY (`AND 128`), print `no hdf` if DRDY never comes.
  - `OUT 0xF0,0x20` (READ SECTORS), poll until DRQ (`AND 8`), abort with the status if ERR, then `L=IN 16:H=IN 17` twice and print `hdf ok `CHR$ L;CHR$ H;CHR$ L2;CHR$ H2.
  - `tests/zx/hdfw.bas` does the same for WRITE SECTORS (0x30) at LBA 1 with 256 words of `OUT 0x11,(I*7+3) MOD 256` then `OUT 0x10,(I*7+3) MOD 256`, waits for BSY to clear, re-reads LBA 1, counts mismatches, prints `hdf rw ok` or `hdf rw bad <count>`.
- [x] **Step 5: Run** the unit tests → all pass (75 + new); `tools/make_test_taps.sh` → 15 files, the two new programs among them; `python3 tools/mk_disk.py sd build/disk/test.vhd` and `hdf build/disk/test.hdf` succeed and `ls`/`cat` round-trip.
- [x] **Step 6: Commit** `tools: FAT16 VHD and RDSK HDF images, and the ATA test programs`.

### Task 2: `img_src`, the sector engine, and `tb_img_src`

**Files:**
- Create: `rtl/disk/img_src.sv`, `sim/models/hps_disk_model.sv`, `sim/tb_img_src.sv`, `sim/run_tb_img_src.sh`

**Interfaces:**
- Produces:
```systemverilog
module img_src (
    // hps_io side, clk_sys: slot a = IDE device 0, slot b = IDE device 1
    input  wire        clk_sys,
    input  wire        reset_sys,
    input  wire  [1:0] img_mounted,   // {b, a}, a pulse per mount event, like hps_io
    input  wire [63:0] img_size,
    output reg  [31:0] lba_a, output reg rd_a, input wire ack_a,
    output reg  [31:0] lba_b, output reg rd_b, input wire ack_b,
    input  wire  [8:0] sd_buff_addr,  // low 9 bits of hps_io's 14-bit address
    input  wire  [7:0] sd_buff_dout,
    output wire  [7:0] sd_buff_din_a, output wire [7:0] sd_buff_din_b,
    input  wire        sd_buff_wr,
    // machine side, clk (CLK_BUS): the upstream img_sdc interface, indices 4 and 5
    input  wire        clk, input wire reset,
    input  wire  [7:0] sdc_rd, input wire [7:0] sdc_wr, input wire [31:0] sdc_sector,
    output reg         sdc_busy, output reg sdc_done, output reg sdc_error,
    output wire  [2:0] sdc_slot,
    output reg         sdc_byte_in_strobe, output reg [8:0] sdc_byte_addr,
    output reg   [7:0] sdc_byte_in_data,   input  wire [7:0] sdc_byte_out_data,
    output wire  [7:0] sdc_img_mounted,    output wire [63:0] sdc_img_size
);
```
  - `sdc_img_mounted = {2'b00, mounted_b, mounted_a, 4'b0000}` (bits 5:4 are the two ATA devices; the low four stay 0 until the floppy plan).
  - Protocol, from `img_sdc.v`/`hdf_ata.v` (read them first): a request is a *level* on `sdc_rd`/`sdc_wr` bit 4 or 5 until `sdc_busy` rises; the engine latches it and raises `sdc_busy`/`sdc_slot` in the same clock or the next, and the requester drops its bit. `sdc_done` is a one-clock pulse; `sdc_slot` stays valid while `sdc_busy` and at `sdc_done`. Read: fetch the sector from the HPS, then 512 `sdc_byte_in_strobe` pulses with `sdc_byte_addr = 0..511` and the byte. Write: 512 samples of `sdc_byte_out_data` at `sdc_byte_addr`, sampled ≥3 `clk` after the address (hdf registers the word and the high/low select), then push to the HPS. Then `sdc_done` for one clock, `sdc_busy` low. A request for an unmounted index ends with `sdc_error`.
  - One 512-byte dual-clock buffer (`reg [7:0] buf [0:511]`, written on `clk_sys` by `sd_buff_wr` while our ack is high, read on `clk`; reversed for writes) and a registered read for `sd_buff_din_*`, as `tape_src` does.
  - Crossings are toggle handshakes with two-flop synchronisers, as in `rtl/tape/tape_src.sv`: mount `{b, a, size}` from `clk_sys` to `clk`, and the request `{a/b, wr, sector}` out and the completion back.
- Consumes: nothing from Task 1 (the tb builds its own image).

- [x] **Step 1: The model first**, `sim/models/hps_disk_model.sv`, mirroring `sim/models/sd_img_model.sv` but read/write and slot-indexed:
```systemverilog
module hps_disk_model #(parameter integer LAT_CLKS = 10) (
    input clk, input reset,
    input [63:0] img_size,            // bytes; the tb uses one size for both slots
    input [1:0]  rd, wr,              // the core's requests, levels until ack
    input [31:0] lba_a, lba_b,
    output reg [1:0] ack,
    output reg [8:0] buff_addr, output reg [7:0] buff_dout, output reg buff_wr,
    input  [7:0] buff_din,
    input  [8:0] rd_addr,             // the tb reads the stored bytes through this
    output [7:0] rd_data,
    output reg [1:0] past_end         // a request touched a sector past the file
);
// reg [7:0] mem [0:1][0:131071];  (256 KB per slot)
```
  Read: after `LAT_CLKS`, `ack` bit high, 512 `buff_wr` pulses with `buff_addr = 0..511` and the sector bytes; write: the same with `buff_wr` low, sampling `buff_din`; bytes past `img_size` read as 0 and set `past_end`.
- [x] **Step 2: The bench**, `sim/tb_img_src.sv`, DUT `img_src` + `hdf_ata` (compiled from `upstream/karabas-go-core-profi/modules/rtl/mcu/hdf_ata.v`, no rewrites), a task-level ATA host (register writes/reads and 16-bit data on `hdf_ata`'s bus at `clk`), and the model. The image: 1024 sectors built in SV, sector 0 with the RDSK geometry `cyl = 1, spt = 63, heads = 16`, sector 1 with `KARABAS HDF` + the `(i*7+3)&0xFF` pattern. Cases, each printing `PASS <case>`/`FAIL <case> <reason>` and ending `tb_img_src: PASS`:
  - `ident`: IDENTIFY DEVICE → word 0 `0x0040`, word 1 `1`, word 3 `16`, word 6 `63`, word 47 `0x8001`, word 60 `0x0400`, word 61 `0`.
  - `read_sector`: READ SECTORS LBA 1 → all 512 bytes equal the image's.
  - `write_sector`: WRITE SECTORS LBA 1 with `0x3C` repeated → the model's memory holds it and a second READ through the engine returns it (the engine writes to the HPS, the read comes back from the HPS).
  - `dev1`: mount slot b only → IDENTIFY on device 1 (`0xD0` write with `sel = 1`) works and `dev1_here` is high.
  - `no_image`: no mount → reading the status register returns 0, a command leaves it 0, the bench does not time out.
  - `dev1_absent`: device 1 with no image → its registers read 0 while device 0 still answers.
  - `short_image`: `img_size = 512 + 100` → READ LBA 1 returns 100 bytes of the file then zeros, `past_end` only for LBA 2; READ LBA 2 returns all zeros.
  - `remount_mid_transfer`: raise the mount for slot a with a *different* image while a READ is streaming → the command ends with the old bytes, and the next READ returns the new image's sector.
  - `eject_mid_transfer`: a mount pulse with `img_size = 0` during a transfer → the transfer completes or errors but does not hang, and the following command sees no device.
  - `slow_hps`: `LAT_CLKS = 50000` → `read_sector` still passes.
- [x] **Step 3: Run** `tools/sim.sh sim/run_tb_img_src.sh` against a stub `img_src` (correct ports, `sdc_busy = 0`, no transfers) → FAIL (`tb_img_src: FAIL ident ...` with the bench's bounded poll), proving the bench reaches the DUT before the engine exists.
- [x] **Step 4: Implement `rtl/disk/img_src.sv`.** Keep the header comment in the style of `tape_src.sv`: the two domains, the protocol from `img_sdc.v`, the arbitration (lowest index first, one in flight), and what a mount does to an in-flight transfer.
- [x] **Step 5: Run** the bench until all cases PASS; then `tools/sim.sh sim/run_tb_tape_src.sh` and `sim/run_tb_gs_mem.sh` (the neighbours stay green).
- [x] **Step 6: Commit** `disk: img_src, the sector engine behind the IDE images`.

### Task 3: the SD path in simulation

**Files:**
- Create: `sim/tb_sd_spi.sv`, `sim/run_tb_sd_spi.sh`

**Interfaces:**
- Consumes: `sys/sd_card.sv` as the DUT (compiled from `sys/`, unmodified) and `sim/models/hps_disk_model.sv` from Task 2 (read side; the model's write path is unused here).
- Produces: the proof that `ss` is active-high (Profi `SD_CS_N` inverted), `sck` idles high with mode-0 sampling, `miso` is the card's data out, and `sdhc = 1` answers block addresses.
- The SPI host is a bench task: `spi_byte(cmd) -> resp` (8 bits, MSB first, sample on `sck` rising for MISO, shift on falling), with `ss` driven low around a command frame; responses are read as 0xFF while busy (0x01/0x00/0x08 etc. are the R1 values `sd_card.sv` returns).

- [x] **Step 1: Write the bench** with cases `init_and_read`, `write_block`, `eject_mid_command`:
  - `init_and_read`: CMD0 → R1 `0x01`, CMD8 (`0x1AA`) → `0x01` and the trailing `0x1AA`, CMD55+ACMD41 → `0x00`, CMD58 → OCR with bit 30 (SDHC), CMD17 (`lba = 1`) → `0x00`, token `0xFE`, then 512 bytes equal to the model's sector 1, then CRC bytes ignored.
  - `write_block`: CMD24 (`lba = 2`), token `0xFE`, 512 bytes `0xA5`, then the `0xE5` data-response and the model's memory at sector 2 equal to `0xA5`; the core's `sd_wr` must be seen before `sd_ack`.
  - `eject_mid_command`: a mount pulse with `img_size = 0` in the middle of CMD17's data phase → `miso` idles at 1 (0xFF read), the bench's bounded read loop exits, and the next CMD0 still answers.
- [x] **Step 2: Run** `tools/sim.sh sim/run_tb_sd_spi.sh` before the SPI host is right → FAIL on the first response byte, which is what pins the polarity: `ss` must be driven active-high (the top inverts `SD_CS_N`), `sck` idles high and data changes on its falling edge, and `miso` is the card's output. Each mismatch is a wiring decision Task 4 then has to reproduce.
- [x] **Step 3: Correct the host until all three cases pass**, then run it three times in a row (no flakiness in the bit-bang).
- [x] **Step 4: Commit** `sim: the SD card SPI path`.

### Task 4: the core — `profi` ports, the slots, the OSD

**Files:**
- Modify: `tools/prepare_upstream.py` (`PROFI_REWRITES`), `tools/tests/test_prepare_upstream.py`
- Modify: `Karabas_Profi.sv` (disk slots, `sd_card`, `img_src`, profi port map, OSD)
- Modify: `files.qip` (`rtl/disk/img_src.sv`), `README.md` (files/features)

**Interfaces:**
- Consumes: `img_src` (Task 2), `sys/sd_card.sv`, the `SDC_*` protocol verified by Task 2/3.
- Produces: `profi` ports, exact text for the rewrites: after `SD_DET_N : in  STD_LOGIC;` add
```vhdl
	-- MiSTer stage 4b: the file mounter's sector engine (img_sdc) is on the
	-- MiSTer side; these are its ports (img_sdc's interface, indices 4 and 5).
	SDC_IMG_MOUNTED : in  STD_LOGIC_VECTOR(7 downto 0);
	SDC_IMG_SIZE    : in  STD_LOGIC_VECTOR(63 downto 0);
	SDC_RD          : out STD_LOGIC_VECTOR(7 downto 0);
	SDC_WR          : out STD_LOGIC_VECTOR(7 downto 0);
	SDC_SECTOR      : out STD_LOGIC_VECTOR(31 downto 0);
	SDC_BYTE_OUT_DATA : out STD_LOGIC_VECTOR(7 downto 0);
	SDC_BUSY        : in  STD_LOGIC;
	SDC_DONE        : in  STD_LOGIC;
	SDC_ERROR       : in  STD_LOGIC;
	SDC_SLOT        : in  STD_LOGIC_VECTOR(2 downto 0);
	SDC_BYTE_IN_STROBE : in  STD_LOGIC;
	SDC_BYTE_ADDR   : in  STD_LOGIC_VECTOR(8 downto 0);
	SDC_BYTE_IN_DATA : in  STD_LOGIC_VECTOR(7 downto 0);
```
  the signal declarations of those 14 names (and `sdc_active`) deleted, the `u_img_sdc` instantiation (from `-- File mounter sector interface` to its closing `);`) deleted, and `STATUS_CF => hdd_active or sdc_active or hdf_led` → `STATUS_CF => hdd_active or hdf_led`.
- Top wiring: `VDNUM(4)`; `wire [3:0] img_mounted; wire [31:0] sd_lba [4]; wire [5:0] sd_blk_cnt [4]; wire [3:0] sd_rd, sd_wr, sd_ack; wire [7:0] sd_buff_din [4];` with `sd_blk_cnt[0..3] = 0`, `sd_buff_din[0] = 8'h00`; tape keeps `[0]`; new `wire sd_ss_n, sd_sck, sd_mosi, sd_miso;` (profi's SPI pins); `sd_card u_sd` on `[1]` with `.sdhc(1'b1)`, `.reset(por_reset)`, `.clk_spi(clk_sys)`, `.ss(~sd_ss_n)`, `.sck(sd_sck)`, `.mosi(sd_mosi)`, `.miso(sd_miso)`, `.sd_buff_addr(sd_buff_addr[8:0])`; `img_src u_img` on `[2]` and `[3]`, `.clk(clk_bus)`, `.reset(profi_areset)`, `.reset_sys(por_reset)`, `.img_mounted(img_mounted[3:2])`, `.img_size(img_size)`, `.sd_buff_addr(sd_buff_addr[8:0])`, `.sd_buff_din_a(sd_buff_din[2])`, `.sd_buff_din_b(sd_buff_din[3])`; profi's `.SD_CS_N(sd_ss_n)`, `.SD_CLK(sd_sck)`, `.SD_DI(sd_mosi)`, `.SD_DO(sd_miso)`, `.SD_DET_N(1'b1)` and the 14 `SDC_*` connections (`sdc_byte_out_data` is a profi *output*: it goes to the engine's input).
- No other change is needed on the IDE side: `hdf_ata` already sees `dev0_en = sw_hdd` and `cf_sel = ~sw_hdd` from `osd_value(8) = 1` in `rtl/host/osd_items.svh` (HDD image, no CF card), so `ide_mux` routes the HDF to the IDE bus with `CF = 0`; its `WA`/`WD`/`WCS_N` outputs stay unconnected at the top. `ide_mux` is *kept*, deviating from the spec's "`ide_mux` is dropped": it is what connects `hdf_ata` to the IDE bus, and removing it would rewire `profi`'s IDE bus for no behaviour change. Record the deviation in the results document.
- OSD: after `S0,TAPTZXCSW,Tape;` add `S1,VHD,SD Card;`, `S2,HDFIMGVHD,IDE 0;`, `S3,HDFIMGVHD,IDE 1;` (the `S` ordinal is the disk slot; the type string is the spec's `.img .hdf .vhd` as three 3-letter groups).

- [x] **Step 1: The rewrite tests first** in `tools/tests/test_prepare_upstream.py`: `test_profi_sdc_ports` (the exact port block appears once and the old signal declarations and `u_img_sdc` are gone), `test_profi_status_cf` (the `hdd_active or hdf_led` line, no `sdc_active`). The 14 declarations are the contiguous block at `profi.vhd:293-306` (with `sdc_active` as its last line): one rewrite deletes the block. The `u_img_sdc` instantiation is one contiguous block too. Copy both old strings from the file verbatim, tabs included — `prepare_upstream.py` matches bytes.
- [x] **Step 2: Run** those two → FAIL; add the rewrites; run → PASS; `tools/check_upstream.sh` → OK; `tools/elab_upstream.sh` → OK (the elab profile keeps upstream's `profi.vhd`, so its output must not change).
- [x] **Step 3: The top.** Widen the disk arrays and add the two instantiations and the profi connections above; update the comment over the disk declarations (VDNUM = 4, which slot is which).
- [ ] **Step 4: Gates.** `python3 -m unittest discover -s tools/tests`; `tools/sim.sh sim/run_all.sh` → `run_all: 18 passed, 0 failed`.
- [ ] **Step 5: Build 48.** `setsid nohup tools/build.sh </dev/null >build/logs/build48.log 2>&1 &`, poll `build: exit 0`, then `git checkout -- Karabas_Profi.qsf`. Record the fitter summary and per-clock slack in the commit body (as the previous builds did).
- [x] **Step 6: README.** The `Files`/`Features` sections gain the three slots and their formats; `Known limitations` loses "No disks yet".
- [ ] **Step 7: Commit** `top: SD card and IDE HDF image slots` with the build number and gate results in the body.

### Task 5: Board run

**Files:**
- Create: `docs/dev/stage4b-results.md`, `docs/dev/stage4b-shots/*.png`
- Modify: `README.md` (whatever the run proves or contradicts)

- [ ] **Step 1: Board prep.** Copy `build/output_files/Karabas_Profi.rbf` (the build48 compile) to `/media/fat/_Computer/Karabas_Profi_20261109.rbf`, and `build/taps/hdf.tap`, `hdfw.tap`, `build/disk/test.vhd`, `build/disk/test.hdf` to `/media/fat/games/Karabas_Profi/`. Write one MGL per check, `<file type="s" index="N" path="..."/>` with N = 0 tape, 1 SD card, 2 IDE 0, 3 IDE 1.
- [ ] **Step 2: IDE rows.** Load the MGL with `hdf.tap` + `test.hdf` on slot 2, `LOAD ""`, play: expect `hdf ok RDSK`. Then `hdfw.tap`: expect `hdf rw ok`, and `sha256sum /media/fat/games/Karabas_Profi/test.hdf` differs from the PC copy while the first 512 bytes still parse as the RDSK (compare with `mk_disk.py`'s reader or `cmp`). Repeat with only slot 3 mounted and `test.hdf` on device 1.
- [ ] **Step 3: No-image row.** No HDF mounted → `hdf.tap` prints `no hdf` within its bounded poll, no hang.
- [ ] **Step 4: SD rows.** DivMMC `On`, `test.vhd` on slot 1, OSD `Reset`, NMI from 128 BASIC → the esxDOS browser lists `TEST.TXT` and `TEST.BAS`; `LOAD "TEST.BAS"` + `RUN` prints `sd ok`; `SAVE "OUT.BAS"` then verify from the PC with `python3 tools/mk_disk.py cat test.vhd OUT.BAS` (fetched from the board).
- [ ] **Step 5: Read-only row.** Mount `test.vhd` read-only, save again, confirm the board's file SHA-256 is unchanged (the HPS drops the write) and the result is recorded.
- [ ] **Step 6: Results.** `docs/dev/stage4b-results.md` in the stage-4a shape: how it was driven, the checks table with pass conditions and shots, findings (what a future script must know — keys, MGLs, the read-only behaviour), gates (tests, `run_all`, build number), and the core/image files left on the card.
- [ ] **Step 7: Commit** `docs: stage 4b board results`.

---

## Verification Summary

| Gate | Command | Pass |
|---|---|---|
| Python | `python3 -m unittest discover -s tools/tests` | all pass (75 + new) |
| Upstream rewrites | `tools/check_upstream.sh` | `OK` |
| Upstream elaboration | `tools/elab_upstream.sh` | exit 0 |
| Simulations | `tools/sim.sh sim/run_all.sh` | `run_all: 18 passed, 0 failed` |
| Build | `build/logs/build48.log` | `build: exit 0`, `check_timing: OK` |
| Board | Task 5 table | every row PASS or recorded as not tested |