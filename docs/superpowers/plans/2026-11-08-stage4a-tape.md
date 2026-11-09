# Stage 4a: Tape Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TAP, TZX and CSW files play in real time into the machine's tape input, so the Profi ROM's normal `LOAD ""` works, at every turbo setting (spec goal 6a, §5.4). Test programs are generated on the PC as TAP/TZX/CSW files.

**Architecture:**
- **Split of stage 4 (controller ruling, 2026-11-08):** stage 4 is four separate subsystems, so it is three plans, each merged after its own board check: 4a tape (this plan; the owner asked for PC-generated TAP test programs first), 4b SD card (DivMMC / Z-Controller, esxDOS) and the two IDE HDF images, 4c the emulated floppy drives on the VG93.
- **PC side:** `tools/zxtap.py` turns BASIC source text into a TAP (a tokeniser for 48K/128K BASIC), wraps a binary as a CODE block, and converts a TAP into TZX (standard-speed blocks) and CSW v1 (RLE pulses). Test programs live as `.bas` sources under `tests/zx/`; `tools/make_test_taps.sh` writes `build/taps/`.
- **Core side:**
  - The player is the owner's ZX-Spectrum_MISTer `rtl/tape.sv` + `rtl/tzxplayer.vhd` (commit c2c4e6f), copied verbatim into `rtl/tape/`.
  - The file is not loaded into memory. It stays an image on the SD card, mounted in the hps_io disk slot 0 (`S0`). A new `rtl/tape/tape_src.sv` reads it sector by sector through `sd_*`, with a two-sector ping-pong cache that prefetches the next sector. It serves `tape.sv`'s memory port, and sniffs the format from the first sector ("ZXTape!" = TZX, "Compressed Square Wave" = CSW, else TAP).
  - The player runs on `clk_bus` with `ce = ena_cpu`, profi's CPU T-state enable, exported by a rewrite. Tape timing then follows the CPU at every turbo, set by OSD or by port `#028B`: turbo loading is plain CPU turbo, as the spec says. Pause stops the tape with the CPU.
  - `TAPE_IN` is the player while a tape is mounted and playing, else the MiSTer I/O board's line-in (`sys/ltc2308_tape`).
- **Controls:** OSD triggers "Tape play/pause", "Tape previous block" and "Tape next block" instead of F1/F2/F3. Controller ruling: the Profi XT keyboard passes F1-F10 to the machine (CP/M and the Profi software use them), so the core must not take them.

**Tech Stack:** SystemVerilog, VHDL-93 (the imported player), Quartus 17 (`tools/build.sh`), Icarus `-g2012` and GHDL 5 (`--synth --out=verilog` to bring `tzxplayer.vhd` into an Icarus testbench) through `tools/sim.sh`, Python 3 (`unittest`, no third-party packages).

**Spec:** `docs/superpowers/specs/2026-11-02-karabas-profi-mister-port-design.md` (goal 6a, §5.4 last bullet, §6 stage 4). Prior art: `~/repo/ZX-Spectrum_MISTer/ZX-Spectrum.sv` (how the ZX core wires `tape.sv`, `ltc2308_tape` and `tape_in`).

## Global Constraints

- Agent process rules — toolchain, gate commands, build numbering, the board
  driving recipe and commit format — are in `AGENTS.md` at the repository root;
  read it before the first task.
- Never edit `upstream/` or `sys/`. Changes to upstream text are rewrites in `tools/prepare_upstream.py`, each matched exactly once, each with a unit test asserting the exact new text.
- `rtl/tape/tape.sv` and `rtl/tape/tzxplayer.vhd` are verbatim copies of `~/repo/ZX-Spectrum_MISTer/rtl/` at commit c2c4e6f (check with `git -C ~/repo/ZX-Spectrum_MISTer show c2c4e6f:rtl/tape.sv | diff - rtl/tape/tape.sv`). Their origin goes in a comment in `files.qip` and in the README; they are not edited.
- `Karabas_Profi.sv` has `` `default_nettype none ``: declare every new wire.
- Every task leaves `tools/sim.sh sim/run_all.sh` → `run_all: N passed, 0 failed` and `python3 -m unittest discover -s tools/tests` OK (59 tests today).
- Tasks that change RTL end with a full build: `setsid nohup tools/build.sh </dev/null >build/logs/buildN.log 2>&1 &`, polled in the foreground until `build: exit` → must be `build: exit 0` (includes `check_timing: OK`, the 10236 and 10541 gates), then `git checkout Karabas_Profi.qsf`. Numbering continues from build 38: the first build of this plan is `build39.log`. Seed fallback (`SEED 2`/`3`) only for failures with both ends in `sys/`. Never weaken a constraint or a test.
- Board checks are driven by the agent once the owner grants the board: the
  `mister-karabas-board` skill for input, `AGENTS.md` for the capture path and the OSD/
  tape traps, `docs/dev/stage4a-results.md` for what the previous runs already proved.
  Anything that needs the owner's ears (sound.tap) waits for the owner.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit areas: `tools`, `sim`, `tape`, `top`, `docs`.

## Review Focus

1. **Loading at turbo 8x, and a turbo change in the middle of a load.** Expected: `LOAD ""` succeeds at every turbo, because the tape counts CPU T-states. Test: Task 3 case `ce_follows_enable` (pulse lengths in `ce` ticks are the same with `ce` every clock and every 8 clocks), and the board run at turbo off and 8x.
2. **A slow SD card.** The HPS may take milliseconds per sector while the tape consumes a byte every ~0.3 ms at turbo 8x. Expected: no gap in the tape signal, because the next sector is fetched while the current one plays. Test: Task 2 case `prefetch_hides_latency` (sector latency 2 ms, consumer one byte per 300 µs, never stalls).
3. **Unmount or a new tape mid-play.** Expected: the old tape stops at once and the new one starts from its beginning, with the format re-sniffed. Test: Task 2 case `remount`.
4. **A file that is not a multiple of 512 bytes, or shorter than one sector.** Expected: exactly `size` bytes are played, never the zero padding of the last sector. Test: Task 2 case `short_file` (100-byte TAP) and Task 3's end-to-end decode, which compares byte counts.
5. **Tokeniser edge cases:** keywords inside strings and after `REM` stay text; numbers get their hidden 5-byte form; `GO TO` and `GO SUB` are one token each. Test: Task 1 cases.

---

## File Structure

| File | Task | Responsibility |
|---|---|---|
| `tools/zxtap.py` (new), `tools/tests/test_zxtap.py` (new) | 1 | BASIC → TAP, CODE → TAP, TAP → TZX, TAP → CSW v1 |
| `tests/zx/*.bas` (new), `tools/make_test_taps.sh` (new) | 1 | test program sources, `build/taps/` generator |
| `rtl/tape/tape_src.sv` (new) | 2 | sd_* sector reader, 2-sector cache, format sniff, `tape.sv` memory port |
| `sim/models/sd_img_model.sv` (new), `sim/tb_tape_src.sv` (new), `sim/run_tb_tape_src.sh` (new) | 2 | hps_io sd_* model serving a file, testbench |
| `rtl/tape/tape.sv`, `rtl/tape/tzxplayer.vhd` (new, verbatim) | 3 | the player |
| `sim/tb_tape_play.sv` (new), `sim/run_tb_tape_play.sh` (new) | 3 | end-to-end: TAP file → tape_src → tape.sv → pulses → decoded bytes |
| `tools/prepare_upstream.py` + tests | 3 | profi port `ENA_CPU_O` |
| `Karabas_Profi.sv`, `files.qip`, `README.md` | 3 | hps_io slot 0, the player, ADC, OSD, LED, `TAPE_IN` |
| `docs/dev/stage4a-results.md` (new) | 4 | board results |

---

### Task 1: `zxtap.py`, test programs on the PC

**Files:**
- Create: `tools/zxtap.py`, `tools/tests/test_zxtap.py`, `tools/make_test_taps.sh`, `tests/zx/hello.bas`, `tests/zx/sound.bas`, `tests/zx/gsquery.bas`

**Interfaces:**
- Produces (importable functions and a CLI):
  - `tokenize_line(text: str) -> bytes`: one BASIC line `"<number> <statements>"` → `num(2, big-endian) + len(2, little-endian) + body + b"\x0d"`.
  - `tokenize_program(src: str) -> bytes`: every non-empty line, in source order.
  - `number_form(text: str) -> bytes`: `0x0E` + the 5-byte form. Integers −65535..65535 use the small-integer form `00 sign lo hi 00` (sign `00` or `FF`, two's complement for negative); others use Spectrum floating point (exponent byte = binary exponent + 0x80 + 1, 4 mantissa bytes, sign in the top bit of the first mantissa byte).
  - `tap_block(flag: int, data: bytes) -> bytes`: `len(2, LE) + flag + data + xor-checksum`.
  - `program_tap(name: str, program: bytes, autostart: int | None) -> bytes`: header (flag 0x00, type 0, name padded to 10 with spaces, data length, param1 = autostart line or 32768, param2 = program length) + data block (flag 0xFF).
  - `code_tap(name: str, data: bytes, addr: int) -> bytes`: header type 3, param1 = addr, param2 = 32768.
  - `tap_to_tzx(tap: bytes, pause_ms: int = 1000) -> bytes`: `b"ZXTape!\x1a\x01\x14"` + one block 0x10 per TAP block (`0x10, pause(2 LE), len(2 LE), data`).
  - `tap_to_csw(tap: bytes, rate: int = 44100) -> bytes`: CSW v1.01 (`b"Compressed Square Wave\x1a"`, version 1,1, rate (2 LE), compression 1 (RLE), flags 0, 3 zero bytes), then RLE pulse lengths in samples. Each length is `round(T * rate / 3500000)`, at least 1; a length > 255 is written as `0x00` + 4 bytes LE. Standard ROM timings in T-states: pilot 2168 × 8063 (flag < 128) or × 3223, sync 667 then 735, bit 0 = 2 × 855, bit 1 = 2 × 1710 (MSB first), then a 1000 ms pause as one pulse.
  - CLI: `zxtap.py bas <src.bas> <out.tap> [--name N] [--autostart L]`, `zxtap.py code <bin> <out.tap> --name N --addr A`, `zxtap.py tzx <in.tap> <out.tzx>`, `zxtap.py csw <in.tap> <out.csw>`.
- Tokeniser rules (decided here):
  - Keywords are the 48K set 0xA5..0xFF plus the 128K `SPECTRUM` 0xA3 and `PLAY` 0xA4, matched case-insensitively, longest first. They match only outside string literals and outside the rest of a `REM` line, and only where the previous character is not a letter. `GO TO`, `GO SUB`, `DEF FN`, `OPEN #`, `CLOSE #`, `INPUT`, `INKEY$`, `PI`, `FN`, `CHR$`, `CODE`, `VAL$` are in the table with their exact spelling (`OPEN #` and `CLOSE #` include the `#`).
  - One space after a keyword and spaces before one are dropped, since the Spectrum prints them itself. Other spaces are kept.
  - Text inside `"..."` is copied byte for byte.
  - A numeric literal outside strings (digits, optional `.` and fraction, optional `e±n`) not part of a variable name is copied as text and followed by `number_form`. A number right after a letter or `$` belongs to the name.
  - Non-ASCII input is an error naming the line.

- [x] **Step 1: Tests first** in `tools/tests/test_zxtap.py`:
  - `test_print_one`: `tokenize_line("10 PRINT 1") == bytes.fromhex("000a0900f5310e0000010000" + "0d")`, with the length field `0x0009` covering the body and the `0x0d`.
  - `test_goto_gosub`: `"20 GO TO 10: GO SUB 30"` contains `0xEC` and `0xED`, not the letters.
  - `test_string_and_rem`: `'30 PRINT "PRINT": REM PRINT 1'` has exactly one 0xF5 before the string, the string bytes `PRINT` literal, 0xEA for REM, then `PRINT 1` literal with no number form after it.
  - `test_lowercase_keywords`: `"10 print 1"` equals `"10 PRINT 1"`.
  - `test_numbers`: `number_form("0") == 0e 00 00 00 00 00`, `"65535" → 0e 00 00 ff ff 00`, `"0.5" → 0e 80 00 00 00 00`, `"1.5" → 0e 81 40 00 00 00`, `"-1"` is not a literal (the `-` is an operator: the tokenised text is `-1` + form of `1`).
  - `test_variable_digits`: `"10 LET a1=2"`: no number form after `a1`, one after `2`.
  - `test_play_token`: `'10 PLAY "c"'` starts the body with 0xA4.
  - `test_tap_checksum`: every block from `program_tap` XORs to 0 over flag + data + checksum; the header is 19 bytes after its length; param2 = program length.
  - `test_tzx`: the signature and one 0x10 block per TAP block, with each block's data equal to the TAP block's.
  - `test_csw_roundtrip`: decode the CSW RLE back to pulse lengths in T-states (× 3500000 / rate), group the pulses as pilot/sync/bits, recover the bytes, and compare with the TAP data (tolerance ±1 sample per pulse).
- [x] **Step 2: Run** `python3 -m unittest tools.tests.test_zxtap -v` → FAIL (no module).
- [x] **Step 3: Implement `tools/zxtap.py`.**
- [x] **Step 4: Programs.**
  - `tests/zx/hello.bas`: `10 PRINT "tape ok"` and `20 PRINT PEEK 23672` (FRAMES low byte, proves it ran).
  - `tests/zx/sound.bas`: stage 3's chip test (AY0, AY1, FM, SAA, OPL, Covox), as in `docs/dev/stage3-results.md`, with uppercase allowed now.
  - `tests/zx/gsquery.bas`: the stage 3 GS page query with a 300-round error count.
  - `tools/make_test_taps.sh` writes `build/taps/<name>.tap`, `.tzx` and `.csw` for each `.bas` with `--autostart 10`, and prints the files.
- [x] **Step 5: Run** the unit tests → OK (all, 59 + new); `tools/make_test_taps.sh` → 9 files.
- [x] **Step 6: Commit** `tools: zxtap, BASIC to TAP/TZX/CSW, and the test programs`.

### Task 2: `tape_src`, the tape file on the SD card

**Files:**
- Create: `rtl/tape/tape_src.sv`, `sim/models/sd_img_model.sv`, `sim/tb_tape_src.sv`, `sim/run_tb_tape_src.sh`

**Interfaces:**
- Produces:
```systemverilog
module tape_src (
    // hps_io side (clk_sys, 50 MHz), disk slot 0, 512-byte sectors
    input  wire        clk_sys,
    input  wire        img_mounted,     // hps_io img_mounted[0] (pulse)
    input  wire [63:0] img_size,
    output reg  [31:0] sd_lba,
    output reg         sd_rd,
    input  wire        sd_ack,
    input  wire  [8:0] sd_buff_addr,
    input  wire  [7:0] sd_buff_dout,
    input  wire        sd_buff_wr,
    // tape side (clk = clk_bus)
    input  wire        clk,
    output reg         tape_ready,      // a file is mounted and sniffed
    output reg   [1:0] tape_mode,       // 0 TAP, 1 CSW, 2 TZX (tape.sv's encoding)
    output reg  [24:0] tape_size,       // min(img_size, 2^25 - 1)
    input  wire        rd,              // tape.sv rd
    input  wire [24:0] addr,            // tape.sv addr
    output reg   [7:0] din,             // tape.sv din
    output reg         rd_en            // tape.sv rd_en
);
```
Behaviour (the header comment states all of it):
- **Mount** (clk_sys): on `img_mounted` with `img_size != 0`, invalidate both cache slots. Then read sector 0 into slot 0 and sniff it: bytes 0..6 = `ZXTape!` → mode 2; bytes 0..21 = `Compressed Square Wave` → mode 1; else mode 0. Then hand `{mode, size}` to the clk domain with a toggle, where `tape_ready` rises. A mount with size 0 (eject) hands over `tape_ready = 0`. In the clk domain, `tape_ready` drops for at least 4 clk cycles between two mounts, so `tape.sv`'s rising-edge `tape_ready` detection sees every new tape.
- **Cache:** two 512-byte slots in one 1 KB dual-clock BRAM (written on clk_sys from `sd_buff_*` while `sd_ack`, read on clk). Each slot has a tag (sector number) and a valid bit owned by the clk domain. A fetch is requested by a toggle carrying `{slot, lba}` from clk to clk_sys, and acknowledged by a toggle back; the slot is invalid while being fetched.
- **Serving `tape.sv`** (clk): the `rd_en` handshake of `tape.sv` (read its lines ~126-140: `rd_req` rises only while `rd_en = 0`; `rd = rd_req & rd_en`; it takes `din` on the first `rd_en = 0` clock after a `rd_en = 1` clock). FSM: `rd_en` alternates 0 → 1. In the `rd_en = 1` state:
  - no `rd`: back to 0;
  - `rd` and `addr[24:9]` hits a valid slot: read the BRAM, load `din`, then `rd_en = 0` on the following clock (din is stable from then on);
  - a miss: request that sector into the slot not holding the current one and wait with `rd_en = 1` until it is valid.
- **Prefetch:** whenever a read hits slot s at sector L and `L + 1` is inside the file and not in the other slot (and no fetch is in flight), fetch `L + 1` into the other slot.
- Addresses ≥ `tape_size` are never requested by `tape.sv`; a sector past the end is never fetched.

`sd_img_model.sv` (sim only): serves a byte array (loaded with `$readmemh` from a hex file the tb writes, or filled by the tb) as hps_io does. On `sd_rd` it waits `LAT_CLKS` clk_sys cycles, raises `sd_ack`, emits 512 `sd_buff_wr` pulses with `sd_buff_addr` 0..511 and `sd_buff_dout` (zero past the end of the file), then drops `sd_ack`. A request while `sd_ack` is high is an error.

- [x] **Step 1: `sim/tb_tape_src.sv`**, clk_sys 50 MHz, clk 28.125 MHz, cases each printing `<case>: ok` or `FAIL <case> ...`:
  - `sniff`: three files (a TAP from `tools/zxtap.py`, its TZX, its CSW, written to `build/sim/` by the run script) give modes 0, 2, 1 and the right sizes.
  - `sequential`: a consumer model of `tape.sv`'s handshake reads every byte 0..size−1 of a 3000-byte file and compares.
  - `prefetch_hides_latency`: `LAT_CLKS` = 100000 (2 ms) and a consumer that wants one byte every 300 µs: after the first byte, no read waits more than 2 clk cycles (log the worst).
  - `random_jump`: reads at 2900, 10, 1500 (crossing sectors backwards) return the right bytes.
  - `short_file`: a 100-byte file: bytes 0..99 correct, and `tape_size` = 100.
  - `remount`: mount file A, read 600 bytes, mount file B: `tape_ready` falls, then rises with B's mode and size, and B's byte 0 is read (not A's cached sector 0).
  - Verdict `tb_tape_src: PASS` / `FAIL`.
- [x] **Step 2: `sim/run_tb_tape_src.sh`**: run `python3 tools/zxtap.py` on the host to make the fixtures (hello.bas → .tap/.tzx/.csw, plus raw byte files), then Icarus in the sim image, as the other scripts do. RED: FAIL (no module).
- [x] **Step 3: Implement `rtl/tape/tape_src.sv`.**
- [x] **Step 4: Run** → `tb_tape_src: PASS`; `run_all` → `14 passed, 0 failed`.
- [x] **Step 5: Commit** `tape: tape_src, the tape file from the SD card through a two-sector cache`.

### Task 3: the player in the core

**Files:**
- Create: `rtl/tape/tape.sv`, `rtl/tape/tzxplayer.vhd` (verbatim), `sim/tb_tape_play.sv`, `sim/run_tb_tape_play.sh`
- Modify: `tools/prepare_upstream.py`, `tools/tests/test_prepare_upstream.py`, `Karabas_Profi.sv`, `files.qip`, `README.md`

**Interfaces:**
- Consumes: Task 2 `tape_src`; Task 1 `zxtap.py` (fixtures).
- Produces, on `profi` (rewrites): port `ENA_CPU_O : out std_logic` after `GSL_TGL : out std_logic;`; `ENA_CPU_O <= ena_cpu;` after `CLK_GS_O <= clk_gs;`. U1's `ENA_CPU` drives profi's `ena_cpu`: the T80 `CEN`, one pulse per CPU T-state at every turbo.
- CONF_STR: `"S0,TAPTZXCSW,Tape;"` (main page, after the PSG/Covox items); `"T[31],Tape play/pause;"`, `"T[32],Tape previous block;"`, `"T[33],Tape next block;"`.

- [x] **Step 1: Import** the two player files verbatim (the Global Constraints check). `files.qip`: `rtl/tape/tzxplayer.vhd` (VHDL), `rtl/tape/tape.sv`, `rtl/tape/tape_src.sv` (SystemVerilog), with an origin comment.
- [x] **Step 2: `sim/tb_tape_play.sv` + `sim/run_tb_tape_play.sh`.** The script converts the player with `ghdl --synth --std=93c -fsynopsys -fexplicit --out=verilog -gTZX_MS=3500 rtl/tape/tzxplayer.vhd -e tzxplayer > build/sim/tzxplayer_syn.v`. That is `tape.sv`'s `TZX_MS = CLOCK/1000` = 3500. Then it compiles `tape.sv`, `tape_src.sv`, `sd_img_model.sv` and the tb with Icarus. Cases:
  - `tap_decode`, `tzx_decode`, `csw_decode`: mount `hello` as TAP, TZX, CSW. `ce` = one clk in 8 (3.5 MHz on 28 MHz). Measure `audio_out` edges in `ce` ticks and decode with a ROM-loader-style decoder: pilot ≥ 2000 ticks, sync, bit = pulse pair, 0 if the pair < 2400 ticks else 1. Both blocks (header, data) must decode to exactly the TAP blocks' flag + data + checksum bytes.
  - `ce_follows_enable`: `tap_decode` again with `ce` every clock (turbo 8x): the same pulse lengths in `ce` ticks (±1), so the same bytes.
  - `tape.sv` ports: `ce`, `mode48k(0)`, `turbo(0)`, `byte_wait(0)`, `pause/prev/next(0)`, `stdload(0)`, `req_hdr(0)`, `tape_ready/tape_mode/tape_size` and the memory port from `tape_src`. Verdict `tb_tape_play: PASS`.
  - If `tape.sv`'s `pause` input must be pulsed to start playback (read its `play_pause` logic: is a new tape playing or paused after `tape_ready` rises?), the tb pulses it. Report which, because Task 4 depends on it.
- [x] **Step 3: Rewrites + tests** (exact text, like stage 3's `GSM_*` tests) → `python3 tools/prepare_upstream.py`, `tools/check_upstream.sh` OK.
- [x] **Step 4: Top** (`Karabas_Profi.sv`):
  - `hps_io`: `.VDNUM(1)`, `.BLKSZ(2)` explicit; wire `img_mounted`, `img_readonly`, `img_size`, `sd_lba` (array of one), `sd_blk_cnt` = 0, `sd_rd`, `sd_wr = 0`, `sd_ack`, `sd_buff_addr`, `sd_buff_dout`, `sd_buff_din` = 0, `sd_buff_wr`.
  - `tape_src u_tape_src` (`clk_sys`, `clk(clk_bus)`: the top's existing `clk_bus` wire from profi's `CLK_BUS` port). Every clk_sys ↔ clk_bus crossing is already cut by the sdc's exclusive groups; `tape_src`'s crossings are toggle handshakes and the dual-clock BRAM.
  - `tape u_tape`: `clk_sys(clk_bus)`, `ce(ena_cpu_o)`, controls from the three OSD triggers. Each trigger is synchronised into clk_bus with 2 FF and made into a one-clock pulse.
  - `ltc2308_tape u_tape_adc(.reset(...), .clk(clk_sys), .ADC_BUS(ADC_BUS), .dout(tape_adc), .active(tape_adc_act))`, as the ZX core wires it. Remove the `ADC_BUS = 'Z` tie-off.
  - profi `TAPE_IN = tape_active ? tape_audio : (adc_act_s ? tape_adc_s : 1'b0)`. `_s` = 2-FF synchronised into clk_bus. No inversion: profi reads `not(TAPE_IN)` as the EAR bit, which matches the ZX core's `ula_tape_in = ~tape_vin`.
  - `LED_USER = tape_active`.
  - CONF_STR lines as above.
- [x] **Step 5: Gates**: unit tests, check_upstream, `tb_tape_play: PASS`, `run_all` → `15 passed, 0 failed`.
- [x] **Step 6: Commits** `tape: import tape.sv and tzxplayer.vhd (ZX-Spectrum_MISTer c2c4e6f)`, `tools: profi ENA_CPU_O`, `top: tape files on disk slot 0`. README: Tape section (mount in the OSD, formats, play/pause/prev/next items, turbo loading = CPU turbo, the line-in).
- [x] **Step 7: Build** `build39.log` → `build: exit 0`. Report per-clock slacks and the fitter summary.

### Task 4: Board run (controller)

The controller copies `build/taps/*` to `/media/fat/games/Karabas_Profi/` on the board. It mounts them through the OSD or an MGL file (`<file type="s" index="0" .../>`), and checks:

| Check | Pass |
|---|---|
| `hello.tap` with `LOAD ""` in 128 BASIC, turbo off | prints `tape ok` |
| the same, turbo 8x | prints `tape ok`, faster |
| `hello.tzx`, `hello.csw` | both load |
| `sound.tap` | loads and runs; the owner hears the six chips |
| `gsquery.tap` at 8x | 0 errors |
| play/pause, previous/next block items | behave as named |
| LED | lit while the tape plays |
| line-in | only if the owner has a cassette or audio source; else recorded as not tested |

Results in `docs/dev/stage4a-results.md`.
