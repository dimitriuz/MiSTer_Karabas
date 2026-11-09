#!/usr/bin/env python3
"""prepare_upstream.py — make the Karabas Go upstream compile with Quartus 17.

Reads the read-only submodule `upstream/karabas-go-core-profi` (+ its `modules/`
submodule) and writes a generated tree (default `build/upstream/`):

  * a directory-preserving mirror: upstream `src/rtl/**` -> `<out>/src/rtl/**`,
    `modules/rtl/**` -> `<out>/modules/rtl/**` (nothing under upstream/ is edited);
  * the compize_proto rewrite: Quartus 17 cannot analyse a VHDL instantiation of
    `entity work.<verilog module>` across the VHDL/Verilog boundary the Vivado flow
    tolerates, so every such instantiation of a Verilog module becomes a component
    instantiation, with a generated `component` declaration (scalar Verilog
    parameters become generics with literals as defaults, vector parameters are
    omitted; every `in` port gets a VHDL default). Files that already declare the
    component (e.g. `opl2_top` in `profi.vhd`) keep theirs;
  * the three init-file rewrites (icons.bit, the VG93 microcode hex, the SAA1099
    compressor LUT) so the paths resolve from the profile's Quartus project dir;
  * the profi.vhd rewrites (core profile only, PROFI_REWRITES): Task 1's
    clock-port plumbing (CLK_VID buffer port, bus_phase/reset_mem signals,
    the U1 clock mappings) and Task 4's no-wait wiring (MEM_READY out to the
    top, cpu_ts/cpu_mc signals, the T80s TS_O/MC_O and the U3 BUS_PHASE/
    RESET_MEM/CPU_TS/CPU_MC/CPU_RESET_N/MEM_READY mappings). Stage 1's
    mem_wait rewrites are gone: cpu_wait and cpu_wait_n are upstream's
    again, no wait reaches the CPU;
  * the T80s.vhd rewrites (core profile only, T80S_REWRITES): the exception
    to "never patch T80" — spec §5.2 requires the no-wait controller to see
    the T-state and M-cycle numbers, so T80s grows TS_O/MC_O output ports
    wired to its internal TState/MCycle registers (behaviour-neutral
    visibility);
  * `upstream.qip`: the file list of `src/karabas_go.prj` in prj order, as
    `set_global_assignment` lines whose paths are relative to the profile's Quartus
    project dir; `uart.v` goes to library `zxuno` (its Verilog `uart_tx`/`uart_rx`
    clash with the VHDL units of the same name in `work`), everything else to `work`;
  * `STAMP`: the two upstream commit hashes.

Profiles:
  core (default) — for the Karabas_Profi project at the repo root; the MiSTer top
      replaces the upstream clock, memory and sdram units (excluded here), and the
      HDMI/PCM5102/karabas_go_top units. Prefix: `build/upstream`.
  elab — for the `tools/elab_upstream.sh` gate in `build/elab/`: only the upstream
      clock and the top-level/HDMI units are replaced (by the gate's clock stub);
      memory/sdram stay. Prefix: `upstream`.

Rules are those of docs/superpowers/plans/stage1-assets/compize_proto.py, the
spike that made `quartus_map --analysis_and_elaboration` of `profi` pass in
raetro/quartus:17.0. A Verilog port the parser cannot read is an error naming the
module and the port text — never a silent skip.
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / "upstream" / "karabas-go-core-profi"
PRJ = "src/karabas_go.prj"

PROFILES = {
    # canonical out (relative to repo root) and the path prefix of the generated
    # qip/init strings, relative to that profile's Quartus project directory.
    "core": {"out": "build/upstream", "prefix": "build/upstream"},
    "elab": {"out": "build/elab/upstream", "prefix": "upstream"},
}

# Excluded from every profile (MiSTer/the gate replaces these units):
EXCLUDED = {
    "src/rtl/clock/clock.vhd",
    "modules/rtl/clk/kg_pll.v",
    "src/rtl/karabas_go_top.vhd",
    "src/rtl/hdmi/hdmi_frame.v",
    "modules/rtl/audio/kg_pcm5102.v",
}
# Excluded only by the core profile (rtl/replaced/ provides them):
CORE_EXTRA = {"src/rtl/memory/memory.vhd", "src/rtl/memory/sdram.vhd"}

# uart.v's Verilog uart_tx/uart_rx clash with the VHDL units in work: library zxuno.
ZXUNO_FILES = {"src/rtl/uart/uart.v"}

INIT_REWRITES = [  # (out-relative file, exact old string, new init path suffix)
    ("src/rtl/osd/icons.vhd", '"rtl/osd/icons.bit"', "src/rtl/osd/icons.bit"),
    ("src/rtl/vg93/vg93_urom.v", '`define VG93_ROM_FILE "vg93-microcode-rom.hex"',
     "src/rtl/vg93/vg93-microcode-rom.hex"),
    ("src/rtl/sound/saa1099.v", '"saa1099_compressor_lut.hex"',
     "src/rtl/sound/saa1099_compressor_lut.hex"),
]
# The upstream selector process (verbatim, so a profi.vhd that changed here
# fails the anchor): generated with _DI_SELECTOR_OLD.replace below.
_DI_SELECTOR_OLD = (
    'process (selector, cpu_a_bus, gx0, serial_ms_do_bus, ram_do_bus, mc146818_do_bus, kb_do_bus, zc_do_bus, ts_do_bus, port_7ffd_reg, port_dffd_reg,' + "\n"
    '\t\t\tvid_attr, port_eff7_reg, joy_bus, ms_z, ms_b, ms_x, ms_y, port_xxC7_reg, port_008b_reg,' + "\n"
    '\t\t\tport_018b_reg, port_028b_reg, gs_do_bus, ide_do_bus, fdd_do_bus, TAPE_IN, ' + "\n"
    '\t\t\tzifi_do_bus, zxuno_uart_do_bus, zxuno_addr_to_cpu, opl3_port_cs, opl3_do_bus)' + "\n"
    'begin' + "\n"
    '\tcase selector is' + "\n"
    '\t\twhen x"00" => cpu_di_bus <= ram_do_bus;' + "\n"
    '\t\twhen x"01" => cpu_di_bus <= mc146818_do_bus;' + "\n"
    '\t\twhen x"02" => cpu_di_bus <= GX0 & not(TAPE_IN) & kb_do_bus;' + "\n"
    '\t\twhen x"03" => cpu_di_bus <= zc_do_bus;' + "\n"
    '\t\twhen x"04" => cpu_di_bus <= "11111100";\t' + "\n"
    '\t\twhen x"05" => cpu_di_bus <= joy_bus;' + "\n"
    '\t\twhen x"06" => cpu_di_bus <= ts_do_bus;' + "\n"
    '\t\twhen x"08" => cpu_di_bus <= port_dffd_reg;' + "\n"
    '\t\twhen x"09" => cpu_di_bus <= port_7ffd_reg;' + "\n"
    '\t\twhen x"0A" => cpu_di_bus <= ms_z(3 downto 0) & \'1\' & not(ms_b(2)) & not(ms_b(0)) & not(ms_b(1)); -- D0=right, D1 = left, D2 = middle, D3 = fourth, D4..D7 - wheel' + "\n"
    '\t\twhen x"0B" => cpu_di_bus <= ms_x;' + "\n"
    '\t\twhen x"0C" => cpu_di_bus <= ms_y;' + "\n"
    '\t\twhen x"0D" => cpu_di_bus <= x"FF"; -- zxuno uart 2 stub' + "\n"
    '\t\twhen x"0E" => cpu_di_bus <= serial_ms_do_bus;' + "\n"
    '\t\twhen x"0F" => cpu_di_bus <= zxuno_addr_to_cpu;' + "\n"
    '\t\twhen x"10" => cpu_di_bus <= zxuno_uart_do_bus;' + "\n"
    '\t\twhen x"11" => cpu_di_bus <= "0000" & port_xxC7_reg(3) & port_xxC7_reg(2) & \'1\' & \'0\';' + "\n"
    '\t\twhen x"12" => cpu_di_bus <= x"FF"; -- flash do bus stub' + "\n"
    '\t\twhen x"13" => cpu_di_bus <= port_008b_reg;' + "\n"
    '\t\twhen x"14" => cpu_di_bus <= port_018b_reg;' + "\n"
    '\t\twhen x"15" => cpu_di_bus <= port_028b_reg;' + "\n"
    '\t\twhen x"16" => cpu_di_bus <= zifi_do_bus;' + "\n"
    '\t\twhen x"17" => cpu_di_bus <= vid_attr;' + "\n"
    '\t\twhen x"18" => cpu_di_bus <= fdd_do_bus;' + "\n"
    '\t\twhen x"19" => cpu_di_bus <= ide_do_bus;' + "\n"
    '\t\twhen x"1A" => cpu_di_bus <= gs_do_bus;' + "\n"
    '\t\twhen x"1B" => cpu_di_bus <= opl3_do_bus;' + "\n"
    "\t\twhen others => cpu_di_bus <= (others => '1');" + "\n"
    '\tend case;' + "\n"
    'end process;' + "\n"
)


# profi.vhd rewrites (core profile only). Stage 1's SDRAM-wait rewrites
# (mem_wait declared, mapped, fed to WAIT_CPU and cpu_wait_n) are gone with
# the no-wait controller: cpu_wait and cpu_wait_n are upstream's again.
# Stage 2 Task 4 adds the no-wait wiring: MEM_READY out to the top (from the
# replaced memory.vhd), cpu_ts/cpu_mc signals mapped on the T80s instance
# (its TS_O/MC_O ports, see T80S_REWRITES) and the U3 memory mappings of
# BUS_PHASE/RESET_MEM (Task 1's clock signals), CPU_TS/CPU_MC/CPU_RESET_N/
# MEM_READY. The elab profile keeps upstream's memory.vhd and T80s, so its
# profi.vhd stays untouched.
# Task 4 (stage 4b): the block the rewrites below remove, copied from
# upstream profi.vhd verbatim (tabs included) so prepare_upstream's
# byte-exact matching finds it.
_SDC_SIGNALS_OLD = (
    "-- SDC sector interface\n"
    "signal sdc_img_mounted    : std_logic_vector(7 downto 0);\n"
    "signal sdc_img_size       : std_logic_vector(63 downto 0);\n"
    "signal sdc_rd             : std_logic_vector(7 downto 0);\n"
    "signal sdc_wr             : std_logic_vector(7 downto 0);\n"
    "signal sdc_sector         : std_logic_vector(31 downto 0);\n"
    "signal sdc_busy           : std_logic;\n"
    "signal sdc_done           : std_logic;\n"
    "signal sdc_error          : std_logic;\n"
    "signal sdc_slot           : std_logic_vector(2 downto 0);\n"
    "signal sdc_byte_in_strobe : std_logic;\n"
    "signal sdc_byte_addr      : std_logic_vector(8 downto 0);\n"
    "signal sdc_byte_in_data   : std_logic_vector(7 downto 0);\n"
    "signal sdc_byte_out_data  : std_logic_vector(7 downto 0);\n"
    "signal sdc_active         : std_logic;\n"
)

_IMG_SDC_OLD = (
    "-- File mounter sector interface (karabas-go-modules img_sdc)\n"
    "u_img_sdc: entity work.img_sdc\n"
    "generic map(\n"
    "\tOUT_LATENCY => 3,\n"
    "\tTIMEOUT     => 5600000,\n"
    "\tRETRIES     => 3\n"
    ")\n"
    "port map (\n"
    "\tclk                => clk_bus,\n"
    "\treset              => areset,\n"
    "\n"
    "\timg_mounted        => mcu_img_mounted,\n"
    "\timg_size           => mcu_img_size,\n"
    "\timg_data_wr        => mcu_img_data_wr,\n"
    "\timg_data_addr      => mcu_img_data_addr,\n"
    "\timg_data           => mcu_img_data,\n"
    "\timg_result_wr      => mcu_img_result_wr,\n"
    "\timg_result         => mcu_img_result,\n"
    "\timg_sum            => mcu_img_sum,\n"
    "\timg_q_wr           => mcu_img_q_wr,\n"
    "\timg_q_di           => mcu_img_q_di,\n"
    "\timg_q_ack          => mcu_img_q_ack,\n"
    "\n"
    "\tsdc_img_mounted    => sdc_img_mounted,\n"
    "\tsdc_img_size       => sdc_img_size,\n"
    "\tsdc_rd             => sdc_rd,\n"
    "\tsdc_wr             => sdc_wr,\n"
    "\tsdc_sector         => sdc_sector,\n"
    "\tsdc_busy           => sdc_busy,\n"
    "\tsdc_done           => sdc_done,\n"
    "\tsdc_error          => sdc_error,\n"
    "\tsdc_slot           => sdc_slot,\n"
    "\tsdc_byte_in_strobe => sdc_byte_in_strobe,\n"
    "\tsdc_byte_addr      => sdc_byte_addr,\n"
    "\tsdc_byte_in_data   => sdc_byte_in_data,\n"
    "\tsdc_byte_out_data  => sdc_byte_out_data,\n"
    "\n"
    "\tactive             => sdc_active\n"
    ");\n"
)

PROFI_REWRITES = [  # (out-relative file, exact old string, exact new string)
    # Task 1 (stage 2): clock.vhd grows CLK_VID (fixed 112.5 MHz), BUS_PHASE
    # and RESET_MEM; profi carries the video clock as a buffer port and the
    # other two as signals (Task 4 maps them on to U3 = memory).
    # (the dead clk_vid signal upstream would clash with the new port name)
    ("src/rtl/profi.vhd",
     "signal clk_vid \t\t\t: std_logic;",
     "-- signal clk_vid \t\t: std_logic; -- MiSTer Stage 2: profi gained the CLK_VID port"),
    ("src/rtl/profi.vhd",
     "\tCLK_SDR : buffer std_logic;",
     "\tCLK_SDR : buffer std_logic;\n\tCLK_VID : buffer std_logic;"),
    ("src/rtl/profi.vhd",
     "signal cpu_wait_n \t\t: std_logic := '1';",
     "signal cpu_wait_n \t\t: std_logic := '1';\n"
     "signal bus_phase : std_logic_vector(1 downto 0);\n"
     "signal reset_mem : std_logic;"),
    ("src/rtl/profi.vhd",
     "\tCLK_SDR  \t\t=> clk_sdr, -- 84",
     "\tCLK_SDR  \t\t=> clk_sdr, -- 84\n"
     "\tCLK_VID  \t\t=> CLK_VID,\n"
     "\tBUS_PHASE \t\t=> bus_phase,\n"
     "\tRESET_MEM \t\t=> reset_mem,"),
    # Task 4 (stage 2): the no-wait controller's wiring. MEM_READY out, the
    # binary T-state/M-cycle numbers of the T80s (Task 3's controller needs
    # them; the G_T80pa generate is left alone — the core selects USE_T80s=1),
    # and U3's new ports.
    ("src/rtl/profi.vhd",
     "\tCLK_12: buffer std_logic;",
     "\tCLK_12: buffer std_logic;\n\tMEM_READY : out std_logic;"),
    ("src/rtl/profi.vhd",
     "signal cpu_wait \t\t\t: std_logic;",
     "signal cpu_wait \t\t\t: std_logic;\n"
     "signal cpu_ts : std_logic_vector(2 downto 0);\n"
     "signal cpu_mc : std_logic_vector(2 downto 0);"),
    # (the DO line below occurs in both CPU generates; the two-line context
    # with `-- memory manager` selects the G_T80s one)
    ("src/rtl/profi.vhd",
     "\tDO\t\t\t\t\t=> cpu_do_bus\n);\nend generate;\n\n\n-- memory manager",
     "\tDO\t\t\t\t\t=> cpu_do_bus,\n\tTS_O\t\t\t\t=> cpu_ts,\n"
     "\tMC_O\t\t\t\t=> cpu_mc\n);\nend generate;\n\n\n-- memory manager"),
    ("src/rtl/profi.vhd",
     "\tGS_WAIT_N \t\t=> gs_wait_n,",
     "\tGS_WAIT_N \t\t=> gs_wait_n,\n"
     "\tBUS_PHASE \t\t=> bus_phase,\n"
     "\tRESET_MEM \t\t=> reset_mem,\n"
     "\tCPU_TS \t\t\t=> cpu_ts,\n"
     "\tCPU_MC \t\t\t=> cpu_mc,\n"
     "\tCPU_RESET_N \t\t=> cpu_reset_n,\n"
     "\tMEM_READY \t\t=> MEM_READY,"),
    # Task 4 fix (build 20: the capture -> DI path lost clk_bus28 setup by
    # -1.087 through the selector tree). The process drives a renamed
    # cpu_di_mux; cpu_di_bus keeps the upstream value, because selector =
    # x"00" exactly when ram_oe_n = '0' (first, highest-priority branch of
    # selector <=). For the same reason the x"00" branch of the renamed
    # case must not read ram_do_bus (build 21: with the tree still on that
    # path, synthesis built capture -> tree -> bypass mux -> DI and closed
    # -1.907): it drives '1' instead and ram_do_bus leaves the sensitivity
    # list, so the only ram_do_bus consumer left is the final mux and
    # memory data reaches the T80 through one LUT - the one-clk_mem path
    # from the SDRAM capture register to the DI latch at turbo 8x. The
    # x"00" value of cpu_di_mux is never used (the final mux takes
    # ram_do_bus whenever selector could be x"00").
    ("src/rtl/profi.vhd",
     "signal cpu_di_bus\t\t\t: std_logic_vector(7 downto 0);",
     "signal cpu_di_bus\t\t\t: std_logic_vector(7 downto 0);\n"
     "signal cpu_di_mux\t\t\t: std_logic_vector(7 downto 0);"),
    ("src/rtl/profi.vhd", _DI_SELECTOR_OLD,
     _DI_SELECTOR_OLD.replace("cpu_di_bus", "cpu_di_mux")
     .replace("serial_ms_do_bus, ram_do_bus,", "serial_ms_do_bus,")
     .replace('when x"00" => cpu_di_mux <= ram_do_bus;',
              "when x\"00\" => cpu_di_mux <= (others => '1');")),
    ("src/rtl/profi.vhd",
     "\tend case;\nend process;\n\nselector <= ",
     "\tend case;\nend process;\n\n"
     "-- MiSTer Stage 2: memory reads bypass the selector tree (one LUT\n"
     "-- between the SDRAM capture and the T80 DI latch, the path with a\n"
     "-- one clk_mem budget at turbo 8x); x\"00\" == ram_oe_n = '0', and\n"
     "-- that branch of the case above drives '1' so the memory data\n"
     "-- cannot enter the tree.\n"
     "cpu_di_bus <= ram_do_bus when ram_oe_n = '0' else cpu_di_mux;\n\n"
     "selector <= "),
    # Task 6 (stage 2): register 15 is the MiSTer Mode item (Pentagon /
    # 48k). Upstream's Karabas Go layout has no OSD item for it and hard-wires
    # kb_screen_mode to "00" (pentagon_video: "00" is Pentagon, "01" the
    # classic 312-line frame with contention), so the core profile grows
    # softsw_regs to 16 registers, gives kg_soft_switches N = 16 and feeds
    # kb_screen_mode from register 15. The Mini layout keeps its register 6.
    ("src/rtl/profi.vhd",
     "signal softsw_regs\t\t: std_logic_vector(15*8-1 downto 0);",
     "signal softsw_regs\t\t: std_logic_vector(16*8-1 downto 0);"),
    ("src/rtl/profi.vhd",
     "\tN \t\t\t\t\t=> 15\n)\nport map (",
     "\tN \t\t\t\t\t=> 16\n)\nport map ("),
    ("src/rtl/profi.vhd",
     "\tkb_screen_mode <= \"00\";",
     "\tkb_screen_mode <= softsw_regs(15*8+1 downto 15*8);"),
    # Task 3 (stage 3): the GS memory is rtl/mem/gs_mem.sv at the MiSTer top
    # (64 KB BRAM + the rest of the 2 MB in the DDR3 behind DDRAM_*), not a
    # second SDRAM controller inside profi. profi therefore exposes the GS bus
    # (memory.vhd's GSM_* mirrors of GS_* and the wait/read data back), the
    # loader's GS bytes (GSL_*: memory.vhd's loader_b registers, to gs_mem's
    # toggle handshake) and clk_gs for gs_mem and the DDRAM_CLK.
    ("src/rtl/profi.vhd",
     "\tMEM_READY : out std_logic;",
     "\tMEM_READY : out std_logic;\n"
     "\tCLK_GS_O : out std_logic;\n"
     "\tGSM_A : out std_logic_vector(20 downto 0);\n"
     "\tGSM_DI : out std_logic_vector(7 downto 0);\n"
     "\tGSM_RD : out std_logic;\n"
     "\tGSM_WR : out std_logic;\n"
     "\tGSM_DO : in std_logic_vector(7 downto 0) := x\"FF\";\n"
     "\tGSM_WAIT_N : in std_logic := '1';\n"
     "\tGSL_A : out std_logic_vector(20 downto 0);\n"
     "\tGSL_D : out std_logic_vector(7 downto 0);\n"
     "\tGSL_TGL : out std_logic;"),
    ("src/rtl/profi.vhd",
     "\tMEM_READY \t\t=> MEM_READY,",
     "\tMEM_READY \t\t=> MEM_READY,\n"
     "\tGSM_A \t\t\t=> GSM_A,\n"
     "\tGSM_DI \t\t\t=> GSM_DI,\n"
     "\tGSM_RD \t\t\t=> GSM_RD,\n"
     "\tGSM_WR \t\t\t=> GSM_WR,\n"
     "\tGSM_DO \t\t\t=> GSM_DO,\n"
     "\tGSM_WAIT_N \t\t=> GSM_WAIT_N,\n"
     "\tGSL_A \t\t\t=> GSL_A,\n"
     "\tGSL_D \t\t\t=> GSL_D,\n"
     "\tGSL_TGL \t\t=> GSL_TGL,"),
    ("src/rtl/profi.vhd",
     "MIDI_RESET_N <= not reset;",
     "MIDI_RESET_N <= not reset;\n"
     "CLK_GS_O <= clk_gs;"),
    # Task 3 (stage 4a): the tape player's clock enable is the CPU's own
    # enable (one pulse per T-state at every turbo, clock.vhd's ENA_CPU), so
    # profi exposes it. The ZX core clocks its tape player the same way.
    ("src/rtl/profi.vhd",
     "\tGSL_TGL : out std_logic;",
     "\tGSL_TGL : out std_logic;\n\tENA_CPU_O : out std_logic;"),
    ("src/rtl/profi.vhd",
     "MIDI_RESET_N <= not reset;\nCLK_GS_O <= clk_gs;",
     "MIDI_RESET_N <= not reset;\nCLK_GS_O <= clk_gs;\n"
     "ENA_CPU_O <= ena_cpu;"),
    # Task 4 (stage 4b): the file mounter's sector engine (img_sdc) leaves
    # profi. On the Karabas Go the MCU's file mounter served the SD card's
    # block requests and hdf_ata from inside the FPGA; on MiSTer hps_io is
    # the mounter, and the sector engine is the top's rtl/disk/img_src.sv
    # (slots 2/3 of hps_io = the two IDE images). profi keeps only what the
    # machine drives: it raises sdc_rd/sdc_wr/sdc_sector on SDC_* ports (the
    # Z-Controller talks to the real SD card on sd_card, not through this),
    # and the completion (busy/done/error) and the 512 strobe bytes come
    # back in. The SD card's own block interface (slot 1) is the top's
    # sys/sd_card.sv entirely.
    ("src/rtl/profi.vhd",
     "\tSD_DET_N : in  STD_LOGIC;",
     "\tSD_DET_N : in  STD_LOGIC;\n"
     "\n"
     "\t-- MiSTer stage 4b: the file mounter's sector engine (img_sdc) is on the\n"
     "\t-- MiSTer side; these are its ports (img_sdc's interface, indices 4 and 5).\n"
     "\tSDC_IMG_MOUNTED : in  STD_LOGIC_VECTOR(7 downto 0);\n"
     "\tSDC_IMG_SIZE    : in  STD_LOGIC_VECTOR(63 downto 0);\n"
     "\tSDC_RD          : out STD_LOGIC_VECTOR(7 downto 0);\n"
     "\tSDC_WR          : out STD_LOGIC_VECTOR(7 downto 0);\n"
     "\tSDC_SECTOR      : out STD_LOGIC_VECTOR(31 downto 0);\n"
     "\tSDC_BYTE_OUT_DATA : out STD_LOGIC_VECTOR(7 downto 0);\n"
     "\tSDC_BUSY        : in  STD_LOGIC;\n"
     "\tSDC_DONE        : in  STD_LOGIC;\n"
     "\tSDC_ERROR       : in  STD_LOGIC;\n"
     "\tSDC_SLOT        : in  STD_LOGIC_VECTOR(2 downto 0);\n"
     "\tSDC_BYTE_IN_STROBE : in  STD_LOGIC;\n"
     "\tSDC_BYTE_ADDR   : in  STD_LOGIC_VECTOR(8 downto 0);\n"
     "\tSDC_BYTE_IN_DATA : in  STD_LOGIC_VECTOR(7 downto 0);"),
    ("src/rtl/profi.vhd", _SDC_SIGNALS_OLD,
     "-- MiSTer stage 4b: sdc_* are profi's SDC_* ports now (img_sdc is the\n"
     "-- top's img_src).\n"),
    ("src/rtl/profi.vhd", _IMG_SDC_OLD,
     "\n-- MiSTer stage 4b: the sector engine is the top's img_src (the SDC_*\n"
     "-- ports); the MCU file mounter's img_* channel is unused on MiSTer.\n"),
    ("src/rtl/profi.vhd",
     "hdf_own <= '1' when sdc_slot(2 downto 1) = \"10\" else '0';\n"
     'sdc_rd <= "00" & hdf_rd & "0000";\n'
     'sdc_wr <= "00" & hdf_wr & "0000";\n'
     "sdc_sector <= hdf_sector;\n"
     "sdc_byte_out_data <= hdf_out_data;",
     "hdf_own <= '1' when SDC_SLOT(2 downto 1) = \"10\" else '0';\n"
     'SDC_RD <= "00" & hdf_rd & "0000";\n'
     'SDC_WR <= "00" & hdf_wr & "0000";\n'
     "SDC_SECTOR <= hdf_sector;\n"
     "SDC_BYTE_OUT_DATA <= hdf_out_data;"),
    ("src/rtl/profi.vhd",
     "hdf_sdc_busy <= sdc_busy and hdf_own;\n"
     "hdf_sdc_done <= sdc_done and hdf_own;\n"
     "hdf_sdc_byte_in_strobe <= sdc_byte_in_strobe and hdf_own;",
     "hdf_sdc_busy <= SDC_BUSY and hdf_own;\n"
     "hdf_sdc_done <= SDC_DONE and hdf_own;\n"
     "hdf_sdc_byte_in_strobe <= SDC_BYTE_IN_STROBE and hdf_own;"),
    ("src/rtl/profi.vhd",
     "\timg_mounted        => sdc_img_mounted(5 downto 4),\n"
     "\timg_size           => sdc_img_size,",
     "\timg_mounted        => SDC_IMG_MOUNTED(5 downto 4),\n"
     "\timg_size           => SDC_IMG_SIZE,"),
    ("src/rtl/profi.vhd",
     "\tsdc_error          => sdc_error,\n"
     "\tsdc_byte_in_strobe => hdf_sdc_byte_in_strobe,\n"
     "\tsdc_byte_addr      => sdc_byte_addr,\n"
     "\tsdc_byte_in_data   => sdc_byte_in_data,",
     "\tsdc_error          => SDC_ERROR,\n"
     "\tsdc_byte_in_strobe => hdf_sdc_byte_in_strobe,\n"
     "\tsdc_byte_addr      => SDC_BYTE_ADDR,\n"
     "\tsdc_byte_in_data   => SDC_BYTE_IN_DATA,"),
    # img_sdc drove kg_mcu's queue inputs IMG_Q_WR/IMG_Q_DI and its ack
    # output had no other consumer; with the engine gone they were the only
    # never-assigned signals left in profi.vhd (Quartus Warning (10541), which
    # tools/check_timing.py fails the build on: an undriven signal may let
    # the fitter prune the logic behind it). The three signals go, and the
    # port map ties the queue inputs to zero and leaves the ack open.
    ("src/rtl/profi.vhd",
     "signal mcu_img_q_wr       : std_logic;\n"
     "signal mcu_img_q_di       : std_logic_vector(23 downto 0);\n"
     "signal mcu_img_q_ack      : std_logic;\n",
     "-- MiSTer stage 4b: the mounter's queue channel (img_sdc) has no engine\n"
     "-- on the MiSTer side; kg_mcu's IMG_Q_* ports are tied below.\n"),
    ("src/rtl/profi.vhd",
     "\tIMG_Q_WR \t\t=> mcu_img_q_wr,\n"
     "\tIMG_Q_DI \t\t=> mcu_img_q_di,\n"
     "\tIMG_Q_ACK \t\t=> mcu_img_q_ack,\n",
     "\tIMG_Q_WR \t\t=> '0',\n"
     "\tIMG_Q_DI \t\t=> (others => '0'),\n"
     "\tIMG_Q_ACK \t\t=> open,\n"),
    # The SD card is hps_io's disk slot 1 (sys/sd_card.sv), not a file
    # mounter slot, so the CF LED no longer lights for it.
    ("src/rtl/profi.vhd",
     "STATUS_CF \t\t=> hdd_active or sdc_active or hdf_led,",
     "STATUS_CF \t\t=> hdd_active or hdf_led,"),
]

# T80s.vhd rewrites (core profile only). The exception to "never patch T80":
# spec §5.2 requires the no-wait controller to see the T-state and M-cycle
# numbers, so T80s grows two output ports wired to its internal TState/MCycle
# registers. Behaviour-neutral visibility: no existing signal changes.
T80S_REWRITES = [  # (out-relative file, exact old string, exact new string)
    ("src/rtl/t80se/T80s.vhd",
     "\t\tDO      : out std_logic_vector(7 downto 0)\n\t);",
     "\t\tDO      : out std_logic_vector(7 downto 0);\n"
     "\t\tTS_O    : out std_logic_vector(2 downto 0);\n"
     "\t\tMC_O    : out std_logic_vector(2 downto 0)\n\t);"),
    ("src/rtl/t80se/T80s.vhd",
     "\tsignal TState\t\t: std_logic_vector(2 downto 0);\n\nbegin\n",
     "\tsignal TState\t\t: std_logic_vector(2 downto 0);\n\nbegin\n\n"
     "\tTS_O <= TState;\n\tMC_O <= MCycle;\n"),
]


def apply_rewrites(text, rewrites):
    """(file, old, new) rewrites over the text; every old string must occur
    exactly once; anything else is an error naming the file and the string."""
    for rel, old, new in rewrites:
        n = text.count(old)
        if n != 1:
            raise SystemExit(f"{rel}: expected exactly one {old!r}, found {n}")
        text = text.replace(old, new)
    return text


def apply_profi_rewrites(text):
    """PROFI_REWRITES over the text of src/rtl/profi.vhd."""
    return apply_rewrites(text, PROFI_REWRITES)


def apply_t80s_rewrites(text):
    """T80S_REWRITES over the text of src/rtl/t80se/T80s.vhd."""
    return apply_rewrites(text, T80S_REWRITES)


class PortParseError(ValueError):
    """A module-header fragment (port or parameter) the parser cannot read."""


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def default_clause(value, is_vector):
    """VHDL default for a Verilog input default literal (compize_proto rules)."""
    value = value.strip()
    mm = re.fullmatch(r"(\d*)'([bdh])([0-9a-fA-F_]+)", value)
    num = None
    if mm:
        num = int(mm.group(3).replace("_", ""), {"b": 2, "d": 10, "h": 16}[mm.group(2)])
    zero = value == "0" or num == 0 or re.fullmatch(r"\{\w+\{1'b0\}\}", value)
    ones = bool(mm and ((mm.group(2) == "b" and set(mm.group(3)) == {"1"})
                        or (mm.group(2) == "h" and set(mm.group(3).lower()) == {"f"}))) \
        or re.fullmatch(r"\{\w+\{1'b1\}\}", value)
    if zero:
        return " := (others => '0')" if is_vector else " := '0'"
    if ones:
        return " := (others => '1')" if is_vector else " := '1'"
    raise ValueError(f"cannot map default {value!r}")


PORT_RE = re.compile(
    r"\s*(input|output|inout)\s+(wire|reg)?\s*(signed)?\s*(\[[^\]]*\])?\s*(\w+)\s*(=\s*(.*))?$",
    re.S)
PARAM_RE = re.compile(r"\s*parameter\s+(\[[^\]]*\]\s*)?(\w+)\s*=\s*(.*)", re.S)


def split_args(text):
    """Split on top-level commas; skip over (), [], {} and "..." runs.

    A Verilog sized-literal apostrophe (5'd16) is NOT a string delimiter; only
    double quotes are, exactly as in the compize_proto spike's comma split.
    """
    out, depth, cur, q = [], 0, "", None
    for ch in text:
        if q:
            cur += ch
            if ch == '"':
                q = None
        elif ch == '"':
            q = ch
            cur += ch
        elif ch in "([{":
            depth += 1
            cur += ch
        elif ch in ")]}":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def parse_ports(ports_text, module_name):
    """[(vhdl_dir, range|None, name, default_literal|None)]; PortParseError else."""
    ports = []
    for p in split_args(ports_text):
        m = PORT_RE.match(p.strip())
        if not m:
            raise PortParseError(
                f"cannot parse port {p.strip()!r} of module {module_name}")
        dr = {"input": "in", "output": "out", "inout": "inout"}[m.group(1)]
        rng = None
        if m.group(4):
            a, b = m.group(4).strip()[1:-1].split(":")
            rng = f"({a.strip()} downto {b.strip()})"
        ports.append((dr, rng, m.group(5), m.group(7)))
    return ports


def generic_clauses(params_text, module_name):
    """Generics from Verilog parameter declarations: integer/string, vectors skipped.

    A parameter-list fragment that is not a `parameter` declaration raises
    naming the module and the fragment, so `#(parameter A=1, B=2)` fails loudly
    instead of silently dropping the generic B.
    """
    gens = []
    for p in split_args(params_text or ""):
        frag = p.strip()
        m = PARAM_RE.match(frag)
        if not m:
            raise PortParseError(
                f"cannot parse parameter fragment {frag!r} of module {module_name}")
        if m.group(1):  # vector-typed parameter: no VHDL generic
            continue
        v = m.group(3).strip()
        name = m.group(2)
        if v.startswith('"'):
            gens.append(f"{name} : string := {v}")
        elif re.fullmatch(r"-?\d+", v):
            gens.append(f"{name} : integer := {v}")
        elif re.fullmatch(r"\d*'[bdh][0-9a-fA-F_]+", v):
            b, x = v.split("'")[1][0], v.split("'")[1][1:].replace("_", "")
            gens.append(f"{name} : integer := {int(x, {'b': 2, 'd': 10, 'h': 16}[b])}")
        else:
            gens.append(f"{name} : integer")
    return gens


def component_declaration(name, params_text, ports_text):
    """The VHDL component block for a Verilog module."""
    ports = parse_ports(ports_text, name)
    pl = []
    for dr, rng, pname, dv in ports:
        clause = (f"{pname} : {dr} std_logic_vector{rng}" if rng
                  else f"{pname} : {dr} std_logic")
        if dr == "in":
            clause += default_clause(dv, bool(rng)) if dv is not None \
                else (" := (others => '0')" if rng else " := '0'")
        pl.append(clause)
    gens = generic_clauses(params_text, name)
    g = ("  generic (\n    " + ";\n    ".join(gens) + "\n  );\n") if gens else ""
    return f"component {name}\n{g}  port (\n    " + ";\n    ".join(pl) + "\n  );\nend component;\n"


def scan_prj():
    """[('vhdl'|'verilog', out_rel)] in prj order."""
    entries = []
    for line in (UPSTREAM / PRJ).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r'^(vhdl|verilog) work "?([^"]+)"?$', line)
        if not m:
            raise SystemExit(f"{PRJ}: unparsable line {line!r}")
        kind, p = m.group(1), m.group(2)
        if p.startswith("../modules/"):
            rel = "modules/" + p[len("../modules/"):]
        else:
            rel = "src/" + p.lstrip("./")
        entries.append((kind, rel))
    return entries


def git_head(path):
    return subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"],
                          capture_output=True, text=True,
                          check=True).stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--profile", choices=sorted(PROFILES), default="core")
    ap.add_argument("--out", default=None,
                    help="output dir (default: the profile's canonical location)")
    args = ap.parse_args()
    prof = PROFILES[args.profile]
    prefix = prof["prefix"]
    out = Path(args.out) if args.out else (ROOT / prof["out"])

    excluded = set(EXCLUDED) | (set(CORE_EXTRA) if args.profile == "core" else set())
    entries = scan_prj()
    kept = [(k, rel) for k, rel in entries if rel not in excluded]

    # ---- mirror copy ----------------------------------------------------------
    # Never overwrite a directory that is not ours: absent, empty, or a previous
    # run's output (a STAMP file is present) are the only accepted states.
    if out.exists() and any(out.iterdir()) and not (out / "STAMP").is_file():
        raise SystemExit(
            f"{out}: refusing to replace a non-empty directory that has no STAMP "
            "file (not a prepare_upstream output); pass a fresh --out")
    if out.exists():
        shutil.rmtree(out)
    for src_rel in ("src/rtl", "modules/rtl"):
        shutil.copytree(UPSTREAM / src_rel, out / src_rel)

    # ---- init-file path rewrites (relative to the profile's project dir) ------
    for rel, old, suffix in INIT_REWRITES:
        p = out / rel
        s = p.read_text(errors="replace")
        path = f'"{prefix}/{suffix}"'
        new = f'`define VG93_ROM_FILE {path}' if old.startswith("`define") else path
        if s.count(old) != 1:
            raise SystemExit(f"{rel}: expected exactly one {old!r}, found {s.count(old)}")
        p.write_text(s.replace(old, new))

    # ---- the profi.vhd and T80s.vhd rewrites (core profile only) -------------
    if args.profile == "core":
        p = out / "src/rtl/profi.vhd"
        p.write_text(apply_profi_rewrites(p.read_text(errors="replace")))
        p = out / "src/rtl/t80se/T80s.vhd"
        p.write_text(apply_t80s_rewrites(p.read_text(errors="replace")))

    # ---- the compize_proto rewrite over the compiled (qip-kept) VHDL ----------
    vmods, vhd_ents = {}, set()
    for kind, rel in kept:
        s = strip_comments((out / rel).read_text(errors="replace"))
        if rel.endswith(".v"):
            for m in re.finditer(r'\bmodule\s+(\w+)\s*(#\s*\((.*?)\)\s*)?\((.*?)\)\s*;',
                                 s, re.S):
                vmods[m.group(1).lower()] = (m.group(1), m.group(3) or "", m.group(4))
        elif rel.endswith(".vhd"):
            for m in re.finditer(r'^\s*entity\s+(\w+)\s+is', s, re.I | re.M):
                vhd_ents.add(m.group(1).lower())
    rewritten = 0
    for kind, rel in kept:
        if not rel.endswith(".vhd"):
            continue
        p = out / rel
        s = p.read_text(errors="replace")
        used = [m.group(1) for m in re.finditer(r'entity\s+work\.(\w+)', s, re.I)
                if m.group(1).lower() in vmods and m.group(1).lower() not in vhd_ents]
        if not used:
            continue
        names = sorted(set(u.lower() for u in used))
        declared = {m.group(1).lower()
                    for m in re.finditer(r'^\s*component\s+(\w+)', s, re.I | re.M)}
        for u in names:
            s = re.sub(r'entity\s+work\.' + u + r'\b', vmods[u][0], s, flags=re.I)
        try:
            decl = "".join(component_declaration(vmods[u][0], vmods[u][1], vmods[u][2])
                           for u in names if u not in declared)
        except ValueError as e:
            raise SystemExit(f"{rel}: {e}")
        s, c = re.subn(r'(architecture\s+\w+\s+of\s+\w+\s+is\s*\n)',
                       lambda m: m.group(1) + decl, s, count=1, flags=re.I)
        assert c == 1, f"{rel}: no single 'architecture X of Y is' line"
        p.write_text(s)
        rewritten += 1

    # ---- upstream.qip ---------------------------------------------------------
    lines = ["# generated by tools/prepare_upstream.py — do not edit; the file "
             "order is src/karabas_go.prj"]
    for kind, rel in kept:
        lib = "zxuno" if rel in ZXUNO_FILES else "work"
        vkind = "VHDL_FILE" if kind == "vhdl" else "VERILOG_FILE"
        lines.append(f'set_global_assignment -library "{lib}" -name {vkind} '
                     f'{prefix}/{rel}')
    (out / "upstream.qip").write_text("\n".join(lines) + "\n")

    # ---- STAMP ------------------------------------------------------------------
    (out / "STAMP").write_text(
        f"karabas-go-core-profi {git_head(UPSTREAM)}\n"
        f"modules {git_head(UPSTREAM / 'modules')}\n")

    print(f"prepare_upstream: profile {args.profile}, out {out}, "
          f"{len(kept)} files in qip, {rewritten} VHDL files rewritten")
    return 0


if __name__ == "__main__":
    sys.exit(main())
