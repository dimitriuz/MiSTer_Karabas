# Stage 5: Serial Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This repo's implementers run through omp (see `AGENTS.md` and `~/repo/llm-setup/working-with-the-local-model.md`); the controller runs `sim/run_all.sh`, builds and every board step.

**Goal:** The Profi's two serial channels reach the MiSTer Linux side as a plain tty (`/dev/ttyS1`), and an OSD item picks which channel: **ESP** (the ZXUNO UART `#FC3B/#FD3B` and the ZiFi API on the `UART_RX/TX/CTS` wires, default) or **USB** (the ZiFi/EVO USB-RS232 channel, which the real board carries as bytes over the MCU link). MidiLink (OSD `UART mode = MIDI`) keeps working and keeps priority.

**Why now, and what it is not:** The owner does not use serial today (spec §5.7); this stage is completeness and the base a Linux-side ESP-AT daemon would later sit on. It is **not** that daemon, not a network stack, and not a baud-rate converter. Anti-goal: anything that makes MIDI worse, that needs Frontier or an edit to `user-startup.sh` or `/media/fat/linux/uartmode`, or that wedges the machine when no tty reader is attached.

**Architecture (my calls, no questions were asked; the owner can overrule any of them):**
- **ESP channel = the wires.** `profi.vhd` already exposes `UART_TX`, `UART_CTS` (out) and `UART_RX` (in), selecting ZiFi or ZXUNO internally (`UART_TX <= zifi_uart_tx when zifi_api_enabled else zxuno_uart_tx`, `profi.vhd:1398`). The top ties `UART_RX(1'b1)` and leaves the outputs open today (`Karabas_Profi.sv:387`). The channel is a **pass-through at the wire level**: the baud rate is whatever the software programmes, and Linux's tty speed is whatever Main_MiSTer sets for the chosen UART mode. No resampling.
- **USB channel = bytes.** `profi.vhd` hands the ZiFi USB path byte strobes (`usb_uart_tx_data/wr` out of the machine, `usb_uart_rx_data/idx` in), carried by `kg_mcu` as `CMD_UART` (`0xFC`) frames: to the MCU `00 d` (byte), `01 dll`, `02 dlm`; from the MCU `idx d` (idx is a counter, a new byte when it changes). `mcu_emu` plays the MCU, so it must (a) take the `CMD_UART` replies the machine sends (they land in `last_reply/reply_valid` today and are ignored) and (b) send received bytes as `CMD_UART` frames. A small serialiser/deserialiser (8N1, fixed divisor, my call: the tty speed of the UART mode) turns bytes into the HPS UART line and back. The `dll/dlm` writes are ignored (documented): the Linux tty speed is fixed per mode.
- **One new module, `rtl/host/uart_route.sv`:** the channel mux (`status` bit), the `UART_RXD` synchroniser into `clk_bus`, the byte serialiser/deserialiser with a small FIFO each way, and the MidiLink priority (`uart_mode == 3` → the existing `mt32_mix` line, untouched). Pure RTL, one clock domain per side with the proven toggle/two-flop crossings only; no new FIFO IP.
- **Modes.** MiSTer's `UART mode` page lists what `CONF_STR` declares. Today only `UART31250,MIDI`. This stage adds a serial mode at the speed of the standard ZiFi baud (115200; the exact `CONF_STR` token syntax is taken from Main_MiSTer / another core's `CONF_STR`, then confirmed on the board through `/tmp/UART_SPEED` — Task 3). *The mode selector is MiSTer's; the channel item is ours; both are needed.*

**Tech Stack:** SystemVerilog (`rtl/host/`, `Karabas_Profi.sv`, `iverilog -g2012`), VHDL rewrites through `tools/prepare_upstream.py` only if a port needs one (expected: none, the top already drives `UART_RX` and reads `UART_TX`), Quartus 17.0, Python 3 stdlib for tools/board.

**Spec:** `docs/superpowers/specs/2026-11-02-karabas-profi-mister-port-design.md` §5.7 (serial), §5.8 (MIDI), §2 future plans (the network daemon stays out).

## Global Constraints

- Agent process rules (toolchain, gate commands, build numbering, board recipe, commit format) are in `AGENTS.md`; read it first. Never edit `upstream/` or `sys/`. `docs/dev/stage5-results.md` is controller-owned.
- `Karabas_Profi.sv` has `` `default_nettype none ``: declare every new wire.
- Implementers never touch the board and never run `sim/run_all.sh` (over 3 hours); they run their own bench via `tools/sim.sh sim/run_tb_*.sh` and `python3 -m unittest discover -s tools/tests`.
- A build is `setsid nohup tools/build.sh </dev/null >build/logs/buildN.log 2>&1 &` (the next free N, 74 or higher), polled to `build: exit 0` with `check_timing: OK`, then restore `Karabas_Profi.qsf`'s `LAST_QUARTUS_VERSION`.
- Board rules (CLAUDE.md): the board is shared; ask first, check `/tmp/CORENAME` is `MENU`, never touch the owner's images, Frontier, `user-startup.sh` or `uartmode`, restore `menu.rbf`. The HDMI capture feed may be down; use `MiSTer_docs/tools/mister_shot.sh`, not `mister.Capture`, while the owner's ffmpeg publisher holds the card.
- Lessons carried from stage 4c, apply them: (1) **a bench that shares its fixture's assumptions proves nothing about the real consumer**; every protocol fact here (`CMD_UART` framing, the ZXUNO register addresses) is checked against the upstream source or the real TR-DOS/ROM behaviour, and the board row is what closes it. (2) Plain BASIC cannot drive a TR-DOS command, and typing into a shell through `zx.type_text` fails for keywords; board programs are `boot` files or short BASIC `OUT` lines built by a script.
- Commit messages end with the attribution lines the session gives. Areas: `tools`, `sim`, `serial`, `top`, `docs`.

## Review Focus

1. **MIDI must not regress.** With `UART mode = MIDI` the line is exactly `mt32_mix`'s; with any other mode the core never drives the line low by accident (idle high). Test: `tb_mt32_mix` unchanged and green; a `tb_uart_route` case per mode.
2. **No tty reader attached.** TX into a UART nobody reads, RX never arriving. Expected: the machine does not stall (the ZiFi USB path has `CPU_WAIT`, `profi.vhd:1733`), a full TX FIFO drops or back-pressures by a documented rule, never deadlocks.
3. **Channel switch mid-byte.** Flipping the OSD item while a byte is on the line. Expected: the byte in flight finishes on the old channel or is dropped whole, never a half byte on the new one.
4. **Baud mismatch.** The pass-through carries whatever baud the software sets; the USB path is fixed. Expected: documented in the README, not "fixed" by guessing.
5. **Clock domains.** `UART_RXD` is asynchronous (two-flop into `clk_bus`, glitch-filtered by majority of 3 over the sample point), the MCU link is `clk_sys`. Test: the bench drives RX with a skewed clock ratio.
6. **The `CMD_UART` bytes `mcu_emu` ignores today.** Adding the decode must not reorder the report burst or change any `tb_mcu_emu` expectation for other commands.

---

## File Structure

| File | Task | Responsibility |
|---|---|---|
| `rtl/host/uart_route.sv` (new), `sim/tb_uart_route.sv`, `sim/run_tb_uart_route.sh` (new) | 1 | channel mux, RX synchroniser, USB byte serialiser/deserialiser, MIDI priority |
| `rtl/host/mcu_emu.sv`, `sim/tb_mcu_emu.sv` | 2 | `CMD_UART` both ways on the MCU link |
| `Karabas_Profi.sv`, `rtl/host/osd_items.svh` (if the item is a switch), `files.qip`, `README.md`, `AGENTS.md`, `tools/board/mister.py`, `tools/board/zx.py` | 3 | wiring, `CONF_STR` mode + channel item, OSD row map, build |
| `docs/dev/stage5-results.md` (new), `docs/dev/stage5-shots/*.png` | 4 | board results |

---

### Task 1: `uart_route` — channel mux, serialiser, MIDI priority

**Files:** Create `rtl/host/uart_route.sv`, `sim/tb_uart_route.sv`, `sim/run_tb_uart_route.sh`.

**Interfaces (proposed; the task may refine names, not behaviour):**
```systemverilog
module uart_route #(parameter integer CLKS_PER_BIT = 0) (   // bit period in clk cycles; 0 = parameter error
    input  wire       clk,              // clk_bus domain for the wire side
    input  wire       reset,
    input  wire       channel,          // 0 ESP (wires), 1 USB (bytes): the OSD item
    input  wire [7:0] uart_mode,        // hps_io: 3 = MIDI
    // ESP wires from/to the machine
    input  wire       esp_tx,           // machine UART_TX
    input  wire       esp_cts,          // machine UART_CTS (out of the machine): ignored toward the HPS, see below
    output wire       esp_rx,           // into the machine's UART_RX, idle high
    // USB bytes from/to the machine
    input  wire [7:0] usb_tx_data, input wire usb_tx_wr,    // one-clock strobe
    output reg  [7:0] usb_rx_data, output reg [7:0] usb_rx_idx,
    // the HPS UART
    input  wire       uart_rxd,         // async
    output wire       uart_txd_serial,  // the line when not MIDI
    // MidiLink line from mt32_mix
    input  wire       midi_line,
    output wire       uart_txd          // UART_TXD
);
```
`uart_txd = (uart_mode == 3) ? midi_line : (channel ? usb_serialiser_out : esp_tx)`; `esp_rx` and `usb_rx_*` are fed from `uart_rxd` only for the selected channel (the other idles: `esp_rx = 1`, no USB bytes). CTS: the HPS UART's `UART_RTS/CTS` are tied low in the top today; the core's `UART_CTS` output is not forwarded (documented), flow control is left to software.

- [ ] **Step 1: Bench first.** Cases: `esp_passthrough` (a bit pattern on `esp_tx` appears on `uart_txd`, a pattern on `uart_rxd` reaches `esp_rx` after the synchroniser), `usb_tx_byte` (a `usb_tx_wr` strobe becomes one 8N1 frame at `CLKS_PER_BIT`), `usb_rx_byte` (a frame on `uart_rxd` becomes `usb_rx_data` and `usb_rx_idx` increments), `midi_priority` (mode 3 → `midi_line` regardless of channel), `idle_other_modes` (idle high with no activity, in each channel), `switch_mid_byte` (review focus 3), `tx_backlog` (a burst of `usb_tx_wr` strobes against a slow line: documented drop/hold rule, no deadlock), `rx_noise` (a one-clock glitch on `uart_rxd` is rejected), `skewed_clock` (`clk` period varied by ±2 %). Guards count edges, never `$time` differences.
- [ ] **Step 2: Run against a stub** (every output idle) → the bench FAILs on `esp_passthrough`/`usb_tx_byte`. **Step 3: Implement**, run → PASS. **Step 4: Mutate** (flip the mode compare, drop the synchroniser, remove the glitch filter, break the idx increment) and confirm each mutation fails a named case. **Step 5: Commit** `serial: uart_route, channel mux, USB byte serialiser and MIDI priority`.

### Task 2: `mcu_emu` — `CMD_UART` both ways

**Files:** Modify `rtl/host/mcu_emu.sv`, `sim/tb_mcu_emu.sv`.

**Interfaces:** `mcu_emu` gains `output reg [7:0] uart_tx_data, output reg uart_tx_stb` (a `CMD_UART` reply with `addr == 0`: a byte the machine sent) and `input [7:0] uart_rx_data, input uart_rx_stb` (a byte to send to the machine as `CMD_UART idx d`, with `idx` an 8-bit counter incremented per byte). Replies with `addr` 1/2 (`dll/dlm`) and 3 (the tsconf rs232 mode) are consumed and ignored. Frame constants come from `upstream/karabas-go-core-profi/modules/rtl/mcu/kg_mcu_cmds.vh` and `kg_mcu_uart.v`, never from memory.

- [ ] **Step 1: Bench cases:** `uart_tx_reply` (a `CMD_UART 00 d` reply raises `uart_tx_stb` with `d`; `last_reply` is still updated for other commands), `uart_rx_send` (a byte becomes one frame, `idx` increments, two back-to-back bytes arrive in order), `uart_rx_in_burst` (a `uart_rx_stb` during a keyboard report burst waits for the burst, never splits it), `dll_dlm_ignored`. Run → FAIL. **Step 2: Implement.** **Step 3:** the whole existing `tb_mcu_emu` stays green unchanged. **Step 4: Mutation matrix** as in stage 4c (each case must fail with the behaviour removed). **Step 5: Commit** `serial: mcu_emu carries CMD_UART both ways`.

### Task 3: Top wiring, `CONF_STR`, build

**Files:** Modify `Karabas_Profi.sv`, `rtl/host/osd_items.svh` (only if the channel item is a core switch), `files.qip`, `README.md`, `AGENTS.md`, `tools/board/mister.py` (`ROWS`), `tools/board/zx.py` (`TAPE_ROW`).

- [ ] **Step 1:** Instantiate `uart_route` between the machine's `UART_TX/RX`, `mcu_emu`'s byte ports and `UART_TXD/UART_RXD`; feed `UART_RX` of the machine from it instead of `1'b1`. The channel item is an `O[..]` bit (`Serial channel,ESP,USB`), MiSTer-side only unless Task 2's source shows the machine needs it; pick a free `status` bit and say which in the commit. Add the serial UART mode to `CONF_STR`: take the exact `UART<speed>...` token syntax from Main_MiSTer's source or an existing core's `CONF_STR`, keep `UART31250,MIDI` first so MIDI's mode number is unchanged (`mt32_mix` compares `uart_mode == 3`; **verify what number Main sends for each entry before trusting 3**, and fix `mt32_mix` and its bench if adding an entry shifts it).
- [ ] **Step 2: Gates:** unit tests, the benches of Tasks 1-2, `tb_mt32_mix`, `tools/check_upstream.sh` `OK`, `python3 -m unittest discover -s tools/tests`. **Step 3: Build** (next free N), `build: exit 0`, `check_timing: OK`, record worst setup slack, restore the `.qsf`.
- [ ] **Step 4: Re-derive the OSD row map** (a new selectable row before `Tape play/pause` shifts `TAPE_ROW` and `mister.ROWS`): count from the source and write the count; the board run re-reads it from a capture (stage 4c found `read_bar` returns `None` on the RTSP frames, so read by eye).
- [ ] **Step 5: README:** the serial section (channel item, the UART mode to pick, baud rules: ESP is the software's baud, USB is fixed, flow control not forwarded; MIDI unchanged; Linux side is `/dev/ttyS1` and the speed Main sets). **Step 6: Commit** `top: serial channels on the HPS UART`.

### Task 4: Board run (controller only, needs the owner's go)

**Files:** Create `docs/dev/stage5-results.md`, `docs/dev/stage5-shots/*.png`.

- [ ] **Step 1: Prep.** Copy the build to `/media/fat/_Computer/Karabas_Profi_<date><letter>.rbf` (never over an existing name). The Linux side needs a tty reader: a `python3`/`stty` session on `/dev/ttyS1` run over ssh (speed and mode set by the OSD, not by `uartmode`).
- [ ] **Step 2: ESP channel TX.** From a short BASIC program built by a script, write the ZXUNO UART (`OUT 64571,<reg>` / `OUT 64827,<value>`, registers from the upstream `zxunouart`) and send a known string; the `ttyS1` reader sees it byte-exact at the OSD mode's speed.
- [ ] **Step 3: ESP channel RX.** Write bytes into `ttyS1`; read them back through the UART status/data registers and print them.
- [ ] **Step 4: USB channel** both ways, the same string, after switching the OSD channel.
- [ ] **Step 5: MIDI unchanged:** `UART mode = MIDI`, no serial traffic leaks; if a MidiLink listener is not available, close this row untested and cite `tb_mt32_mix`.
- [ ] **Step 6: Switch mid-traffic and no-reader:** the machine keeps running with nobody on `ttyS1`.
- [ ] **Step 7: Results** in the stage-4c shape: how it was driven, checks table, findings, gates (tests, `run_all: 23 + new benches`, build N), every **closed untested** row with its reason. Shots referenced, no orphans. **Step 8: Restore `menu.rbf`, commit** `docs: stage 5 board results`.

---

## Verification Summary

| Gate | Command | Pass |
|---|---|---|
| Python tools | `python3 -m unittest discover -s tools/tests` | OK |
| `uart_route` bench | `tools/sim.sh sim/run_tb_uart_route.sh` | PASS, every case mutation-proven |
| `mcu_emu` bench | `tools/sim.sh sim/run_tb_mcu_emu.sh` | PASS, existing cases unchanged |
| MIDI | `tools/sim.sh sim/run_tb_mt32_mix.sh` | PASS unchanged (or updated if the mode number moved, with the reason in the commit) |
| Upstream untouched | `tools/check_upstream.sh` | OK |
| Everything | `tools/sim.sh sim/run_all.sh` (controller) | `run_all: 25 passed, 0 failed` (23 + 1 new bench; recount if a task adds one) |
| Build | `tools/build.sh` | `build: exit 0`, `check_timing: OK` |
| Board | Task 4 | rows pass or are closed untested with a reason |

## Open points the plan could not settle from the sources (the first task that touches each resolves it and writes the answer into the commit)

- The exact `CONF_STR` token for a second UART mode and the mode number Main sends for it.
- Whether the ZiFi USB path needs the `dll/dlm` speed to be honoured by anything (the plan says no; the ZiFi/EVO software may poll it).
- The USB-channel serialiser's fixed baud (115200 assumed to match the serial mode).
