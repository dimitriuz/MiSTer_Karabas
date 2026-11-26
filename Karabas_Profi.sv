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
	"Karabas_Profi;UART115200:31250,MIDI;",
	"S2,HDFIMGVHD,IDE 0;",
	"S3,HDFIMGVHD,IDE 1;",
	"-;",
	"S1,VHD,SD Card;",
	"-;",
	"S4,TRDIMGSCL,Floppy A (TRD);",
	"S5,TRDIMGSCL,Floppy B (TRD);",
	"F1,FDIUDITD0SCL,Floppy A (raw);",
	"F2,FDIUDITD0SCL,Floppy B (raw);",
	"O[35:34],Disk layout,Auto,TR-DOS,CP/M;",
	"-;",
	"P3,Tape;",
	"P3S0,TAPTZXCSW,Tape;",
	"P3T[31],Tape play/pause;",
	"P3T[32],Tape previous block;",
	"P3T[33],Tape next block;",
	"P3-;",
	"P3O[56:55],Tape monitor,Off,In,Out,Both;",
	"-;",
	"O[2:1],ROM Bank,ROMain,PQ-DOS,FDImage,FATALL;",
	"O[26],Mode,Pentagon,48k;",
	"O[9:8],Turbo,Off,2x,4x,8x;",
	"O[16],DivMMC,Off,On;",
	"O[18],Pause,Off,On;",
	"-;",
	"O[12:10],Joystick L,Kempston,Sinclair1,Sinclair2,Cursor,QAOPM,QAOPS;",
	"O[15:13],Joystick R,Sinclair1,Sinclair2,Cursor,QAOPM,QAOPS,Kempston;",
	"O[17],Keyboard,Profi XT,Spectrum;",
	"-;",
	"O[6:4],PSG Mix,AY ACB,AY Mono,YM ABC,YM ACB,YM Mono,AY ABC;",
	"O[3],Covox,On,Off;",
	"P2,MT32-pi;",
	"P2O[27],Use MT32-pi,Yes,No;",
	"P2O[39:38],Show Info,No,Yes,LCD-On,LCD-Auto;",
	"P2O[52:51],LCD Type,Auto,SSD1306,SH1106,HD44780;",
	"P2O[54:53],HD44780 Size,20x4,16x2,20x2,16x4;",
	"P2-;",
	"P2-,Default Config:;",
	"P2O[50:48],Synth,Munt,FluidSynth,EmuSC,Nuked SC-55,MU50;",
	"P2O[30:29],Munt ROM,MT-32 v1,MT-32 v2,CM-32L;",
	"P2O[47:44],SoundFont,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15;",
	"P2-;",
	"P2T[43],Reset Hanging Notes;",
	"-;",
	"P1,Video;",
	"P1O[22:21],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[25:23],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1O[7],VSync,50 Hz,60 Hz;",
	"-;",
	"O[36],Serial channel,ESP,USB;",
	"O[37],FDC trace to UART,Off,On;",
	"-;",
	"T[19],GS Reset;",
	"T[20],NMI;",
	"R[0],Reset;",
	"I,",
	"MT32-pi: SoundFont #0,",
	"MT32-pi: SoundFont #1,",
	"MT32-pi: SoundFont #2,",
	"MT32-pi: SoundFont #3,",
	"MT32-pi: SoundFont #4,",
	"MT32-pi: SoundFont #5,",
	"MT32-pi: SoundFont #6,",
	"MT32-pi: SoundFont #7,",
	"MT32-pi: SoundFont #8,",
	"MT32-pi: SoundFont #9,",
	"MT32-pi: SoundFont #10,",
	"MT32-pi: SoundFont #11,",
	"MT32-pi: SoundFont #12,",
	"MT32-pi: SoundFont #13,",
	"MT32-pi: SoundFont #14,",
	"MT32-pi: SoundFont #15,",
	"MT32-pi: MT-32 v1,",
	"MT32-pi: MT-32 v2,",
	"MT32-pi: CM-32L,",
	"MT32-pi: Unknown mode,",
	"MT32-pi: EmuSC,",
	"MT32-pi: Nuked SC-55,",
	"MT32-pi: MU50;",
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
wire        mt32_info_req;        // OSD info message: the MT32-pi mode changed (below)
wire  [7:0] mt32_info_val;
wire  [7:0] vm_r, vm_g, vm_b;     // the video mixer's output, before the MT32-pi LCD overlay
wire [7:0] uart_mode;             // OSD "UART mode" select: 3 = MIDI

// keyboard shortcuts (rtl/host/hotkeys.sv): Ctrl+Alt+Del reset, Ctrl+Alt+End NMI,
// Ctrl+Alt+PgUp turbo cycle (written back to the OSD status)
wire        hk_reset, hk_nmi, hk_turbo_set;
wire  [1:0] hk_turbo;
wire osd_reset = status[0] | buttons[1] | RESET | hk_reset;
// what mcu_emu sees: the status with the NMI shortcut OR'd into the NMI trigger bit
wire [127:0] status_mcu = status | {107'd0, hk_nmi, 20'd0};

wire        ioctl_download;
wire [15:0] ioctl_index;
// The ioctl window is shared: mcu_emu raises its part while its boot.rom
// frames go out, fdd_src while an FD image streams in (both pause Main,
// never both at once in practice: the boot stream finishes long before the
// first FD mount). hps_io itself never reads ioctl_wait (only the ARM
// throttles on it), so an OR is safe.
wire mcu_ioctl_wait;
wire fdd_ioctl_wait;
wire ioctl_wait = mcu_ioctl_wait | fdd_ioctl_wait;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [7:0]  ioctl_dout;

// MiSTer disk slots: the mount handshake and the SD block interface hps_io
// shares with the core. VDNUM=6 (six slots), BLKSZ=2 (512-byte sectors), so
// sd_buff_addr is [13:0] and the block readers use its low 9 bits:
//   0  the tape file (S0, the TAPE section), rtl/tape/tape_src.sv
//   1  the Z-Controller's SD card (S1), sys/sd_card.sv, one sector at a time
//   2  the IDE hard disk, device 0 (S2, "IDE 0"), rtl/disk/img_src.sv slot a
//   3  the IDE hard disk, device 1 (S3, "IDE 1"), rtl/disk/img_src.sv slot b
//   4  floppy drive A: (S4, "FD A:"), rtl/disk/fdd_src.sv drive a
//   5  floppy drive B: (S5, "FD B:"), rtl/disk/fdd_src.sv drive b
// Only slots 1..5 can be written (the SD card, the IDE disks, the FD
// images); the tape is read-only, so sd_wr[0] stays 0.
wire  [5:0]  img_mounted;
wire         img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba [6];
wire   [5:0] sd_blk_cnt [6];
wire   [5:0] sd_rd, sd_wr, sd_ack;
wire  [13:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din [6];
wire         sd_buff_wr;

// Mount settle. Main mounts an MGL's files some time after the core starts,
// and a mount resets the card's queued transfer (sys/sd_card.sv clears its
// sector pointers) and img_src's mount registers. The machine's ROM probes
// both drives within its first few hundred milliseconds; a probe that is in
// flight when a mount lands never finishes, and the machine stops on the
// loader screen with the Drive line drawn. So mcu_emu does not begin the
// boot.rom stream until the mounts are settled (rtl/host/mount_settle.sv):
// 1.34 s after the last disk mount, and at most 3 s from power-up when no
// disk mount has arrived at all, so a core loaded without a file still
// boots. Releasing at power-up instead let the machine's probe overtake a
// late mount, which on the board stops the boot about one time in three.
// Card media. With no file mounted on the card's slot the model still
// answers commands and then waits forever for a sector the HPS will never
// send (its CMD17 has no timeout), so a ROM that probes the card hangs on
// the Drive line instead of falling back to the disks. Holding the card in
// reset until a file is mounted makes an absent card look absent: MISO
// reads 1 and nothing answers, which is what the ROM's probe expects.
reg sd_media = 1'b0;
always @(posedge clk_sys) begin
	if (por_reset)          sd_media <= 1'b0;
	else if (img_mounted[1]) sd_media <= (img_size != 64'd0);
end

wire mounts_settled;
mount_settle u_settle (
	.clk(clk_sys),
	.reset(por_reset),
	.mounted(img_mounted),
	.settled(mounts_settled)
);

assign sd_blk_cnt[0] = 6'd0;
assign sd_blk_cnt[1] = 6'd0;
assign sd_blk_cnt[2] = 6'd0;
assign sd_blk_cnt[3] = 6'd0;
assign sd_blk_cnt[4] = 6'd0;   // one 512-byte sector per request (BLKSZ=2)
assign sd_blk_cnt[5] = 6'd0;
assign sd_wr[0]      = 1'b0;
assign sd_buff_din[0] = 8'd0;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(6), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_in({status[127:10], hk_turbo, status[7:0]}),
	.status_set(hk_turbo_set),
	.status_menumask(16'd0),
	.info_req(mt32_info_req),
	.info(mt32_info_val),

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

hotkeys u_hotkeys (
	.clk(clk_sys),
	.reset(por_reset | RESET),
	.ps2_key(ps2_key),
	.turbo_now(status[9:8]),
	.hk_reset(hk_reset),
	.hk_nmi(hk_nmi),
	.turbo_new(hk_turbo),
	.turbo_set(hk_turbo_set)
);

wire mcu_cs_n, mcu_sck, mcu_mosi, mcu_miso;
wire [23:0] mcu_last_reply;   // for later stages
wire        mcu_reply_valid;

// ---------------- the USB-RS232 byte channel (stage 5) ------------------
// uart_route hands the machine's serial bytes to/from mcu_emu's MCU link. It
// has no receive strobe, only the byte and kg_mcu_uart's counter, so the
// strobe is made here from a change of that counter: the clock the counter
// moves is also the clock its usb_rx_data is new (the module writes the two
// together), and mcu_emu latches with a nonblocking assignment in that same
// clock. The counter it sends *to* the machine is its own (first frame idx 1),
// so nothing here has to line up with the route's.
// uart_reset: power-on and the async board reset only, like ps2_hid next to
// it - a core (OSD) reset must not re-initialise a module in the middle of
// the SPI link's handshake, and the route's channel latch restarts anyway.
wire uart_reset = por_reset | RESET;

wire [7:0] route_usb_rx_data;
wire [7:0] route_usb_rx_idx;
reg  [7:0] route_usb_rx_idx_q = 8'd0;

always @(posedge clk_sys) begin
    if (uart_reset) route_usb_rx_idx_q <= 8'd0;
    else            route_usb_rx_idx_q <= route_usb_rx_idx;
end

// gated with the reset so the route's counter falling back to 0 cannot be
// read as a received byte
wire       mcu_uart_rx_stb  = !uart_reset && (route_usb_rx_idx != route_usb_rx_idx_q);
wire [7:0] mcu_uart_rx_data = route_usb_rx_data;
wire [7:0] mcu_uart_tx_data;
wire       mcu_uart_tx_stb;

mcu_emu u_mcu (
	.clk(clk_sys),
	.reset(por_reset),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(mcu_ioctl_wait),

	.status(status_mcu),
	.osd_reset(osd_reset),

	.kb_report(kb_report),
	.kb_changed(kb_changed),

	.rtc(hps_rtc),
	.ps2_mouse(ps2_mouse),
	.ps2_mouse_ext(ps2_mouse_ext),
	.joy0(joystick_0),
	.joy1(joystick_1),

	// the machine's USB-RS232 port as bytes (stage 5, rtl/host/uart_route.sv)
	.uart_rx_data(mcu_uart_rx_data),
	.uart_rx_stb(mcu_uart_rx_stb),
	.uart_tx_data(mcu_uart_tx_data),
	.uart_tx_stb(mcu_uart_tx_stb),

	.mem_ready(mem_ready),
	.mounts_settled(mounts_settled),

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

// the ESP wire channel (stage 5): the machine's UART pins, wired to
// rtl/host/uart_route.sv; esp_cts arrives but is not forwarded (no CTS path
// into the tty), and esp_rx leaves a clk_sys register into the machine's own
// two-flop input stage.
wire esp_tx, esp_cts, esp_rx;

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

// ---------------- The floppy drives (stage 4c) -------------------------
// Two drives on the VG93 FDC inside profi: rtl/disk/floppy.sv is the drive
// model (heads, flux, index), rtl/disk/fdd_store.sv keeps the tracks in
// DDR3 and the written sectors, rtl/disk/fdd_src.sv owns the HPS files of
// the disk slots 4 and 5 (the images). The FDC pins live on clk_bus.
wire [1:0] fdc_drive;            // one-hot {B,A}, motor-gated in hrdy_fdc
wire       fdc_motor, fdc_dir, fdc_step, fdc_side_n;
wire       fdc_wdata, fdc_wgate;
wire       fdc_index, fdc_tr00, fdc_wprt_chip, fdc_rdata;
wire       fdc_swap;             // profi FDC_SWAP_O: the swap cable
wire [1:0] fdc_wprt;             // fdd_src's write-protects, clk_sys below

// The drives share profi's reset, the PLL lock: during a relock the FDC is
// stopped too, and half-stepped heads simply re-restore on the next
// command. fdd_src and fdd_store reset at power-on only - their fill and
// drain handshakes must not be pulled apart mid-transfer, and the mounted
// images stay across a machine reset.
//
// Ruling R10: ds80 (vmode[3], a profi register on clk_bus) and the swap
// cable go into the drive model through two flops; the write-protects of
// fdd_src cross from clk_sys the same way.
reg [1:0] ds80_sync = 2'b00;
always @(posedge clk_bus) ds80_sync <= {ds80_sync[0], vmode[3]};
wire      ds80_s = ds80_sync[1];

reg [1:0] fdc_swap_sync = 2'b00;
always @(posedge clk_bus) fdc_swap_sync <= {fdc_swap_sync[0], fdc_swap};

reg [1:0] fdc_wp_s1 = 2'b00, fdc_wp_s2 = 2'b00;   // clk_sys -> clk_bus
always @(posedge clk_bus) begin
	fdc_wp_s1 <= fdc_wprt;
	fdc_wp_s2 <= fdc_wp_s1;
end

// The flux-cell cadence, the same two ratios tb_floppy verified:
// clk_bus * 4/225 = 0.5 MHz at 28.125 MHz, * 14/675 = 0.5 MHz at 24.107.
wire [15:0] fdc_cell_num = ds80_s ? 16'd14 : 16'd4;
wire [15:0] fdc_cell_den = ds80_s ? 16'd675 : 16'd225;

// The FDC bus cycle for rtl/host/fdc_trace.sv (profi.vhd's DBG_FDC_* taps).
wire       dbg_fdc_wr, dbg_fdc_rd, dbg_fdc_ff, dbg_pc_fetch;
wire [15:0] dbg_pc;
wire  [7:0] dbg_pc_di;
wire [1:0] dbg_fdc_reg;
wire [7:0] dbg_fdc_d, dbg_fdc_q;

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

	.UART_RX(esp_rx),             // the HPS line as the machine's RX (stage 5)
	.UART_TX(esp_tx),             // the machine's wire TX, to uart_route
	.UART_CTS(esp_cts),           // accepted, deliberately unused
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

	.SD_CS_N(sd_ss_n),            // the Z-Controller's SPI on the SD card
	.SD_DO(sd_miso),
	.SD_DI(sd_mosi),
	.SD_CLK(sd_sck),
	.SD_DET_N(1'b1),

	// hdf_ata's sector requests out to the top's sector engine and the
	// 512 strobe bytes back (rtl/disk/img_src.sv, disk slots 2/3)
	.SDC_IMG_MOUNTED(sdc_img_mounted),
	.SDC_IMG_SIZE(sdc_img_size),
	.SDC_RD(sdc_rd),
	.SDC_WR(sdc_wr),
	.SDC_SECTOR(sdc_sector),
	.SDC_BYTE_OUT_DATA(sdc_byte_out_data),
	.SDC_BUSY(sdc_busy),
	.SDC_DONE(sdc_done),
	.SDC_ERROR(sdc_error),
	.SDC_SLOT(sdc_slot),
	.SDC_BYTE_IN_STROBE(sdc_byte_in_strobe),
	.SDC_BYTE_ADDR(sdc_byte_addr),
	.SDC_BYTE_IN_DATA(sdc_byte_in_data),

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

	.FDC_INDEX(fdc_index),
	.FDC_DRIVE(fdc_drive),
	.FDC_MOTOR(fdc_motor),
	.FDC_DIR(fdc_dir),
	.FDC_STEP(fdc_step),
	.FDC_WDATA(fdc_wdata),
	.FDC_WGATE(fdc_wgate),
	.FDC_TR00(fdc_tr00),
	.FDC_WPRT(fdc_wprt_chip),
	.FDC_RDATA(fdc_rdata),
	.DBG_FDC_WR(dbg_fdc_wr),
	.DBG_FDC_RD(dbg_fdc_rd),
	.DBG_FDC_FF(dbg_fdc_ff),
	.DBG_FDC_REG(dbg_fdc_reg),
	.DBG_FDC_D(dbg_fdc_d),
	.DBG_FDC_Q(dbg_fdc_q),
	.DBG_PC_FETCH(dbg_pc_fetch),
	.DBG_PC(dbg_pc),
	.DBG_PC_DI(dbg_pc_di),
	.FDC_SIDE_N(fdc_side_n),
	.FDC_SWAP_O(fdc_swap)
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

	.ddr_busy(gs_busy),
	.ddr_burstcnt(),
	.ddr_addr(gs_addr),
	.ddr_dout(gs_dout),
	.ddr_dout_ready(gs_dout_ready),
	.ddr_rd(gs_rd),
	.ddr_din(gs_din),
	.ddr_be(gs_be),
	.ddr_we(gs_we)
);

assign DDRAM_CLK = gs_clk;

// The shared Avalon port: gs_mem is the priority master, the floppy drive
// store (rtl/disk/fdd_store.sv) is master 1. The two regions are disjoint
// (the GS cache at byte 0x3000_0000, the drive store above it), so no
// address translation is needed; the arbiter only shares busy. reset is the
// PLL lock like gs_mem's; the store keeps its own power-on reset (below).
wire        gs_busy;
wire [28:0] gs_addr;
wire [63:0] gs_din;
wire  [7:0] gs_be;
wire        gs_rd, gs_we;
wire [63:0] gs_dout;
wire        gs_dout_ready;

wire        f_busy;
wire [28:0] f_addr;
wire [63:0] f_din, f_dout;
wire  [7:0] f_be;
wire        f_req, f_rd, f_we;
wire        f_dout_ready;

ddr_arb u_ddr_arb (
	.clk(gs_clk),
	.reset(profi_areset),
	.g_req(gs_rd | gs_we),
	.g_addr(gs_addr),
	.g_din(gs_din),
	.g_be(gs_be),
	.g_rd(gs_rd),
	.g_we(gs_we),
	.g_busy(gs_busy),
	.g_dout(gs_dout),
	.g_dout_ready(gs_dout_ready),
	.f_req(f_req),
	.f_addr(f_addr),
	.f_din(f_din),
	.f_be(f_be),
	.f_rd(f_rd),
	.f_we(f_we),
	.f_busy(f_busy),
	.f_dout(f_dout),
	.f_dout_ready(f_dout_ready),
	.ddr_rd(DDRAM_RD),
	.ddr_we(DDRAM_WE),
	.ddr_addr(DDRAM_ADDR),
	.ddr_din(DDRAM_DIN),
	.ddr_be(DDRAM_BE),
	.ddr_burstcnt(DDRAM_BURSTCNT),
	.ddr_busy(DDRAM_BUSY),
	.ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY)
);


// ---------------- the floppy stack (stage 4c) --------------------------
// The three modules share toggle handshakes across their clock edges; the
// whole path was verified together in sim/tb_fdd_img.sv (the store and the
// image source) and sim/tb_floppy.sv (the drive against the real hrdy_fdc).

// store <-> image source (the fill and the drain, toggle handshakes)
wire        fill_tgl;
wire [31:0] fill_word;
wire        fill_ack_tgl;
wire [8:0]  drn_addr_b;
wire [7:0]  drn_q_b;
wire        drn_tgl;
wire [11:0] drn_info;
wire        drn_ack_tgl;

// drive <-> store (track reads and written sectors, clk_bus toggles)
wire        trk_req_tgl;
wire [8:0]  trk_req;
wire        trk_ack_tgl;
wire [9:0]  trk_ack;
wire [12:0] trk_len;
wire [12:0] trk_addr_b;
wire [8:0]  trk_q_b;
wire [9:0]  wr_addr;
wire [7:0]  wr_data;
wire        wr_we, wr_tgl, wr_ack_tgl;
wire [35:0] wr_info;

fdd_store u_fdd_store (
	.clk(gs_clk),                 // the DDR master's clock
	.reset(por_reset),            // power-on only: a card swap never stops
	.clk_bus(clk_bus),            // the machine's buffers
	.clk_sys(clk_sys),            // the drain host's side

	.f_addr(f_addr), .f_din(f_din), .f_be(f_be),
	.f_req(f_req), .f_rd(f_rd), .f_we(f_we),
	.f_busy(f_busy), .f_dout(f_dout), .f_dout_ready(f_dout_ready),

	.fill_tgl(fill_tgl), .fill_word(fill_word), .fill_ack_tgl(fill_ack_tgl),

	.trk_req_tgl(trk_req_tgl), .trk_req(trk_req),
	.trk_ack_tgl(trk_ack_tgl), .trk_ack(trk_ack), .trk_len(trk_len),
	.trk_addr_b(trk_addr_b), .trk_q_b(trk_q_b),
	.wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we),
	.wr_info(wr_info), .wr_tgl(wr_tgl), .wr_ack_tgl(wr_ack_tgl),

	.drn_addr_b(drn_addr_b), .drn_q_b(drn_q_b),
	.drn_tgl(drn_tgl), .drn_info(drn_info), .drn_ack_tgl(drn_ack_tgl)
);

// The drives themselves: the two models answer the FDC with the flux of the
// tracks the store keeps. The track RAMs' port A is the store's to write;
// port A's read side is unused (tb_floppy: the model mirrors the address
// only), so q_a reads 0.
floppy u_floppy (
	.clk(clk_bus),
	.reset(profi_areset),
	.ds80(ds80_s),
	.swap(fdc_swap_sync[1]),
	.cell_num(fdc_cell_num),
	.cell_den(fdc_cell_den),

	.fdc_drive(fdc_drive), .fdc_motor(fdc_motor), .fdc_step(fdc_step),
	.fdc_dir(fdc_dir), .fdc_side_n(fdc_side_n),
	.fdc_wgate(fdc_wgate), .fdc_wdata(fdc_wdata),
	.fdc_rdata(fdc_rdata), .fdc_index(fdc_index),
	.fdc_tr00(fdc_tr00), .fdc_wprt(fdc_wprt_chip),
	.wprt(fdc_wp_s2),

	.trk_req_tgl(trk_req_tgl), .trk_req(trk_req),
	.trk_ack_tgl(trk_ack_tgl), .trk_ack(trk_ack), .trk_len(trk_len),
	.trk_addr_a(), .trk_addr_b(trk_addr_b),
	.trk_q_a(9'd0), .trk_q_b(trk_q_b),

	.wr_tgl(wr_tgl), .wr_info(wr_info), .wr_ack_tgl(wr_ack_tgl),
	.wr_addr(wr_addr), .wr_data(wr_data), .wr_we(wr_we)
);

// The image source: the HPS files of slots 4 and 5 (FD A:, FD B:). One
// shared sector request, so the same lba and data byte go to both slots;
// only the selected one ever asks (sd_ack[5:4]).
wire [1:0] fdd_sd_rd, fdd_sd_wr;
wire [31:0] fdd_sd_lba;
wire [7:0] fdd_sd_din;
assign sd_rd[4]  = fdd_sd_rd[0];
assign sd_rd[5]  = fdd_sd_rd[1];
assign sd_wr[4]  = fdd_sd_wr[0];
assign sd_wr[5]  = fdd_sd_wr[1];
assign sd_lba[4] = fdd_sd_lba;
assign sd_lba[5] = fdd_sd_lba;
assign sd_buff_din[4] = fdd_sd_din;
assign sd_buff_din[5] = fdd_sd_din;

fdd_src u_fdd_src (
	.clk_sys(clk_sys),
	.reset_sys(por_reset),

	.img_mounted(img_mounted[5:4]),
	.img_size(img_size),
	.img_readonly(img_readonly),
	.sd_rd(fdd_sd_rd), .sd_wr(fdd_sd_wr),
	.sd_lba(fdd_sd_lba),
	.sd_ack(sd_ack[5:4]),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(fdd_sd_din),
	.sd_buff_wr(sd_buff_wr),

	.status(status),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(fdd_ioctl_wait),

	.wprt(fdc_wprt),

	.fill_tgl(fill_tgl), .fill_word(fill_word), .fill_ack_tgl(fill_ack_tgl),
	.drn_addr_b(drn_addr_b), .drn_q_b(drn_q_b),
	.drn_tgl(drn_tgl), .drn_info(drn_info), .drn_ack_tgl(drn_ack_tgl)
);
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
// memory port. tape.sv and its TZX engine rtl/tape/tzxplayer.vhd are copies
// of ZX-Spectrum_MISTer c2c4e6f with the deviations listed in files.qip;
// tape.sv's TAP and CSW decoders and its TZX engine play the file as it is; their
// pulses count `ce` ticks, so `ce` is the CPU's own enable: one pulse per
// T-state at whatever Turbo is set to.
//
// The three OSD triggers (T[33:31]) are two-flop synchronised into clk_bus
// and turned into 15-clock holds (a `ce`-sampled input needs the level to
// outlast the gap between two `ce` pulses). `tape_active` selects the tape
// audio for the machine's EAR input; with no tape playing, the LTC2308
// line-in on the MiSTer ADC header is the source when it sees a signal, as
// on the ZX core. A freshly mounted tape is paused: the player's play_pause
// is 1 until the play/pause trigger.
wire        tape_ready;
wire  [1:0] tape_mode;        // always CSW: tape_src forces the converter's
                              // stream, the sniffed mode is its internal one
wire [24:0] tape_size;
wire        tape_rd;
wire [24:0] tape_addr;
wire  [7:0] tape_din;
wire        tape_rd_en;
wire        tape_active, tape_audio;
wire        tape_pause, tape_prev, tape_next;   // OSD trigger levels
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
// one clk_bus earlier; a rising edge of the second stage sets a 15-clock hold.
// tape.sv samples these controls only on its `ce` input, the CPU's T-state
// enable: at Turbo Off that is one clk_bus in eight, so a one-clock pulse
// would usually be missed. 15 clocks span at least one `ce` pulse at every
// Turbo setting (two at Turbo Off), and tape.sv reacts to the rising edge it
// sees, so the longer level still acts exactly once.
reg [2:0] tape_trig_s [0:2];
reg [3:0] tape_trig_hold [0:2];
always @(posedge clk_bus) begin
	tape_trig_s[0] <= {tape_trig_s[0][1:0], status[31]};
	tape_trig_s[1] <= {tape_trig_s[1][1:0], status[32]};
	tape_trig_s[2] <= {tape_trig_s[2][1:0], status[33]};
	if (tape_trig_s[0][1] & ~tape_trig_s[0][2]) tape_trig_hold[0] <= 4'hF;
	else if (tape_trig_hold[0]) tape_trig_hold[0] <= tape_trig_hold[0] - 4'd1;
	if (tape_trig_s[1][1] & ~tape_trig_s[1][2]) tape_trig_hold[1] <= 4'hF;
	else if (tape_trig_hold[1]) tape_trig_hold[1] <= tape_trig_hold[1] - 4'd1;
	if (tape_trig_s[2][1] & ~tape_trig_s[2][2]) tape_trig_hold[2] <= 4'hF;
	else if (tape_trig_hold[2]) tape_trig_hold[2] <= tape_trig_hold[2] - 4'd1;
end

assign tape_pause = |tape_trig_hold[0];
assign tape_prev  = |tape_trig_hold[1];
assign tape_next  = |tape_trig_hold[2];

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
// tape.sv's `active` drops when its read counter hits 0, and the TZX engine
// reads a block's last byte *before* it plays it: with a TZX that ends in a data
// block `active` fell a whole byte early (sim: 7.97 ms against the last audio
// edge at 8.70 ms), the EAR input switched to the line-in and the ROM lost the
// checksum byte (`R Tape loading error`, or a hang at the end of the load).
// For a TAP or TZX the tape therefore stays selected for 2^22 clk_bus (about 150 ms)
// after `active` falls; a byte lasts at most 8 ms at Turbo Off.
reg [21:0] tape_hold = 22'd0;
always @(posedge clk_bus) begin
	if (tape_active)         tape_hold <= {22{1'b1}};
	else if (|tape_hold)     tape_hold <= tape_hold - 22'd1;
end
wire tape_sel = tape_active | (tape_mode != 2'd1 && |tape_hold);

assign tape_in  = tape_sel ? tape_audio : (tape_adc_act_s[1] ? tape_adc_s[1] : 1'b0);
assign LED_USER = tape_active;

///////////////////////   STORAGE: SD CARD AND IDE IMAGES   //////////////////

// The Z-Controller's SPI bus (profi's SD_* pins, driven by zc_spi from the
// Z80 side) hosts a real SD card as MiSTer disk slot 1: sys/sd_card.sv
// answers its CMD17/CMD24 with the mounted file's sectors through hps_io.
// The card model is SDHC (block addressing, so CMD1/ACMD41 never pass), and
// it is reset by the power-on reset only: a card is not reset by the
// machine's RESET item. Its chip select is the card's active-low SS (the
// card treats ss = 1 as deselected), exactly what profi's SD_CS_N is;
// sim/tb_sd_spi.sv pins that polarity on the unmodified card.
wire sd_ss_n, sd_sck, sd_mosi, sd_miso;

// The card's SPI side runs on clk_bus, the clock zc_spi makes sck, mosi and
// the sampling of miso from. Board, 2026-11-18: with clk_spi = clk_sys (50
// MHz) the card sampled the machine's 14 MHz sck asynchronously and its
// answers came back with bits repeated (CMD8's R7 read 0 0 0 58 175 for
// 0 0 1 170 255; the ROM's SD probe then never finished). sim/tb_sd_zc.sv
// pins the clocking. The card's sd_rd/sd_wr leave that domain here and
// reach hps_io through two flops; sd_lba is stable long before sd_rd.
wire sd_card_rd, sd_card_wr;
reg [1:0] sd_rd_s = 2'b00, sd_wr_s = 2'b00;
always @(posedge clk_sys) begin
	sd_rd_s <= {sd_rd_s[0], sd_card_rd};
	sd_wr_s <= {sd_wr_s[0], sd_card_wr};
end
assign sd_rd[1] = sd_rd_s[1];
assign sd_wr[1] = sd_wr_s[1];

sd_card u_sd (
	.clk_sys(clk_sys),
	.reset(por_reset | ~sd_media),
	.sdhc(1'b1),
	.img_mounted(img_mounted[1]),
	.img_size(img_size),
	.sd_lba(sd_lba[1]),
	.sd_rd(sd_card_rd),
	.sd_wr(sd_card_wr),
	.sd_ack(sd_ack[1]),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din[1]),
	.sd_buff_wr(sd_buff_wr),
	.clk_spi(clk_bus),
	.ss(sd_ss_n),
	.sck(sd_sck),
	.mosi(sd_mosi),
	.miso(sd_miso)
);

// The two IDE hard disks (MiSTer disk slots 2 and 3, OSD "IDE 0"/"IDE 1").
// On the Karabas Go the sector engine behind the machine's disk interface
// (img_sdc, the MCU file mounter's) lived inside profi and served both the
// Z-Controller and hdf_ata; here it is rtl/disk/img_src.sv on MiSTer disk
// slots 2/3, and profi's SDC_* ports are hdf_ata's side of the same
// handshake (a request level, busy, done, error, and 512 byte strobes).
// The engine's hps_io side runs on clk_sys, its machine side on CLK_BUS.
wire  [7:0] sdc_img_mounted;
wire [63:0] sdc_img_size;
wire  [7:0] sdc_rd, sdc_wr, sdc_byte_out_data, sdc_byte_in_data;
wire [31:0] sdc_sector;
wire  [2:0] sdc_slot;
wire  [8:0] sdc_byte_addr;
wire        sdc_busy, sdc_done, sdc_error, sdc_byte_in_strobe;

img_src u_img (
	.clk_sys(clk_sys),
	.reset_sys(por_reset),
	.img_mounted(img_mounted[3:2]),
	.img_size(img_size),
	.lba_a(sd_lba[2]),
	.rd_a(sd_rd[2]),
	.wr_a(sd_wr[2]),
	.ack_a(sd_ack[2]),
	.lba_b(sd_lba[3]),
	.rd_b(sd_rd[3]),
	.wr_b(sd_wr[3]),
	.ack_b(sd_ack[3]),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din_a(sd_buff_din[2]),
	.sd_buff_din_b(sd_buff_din[3]),
	.sd_buff_wr(sd_buff_wr),

	.clk(clk_bus),
	.reset(profi_areset),
	.sdc_rd(sdc_rd),
	.sdc_wr(sdc_wr),
	.sdc_sector(sdc_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_byte_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_byte_in_data),
	.sdc_byte_out_data(sdc_byte_out_data),
	.sdc_img_mounted(sdc_img_mounted),
	.sdc_img_size(sdc_img_size)
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

	.VGA_R(vm_r),                 // onto the MiSTer outputs through the LCD overlay
	.VGA_G(vm_g),
	.VGA_B(vm_b),
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
// "Reset Hanging Notes" (status[43], a button) resets the mt32pi link, which makes
// the Pi drop its notes - the same way as the other cores' MT32-pi pages
wire        mt32_rst = RESET | status[0] | status[43];
// OSD Synth item order (Munt first, the old default) -> the module's encoding:
// 0 FluidSynth (0xA2), 1 Munt (0xA1), 2 EmuSC (0xA3), 3 Nuked SC-55 (0xA4), 4 MU50 (0xA5).
// The last three need the ckeisc/mt32-pi fork; a stock Pi treats them as FluidSynth.
wire  [2:0] mt32_synth_req = (status[50:48] == 3'd0) ? 3'd1 :
                             (status[50:48] == 3'd1) ? 3'd0 : status[50:48];
wire [15:0] mt32_i2s_l, mt32_i2s_r;
wire        mt32_available;
wire        midi_tx_to_pi;
wire        midi_line;            // mt32_mix's MidiLink line, to uart_route
wire        uart_txd;             // the driven HPS line (uart_route's output)
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

	.reset(mt32_rst),
	.midi_tx(midi_tx_to_pi),
	.midi_rx(),

	.mt32_i2s_l(mt32_i2s_l),
	.mt32_i2s_r(mt32_i2s_r),
	.mt32_available(mt32_available),

	.mt32_synth_req(mt32_synth_req),
	.mt32_rom_req(status[30:29]),
	.mt32_sf_req({12'd0, status[47:44]}),
	.mt32_lcd_type(status[52:51]),
	.mt32_hd_size(status[54:53]),

	.mt32_mode(mt32_mode),
	.mt32_rom(mt32_rom),
	.mt32_sf(mt32_sf),
	.mt32_newmode(mt32_newmode),
	.mt32_lcd_en(mt32_lcd_en),
	.mt32_lcd_pix(mt32_lcd_pix),
	.mt32_lcd_update(mt32_lcd_update)
);

// OSD info message ("Show Info: Yes"): when the Pi reports a new mode, show which
// SoundFont or Munt ROM it runs. The index is the 1-based `I,` string of CONF_STR.
reg       mt32_newmode_d = 1'b0;
reg       mt32_info_req_r = 1'b0;
reg [7:0] mt32_info_disp = 8'd0;
always @(posedge clk_sys) begin
	mt32_newmode_d <= mt32_newmode;
	mt32_info_req_r <= (mt32_newmode_d ^ mt32_newmode) && (status[39:38] == 2'd1);

	// 1-based index into the "I," strings: 1..16 SoundFont #0..#15, 17..19 MT-32 v1 /
	// v2 / CM-32L, 20 unknown, 21 EmuSC, 22 Nuked SC-55, 23 MU50
	mt32_info_disp <= (mt32_mode == 8'hA2) ? (8'd1 + {4'd0, mt32_sf[3:0]}) :
	                  (mt32_mode == 8'hA1 && mt32_rom == 8'd0) ? 8'd17 :
	                  (mt32_mode == 8'hA1 && mt32_rom == 8'd1) ? 8'd18 :
	                  (mt32_mode == 8'hA1 && mt32_rom == 8'd2) ? 8'd19 :
	                  (mt32_mode == 8'hA3) ? 8'd21 :
	                  (mt32_mode == 8'hA4) ? 8'd22 :
	                  (mt32_mode == 8'hA5) ? 8'd23 : 8'd20;

	if (mt32_rst) begin
		mt32_newmode_d <= mt32_newmode;
		mt32_info_req_r <= 1'b0;
	end
end
assign mt32_info_req = mt32_info_req_r;
assign mt32_info_val = mt32_info_disp;

// The Pi's LCD picture over the video ("Show Info: LCD-On" always, "LCD-Auto" for 2 s
// after each LCD update). It replaces the two top bits of each colour.
reg [31:0] mt32_lcd_timeout = 32'd0;
reg        mt32_lcd_update_d = 1'b0;
reg        mt32_lcd_on = 1'b0;
always @(posedge clk_sys) begin
	mt32_lcd_update_d <= mt32_lcd_update;

	if (mt32_rst) begin
		mt32_lcd_timeout <= 32'd0;
		mt32_lcd_update_d <= mt32_lcd_update;
		mt32_lcd_on <= 1'b0;
	end
	else begin
		if (mt32_lcd_timeout != 0) mt32_lcd_timeout <= mt32_lcd_timeout - 1'd1;

		if (status[39:38] == 2'd2) mt32_lcd_on <= 1'b1;
		else if (status[39:38] != 2'd3) mt32_lcd_on <= 1'b0;
		else begin
			if (mt32_lcd_timeout == 0) mt32_lcd_on <= 1'b0;
			if (mt32_lcd_update_d ^ mt32_lcd_update) begin
				mt32_lcd_on <= 1'b1;
				mt32_lcd_timeout <= 32'd100_000_000;   // 2 s of clk_sys
			end
		end
	end
end

wire mt32_lcd = mt32_lcd_on & mt32_lcd_en;
assign VGA_R = mt32_lcd ? {{2{mt32_lcd_pix}}, vm_r[7:2]} : vm_r;
assign VGA_G = mt32_lcd ? {{2{mt32_lcd_pix}}, vm_g[7:2]} : vm_g;
assign VGA_B = mt32_lcd ? {{2{mt32_lcd_pix}}, vm_b[7:2]} : vm_b;

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
	.uart_txd(midi_line)
);


///////////////////////   SERIAL: THE HPS UART   ///////////////////////////

// Stage 5: the machine's two serial channels on Main_MiSTer's /dev/ttyS1.
// The OSD `Serial channel` item (status[36], MiSTer-side only - it is not a
// KG soft switch, so it is not in rtl/host/osd_items.svh) picks the ESP wires
// or the ZiFi/EVO USB byte channel; UART mode MIDI (uart_mode == 3) keeps
// priority over both and is exactly mt32_mix's line, as before.
// The FDC trace (OSD `FDC trace to UART`, status[37]) takes the USB byte channel:
// it forces the channel to USB and replaces the MCU's bytes while it is on, so
// `cat /dev/ttyS1` on the board shows the log (docs/dev/fdc-trace.md).
wire       fdc_trace_en = status[37];
wire [7:0] trace_tx_data, pc_tx_data;
wire       trace_tx_wr, pc_tx_wr, trace_burst_end, trace_idle;
fdc_trace u_fdc_trace (
	.clk_bus(clk_bus), .clk_sys(clk_sys), .enable(fdc_trace_en),
	.dbg_wr(dbg_fdc_wr), .dbg_rd(dbg_fdc_rd), .dbg_ff(dbg_fdc_ff),
	.dbg_reg(dbg_fdc_reg), .dbg_d(dbg_fdc_d), .dbg_q(dbg_fdc_q),
	.tx_data(trace_tx_data), .tx_wr(trace_tx_wr),
	.burst_end(trace_burst_end), .idle(trace_idle)
);
// the opcode fetches that follow a long data read (the disk loader's first moves)
pc_trace u_pc_trace (
	.clk_bus(clk_bus), .clk_sys(clk_sys), .enable(fdc_trace_en),
	.trig(trace_burst_end), .fetch(dbg_pc_fetch), .a(dbg_pc), .di(dbg_pc_di),
	.other_idle(trace_idle),
	.tx_data(pc_tx_data), .tx_wr(pc_tx_wr)
);

uart_route u_uart_route (
	.clk(clk_sys),
	.reset(uart_reset),
	.channel(status[36] | fdc_trace_en),
	.uart_mode(uart_mode),
	.esp_tx(esp_tx),
	.esp_cts(esp_cts),
	.esp_rx(esp_rx),
	.usb_tx_data(fdc_trace_en ? (pc_tx_wr ? pc_tx_data : trace_tx_data) : mcu_uart_tx_data),
	.usb_tx_wr(fdc_trace_en ? (trace_tx_wr | pc_tx_wr) : mcu_uart_tx_stb),
	.usb_rx_data(route_usb_rx_data),
	.usb_rx_idx(route_usb_rx_idx),
	.uart_rxd(UART_RXD),
	.midi_line(midi_line),
	.uart_txd(uart_txd)
);

assign USER_OUT = mt32_user_out;  // [1] MIDI TX, [0] SDA/RX, [6:2] held high
// Debug beacon (rtl/host/core_beacon.sv): a heartbeat line on the HPS UART whatever the
// machine does, to tell a dead core (no video sync: Main_MiSTer then spins in findPLLpar)
// from a running one. It shares the line with MIDI / USB / ESP, so it is a debug option:
// BEACON = 0 removes it.
localparam BEACON = 0;
reg [10:0] bc_bus = 11'd0;
reg [11:0] bc_mem = 12'd0;
reg [11:0] bc_vid = 12'd0;
reg  [9:0] bc_cpu = 10'd0;
always @(posedge clk_bus) begin
	bc_bus <= bc_bus + 11'd1;
	if (ena_cpu_o) bc_cpu <= bc_cpu + 10'd1;
end
always @(posedge clk_sdr) bc_mem <= bc_mem + 12'd1;
always @(posedge clk_vid) bc_vid <= bc_vid + 12'd1;
wire beacon_tx;
core_beacon u_beacon (
	.clk(clk_sys),
	.flags({profi_areset, profi_reset, mem_ready, 5'd0}),
	.t_bus(bc_bus[10]), .t_mem(bc_mem[11]), .t_vid(bc_vid[11]),
	.t_vs(VGA_VS), .t_cpu(bc_cpu[9]),
	.tx(beacon_tx)
);
assign UART_TXD = BEACON ? (uart_txd & beacon_tx) : uart_txd;   // MIDI, USB bytes, ESP wires (+ beacon)

///////////////////////   AUDIO   //////////////////////////////////////////

assign AUDIO_L = mix_l;
assign AUDIO_R = mix_r;
assign AUDIO_S = 1;               // signed samples
assign AUDIO_MIX = 0;

endmodule

`default_nettype wire
