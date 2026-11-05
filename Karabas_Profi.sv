// ============================================================================
//
// Karabas_Profi.sv - the MiSTer top (module `emu`) of the Karabas Pro +
// (Profi) port. Pattern: Template_MiSTer Template.sv at
// 76dd8f5c509a2237b8e707773032a31df5905048 (port list via sys/emu_ports.vh,
// the hps_io hookup, CONF_STR, VIDEO_ARX/ARY).
//
// Clocks: the machine's PLL is the one inside clock.vhd, below profi.
// CLK_VIDEO is clk_vid, the fixed 112.5 MHz output of that PLL (the machine's
// video pixels cross into it through an async FIFO, see the VIDEO
// section); clk_sdr is the muxed memory clock (112.5 / 96.428571 MHz),
// clk_bus its quarter (28.125 / 24.107142 MHz). clk_sys for hps_io, mcu_emu and
// ps2_hid is the 50 MHz input itself. Every path between that 50 MHz domain and
// the machine is
// asynchronous by design: the SPI link into kg_mcu (mcu_emu's registers on
// one side, kg_mcu's synchroniser chain on the other) and the quasi-static
// OSD bits (which also only travel as switch frames over that link).
//
// Reset: profi has no reset input - the RESET item reaches kg_mcu as a
// switch frame through mcu_emu. mcu_emu resets on power-on only (its
// contract), ps2_hid additionally on the MiSTer async RESET.
//
// VGA colors: profi's RGB is 3 bits per component, widened as {c,c,c[2:1]};
// its syncs are active low, video_mixer wants positive pulses.
// ============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_USER  = 0;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Aspect ratio item (CONF_STR below): 0 = 4:3 original, 1 = full screen,
// 2, 3 = the ARC1/ARC2 modes (template pattern).
wire [1:0] ar = status[22:21];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

// The OSD items are the CMD_SWITCHES table of rtl/host/osd_items.svh (the
// indices and fields mcu_emu sends over the MCU link); the aspect/scandoubler
// fields are MiSTer-side only.
`include "build_id.v"
localparam CONF_STR = {
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
};

///////////////////////   CLOCKS AND RESET   ///////////////////////////////

// clk_sys: the 50 MHz input itself (hps_io, mcu_emu, ps2_hid); no PLL.
wire clk_sys = CLK_50M;

// power-on reset: the configuration logic's done bit is not exposed, so a
// shift register of its own start value holds the reset for its first few
// clocks. mcu_emu must not see anything else (reset pulses reach the core
// as switch frames, see rtl/host/mcu_emu.sv).
reg [7:0] por = 8'hFF;
always @(posedge clk_sys) por <= {por[6:0], 1'b0};
wire por_reset = |por;

wire [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire forced_scandoubler;
wire [21:0] gamma_bus;

wire osd_reset = status[0] | buttons[1] | RESET;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [7:0]  ioctl_dout;
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

///////////////////////   KEYBOARD AND MCU LINK   //////////////////////////

wire [55:0] kb_report;
wire        kb_changed;

ps2_hid ps2_hid (
	.clk(clk_sys),
	.reset(por_reset | RESET),
	.ps2_key(ps2_key),
	.report(kb_report),
	.changed(kb_changed)
);

wire mcu_cs_n, mcu_sck, mcu_mosi, mcu_miso;
wire [23:0] mcu_last_reply;   // for later stages
wire        mcu_reply_valid;

mcu_emu u_mcu (
	.clk(clk_sys),
	.reset(por_reset),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.status(status),
	.osd_reset(osd_reset),

	.kb_report(kb_report),
	.kb_changed(kb_changed),

	.spi_cs_n(mcu_cs_n),
	.spi_sck(mcu_sck),
	.spi_mosi(mcu_mosi),
	.spi_miso(mcu_miso),

	.last_reply(mcu_last_reply),
	.reply_valid(mcu_reply_valid)
);

///////////////////////   THE MACHINE   ////////////////////////////////////

wire clk_bus, clk_sdr, clk_vid; // from profi's clock generator (clock.vhd)
wire profi_reset, profi_areset, profi_kb_reset;   // buffer ports, read-only

wire [8:0]  rgb;
wire        rgb_hs, rgb_vs, rgb_blank, rgb_clk, vga_clk;
wire        rgb_frame, rgb_pixel, adc_clk;
wire [3:0]  vmode;               // ds80, screen mode, vsync (video blank polarity)
wire [15:0] profi_audio_l, profi_audio_r;
wire [1:0]  sdr_dqm;

// The VHDL entity binds by name; generics per the Stage-1 constraints.
profi #(
	.ENABLE_FDD(1),
	.ENABLE_GS(0),
	.ENABLE_OPL3(1),
	.ENABLE_SAA(1),
	.ENABLE_SERIAL_MOUSE(1),
	.NUM_KEYS(4),
	.USE_T80s(1),
	.BURST_MAX_MHZ(0),
	.SOFTSW_LAYOUT(0)
) u_profi (
	.CLK_50MHZ(clk_sys),
	.CLK_BUS(clk_bus),
	.CLK_SDR(clk_sdr),
	.CLK_VID(clk_vid),
	.CLK_12(),                    // '0' in clock.vhd; FT812/MIDI only
	.CLK_8(),
	.RESET(profi_reset),
	.ARESET(profi_areset),        // the only reset of sram_bridge/sdram
	.KB_RESET(profi_kb_reset),

	.UART_RX(1'b1),               // no UART, SD card, CF, tape or ADC here:
	.UART_TX(),                   // the inputs at the profi boundary carry
	.UART_CTS(),                  // the "no drive" level (active-high)
	.MA(),
	.MD(),                        // the main memory is MiSTer's SDRAM now
	.MWR_N(),
	.MRD_N(),

	.SDR_BA(SDRAM_BA),            // memory.vhd -> sram_bridge -> sdram.sv
	.SDR_A(SDRAM_A),
	.SDR_CLK(),                   // the top drives SDRAM_CLK (altddio below)
	.SDR_DQM(sdr_dqm),
	.SDR_WE_N(SDRAM_nWE),
	.SDR_CAS_N(SDRAM_nCAS),
	.SDR_RAS_N(SDRAM_nRAS),
	.SDR_DQ(SDRAM_DQ),

	.SD_CS_N(),
	.SD_DI(),
	.SD_DO(1'b1),
	.SD_CLK(),
	.SD_DET_N(1'b1),

	.RGB_CLK(rgb_clk),
	.VGA_CLK(vga_clk),
	.RGB(rgb),
	.RGB_HS(rgb_hs),
	.RGB_VS(rgb_vs),
	.RGB_BLANK(rgb_blank),
	.RGB_FRAME(rgb_frame),
	.RGB_PIXEL(rgb_pixel),
	.SCANDOUBLER(),
	.VMODE(vmode),
	.DVI_ONLY(),

	.WA(),
	.WCS_N(),
	.WRD_N(),
	.WWR_N(),
	.WRESET_N(),
	.WD(),

	.TAPE_IN(1'b0),
	.TAPE_OUT(),
	.BEEPER(),
	.AUDIO_L(profi_audio_l),
	.AUDIO_R(profi_audio_r),

	.ADC_CLK(adc_clk),            // = ENA_RGB: the pixel enable
	.ADC_L(24'd0),
	.ADC_R(24'd0),
	.ESP_L(16'd0),
	.ESP_R(16'd0),

	.MCU_CS_N(mcu_cs_n),          // the SPI link from mcu_emu
	.MCU_SCK(mcu_sck),
	.MCU_MOSI(mcu_mosi),
	.MCU_MISO(mcu_miso),
	.MCU_IO(4'b0000),
	.MCU_BURST_CS_N(1'b1),        // no burst master on MiSTer (stage 2)
	.MCU_BURST_READY(),

	.MIDI_TX(),
	.MIDI_RESET_N(),

	.FDC_INDEX(1'b0),             // no drives yet (stage 2)
	.FDC_DRIVE(),
	.FDC_MOTOR(),
	.FDC_DIR(),
	.FDC_STEP(),
	.FDC_WDATA(),
	.FDC_WGATE(),
	.FDC_TR00(1'b0),
	.FDC_WPRT(1'b0),
	.FDC_RDATA(1'b0),
	.FDC_SIDE_N()
);

assign {SDRAM_DQMH, SDRAM_DQML} = sdr_dqm;
assign SDRAM_nCS = 1'b0;
assign SDRAM_CKE = 1'b1;

// SDRAM_CLK: the memory clock leaves through a DDR output register, the
// same trick as at the end of rtl/mem/sdram.sv (copied from there verbatim,
// the .outclock net is clk_sdr = clk_mem here and the dataout the MiSTer pin).
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_sdr),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

///////////////////////   VIDEO   //////////////////////////////////////////

// The machine's video chain is clocked by clk_bus with the pixel enable
// ADC_CLK = ENA_RGB; the pixels cross into the clk_vid domain (CLK_VIDEO =
// the fixed 112.5 MHz PLL output on profi's CLK_VID port) through an async FIFO
// - every clk_bus -> clk_vid crossing in this port is a cdc_fifo (push on
// the clk_bus edge with ADC_CLK = '1'). The FIFO resets with the machine
// ARESET (= not locked: held for far more than three clk_bus clocks, see
// rtl/mem/cdc_fifo.vhd).
//
// clk_vid is a direct PLL clock, which is what sys_top's clock switches
// (hdmi_clk_sw, vga_clk_sw) require on CLK_VIDEO; clk_bus is divided from the
// DS80-muxed memory clock and can never be such a net.

// The crossing itself is rtl/video/video_cdc.sv (async cdc_fifo DW=12
// AW=3 + the pop capture register): push on ce_in, pop whenever not empty,
// ce_out/dout change together - dout is stable from one ce_out to the
// next (sim/tb_video_cdc.sv checks exactly this, plus exact-once order and
// the stalled-burst case).
wire        vid_ce;
wire [11:0] vid_r;

// RGB_BLANK has opposite polarities in the two upstream video generators:
// profi_video (DS80, 512x240) drives 1 while blanking, pentagon_video (the
// Spectrum modes) drives 0 while blanking (blank_r). Upstream's own top never
// uses RGB_BLANK (its HDMI frame is built from RGB_PIXEL/RGB_FRAME), so the
// mismatch only shows here. Normalise to 1 = blanking on the clk_bus side;
// vmode[3] is profi's ds80 register (VMODE <= ds80 & ...), also on clk_bus.
wire        rgb_blank_hi = vmode[3] ? rgb_blank : ~rgb_blank;

video_cdc #(.W(12)) video_cdc (
	.clk_bus(clk_bus),
	.clk_vid(clk_vid),
	.reset(profi_areset),
	.ce_in(adc_clk),              // ENA_RGB: one word per pixel
	.din({rgb, rgb_hs, rgb_vs, rgb_blank_hi}),
	.stall(1'b0),                 // sim-only hold-off
	.ce_out(vid_ce),
	.dout(vid_r)
);

wire       vga_hs    = ~vid_r[2];   // the profi syncs are active low
wire       vga_blank =  vid_r[0];

assign CLK_VIDEO = clk_vid;

// VBlank and VS for the mixer: the machine's VSYNC can lie outside its
// vertical blank (the 60 Hz Spectrum modes: upstream pentagon_video.vhd
// drives VSYNC at chr_row 27 while the blank covers rows 28-29), so
// rtl/video/vframe_gen.sv rebuilds both from the run of fully blank lines
// in the popped pixel stream, on the clk_vid side with the pop strobe as
// the clock enable.
wire vf_vblank, vf_vs;
vframe_gen vframe_gen (
	.clk(clk_vid),
	.ce(vid_ce),
	.hs_n(vid_r[2]),
	.blank(vid_r[0]),
	.vblank(vf_vblank),
	.vs(vf_vs)
);

wire [2:0] fx = status[25:23];    // Scandoubler Fx: None, HQ2x, CRT 25/50/75

// CRT scanline strength for MiSTer (sys/scanlines.v: 0 = off, 1/2/3 =
// 25/50/75%): with the CONF_STR order above HQ2x is fx = 1 and must stay
// at sl = 0, so everything from fx = 2 on shifts down by one - the ZX-Demo
// pattern.
wire [2:0] sl = (fx > 3'd1) ? (fx - 3'd1) : 3'd0;
assign VGA_SL = sl[1:0];

wire [7:0] r8w = {vid_r[11:9], vid_r[11:9], vid_r[10:9]};
wire [7:0] g8w = {vid_r[8:6], vid_r[8:6], vid_r[7:6]};
wire [7:0] b8w = {vid_r[5:3], vid_r[5:3], vid_r[4:3]};

video_mixer #(.LINE_LENGTH(1024), .GAMMA(1)) video_mixer
(
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(CE_PIXEL),          // the mixer's own pixel enable output
	.ce_pix(vid_ce),

	.scandoubler(forced_scandoubler | (fx != 0)),
	.hq2x(fx == 3'd1),

	.gamma_bus(gamma_bus),

	.R(r8w),
	.G(g8w),
	.B(b8w),

	.HSync(vga_hs),
	.VSync(vf_vs),
	.HBlank(vga_blank),
	.VBlank(vf_vblank),

	.HDMI_FREEZE(1'b0),
	.freeze_sync(),

	.VGA_R(VGA_R),                // straight onto the MiSTer outputs
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(VGA_DE)
);


///////////////////////   AUDIO   //////////////////////////////////////////

assign AUDIO_L = profi_audio_l;
assign AUDIO_R = profi_audio_r;
assign AUDIO_S = 1;               // signed samples
assign AUDIO_MIX = 0;

endmodule
