# Karabas_Profi timing constraints. Base: Template_MiSTer Template.sdc at
# 76dd8f5c509a2237b8e707773032a31df5905048 (the two derive lines below).
# sys/sys_top.sdc stays included as the template does it.
#
# Clock structure (names as derive_pll_clocks and sys_top create them, from
# the Clocks table of the build logs):
#
#   FPGA_CLK2_50 (sys_top line `.CLK_50M(FPGA_CLK2_50)`) is clk_sys: hps_io,
#     mcu_emu, ps2_hid and the mcu_spi_master clock divider live here.
#   emu|u_profi|U1|U2|pll_inst: the machine's one PLL (clock.vhd inside
#     profi): general[0] 28.125 (clk_gs), general[1] 24.107142 (the port's
#     PLL request leaves it unconnected, the fitter prunes its counter),
#     general[2] 112.5 MHz (clk_vid: CLK_VIDEO, video CDC read side,
#     vframe_gen, video_mixer; and clkmux2 branch 0) and general[3]
#     96.428571 MHz (clkmux2 branch 1).
#   emu:emu|profi:u_profi|clock:U1|clkmux2:U9|clk_out is the fabric
#     glitch-free mux output (clk_mem: the SDRAM clock of the no-wait
#     controller and the SDRAM_CLK altddio): two generated clocks on that one pin,
#     clk_mem112 and clk_mem96, one per PLL input, logically exclusive -
#     the mux passes one of them at a time. The fitter turns the fabric mux
#     into a clock-enable cell, so the generated clocks go on its
#     |clk_out~CLKENA*|outclk pin (names proven on the build 8 netlist; a
#     -source clock object is rejected there - the master is named as its
#     plain net).
#   emu:emu|profi:u_profi|clock:U1|clkdiv4:U11|q: the bus clock, a fabric
#     register toggling once per 4 clk_mem (50 % duty). clk_bus28 and
#     clk_bus24 are generated clocks defined ON THE DIVIDER REGISTER'S OWN
#     CLOCK PIN (-source q|clk, -master_clock clk_mem112/96), so the
#     analysis carries the full clk_mem launch path (PLL, clkmux2 CLKENA)
#     as source latency; defining them from the PLL output pin (as the
#     first stage-2 builds did) starts them at q with zero latency and
#     invents ~14 ns of bus-vs-mem skew (build 19: clk_bus28 -15.4 ns on a
#     3.7 ns path). They stay related to clk_mem (the divider is plain
#     logic and the whole design samples memory against the bus phase, so
#     between them is ordinary synchronous timing).
#   clkgate (clock:U1|clkgate:U10, `clk and en_r`): Quartus 17's gated-clock
#     conversion turns its loads into clk_bus registers with a clock enable
#     (build 4: "Auto Gated Clock Conversion On", clkgate:U10|gclk appears
#     nowhere in the sta report), so clk_rgb needs no clock of its own.
#   emu:emu|mcu_emu:u_mcu|mcu_spi_master:u_spi|spi_sck: the /4 register that
#     drives the MCU SPI clock (kg_mcu synchronizes it internally) - the
#     only clock a build left unconstrained (332060).
#
# Groups: sys_top.sdc decouples the sys clock domains from the core with
# `-group [get_clocks {*|pll|pll_inst|...}]`, but our PLL is instantiated as
# U2|pll_inst (no `|pll|` level), so that filter matches nothing (build log
# warning 332174) and every core<->sys path was timed as related: that was
# the -11.3 ns on pll_audio, -6.9 on h2f_user0_clk, -6.7 on pll_hdmi and
# -3.9 on FPGA_CLK1_50 of build 7. The set_clock_groups -exclusive below
# mirrors sys_top's line with the core's clocks as the first group; every
# crossing it cuts is synchronized by design - the SPI link into kg_mcu
# (mcu_emu's registers on one side, kg_mcu's synchroniser chain on the
# other; clk_sys = FPGA_CLK2_50 vs the bus clocks is that link), the quasi-
# static OSD bits (which only travel as switch frames over that link), the
# video cdc_fifo handshake between the bus clocks and clk_vid, and the CE_PIXEL
# sampling of the video outputs. The memory side needs no FIFO since Stage 2:
# clk_bus and clk_mem are related (the divider) and the SDRAM controller
# samples the CPU bus at the bus clock's own phase.

derive_pll_clocks
derive_clock_uncertainty

create_generated_clock -name mcu_sck -divide_by 4 \
	-source [get_pins {emu:emu|mcu_emu:u_mcu|mcu_spi_master:u_spi|spi_sck|clk}] \
	[get_registers {emu:emu|mcu_emu:u_mcu|mcu_spi_master:u_spi|spi_sck}]

# clkmux2: clk_mem is general[2] or general[3], never both (DS80).
create_generated_clock -name clk_mem112 -divide_by 1 \
	-source {emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk} \
	[get_pins {emu:emu|profi:u_profi|clock:U1|clkmux2:U9|clk_out~CLKENA*|outclk}]
create_generated_clock -name clk_mem96 -divide_by 1 -add \
	-source {emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk} \
	[get_pins {emu:emu|profi:u_profi|clock:U1|clkmux2:U9|clk_out~CLKENA*|outclk}]

# clkdiv4: the bus clock is the divider register's q, a quarter of the
# selected clk_mem. Defined from the divider register's own clock pin with
# the mux clocks as masters, so the bus clocks carry the clk_mem source
# latency (the q|clk pin exists because q is a real register; 2b keeps q
# non-inverted so the defined polarity matches the register). q's own
# clock pin is the same net the clk_mem clocks reach, hence -divide_by 4
# of clk_mem with no extra latency line.
create_generated_clock -name clk_bus28 -divide_by 4 -master_clock clk_mem112 \
	-source [get_pins {emu:emu|profi:u_profi|clock:U1|clkdiv4:U11|q|clk}] \
	[get_registers {emu:emu|profi:u_profi|clock:U1|clkdiv4:U11|q}]
create_generated_clock -name clk_bus24 -divide_by 4 -add -master_clock clk_mem96 \
	-source [get_pins {emu:emu|profi:u_profi|clock:U1|clkdiv4:U11|q|clk}] \
	[get_registers {emu:emu|profi:u_profi|clock:U1|clkdiv4:U11|q}]

# DS80 selects one {clk_mem, clk_bus} pair at a time.
# (the SDRAM_CLK pin clocks are defined further down; they join these groups there)
set_clock_groups -logically_exclusive -group {clk_mem112 clk_bus28} \
	-group {clk_mem96 clk_bus24}

# The fixed PLL outputs general[2] (drives the video chain directly as
# CLK_VIDEO) and general[0] (CLK_GS: the GS CPU plus gs_mem, its DDRAM_CLK)
# are asynchronous to the memory/bus pairs.
# general[2]: everything between the video chain and the machine goes through
# the video cdc_fifo. This cut does not touch the clock network itself:
# clk_mem112 and clk_bus28 keep their derivation from general[2], and clk_bus
# stays related to clk_mem.
# general[0]: gs.v's host side is level-based on strobes at least three bus
# clocks long, the GS output samples cross with the two-equal-samples rule,
# the GS ROM loader crosses as gs_mem's toggle handshake, and Task 1's clock
# alignment attempt was dropped (builds 31-35).
set_clock_groups -asynchronous \
	-group {emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk} \
	-group {clk_mem112 clk_mem96 clk_bus28 clk_bus24}
set_clock_groups -asynchronous \
	-group {emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} \
	-group {clk_mem112 clk_mem96 clk_bus28 clk_bus24}

# The mirror of sys_top.sdc's decoupling line (which our PLL's instance
# names escape); the sys groups beyond are exactly its list. mcu_sck stands
# in a group of its own: kg_mcu's kg_spi_slave shifts its do_buffer on the
# SCK signal itself (sta report: "do_buffer[16] is being clocked by ...
# spi_sck") and hands the byte to the bus clocks through its internal
# synchronisers - the link is asynchronous exactly as with a real MCU.
set_clock_groups -exclusive \
	-group {emu|u_profi|U1|U2|pll_inst|altera_pll_i|*[*].*|divclk \
		clk_mem112 clk_mem96 clk_bus28 clk_bus24} \
	-group {mcu_sck} \
	-group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks { spi_sck }] \
	-group [get_clocks { hdmi_sck }] \
	-group [get_clocks { *|h2f_user0_clk }] \
	-group [get_clocks { FPGA_CLK1_50 }] \
	-group [get_clocks { FPGA_CLK2_50 }] \
	-group [get_clocks { FPGA_CLK3_50 }]

# Ruling R10: the select (ds80 = vmode(3), a video-domain register) is the
# asynchronous input of the two 2-flop synchroniser chains of clkmux2; its
# setup to the first sampling stage is not a synchronous requirement (the
# d1/q1 stages stay timed: a late sample only costs cycles).
# Stage 2 adds the same for the branch-enable interlock captures en0 <= d1
# and not en1, en1 <= q1 and not en0: between general[2] and general[3] the
# 6:7 output counters of one VCO put the nearest sampling edge 1.48 ns apart
# (build 16: -10.6/-8.3, TNS -2059 on both), no logic closes that; the
# interlock is the protection for the branch enables (never on together),
# and falling-edge sampling keeps its wrong-sample cost at one lost cycle.
set_false_path -to [get_registers {emu:emu|profi:u_profi|clock:U1|clkmux2:U9|d0 emu:emu|profi:u_profi|clock:U1|clkmux2:U9|q0 emu:emu|profi:u_profi|clock:U1|clkmux2:U9|en0 emu:emu|profi:u_profi|clock:U1|clkmux2:U9|en1}]

# The no-wait controller samples the clk_bus-domain CPU signals (addr, din,
# wr_en, TS, MC, the strobes, cpu_reset_n, ena) only at the clk_mem clock
# edge whose previous registered BUS_PHASE sample is "01" (the clock unit
# drives BUS_PHASE = "01" for 2 clk_mem starting one clk_mem after each
# clk_bus rising edge, so the sample edge lands 2 clk_mem after it; the
# inputs of that flop path go through only the controller's first pipeline
# registers): a clk_bus -> clk_mem path therefore has 2 clk_mem to settle -
# setup 2. The matching hold counts unchanged clock edges: with setup at 2,
# -hold 1 keeps the paths timed against the very next clk_mem edge, so no
# combinational loop opens. (The reverse direction has no paths: the
# controller's outputs are registered on clk_mem into clk_bus-domain CPU
# inputs, which STA already times at the clock boundary.)
set_multicycle_path -setup 2 -from [get_clocks {clk_bus28}] -to [get_clocks {clk_mem112}]
set_multicycle_path -hold 1 -from [get_clocks {clk_bus28}] -to [get_clocks {clk_mem112}]
set_multicycle_path -setup 2 -from [get_clocks {clk_bus24}] -to [get_clocks {clk_mem96}]
set_multicycle_path -hold 1 -from [get_clocks {clk_bus24}] -to [get_clocks {clk_mem96}]

# The controller's read-capture register (cpu_byte_r) loads on the clk_mem edge
# S0 + 6, 8 clk_mem after the bus edge the cycle started on, i.e. on an edge that
# coincides with a clk_bus rising edge (tb_turbo_nowait checks every DO change
# against this). At turbo 11 that is the edge E2 that would end T2, so
# memory.vhd holds T2 one clk_bus period (MEM_WAIT) and the T80 latches at the
# next bus edge, 4 clk_mem later: the default setup relation; at the lower turbos
# the latch is later still. The default HOLD check compares a capture launched
# on the clk_mem edge that coincides with a bus edge against a latch edge at
# 0 ns - a phase at which the T80 never latches DI. clk_bus also reaches its
# registers ~3.5 ns later than clk_mem (divider + its CLKENA), so the router
# would meet that impossible hold in the fast corner by padding the next
# cpu_byte_r -> T80 route (build 22: two neighbouring LABs, 5.85 + 6.25 ns
# of routing, clk_bus28 setup -1.472). -hold 3 with -start moves the hold
# check to the bus edge 4 clk_mem before the launch, i.e. the edge that
# really must still see the old data.
# cpu_byte_r is the one capture register (the IO input register of SDRAM_DQ[7:0],
# which b_dout shares).
set_multicycle_path -start -hold 3 \
	-from [get_registers {*sdram_nowait:U_SDRAM|cpu_byte_r[*]}] \
	-to [get_clocks {clk_bus28 clk_bus24}]

# b_done is a toggle: sdram_nowait's b_done_r (clk_mem) is consumed in
# memory.vhd only through the 2-flop synchroniser b_done_s1 -> b_done_s2
# into clk_bus, and the logic acts on the second stage alone (the s1 /= s2
# edge compare), so the first stage may go metastable.
set_false_path -from [get_registers {*sdram_nowait:U_SDRAM|b_done_r}] \
	-to [get_registers {*memory:U3|b_done_s1}]

# (the stage 1 sram_bridge cdc_fifo false paths went with the bridge: the
# no-wait controller has no gray-pointer crossing between these clocks)


# ---- the SDRAM chip's I/O timing (the pins were unconstrained before: the
# data the chip returns was never timed, so whether it was captured correctly
# depended on the seed's placement) ----
# SDRAM_CLK leaves through the DDR output register as clk_mem inverted (datain_h
# 0, datain_l 1), one generated clock per clkmux2 input.
create_generated_clock -name SDRAM_CLK112 -invert -master_clock clk_mem112 \
	-source [get_pins {emu:emu|profi:u_profi|clock:U1|clkmux2:U9|clk_out~CLKENA*|outclk}] \
	[get_ports {SDRAM_CLK}]
create_generated_clock -name SDRAM_CLK96 -invert -add -master_clock clk_mem96 \
	-source [get_pins {emu:emu|profi:u_profi|clock:U1|clkmux2:U9|clk_out~CLKENA*|outclk}] \
	[get_ports {SDRAM_CLK}]
# the chip (MiSTer SDRAM module, -6/-7 grade, CL2): tAC 5.4 + ~1 board on the data
# it drives (max), tOH 2.5 + ~0.7 (min); tIS 1.5 and tIH 0.8 on what it samples
foreach c {SDRAM_CLK112 SDRAM_CLK96} {
	set_input_delay -clock $c -max 6.4 [get_ports {SDRAM_DQ[*]}] -add_delay
	set_input_delay -clock $c -min 3.2 [get_ports {SDRAM_DQ[*]}] -add_delay
	set_output_delay -clock $c -max 1.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE}] -add_delay
	set_output_delay -clock $c -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE}] -add_delay
}
set_clock_groups -logically_exclusive -group {clk_mem112 clk_bus28 SDRAM_CLK112} \
	-group {clk_mem96 clk_bus24 SDRAM_CLK96}
# The read data: a READ at S0 + 2 is seen by the chip at S0 + 2.5 (SDRAM_CLK is
# clk_mem inverted); the CL2 data is launched by the chip edge S0 + 4.5 and the
# controller's capture register (the IO input register of SDRAM_DQ[7:0]) loads
# on the clk_mem edge S0 + 6, the SECOND rising clk_mem edge after that launch
# (S0 + 5 is the first, half a period after it: far too early for 6.4 ns of tAC +
# board + ~2.4 ns of SDRAM_CLK pin lag). STA's default relation SDRAM_CLK* (clk_mem
# fall) -> clk_mem* (rise) is the first rising edge, so the setup relation is
# one clk_mem longer: -setup 2 = 1.5 periods = 13.3 ns at 112.5 MHz. -hold is left
# at its default, which then checks the NEXT chip data (launched one period
# later, ~5.6 ns min delay) against this same capture edge - the real hold
# requirement. (The former `-setup 3 -hold 2` described a capture at S0 + 7, a
# whole period later than the real one, so STA reported ~2 periods of slack the
# hardware never had and the capture worked only when the fitter placed the
# capture clock late; the true figures for the S0 + 5 capture were -8.1 ns at
# 112.5 MHz and -7.4 ns at 96.4 MHz.)
set_multicycle_path -setup 2 -from [get_clocks {SDRAM_CLK112}] -to [get_clocks {clk_mem112}]
set_multicycle_path -setup 2 -from [get_clocks {SDRAM_CLK96}]  -to [get_clocks {clk_mem96}]

# The HQ2x scandoubler's blender (sys/hq2x.sv) runs on clk_vid (112.5 MHz) but every register in it
# is enabled by ce_in = scandoubler's ce_x4i, which fires at 1/4, 2/4 and 3/4 of a pixel plus once
# per line at the hsync edge: with our pixel strobe (ENA_RGB, 7 MHz Spectrum modes = 16 clk_vid,
# 12 MHz DS80 = ~9) the regular spacing is 4, never below 2 clk_vid. Both ends of every path into the
# blender are loaded on that enable, so two clk_vid periods are available (the long Blend adder
# chain missed one by 1.4 to 1.7 ns in seeds 12, 15 and 17, and swings by 2 ns between seeds).
# The only 1-clk spacing is the hsync-edge pulse next to a regular one, inside the blanking.
set_multicycle_path -setup 2 -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
set_multicycle_path -hold  1 -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
