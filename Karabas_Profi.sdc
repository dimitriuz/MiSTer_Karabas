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
set_clock_groups -logically_exclusive -group {clk_mem112 clk_bus28} \
	-group {clk_mem96 clk_bus24}

# The fixed PLL output general[2] (drives the video chain directly as
# CLK_VIDEO) is asynchronous to the memory/bus pairs: everything between the
# video chain and the machine goes through the video cdc_fifo. This cut does
# not touch the clock network itself: clk_mem112 and clk_bus28 keep their
# derivation from general[2], and clk_bus stays related to clk_mem.
# (general[0] would belong here too, but with ENABLE_GS = 0 nothing loads
# CLK_GS, the fitter prunes the output counter, and referencing the pruned
# clock in an sdc line fails the build - restore it together with the GS.)
set_clock_groups -asynchronous \
	-group {emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk} \
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

# b_done is a toggle: sdram_nowait's b_done_r (clk_mem) is consumed in
# memory.vhd only through the 2-flop synchroniser b_done_s1 -> b_done_s2
# into clk_bus, and the logic acts on the second stage alone (the s1 /= s2
# edge compare), so the first stage may go metastable.
set_false_path -from [get_registers {*sdram_nowait:U_SDRAM|b_done_r}] \
	-to [get_registers {*memory:U3|b_done_s1}]

# (the stage 1 sram_bridge cdc_fifo false paths went with the bridge: the
# no-wait controller has no gray-pointer crossing between these clocks)

