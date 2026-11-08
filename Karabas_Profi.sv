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

assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

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
`default_nettype none
localparam CONF_STR = {
	"Karabas_Profi;UART31250,MIDI;",
	"-;",
	"P1,Video;",
	"P1O[22:21],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[25:23],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1O[7],VSync,50 Hz,60 Hz;",
	"P2,MT32-pi;",
	"P2O[27],Use MT32-pi,Yes,No;",
	"P2O[28],Synth,Munt,FluidSynth;",
	"P2O[30:29],Munt ROM,MT-32 v1,MT-32 v2,CM-32L;",
	"-;",
	"O[2:1],ROM Bank,ROMain,PQ-DOS,FDImage,FATALL;",
	"O[9:8],Turbo,Off,2x,4x,8x;",
	"O[6:4],PSG Mix,AY ACB,AY Mono,YM ABC,YM ACB,YM Mono,AY ABC;",
	"O[3],Covox,On,Off;",
	"S0,TAPTZXCSW,Tape;",
	"T[31],Tape play/pause;",
	"T[32],Tape previous block;",
	"T[33],Tape next block;",
	"O[12:10],Joystick L,Kempston,Sinclair1,Sinclair2,Cursor,QAOPM,QAOPS;",
	"O[15:13],Joystick R,Sinclair1,Sinclair2,Cursor,QAOPM,QAOPS,Kempston;",
	"O[16],DivMMC,Off,On;",
	"O[17],Keyboard,Profi XT,Spectrum;",
	"O[18],Pause,Off,On;",
	"O[26],Mode,Pentagon,48k;",
	"-;",
	"T[19],GS Reset;",
	"T[20],NMI;",
	"R[0],Reset;",
	"J1,A,B,C,X,Y,Z,Start,Mode;",
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
wire [7:0] uart_mode;             // OSD "UART mode" select: 3 = MIDI

wire osd_reset = status[0] | buttons[1] | RESET;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [7:0]  ioctl_dout;
wire        ioctl_wait;

// MiSTer disk slot 0 (the tape file, see the TAPE section): the mount
// handshake and the SD block interface hps_io shares with the core. VDNUM=1
// (one slot), BLKSZ=2 (512-byte sectors), so sd_buff_addr is [13:0]; the
// tape reader uses the low 9 bits of the 512-byte sector.
wire  [0:0]  img_mounted;
wire         img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba [1];
wire   [5:0] sd_blk_cnt [1];
wire   [0:0] sd_rd, sd_wr, sd_ack;
wire  [13:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din [1];
wire         sd_buff_wr;

assign sd_blk_cnt[0] = 6'd0;
assign sd_wr        = 1'b0;
assign sd_buff_din[0] = 8'd0;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(1), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.uart_mode(uart_mode),

	.ps2_key(ps2_key),

	.RTC(hps_rtc),
	.ps2_mouse(ps2_mouse),
	.ps2_mouse_ext(ps2_mouse_ext),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),

	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   KEYBOARD AND MCU LINK   //////////////////////////

// the rest of the MCU's board inputs: MiSTer's RTC, PS/2 mouse (bit 24
// toggles per report, ps2_mouse_ext[7:0] is the wheel) and joystick words
wire [64:0]  hps_rtc;
wire [24:0]  ps2_mouse;
wire [15:0]  ps2_mouse_ext;
wire [31:0]  joystick_0, joystick_1;

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

	.rtc(hps_rtc),
	.ps2_mouse(ps2_mouse),
	.ps2_mouse_ext(ps2_mouse_ext),
	.joy0(joystick_0),
	.joy1(joystick_1),

	.mem_ready(mem_ready),

	.spi_cs_n(mcu_cs_n),
	.spi_sck(mcu_sck),
	.spi_mosi(mcu_mosi),
	.spi_miso(mcu_miso),

	.last_reply(mcu_last_reply),
	.reply_valid(mcu_reply_valid)
);

///////////////////////   THE MACHINE   ////////////////////////////////////

wire clk_bus, clk_sdr, clk_vid; // from profi's clock generator (clock.vhd)
wire ena_cpu_o;                // profi ENA_CPU: one pulse per CPU T-state
wire profi_reset, profi_areset, profi_kb_reset;   // buffer ports, read-only
wire [15:0] profi_audio_l, profi_audio_r;         // AU samples, AUDIO_L/R below
wire        midi_tx;           // profi MIDI_TX (TurboSound AY port A bit 2)

wire [8:0]  rgb;
wire        rgb_hs, rgb_vs, rgb_blank, rgb_clk, vga_clk;
wire        rgb_frame, rgb_pixel, adc_clk;
wire [3:0]  vmode;               // ds80, screen mode, vsync (video blank polarity)
wire [1:0]  sdr_dqm;
wire        mem_ready;         // sdram_nowait init done (memory.vhd -> mcu_emu)

wire        gs_clk;            // CLK_GS 28.125 MHz: the GS CPU, gs_mem, DDRAM_CLK
wire [20:0] gsm_a, gsl_a;      // GS bus out of memory.vhd / its loader bytes
wire  [7:0] gsm_di, gsm_do, gsl_d;
wire        gsm_rd, gsm_wr, gsm_wait_n, gsl_tgl;

// The VHDL entity binds by name; generics per the Stage-1 constraints.
profi #(
	.ENABLE_FDD(1),
	.ENABLE_GS(1),
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
	.ARESET(profi_areset),        // the one reset of sdram_nowait (via profi)
	.KB_RESET(profi_kb_reset),

	.UART_RX(1'b1),               // no UART, SD card, CF, tape or ADC here:
	.UART_TX(),                   // the inputs at the profi boundary carry
	.UART_CTS(),                  // the "no drive" level (active-high)
	.MA(),
	.MD(),                        // the main memory is MiSTer's SDRAM now
	.MWR_N(),
	.MRD_N(),

	.SDR_BA(SDRAM_BA),            // memory.vhd -> sdram_nowait -> the SDRAM
	.SDR_A(SDRAM_A),
	.SDR_CLK(),                   // the top drives SDRAM_CLK (altddio below)
	.SDR_DQM(sdr_dqm),
	.SDR_WE_N(SDRAM_nWE),
	.SDR_CAS_N(SDRAM_nCAS),
	.SDR_RAS_N(SDRAM_nRAS),
	.SDR_DQ(SDRAM_DQ),
	.MEM_READY(mem_ready),        // init done, gate of mcu_emu's start
	.CLK_GS_O(gs_clk),
	.GSM_A(gsm_a),
	.GSM_DI(gsm_di),
	.GSM_RD(gsm_rd),
	.GSM_WR(gsm_wr),
	.GSM_DO(gsm_do),
	.GSM_WAIT_N(gsm_wait_n),
	.GSL_A(gsl_a),
	.GSL_D(gsl_d),
	.GSL_TGL(gsl_tgl),
	.ENA_CPU_O(ena_cpu_o),

	.SD_CS_N(),
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

	.TAPE_IN(tape_in),
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

	.MIDI_TX(midi_tx),
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

// The General Sound's memory: 64 KB of GS RAM in BRAM and the rest of the
// 2 MB in MiSTer's DDR3 through the DDRAM_* Avalon port. Its clock is the
// GS clock itself (CLK_GS, 28.125 MHz), asynchronous to the bus clocks; the
// GS bus and the ROM loader bytes cross by design (see Karabas_Profi.sdc).
// reset is the PLL lock (profi_areset), never the OSD reset: the GS CPU is
// reset inside profi, and aborting a DDR3 transaction mid-flight would break
// the Avalon protocol.
gs_mem u_gs_mem (
	.clk(gs_clk),
	.reset(profi_areset),

	.a(gsm_a),
	.din(gsm_di),
	.rd(gsm_rd),
	.wr(gsm_wr),
	.dout(gsm_do),
	.wait_n(gsm_wait_n),

	.ldr_a(gsl_a),
	.ldr_d(gsl_d),
	.ldr_tgl(gsl_tgl),

	.ddr_busy(DDRAM_BUSY),
	.ddr_burstcnt(DDRAM_BURSTCNT),
	.ddr_addr(DDRAM_ADDR),
	.ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY),
	.ddr_rd(DDRAM_RD),
	.ddr_din(DDRAM_DIN),
	.ddr_be(DDRAM_BE),
	.ddr_we(DDRAM_WE)
);

assign DDRAM_CLK = gs_clk;

assign {SDRAM_DQMH, SDRAM_DQML} = sdr_dqm;
assign SDRAM_nCS = 1'b0;
assign SDRAM_CKE = 1'b1;

// SDRAM_CLK: the memory clock leaves through a DDR output register, the
// trick of upstream's rtl/mem/sdram.sv (gone with Stage 2; sim/tb_turbo_nowait
// models the same clock as not clk_mem delayed 1 ns). The .outclock net is
// clk_sdr = clk_mem here and the dataout the MiSTer pin.
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

///////////////////////   TAPE   //////////////////////////////////////////

// The tape file comes from MiSTer disk slot 0 (OSD "Tape: mount"): the bytes
// are never loaded into memory, rtl/tape/tape_src.sv reads them from the
// SD image in two cached 512-byte sectors (clk_sys side) and serves the ZX
// core's player, rtl/tape/tape.sv (clk_bus side), through its rd_en/addr/din
// memory port. tape.sv and its TZX engine rtl/tape/tzxplayer.vhd are verbatim
// copies of ZX-Spectrum_MISTer c2c4e6f; the player's TAP/CSW decoder and the
// TZX engine both count their pulses in `ce` ticks, so `ce` is the CPU's own
// enable: one pulse per T-state at whatever Turbo is set to.
//
// The three OSD triggers (T[33:31]) are two-flop synchronised into clk_bus
// and turned into one-clock pulses. `tape_active` selects the tape audio for
// the machine's EAR input; with no tape playing, the LTC2308 line-in on the
// MiSTer ADC header is the source when it sees a signal, as on the ZX core.
// A freshly mounted tape is paused: the player's play_pause is 1 until the
// play/pause trigger.
wire        tape_ready;
wire  [1:0] tape_mode;        // 0 TAP, 1 CSW, 2 TZX (sniffed by tape_src)
wire [24:0] tape_size;
wire        tape_rd;
wire [24:0] tape_addr;
wire  [7:0] tape_din;
wire        tape_rd_en;
wire        tape_active, tape_audio;
wire        tape_adc, tape_adc_act;
wire        tape_in;

tape_src u_tape_src (
	.clk_sys(clk_sys),
	.img_mounted(img_mounted[0]),
	.img_size(img_size),
	.sd_lba(sd_lba[0]),
	.sd_rd(sd_rd[0]),
	.sd_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),

	.clk(clk_bus),
	.tape_ready(tape_ready),
	.tape_mode(tape_mode),
	.tape_size(tape_size),
	.rd(tape_rd),
	.addr(tape_addr),
	.din(tape_din),
	.rd_en(tape_rd_en)
);

// {pause, prev, next}: first sync stage, second sync stage, the second stage
// one clk_bus earlier; a rising edge of the second stage is the pulse.
reg [2:0] tape_trig_s [0:2];
always @(posedge clk_bus) begin
	tape_trig_s[0] <= {tape_trig_s[0][1:0], status[31]};
	tape_trig_s[1] <= {tape_trig_s[1][1:0], status[32]};
	tape_trig_s[2] <= {tape_trig_s[2][1:0], status[33]};
end

wire tape_pause = tape_trig_s[0][1] & ~tape_trig_s[0][2];
wire tape_prev  = tape_trig_s[1][1] & ~tape_trig_s[1][2];
wire tape_next  = tape_trig_s[2][1] & ~tape_trig_s[2][2];

tape u_tape (
	.clk_sys(clk_bus),
	.ce(ena_cpu_o),

	.mode48k(1'b0),
	.turbo(1'b0),
	.byte_wait(1'b0),
	.byte_ready(),
	.dout(),

	.pause(tape_pause),
	.prev(tape_prev),
	.next(tape_next),
	.active(tape_active),
	.available(),

	.tape_ready(tape_ready),
	.tape_mode(tape_mode),
	.tape_size(tape_size),
	.stdload(1'b0),
	.req_hdr(1'b0),

	.audio_out(tape_audio),

	.rd_en(tape_rd_en),
	.rd(tape_rd),
	.addr(tape_addr),
	.din(tape_din)
);

// Line-in: the MiSTer's LTC2308 ADC (header pins) as the ZX core wires it.
// Its parallel/serial bus is the top's ADC_BUS; dout/active cross into
// clk_bus with two flops and are sampled only at the second stage.
ltc2308_tape u_tape_adc (
	.reset(por_reset),
	.clk(clk_sys),
	.ADC_BUS(ADC_BUS),
	.dout(tape_adc),
	.active(tape_adc_act)
);

reg [1:0] tape_adc_s, tape_adc_act_s;
always @(posedge clk_bus) begin
	tape_adc_s     <= {tape_adc_s[0], tape_adc};
	tape_adc_act_s <= {tape_adc_act_s[0], tape_adc_act};
end

// profi reads not(TAPE_IN) as the EAR bit, exactly like the ZX core's
// ula_tape_in = ~tape_vin, so the player output goes in unchanged.
assign tape_in  = tape_active ? tape_audio : (tape_adc_act_s[1] ? tape_adc_s[1] : 1'b0);
assign LED_USER = tape_active;

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
// the clock enable. While it is not locked yet it passes the machine VSYNC
// through as a fallback, so the scaler never sees a frame without sync.
wire vf_vblank, vf_vs;
vframe_gen vframe_gen (
	.clk(clk_vid),
	.ce(vid_ce),
	.hs_n(vid_r[2]),
	.blank(vid_r[0]),
	.vs_n(vid_r[1]),
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


///////////////////////   MIDI: MIDILINK AND MT32-PI   ////////////////////

// The machine's MIDI out is the TurboSound's (AY port A bit 2), as on the
// ZX 128. It takes two routes: the HPS UART for MidiLink (OSD UART mode =
// MIDI, then a PC-side MidiLink can reach a remote mt32-pi, MUNT,
// FluidSynth or a USB MIDI adapter) and an mt32-pi on the MiSTer USER port
// through sys/mt32pi.sv, whose I2S audio rtl/sound/mt32_mix.sv mixes into
// AUDIO_L/R. The MT32-pi OSD page picks the Pi's synth and ROM; "Use
// MT32-pi: No" silences the USER-port Pi only, never MidiLink.
wire [6:0]  mt32_user_out;
wire [15:0] mt32_i2s_l, mt32_i2s_r;
wire        mt32_available;
wire        midi_tx_to_pi;
wire        uart_txd;
wire [15:0] mix_l, mix_r;
wire [7:0]  mt32_mode, mt32_rom, mt32_sf;
wire        mt32_newmode, mt32_lcd_en, mt32_lcd_pix, mt32_lcd_update;

mt32pi u_mt32pi (
	.CLK_AUDIO(CLK_AUDIO),
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.USER_IN(USER_IN),
	.USER_OUT(mt32_user_out),

	.reset(RESET | status[0]),
	.midi_tx(midi_tx_to_pi),
	.midi_rx(),

	.mt32_i2s_l(mt32_i2s_l),
	.mt32_i2s_r(mt32_i2s_r),
	.mt32_available(mt32_available),

	.mt32_mode_req(status[28]),
	.mt32_rom_req(status[30:29]),
	.mt32_sf_req(8'd0),

	.mt32_mode(mt32_mode),
	.mt32_rom(mt32_rom),
	.mt32_sf(mt32_sf),
	.mt32_newmode(mt32_newmode),
	.mt32_lcd_en(mt32_lcd_en),
	.mt32_lcd_pix(mt32_lcd_pix),
	.mt32_lcd_update(mt32_lcd_update)
);

mt32_mix u_mt32_mix (
	.clk(CLK_AUDIO),
	.emu_l(profi_audio_l),
	.emu_r(profi_audio_r),
	.pi_l(mt32_i2s_l),
	.pi_r(mt32_i2s_r),
	.pi_available(mt32_available),
	.pi_disable(status[27]),
	.midi_tx(midi_tx),
	.uart_mode(uart_mode),
	.audio_l(mix_l),
	.audio_r(mix_r),
	.midi_tx_to_pi(midi_tx_to_pi),
	.uart_txd(uart_txd)
);

assign USER_OUT = mt32_user_out;  // [1] MIDI TX, [0] SDA/RX, [6:2] held high
assign UART_TXD = uart_txd;       // MidiLink; idle high outside UART mode 3

///////////////////////   AUDIO   //////////////////////////////////////////

assign AUDIO_L = mix_l;
assign AUDIO_R = mix_r;
assign AUDIO_S = 1;               // signed samples
assign AUDIO_MIX = 0;

endmodule

`default_nettype wire
