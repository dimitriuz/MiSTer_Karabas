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
#     profi): general[0] 28.125, general[1] 24.107142 (both into clkmux2),
#     general[2] 112.5 MHz (clk_sdr: SDRAM, CLK_VIDEO).
#   emu:emu|profi:u_profi|clock:U1|clkmux2:U9|clk_out is the fabric
#     glitch-free mux output: two generated clocks on that one pin, one per
#     PLL input, logically exclusive - the mux passes one of them at a time.
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
# sram_bridge and video cdc_fifo handshakes between the bus clocks and
# clk_sdr (112.5 MHz), and the CE_PIXEL sampling of the video outputs.

derive_pll_clocks
derive_clock_uncertainty

create_generated_clock -name mcu_sck -divide_by 4 \
	-source [get_pins {emu:emu|mcu_emu:u_mcu|mcu_spi_master:u_spi|spi_sck|clk}] \
	[get_registers {emu:emu|mcu_emu:u_mcu|mcu_spi_master:u_spi|spi_sck}]

# clkmux2: the bus clock is general[0] or general[1], never both. The fitter
# turns the fabric mux into a clock-enable cell, so the generated clocks go
# on its outclk pin (names proven on the build 8 netlist: a -source clock
# object is rejected there - the master is named as its plain net).
create_generated_clock -name clk_bus28 -divide_by 1 \
	-source {emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} \
	[get_pins {emu:emu|profi:u_profi|clock:U1|clkmux2:U9|clk_out~CLKENA*|outclk}]
create_generated_clock -name clk_bus24 -divide_by 1 -add \
	-source {emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} \
	[get_pins {emu:emu|profi:u_profi|clock:U1|clkmux2:U9|clk_out~CLKENA*|outclk}]
set_clock_groups -logically_exclusive -group {clk_bus28} -group {clk_bus24}
set_clock_groups -asynchronous \
	-group {clk_bus28 clk_bus24 \
		emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
		emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} \
	-group {emu|u_profi|U1|U2|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}

# The mirror of sys_top.sdc's decoupling line (which our PLL's instance
# names escape); the sys groups beyond are exactly its list. mcu_sck stands
# in a group of its own: kg_mcu's kg_spi_slave shifts its do_buffer on the
# SCK signal itself (sta report: "do_buffer[16] is being clocked by ...
# spi_sck") and hands the byte to the bus clocks through its internal
# synchronisers - the link is asynchronous exactly as with a real MCU.
set_clock_groups -exclusive \
	-group {emu|u_profi|U1|U2|pll_inst|altera_pll_i|*[*].*|divclk clk_bus28 clk_bus24} \
	-group {mcu_sck} \
	-group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks { spi_sck }] \
	-group [get_clocks { hdmi_sck }] \
	-group [get_clocks { *|h2f_user0_clk }] \
	-group [get_clocks { FPGA_CLK1_50 }] \
	-group [get_clocks { FPGA_CLK2_50 }] \
	-group [get_clocks { FPGA_CLK3_50 }]
