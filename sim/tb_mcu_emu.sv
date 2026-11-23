// Testbench for rtl/host/mcu_emu.sv: the emulated MCU behind upstream's
// unmodified kg_mcu (generics and the tied inputs as in profi.vhd U7) on a
// 28.125 MHz clk_bus of unrelated phase, plus kg_soft_switches #(.N(21))
// fed by SOFTSW_COMMAND as in profi.vhd U9.
//
// A behavioural ioctl source streams a 0x58000-byte pseudo-random boot.rom
// (fixed LFSR; one byte at a time, the next byte only after ioctl_wait
// falls). The bench decodes every SPI frame from the link wires and checks:
//   no_boot_rom_stays_busy  no download -> no frame at all, BUSY stays 1;
//   rom_load                every ROMLOAD_WR equals the mapped source byte,
//                           in order, no duplicates, ROMLOADER_ACTIVE from
//                           before the first write to after the last, and
//                           the whole frame stream (bank frames only when
//                           the address bytes change; the 256-frame RTC
//                           block after the switches) is exactly the
//                           protocol's;
//   init_and_busy           BUSY 1 until after INIT_DONE, then 0;
//   mem_ready_gate          mem_ready 0 for 1 ms with a download up: no
//                           frame at all and ioctl_wait held; after it
//                           rises the normal start sequence follows;
//   switch_during_load      status changes while streaming: no 05 frame
//                           before the ROMLOADER-off frame (the stream
//                           walk proves it), and the registers hold the
//                           last value after INIT_DONE;
//   switches                every soft-switch register 0..15 holds the
//                           osd_items table's value after INIT_DONE; a
//                           status change reaches register 0 in 50 us;
//   keyboard                a kb_changed report reaches KB_STATUS/KB_DAT0;
//   reset_trigger           osd_reset pulses register 14, and the pulse
//                           ends after TRIGGER_CLKS;
//   and a second download repeating the whole start sequence;
//   uart_tx_reply           a CMD_UART 00 d reply raises uart_tx_stb with d;
//                           a reply of another command still reaches
//                           last_reply and never raises the strobe;
//   dll_dlm_ignored         the CMD_UART replies of addrs 01/02/03 (dll, dlm
//                           and the tsconf rs232 mode) are consumed: no
//                           strobe, though the frames are seen on the link;
//   uart_rx_send            every uart_rx_stb byte becomes one CMD_UART frame
//                           carrying its own idx, and two bytes in
//                           consecutive clocks are both delivered in order;
//   uart_rx_in_burst        a byte arriving during a keyboard report burst
//                           waits for it: the seven CMD_KBD frames of the
//                           report stay contiguous and the frame follows;
//   uart_rx_fifo_full       ten bytes in one frame time: the queue is eight
//                           deep, the newest byte is dropped and the earlier
//                           ones arrive in order;
//   uart_interleaves_mouse_burst, uart_interleaves_joy_burst,
//   uart_interleaves_rtc_burst
//                           a byte arriving in the middle of a mouse,
//                           joystick or RTC report burst waits for it: the
//                           burst's frames stay contiguous and the CMD_UART
//                           frame follows the last one;
//   uart_rx_push_with_freeing_pop
//                           a byte arriving in the clock a FULL queue gives
//                           up its head is accepted, not dropped: the slot
//                           is free before the next arbiter decision.
// The last line printed is `tb_mcu_emu: PASS` or `tb_mcu_emu: FAIL <reason>`;
// run via sim/run_tb_mcu_emu.sh (iverilog -g2012).
`timescale 1ns / 1ps

module tb_mcu_emu;

   localparam integer ROMSIZE = 360448;      // 0x58000
   localparam integer ROMMAX  = 360960;      // + two more 256-byte runs
   localparam integer FMAX    = 370000;

   reg clk = 1'b0;
   always #10 clk = ~clk;                    // clk_sys 50 MHz
   reg clk_bus = 1'b0;
   always #17.7778 clk_bus = ~clk_bus;       // 28.125 MHz, unrelated phase

   reg reset = 1'b1;

   `define FAIL(MSG) begin \
      $display("tb_mcu_emu: FAIL %s at %0t", (MSG), $time); \
      $finish; \
   end

   // ---------------- mcu_emu ----------------

   reg          ioctl_download = 1'b0;
   reg  [15:0]  ioctl_index    = 16'd0;
   reg          ioctl_wr       = 1'b0;
   reg  [26:0]  ioctl_addr     = 27'd0;
   reg  [7:0]   ioctl_dout     = 8'd0;
   wire         ioctl_wait;
   reg  [127:0] status         = 128'd0;
   reg          osd_reset      = 1'b0;
   reg  [55:0]  kb_report      = 56'd0;
   reg          kb_changed     = 1'b0;
   reg          mem_ready      = 1'b1;   // the machine's SDRAM ready
   reg          mounts_settled = 1'b1;   // the disk mounts have settled
   // the other MCU inputs, fixed: BCD 23:59:58 31.12.25 weekday 3, no
   // mouse reports, released joysticks. RTC_CLKS is far beyond this run,
   // so the run loop's periodic refresh never adds frames.
   reg  [64:0]  rtc = {1'b0, 8'h00, 8'h03, 8'h25, 8'h12, 8'h31,
                       8'h23, 8'h59, 8'h58};
   reg  [24:0]  ps2_mouse     = 25'd0;
   reg  [15:0]  ps2_mouse_ext = 16'd0;
   reg  [31:0]  joy0 = 32'd0, joy1 = 32'd0;
   wire         spi_cs_n, spi_sck, spi_mosi;
   wire         sck_dly, mosi_dly;    // the wire transport: the slave and
   assign #5  sck_dly  = spi_sck;     // the decoder see SCK 5 ns and MOSI
   assign #15 mosi_dly = spi_mosi;    // 15 ns late - a MOSI bit moving on
                                      // the rising edge therefore arrives to
                                      // the slave as its previous value
   wire         spi_miso;
   wire [23:0]  last_reply;
   wire         reply_valid;

   // the USB-RS232 byte channel (stage 5): uart_rx_* is a byte for the
   // machine, uart_tx_* a byte the machine sent
   reg  [7:0]  uart_rx_data = 8'h00;
   reg         uart_rx_stb  = 1'b0;
   wire [7:0]  uart_tx_data;
   wire        uart_tx_stb;
   // the same bytes on the machine's side (kg_mcu_uart's own ports)
   reg  [7:0]  mcu_uart_tx_data = 8'h00;
   reg         mcu_uart_tx_wr   = 1'b0;
   reg         mcu_uart_tx_mode = 1'b0;
   reg  [7:0]  mcu_uart_dll = 8'h00, mcu_uart_dlm = 8'h00;
   reg         mcu_uart_dll_wr = 1'b0, mcu_uart_dlm_wr = 1'b0;
   wire [7:0]  MCU_UART_RX_DATA, MCU_UART_RX_IDX;
   // dut2's strobes: only a CMD_UART 00 reply may raise them
   wire [7:0]  uart_tx2_data;
   wire        uart_tx2_stb;

   // one byte presented exactly in the clock the queue frees a slot: ur_pop
   // is the DUT's own pop strobe - combinational in the cycle that ends at
   // the posedge where the head byte leaves - so a strobe driven from it
   // lands in that same clock. That is the only way to put a byte into a full
   // queue at the moment its head is taken (uart_rx_push_with_freeing_pop).
   reg         inj_arm  = 1'b0;
   reg  [7:0]  inj_data = 8'h00;
   wire        inj_stb  = inj_arm && dut.ur_pop;
   integer     inj_cnt  = 0;      // injections that happened
   integer     inj_full = 0;      // of those, the ones on a full queue

   mcu_emu #(
      .TRIGGER_CLKS (2000),   // 40 us at 50 MHz
      .NOP_CLKS     (200),    // 4 us
      .RTC_CLKS     (100000000),
      .SEC_CLKS     (2000000000)
   ) dut (
      .clk (clk), .reset (reset),
      .ioctl_download (ioctl_download), .ioctl_index (ioctl_index),
      .ioctl_wr (ioctl_wr), .ioctl_addr (ioctl_addr),
      .ioctl_dout (ioctl_dout), .ioctl_wait (ioctl_wait),
      .status (status), .osd_reset (osd_reset),
      .kb_report (kb_report), .kb_changed (kb_changed),
      .rtc (rtc), .ps2_mouse (ps2_mouse), .ps2_mouse_ext (ps2_mouse_ext),
      .joy0 (joy0), .joy1 (joy1),
      .mem_ready (mem_ready),
      .mounts_settled (mounts_settled),
      .spi_cs_n (spi_cs_n), .spi_sck (spi_sck), .spi_mosi (spi_mosi),
      .spi_miso (spi_miso),
      .uart_rx_data (uart_rx_stb ? uart_rx_data : inj_data),
      .uart_rx_stb  (uart_rx_stb | inj_stb),
      .uart_tx_data (uart_tx_data), .uart_tx_stb (uart_tx_stb),
      .last_reply (last_reply), .reply_valid (reply_valid)
   );

   // the injection is one byte, and the case's premise is that it landed on a
   // full queue: without that clock the test would only prove that a byte with
   // free room is accepted, which uart_rx_send already shows
   always @(posedge clk)
      if (inj_stb) begin
         inj_arm <= 1'b0;
         inj_cnt = inj_cnt + 1;
         if (dut.ur_cnt === 4'd8) inj_full = inj_full + 1;
      end

   // ---------------- kg_mcu, profi.vhd U7 ----------------

   wire mcu_miso;
   assign spi_miso = mcu_miso;

   wire [7:0]  KB_STATUS, KB_DAT0, KB_DAT1, KB_DAT2;
   wire [7:0]  KB_DAT3, KB_DAT4, KB_DAT5;
   wire        ROMLOADER_ACTIVE, ROMLOAD_WR;
   wire [31:0] ROMLOAD_ADDR;
   wire [7:0]  ROMLOAD_DATA;
   wire [15:0] SOFTSW_COMMAND;
   wire [7:0]  HWID;
   wire        BUSY;
   wire [21*8-1:0] softsw_regs;

   kg_mcu #(
      .BURST_MAX_MHZ (0), .CS_FILTER (3), .ENABLE_RTC (1), .ENABLE_UART (1),
      .ENABLE_MATRIX (1), .ENABLE_DEBUG (0), .ENABLE_IMG (1),
      .ENABLE_FILE (0), .ENABLE_FT (0), .ENABLE_SD2 (0)
   ) u_mcu (
      .CLK (clk_bus), .N_RESET (~reset),
      .MCU_MOSI (mosi_dly), .MCU_MISO (mcu_miso), .MCU_SCK (sck_dly),
      .MCU_SS (spi_cs_n), .MCU_SPI_FT_SS (1'b1), .MCU_SPI_SD2_SS (1'b1),
      .MCU_BURST_CS_N (1'b1), .MCU_BURST_READY (),
      .MS_X (), .MS_Y (), .MS_Z (), .MS_B (), .MS_UPD (),
      .KB_STATUS (KB_STATUS), .KB_DAT0 (KB_DAT0), .KB_DAT1 (KB_DAT1),
      .KB_DAT2 (KB_DAT2), .KB_DAT3 (KB_DAT3), .KB_DAT4 (KB_DAT4),
      .KB_DAT5 (KB_DAT5), .KB_SCANCODE (), .KB_SCANCODE_UPD (),
      .XT_SCANCODE (), .XT_SCANCODE_UPD (),
      .JOY_L (), .JOY_R (), .BTNS (),
      .RTC_A (8'h00), .RTC_DI (8'h00), .RTC_DO (), .RTC_CS (1'b1),
      .RTC_WR_N (1'b1),
      .UART_RX_DATA (MCU_UART_RX_DATA), .UART_RX_IDX (MCU_UART_RX_IDX),
      .UART_TX_DATA (mcu_uart_tx_data), .UART_TX_WR (mcu_uart_tx_wr),
      .UART_TX_MODE (mcu_uart_tx_mode), .UART_DLM (mcu_uart_dlm),
      .UART_DLL (mcu_uart_dll), .UART_DLM_WR (mcu_uart_dlm_wr),
      .UART_DLL_WR (mcu_uart_dll_wr),
      .SOFTSW_COMMAND (SOFTSW_COMMAND), .OSD_COMMAND (),
      .ROMLOADER_ACTIVE (ROMLOADER_ACTIVE), .ROMLOAD_ADDR (ROMLOAD_ADDR),
      .ROMLOAD_DATA (ROMLOAD_DATA), .ROMLOAD_WR (ROMLOAD_WR),
      .IOCTL_ACTIVE (), .FILELOAD_RESET (), .FILELOAD_ACTIVE (),
      .FILELOAD_SIZE (), .FILELOAD_ADDR (), .FILELOAD_DATA (),
      .FILELOAD_WR (),
      .FT_SPI_ON (), .FT_VGA_ON (), .FT_RESET (), .FT_SCK (), .FT_MOSI (),
      .FT_MISO (1'b1), .FT_CS_N (),
      .SD2_SCK (), .SD2_MOSI (), .SD2_MISO (1'b1), .SD2_CS_N (),
      .MATRIX_CMD (24'd0), .MATRIX_CMD_WR (1'b0),
      .DEBUG_ADDR (16'd0), .DEBUG_DATA (16'd0),
      .HWID (HWID), .DVI_ONLY (),
      .IMG_MOUNTED (), .IMG_SIZE (), .IMG_DATA_WR (), .IMG_DATA_ADDR (),
      .IMG_DATA (), .IMG_RESULT_WR (), .IMG_RESULT (), .IMG_SUM (),
      .IMG_Q_WR (1'b0), .IMG_Q_DI (24'd0), .IMG_Q_ACK (), .IMG_PHYS_WR (),
      .IMG_PHYS (), .IMG_FLUSH (),
      .ESP_UART_TX_DATA (), .ESP_UART_TX_WR (), .ESP_UART_RX_DATA (8'h00),
      .ESP_UART_RX_WR (1'b0), .ESP_UART_RX_ACK (),
      .FLASHBOOT_START (1'b0), .FLASHBOOT_COREID (5'd0),
      .BUSY (BUSY)
   );

   kg_soft_switches #(.N (21)) u_sw (
      .clk (clk_bus), .command (SOFTSW_COMMAND),
      .regs (softsw_regs), .upd ()
   );

   // ---------------- reply path: second emulator behind a stub slave -----

   wire         cs2, sck2, mosi2, miso2;
   wire [23:0]  rep2_last;
   wire         rep2_vld;
   reg  [23:0]  stub_word = 24'hFF0000;   // NOPE until the request
   wire         stub_req;
   reg          dl2 = 1'b0;
   integer      rep2_cnt = 0;
   reg  [23:0]  rep2_get = 24'd0;
   integer      cs2_cnt = 0;

   mcu_emu #(
      .TRIGGER_CLKS (2000), .NOP_CLKS (200), .RTC_CLKS (100000000),
      .SEC_CLKS (2000000000)
   ) dut2 (
      .clk (clk), .reset (reset),
      .ioctl_download (dl2), .ioctl_index (16'd0),
      .ioctl_wr (1'b0), .ioctl_addr (27'd0), .ioctl_dout (8'd0),
      .ioctl_wait (),
      .status (128'd0), .osd_reset (1'b0),
      .kb_report (56'd0), .kb_changed (1'b0),
      .rtc (rtc), .ps2_mouse (ps2_mouse), .ps2_mouse_ext (ps2_mouse_ext),
      .joy0 (joy0), .joy1 (joy1),
      .mem_ready (1'b1), .mounts_settled (1'b1),
      .spi_cs_n (cs2), .spi_sck (sck2), .spi_mosi (mosi2),
      .spi_miso (miso2),
      .uart_rx_data (8'h00), .uart_rx_stb (1'b0),
      .uart_tx_data (uart_tx2_data), .uart_tx_stb (uart_tx2_stb),
      .last_reply (rep2_last), .reply_valid (rep2_vld)
   );

   kg_spi_slave #(.N (24)) stub (
      .clk (clk), .sck (sck2), .ssel (cs2), .mosi (mosi2), .miso (miso2),
      .di (stub_word), .wren (1'b1), .di_req (stub_req),
      .do_valid (), .dout ()
   );

   always @(posedge clk)
      if (stub_req) stub_word <= 24'h010003;
   always @(posedge rep2_vld) begin
      rep2_cnt = rep2_cnt + 1;
      rep2_get = rep2_last;
   end
   always @(posedge cs2) cs2_cnt = cs2_cnt + 1;

   // ---------------- the byte-channel probes ----------------

   // every byte the emulator handed out: dut is driven by the real
   // kg_mcu_uart in front of it, dut2 only by the stub's reply words
   reg  [7:0]  txlog [0:31];
   integer     ntx  = 0;
   integer     ntx2 = 0;
   always @(posedge clk) begin
      if (uart_tx_stb) begin
         if (ntx >= 32) `FAIL("uart_tx log overflow")
         txlog[ntx] = uart_tx_data;
         ntx = ntx + 1;
      end
      if (uart_tx2_stb) ntx2 = ntx2 + 1;
   end

   // every non-NOPE reply dut saw: it proves a frame a case relies on really
   // crossed the link, so a missing frame cannot pass as an ignored one
   reg  [23:0] rplog [0:31];
   integer     nrp = 0;
   always @(posedge clk) begin
      if (reply_valid) begin
         if (nrp >= 32) `FAIL("reply log overflow")
         rplog[nrp] = last_reply;
         nrp = nrp + 1;
      end
   end

   // kg_mcu_uart's received side: one entry per change of its idx, the pair
   // {idx, byte} it latched (both of its registers move in the same clock,
   // and this reads the values of the previous one)
   reg  [7:0]  urq_idx = 8'h00;
   reg  [15:0] rxlog [0:31];
   integer     nrx = 0;
   always @(posedge clk_bus)
      if (MCU_UART_RX_IDX !== urq_idx) begin
         urq_idx = MCU_UART_RX_IDX;
         if (nrx >= 32) `FAIL("uart_rx log overflow")
         rxlog[nrx] = {MCU_UART_RX_IDX, MCU_UART_RX_DATA};
         nrx = nrx + 1;
      end

   // one byte for the machine, a one-clock strobe off the sampling edge
   task rx_byte;
      input [7:0] b;
      begin
         @(negedge clk);
         uart_rx_data = b;
         uart_rx_stb  = 1'b1;
         @(negedge clk);
         uart_rx_stb  = 1'b0;
      end
   endtask

   // two bytes in two consecutive clocks, so the second one arrives while the
   // first is still going out
   task rx_byte_two;
      input [7:0] b1;
      input [7:0] b2;
      begin
         @(negedge clk);
         uart_rx_data = b1;
         uart_rx_stb  = 1'b1;
         @(negedge clk);
         uart_rx_data = b2;
         @(negedge clk);
         uart_rx_stb  = 1'b0;
         // the premise on the wire: with the link busy the second byte had
         // to wait in the queue, there was no free slot to fire it in
         if (dut.waiting !== 1'b1)
            `FAIL("the second byte arrived with the link idle, not a test of the queue")
      end
   endtask

   // the burst check of the three report sources: `n` frames of command `cmd`
   // in one uninterrupted run, and the CMD_UART frame of the byte that arrived
   // during them only after the burst's last frame. `base` is the frame index
   // the burst was started from, so a frame of an earlier case can never be
   // mistaken for the burst's first frame
   task burst_after_byte;
      input [7:0]   cmd;
      input integer n;
      input integer base;
      integer k, fb, fu;
      begin
         fb = -1;
         fu = -1;
         for (k = base; k < nfrm && fb < 0; k = k + 1)
            if (flog[k][23:16] === cmd) fb = k;
         if (fb < 0) `FAIL("no frame of the burst was logged")
         for (k = fb; k < fb + n; k = k + 1)
            if (k >= nfrm)
               `FAIL("the burst ended before all its frames went out")
            else if (flog[k][23:16] !== cmd)
               `FAIL("a frame of the report burst was split by another command")
         for (k = fb; k < nfrm; k = k + 1)
            if (flog[k][23:16] === 8'hFC && fu < 0) fu = k;
         if (fu < 0) `FAIL("the queued byte's CMD_UART frame never went out")
         if (fu < fb + n)
            `FAIL("the queued byte's frame went out inside the report burst")
      end
   endtask

   // ---------------- expected ROM image (fixed LFSR) ----------------

   reg [31:0] lfsr;
   reg [31:0] exp_addr [0:ROMMAX-1];
   reg [7:0]  exp_data [0:ROMMAX-1];
   integer    expected_total;

   function [31:0] rom_map;    // the boot.rom map (Global Constraints)
      input [26:0] o;
      begin
         rom_map = (o < 27'h50000) ? (32'h00100000 + {5'd0, o})
                                   : (32'h80000000 + ({5'd0, o} - 32'h00050000));
      end
   endfunction

   // ---------------- frame decoder (the link wires) ----------------

   reg [23:0] flog [0:FMAX-1];
   integer    nfrm = 0;
   integer    cbits = 0;
   reg [23:0] cword = 24'd0;
   integer    cs_ever_low = 0;
   // BUSY is 1 from INIT_START to INIT_DONE; INIT_START's own frame is
   // excluded (kg_mcu sees it only after the frame).
   integer    busy_mode = 0;      // 1: busy, 2: free, 3: busy again
   integer    busy_skip = -1;     // frame index of the last INIT_START
   integer    fe_total  = 0;      // INIT_DONE frames seen

   always @(negedge spi_cs_n) cbits = 0;
   always @(posedge sck_dly)
      if (!reset && !spi_cs_n) begin
         cword = {cword[22:0], mosi_dly};
         cbits = cbits + 1;
      end
   always @(posedge spi_cs_n) begin
      if (!reset) begin
         cs_ever_low = 1;
         if (cbits == 24) begin
            if (nfrm >= FMAX) `FAIL("frame log overflow")
            flog[nfrm] = cword;
            if (cword == 24'hFD0000) begin
               busy_mode  = 1;
               busy_skip  = nfrm;
            end else if (cword == 24'hFE0000) begin
               fe_total = fe_total + 1;
               if (busy_mode == 1) busy_mode = 2;
            end
            if (busy_mode == 1 && nfrm != busy_skip && BUSY !== 1'b1)
               `FAIL("BUSY dropped before INIT_DONE")
            nfrm = nfrm + 1;
         end
      end
   end

   // ---------------- ROM write recorder ----------------

   integer rom_rec = 0;
   integer act_prev = 0, act_downs = 0;
   integer t_act_up = 0, t_first_wr = 0, t_last_wr = 0, t_act_down = 0;

   always @(posedge clk_bus) begin
      if (ROMLOADER_ACTIVE && !act_prev) begin
         act_prev = 1;
         t_act_up = $time;
      end else if (!ROMLOADER_ACTIVE && act_prev) begin
         act_prev   = 0;
         t_act_down = $time;
         act_downs  = act_downs + 1;
         if (rom_rec != expected_total)
            `FAIL("ROMLOADER off before every byte was written")
      end
      if (ROMLOAD_WR) begin
         if (rom_rec >= ROMMAX) `FAIL("more ROMLOAD_WR than source bytes")
         if (!ROMLOADER_ACTIVE) `FAIL("ROMLOAD_WR with ROMLOADER_ACTIVE 0")
         if (ROMLOAD_ADDR !== exp_addr[rom_rec] ||
             ROMLOAD_DATA !== exp_data[rom_rec]) begin
            $display("tb_mcu_emu: FAIL write %08d is %8h/%02h expected %8h/%02h at %0d",
                     rom_rec, ROMLOAD_ADDR, ROMLOAD_DATA,
                     exp_addr[rom_rec], exp_data[rom_rec], rom_rec);
            $finish;
         end
         if (rom_rec == 0) t_first_wr = $time;
         t_last_wr = $time;
         rom_rec   = rom_rec + 1;
      end
   end

   // ---------------- expected OSD values (osd_items.svh table) -------

   // the status vector exercising every row of the table, ROM Bank = bank
   function [127:0] status_full;
      input [1:0] bank;
      begin
         status_full = (128'd1 << 1) | (128'd1 << 2) |        // ROM Bank 3
                       (128'd1 << 4) | (128'd1 << 6) |        // PSG field 5
                       (128'd1 << 7) |                        // VSync 1
                       (128'd1 << 9) |                        // Turbo 2
                       (128'd1 << 12) |                     // Joy L field 4
                       (128'd1 << 13) | (128'd1 << 15) |     // Joy R field 5
                       (128'd1 << 16) | (128'd1 << 17) |      // DivMMC, Kbd
                       (128'd1 << 18) |                       // Pause
                       (128'd1 << 56);                        // Tape monitor field 2
         status_full[2:1] = bank;
      end
   endfunction

   integer curbank = 3;                  // status[2:1] as last sent
   integer curtape = 2;                  // status[56:55] as last sent
   function [7:0] exp_sw;
      input integer idx;
      begin
         case (idx)
            0:       exp_sw = curbank[7:0];
            1:       exp_sw = 8'd1;      // Covox: field 0, ~0
            2:       exp_sw = 8'd0;      // PSG mix: (5 + 1) % 6
            3:       exp_sw = 8'd1;
            4:       exp_sw = 8'd2;
            5:       exp_sw = 8'd4;
            6:       exp_sw = 8'd0;      // Joy R: (5 + 1) % 6
            7:       exp_sw = 8'd1;
            8:       exp_sw = 8'd1;      // HDD: constant 1
            10:      exp_sw = 8'd1;
            11:      exp_sw = 8'd1;
            15:      exp_sw = 8'd0;      // Mode: Pentagon
            20:      exp_sw = curtape[7:0];   // Tape monitor: status[56:55]
            default: exp_sw = 8'd0;      // 9, and the triggers 12..14
         endcase
      end
   endfunction

   // the RTC block of the start sequence: the fixed BCD time above, the
   // control registers and FF through 0xFF
   function [23:0] exp_rtc;
      input integer k;
      begin
         case (k)
            0:  exp_rtc = 24'hFA0058;    // sec
            1:  exp_rtc = 24'hFA0259;    // min
            2:  exp_rtc = 24'hFA0423;    // hour
            3:  exp_rtc = 24'hFA0604;    // weekday 3 + 1
            4:  exp_rtc = 24'hFA0731;    // date
            5:  exp_rtc = 24'hFA0812;    // month
            6:  exp_rtc = 24'hFA0925;    // year
            7:  exp_rtc = 24'hFA0100;
            8:  exp_rtc = 24'hFA0300;
            9:  exp_rtc = 24'hFA0500;
            10: exp_rtc = 24'hFA0A26;
            11: exp_rtc = 24'hFA0B02;    // BCD, 24 h
            12: exp_rtc = 24'hFA0C00;
            13: exp_rtc = 24'hFA0D80;
            default: exp_rtc = {8'hFA, k[7:0], 8'hFF};
         endcase
      end
   endfunction

   // wait for a condition to stop holding, with a timeout in microseconds
   // (50 clocks at the 20 ns clock); the guard counts clock edges instead
   // of comparing $time differences: a 32-bit snapshot truncates $time
   // (ps) at the microsecond marks this test runs at, and deep-sim 64-bit
   // and real time comparisons mis-evaluate in this simulator (guards
   // that must fire silently did not in debug)
   integer g_n;
   `define WAIT_GT(COND, BUDGET_US, WHY) begin                          \
         g_n = 0;                                                       \
         while (COND) begin                                             \
            if (g_n >= (BUDGET_US) * 50 || g_n < 0)                     \
               `FAIL(WHY)                                               \
            g_n = g_n + 1;                                              \
            @(negedge clk);                                             \
         end                                                            \
      end

   // ---------------- ioctl source ----------------

   task stream_range;                     // source bytes [lo, hi)
      input integer lo;
      input integer hi;
      integer k;
      begin
         for (k = lo; k < hi; k = k + 1) begin
            if (k != lo) @(negedge clk);  // first byte rides the download
            else         #1;               // edge itself, off the wake edge
            ioctl_addr = k[26:0];
            ioctl_dout = exp_data[k];     // hps_io: ioctl_wr is high for
            ioctl_wr   = 1'b1;             // exactly the one clock it is
            @(posedge clk);                // sampled on
            #1;                            // off the edge, so the clear
            ioctl_wr   = 1'b0;             // never races the sampling
            while (ioctl_wait === 1'b1) @(posedge clk);
         end
      end
   endtask

   // the real HPS behaviour: it never strobes while ioctl_wait is high,
   // not even for the first byte - so it starts only after the emulator
   // released the wait again
   task stream_range_hps;
      input integer lo;
      input integer hi;
      integer k;
      begin
         for (k = lo; k < hi; k = k + 1) begin
            `WAIT_GT(ioctl_wait === 1'b1, 20000, "the download hung: ioctl_wait never dropped");
            if (k != lo) @(negedge clk);
            else         #1;
            ioctl_addr = k[26:0];
            ioctl_dout = exp_data[k];
            ioctl_wr   = 1'b1;
            @(posedge clk);
            #1;
            ioctl_wr   = 1'b0;
         end
      end
   endtask

   integer walk_n;

   // one frame against its expected word
   task chkfrm;
      input integer j;
      input [23:0] want;
      begin
         if (flog[j] !== want) begin
            $display("tb_mcu_emu: FAIL frame %0d is %6h expected %6h",
                     j, flog[j], want);
            $finish;
         end
      end
   endtask

   // compare the frames [fbase, ...) with the protocol's stream for source
   // bytes [lo, hi): start sequence, banks only when they change, data,
   // ROMLOADER off, the 16 switches (0-8, 10-15, 20), the keyboard clear, INIT_DONE.
   task walk_stream;
      input integer fbase;
      input integer lo;
      input integer hi;
      integer j, k, b;
      reg [7:0] pb0, pb1, pb2, bb;
      reg [31:0] a;
      begin
         j = fbase;
         chkfrm(j, 24'hFD0000);   j = j + 1;
         chkfrm(j, 24'hF90001);   j = j + 1;
         chkfrm(j, 24'h080001);   j = j + 1;
         pb0 = 8'hFF; pb1 = 8'hFF; pb2 = 8'hFF;
         for (k = lo; k < hi; k = k + 1) begin
            a = exp_addr[k];
            if (a[15:8] !== pb0) begin
               chkfrm(j, {8'h06, 8'h00, a[15:8]}); j = j + 1; pb0 = a[15:8];
            end
            if (a[23:16] !== pb1) begin
               chkfrm(j, {8'h06, 8'h01, a[23:16]}); j = j + 1; pb1 = a[23:16];
            end
            if (a[31:24] !== pb2) begin
               chkfrm(j, {8'h06, 8'h02, a[31:24]}); j = j + 1; pb2 = a[31:24];
            end
            chkfrm(j, {8'h07, a[7:0], exp_data[k]}); j = j + 1;
         end
         chkfrm(j, 24'h080000);   j = j + 1;
         for (b = 0; b <= 15; b = b + 1)
            if (b != 9) begin
               bb = b;
               chkfrm(j, {8'h05, bb, exp_sw(b)});   j = j + 1;
            end
         chkfrm(j, {8'h05, 8'h14, exp_sw(20)});     j = j + 1;   // Tape monitor
         for (b = 0; b < 256; b = b + 1) begin
            chkfrm(j, exp_rtc(b));                  j = j + 1;
         end
         for (b = 0; b <= 6; b = b + 1) begin
            bb = b;
            chkfrm(j, {8'h01, bb, 8'h00});          j = j + 1;
         end
         chkfrm(j, 24'hFE0000);   j = j + 1;
         walk_n = j - fbase;
      end
   endtask

   // ---------------- main ----------------

   integer i, base, n0, mseen, rp2, rpa, rpb, f0, f1, jj;
   reg [15:0] wexp;
   reg [7:0]  bexp;

   initial begin
      // the image (the fixed LFSR the source plays)
      lfsr = 32'h12345678;
      for (i = 0; i < ROMSIZE; i = i + 1) begin
         lfsr = (lfsr >> 1) ^ (lfsr[0] ? 32'hEDB88320 : 32'd0);
         exp_addr[i] = rom_map(i[26:0]);
         exp_data[i] = lfsr[7:0];
      end
      for (i = 0; i < 512; i = i + 1) begin   // the extra downloads replay
         exp_addr[ROMSIZE + i] = exp_addr[i % 256];
         exp_data[ROMSIZE + i] = exp_data[i % 256];
      end
      expected_total = ROMSIZE;

      status = status_full(2'b11);
      repeat (20) @(negedge clk);
      reset = 1'b0;

      // no_boot_rom_stays_busy: nothing may move for 2 ms
      #2000000;
      if (nfrm != 0 || cs_ever_low != 0)
         `FAIL("frames were sent without a boot.rom download")
      if (BUSY !== 1'b1) `FAIL("BUSY is 0 before INIT_START")

      // mem_ready_gate: with the machine's SDRAM controller not ready the
      // start sequence must not begin: a download up for 1 ms sends no
      // frame and holds ioctl_wait high; when mem_ready rises the normal
      // start sequence follows from this very download (the frame walk
      // below proves INIT_START was its first frame).
      mem_ready = 1'b0;
      #1000;
      ioctl_download = 1'b1;
      #1000000;
      if (nfrm != 0 || cs_ever_low != 0)
         `FAIL("a frame went out while mem_ready was 0")
      if (ioctl_wait !== 1'b1)
         `FAIL("ioctl_wait is not held while mem_ready is 0")
      if (BUSY !== 1'b1) `FAIL("BUSY dropped with mem_ready 0")
      mem_ready = 1'b1;

      // mounts_settle: the same hold from the clk_sys side. A mount that
      // lands while the ROM probes the drives never completes the probe on
      // the board, so the start waits for the mounts (Karabas_Profi.sv).
      mounts_settled = 1'b0;
      #1000000;
      if (nfrm != 0 || cs_ever_low != 0)
         `FAIL("a frame went out before the disk mounts settled")
      if (ioctl_wait !== 1'b1)
         `FAIL("ioctl_wait is not held before the disk mounts settle")
      mounts_settled = 1'b1;

      // the full download, two status changes while streaming
      ioctl_download = 1'b1;
      stream_range(0, 65536);            // 0x10000
      status = status_full(2'b01);
      stream_range(65536, 196608);       // 0x30000
      status = status_full(2'b10);
      stream_range(196608, ROMSIZE);
      status         = status_full(2'b11);
      curbank        = 3;
      ioctl_download = 1'b0;

      // INIT_DONE closes the start sequence
      `WAIT_GT(fe_total < 1, 200000, "INIT_DONE was not sent");
      walk_stream(0, 0, ROMSIZE);
      if (nfrm != walk_n) begin
         $display("tb_mcu_emu: FAIL %0d frames logged, %0d expected",
                  nfrm, walk_n);
         $finish;
      end

      // rom_load: the recorder walked the whole image; the per-write
      // checks ran live. What is left: the counts and the loader window.
      if (rom_rec != ROMSIZE) `FAIL("ROMLOAD_WR count differs from the source")
      if (act_downs != 1) `FAIL("ROMLOADER_ACTIVE did not fall exactly once")
      if (!(t_act_up < t_first_wr))
         `FAIL("ROMLOADER_ACTIVE rose after the first write")
      if (!(t_act_down > t_last_wr))
         `FAIL("ROMLOADER_ACTIVE fell before the last write")

      // init_and_busy: BUSY is 1 until after INIT_DONE, then 0 (the walk
      // checked every frame up to INIT_DONE; now the drop)
      `WAIT_GT(BUSY !== 1'b0, 5000, "BUSY stuck after INIT_DONE");
      if (HWID !== 8'h01) `FAIL("HW_SETUP board is not Go")

      // switch_during_load / switches: every register holds the table's
      // value for the last status (the walk proved no 05 frame went out
      // before the ROMLOADER-off frame)
      #10000;
      for (i = 0; i <= 15; i = i + 1)
         if (softsw_regs[i*8 +: 8] !== exp_sw(i)) begin
            $display("tb_mcu_emu: FAIL reg %0d is %02h expected %02h",
                     i, softsw_regs[i*8 +: 8], exp_sw(i));
            $finish;
         end
      if (softsw_regs[20*8 +: 8] !== exp_sw(20)) begin
         $display("tb_mcu_emu: FAIL reg 20 is %02h expected %02h",
                  softsw_regs[20*8 +: 8], exp_sw(20));
         $finish;
      end

      // a changed status reaches register 0 within 50 us
      @(negedge clk);
      status[2:1] = 2'b01;
      curbank     = 1;
      `WAIT_GT(softsw_regs[0*8 +: 8] !== 8'd1, 50000, "register 0 did not follow status");

      // the Mode item: a status[26] change at run time sends 05 0F 01 and,
      // back to 0, 05 0F 00 (the walk proved the start frame was 05 0F 00)
      n0 = nfrm;
      @(negedge clk);
      status[26] = 1'b1;
      `WAIT_GT(softsw_regs[15*8 +: 8] !== 8'd1, 50000, "register 15 did not follow status");
      mseen = 0;
      for (i = n0; i < nfrm; i = i + 1)
         if (flog[i] === 24'h050F01) mseen = 1;
      if (!mseen) `FAIL("no 05 0F 01 frame for status[26] = 1");
      n0 = nfrm;
      @(negedge clk);
      status[26] = 1'b0;
      `WAIT_GT(softsw_regs[15*8 +: 8] !== 8'd0, 50000, "register 15 did not follow status back");
      mseen = 0;
      for (i = n0; i < nfrm; i = i + 1)
         if (flog[i] === 24'h050F00) mseen = 1;
      if (!mseen) `FAIL("no 05 0F 00 frame for status[26] = 0");

      // the Tape monitor item (index 20): status[56:55] = 3 sends 05 14 03
      n0 = nfrm;
      @(negedge clk);
      status[56:55] = 2'b11;
      curtape       = 3;
      `WAIT_GT(softsw_regs[20*8 +: 8] !== 8'd3, 50000, "register 20 did not follow status");
      mseen = 0;
      for (i = n0; i < nfrm; i = i + 1)
         if (flog[i] === 24'h051403) mseen = 1;
      if (!mseen) `FAIL("no 05 14 03 frame for status[56:55] = 3");

      // keyboard
      @(negedge clk);
      kb_report  = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h04, 8'h02};
      kb_changed = 1'b1;
      @(negedge clk);
      kb_changed = 1'b0;
      `WAIT_GT(KB_STATUS !== 8'h02 || KB_DAT0 !== 8'h04 || KB_DAT1 !== 8'h00 || KB_DAT2 !== 8'h00 || KB_DAT3 !== 8'h00 || KB_DAT4 !== 8'h00 || KB_DAT5 !== 8'h00, 60000, "the keyboard report did not arrive");
      if (BUSY !== 1'b0) `FAIL("BUSY went back to 1 in the run loop")

      // an update arriving mid-burst: the latest report must then be sent
      // in full, never a blend of two reports
      @(negedge clk);
      kb_report  = {8'h00, 8'h00, 8'h00, 8'h00, 8'h1f, 8'h1e, 8'h03};
      kb_changed = 1'b1;
      @(negedge clk);
      kb_changed = 1'b0;
      #4001;                            // past the first frame, mid burst;
                                        // the odd delay drives off an edge
      kb_report  = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h04, 8'h01};
      kb_changed = 1'b1;
      @(negedge clk);
      kb_changed = 1'b0;
      `WAIT_GT(KB_STATUS !== 8'h01 || KB_DAT0 !== 8'h04 || KB_DAT1 !== 8'h00 || KB_DAT2 !== 8'h00 || KB_DAT3 !== 8'h00 || KB_DAT4 !== 8'h00 || KB_DAT5 !== 8'h00, 60000, "a burst-replacing report was not sent in full");

      // reset_trigger: one clock of osd_reset pulses register 14, and the
      // pulse ends after TRIGGER_CLKS (2000 clocks = 40 us)
      @(negedge clk);
      osd_reset = 1'b1;
      @(negedge clk);
      osd_reset = 1'b0;
      `WAIT_GT(softsw_regs[14*8 +: 8] !== 8'h01, 15000, "osd_reset did not pulse register 14");
      #20000;                       // TRIGGER_CLKS has not passed yet
      if (softsw_regs[14*8 +: 8] !== 8'h01)
         `FAIL("the Reset pulse ended before TRIGGER_CLKS")
      `WAIT_GT(softsw_regs[14*8 +: 8] !== 8'h00, 60000, "the Reset pulse did not end");
      // the keyboard back to idle, so the report frames between ROMLOADER
      // off and INIT_DONE carry zeros again
      @(negedge clk);
      kb_report  = 56'd0;
      kb_changed = 1'b1;
      @(negedge clk);
      kb_changed = 1'b0;
      `WAIT_GT(KB_STATUS !== 8'h00, 60000, "the keyboard did not reach idle");

      // a second boot.rom download repeats the whole start sequence
      expected_total = ROMSIZE + 256;
      base           = nfrm;
      ioctl_download = 1'b1;
      stream_range(0, 256);
      ioctl_download = 1'b0;
      `WAIT_GT(fe_total < 2, 200000, "the second INIT_DONE was not sent");
      walk_stream(base, 0, 256);
      if (nfrm != base + walk_n) `FAIL("stray frames in the second download")
      if (rom_rec != ROMSIZE + 256)
         `FAIL("the second download did not reach the ROM")
      if (act_downs != 2) `FAIL("ROMLOADER_ACTIVE did not fall the second time")

      // a third download with the source behaving like the real HPS: it
      // holds every byte - the first included - while ioctl_wait is high,
      // so the first strobe only follows the release at S_STRM
      expected_total = ROMSIZE + 512;
      base           = nfrm;
      ioctl_download = 1'b1;
      #1000;                            // a few clocks of slack, as the
      stream_range_hps(0, 256);         // HPS thread takes before it looks
      ioctl_download = 1'b0;
      `WAIT_GT(fe_total < 3, 200000, "the third INIT_DONE was not sent");
      walk_stream(base, 0, 256);
      if (nfrm != base + walk_n) `FAIL("stray frames in the third download")
      if (rom_rec != ROMSIZE + 512)
         `FAIL("the third download did not reach the ROM")
      if (act_downs != 3) `FAIL("ROMLOADER_ACTIVE did not fall the third time")

      // the reply path (second emulator behind the stub): the first frame
      // is answered NOPE (nothing may arrive), the second with a word
      rep2_cnt = 0; cs2_cnt = 0;
      @(negedge clk);
      dl2 = 1'b1;
      `WAIT_GT(cs2_cnt < 1, 5000, "the stub link sent no frame");
      #1000;                            // past that frame's rx_valid
      if (rep2_cnt !== 0) `FAIL("reply_valid fired for a NOPE reply")
      `WAIT_GT(rep2_cnt < 1, 10000, "the reply word never arrived");
      if (rep2_get !== 24'h010003)
         `FAIL("the reply word did not reach last_reply uncorrupted")
      `WAIT_GT(BUSY !== 1'b0, 5000, "BUSY stuck after the second INIT_DONE");

      // ============================================================
      // the USB-RS232 byte channel (stage 5)
      // ============================================================

      // uart_tx_reply: kg_mcu_uart builds CMD_UART 00 d from a UART_TX_WR
      // strobe of the machine, so the frame's constants here are upstream's;
      // the emulator hands the byte out with a one-clock strobe
      rpa = nrp;                        // the reply log never starts empty:
                                        // the very first frame of the run is
                                        // answered with the reply queue's
                                        // initial word, which is no NOPE
      @(negedge clk);
      dl2 = 1'b0;                       // release dut2's download: its start
                                        // sequence ends and every frame it
                                        // then polls is answered CMD_KBD 00 03
      @(negedge clk_bus);
      mcu_uart_tx_data = 8'h41;
      mcu_uart_tx_wr   = 1'b1;
      @(negedge clk_bus);
      mcu_uart_tx_wr   = 1'b0;
      `WAIT_GT(ntx < 1, 5000, "a CMD_UART 00 reply never raised uart_tx_stb");
      if (txlog[0] !== 8'h41) begin
         $display("tb_mcu_emu: FAIL uart_tx_data is %02h expected 41", txlog[0]);
         $finish;
      end
      // the frame really was CMD_UART 00 41 on the link, which is also the
      // premise of the case below: a CMD_UART reply reaches last_reply like
      // every other reply does
      `WAIT_GT(nrp < rpa + 1, 5000, "the CMD_UART reply never reached mcu_emu");
      if (rplog[rpa] !== 24'hFC0041) begin
         $display("tb_mcu_emu: FAIL the reply frame is %6h expected fc0041", rplog[rpa]);
         $finish;
      end
      // a reply of another command still reaches last_reply and never the
      // byte channel: the ~280 frames dut2 walked to get to its run loop and
      // the ones it polls in it are all CMD_KBD replies
      rp2 = rep2_cnt;
      `WAIT_GT(rep2_cnt < rp2 + 100, 20000, "a CMD_KBD reply stream stopped reaching last_reply");
      if (ntx2 !== 0) begin
         $display("tb_mcu_emu: FAIL uart_tx_stb fired %0d times for CMD_KBD replies", ntx2);
         $finish;
      end

      // dll_dlm_ignored: the divisor writes (CMD_UART 01, 02) and the tsconf
      // rs232 mode byte (03) are consumed and ignored
      n0 = ntx;
      rpb = nrp;
      @(negedge clk_bus);
      mcu_uart_dll    = 8'h07;
      mcu_uart_dll_wr = 1'b1;
      @(negedge clk_bus);
      mcu_uart_dll_wr = 1'b0;
      `WAIT_GT(nrp < rpb + 1, 5000, "the dll frame never reached mcu_emu");
      @(negedge clk_bus);
      mcu_uart_dlm    = 8'h12;
      mcu_uart_dlm_wr = 1'b1;
      @(negedge clk_bus);
      mcu_uart_dlm_wr = 1'b0;
      `WAIT_GT(nrp < rpb + 2, 5000, "the dlm frame never reached mcu_emu");
      @(negedge clk_bus);
      mcu_uart_tx_mode = 1'b1;
      mcu_uart_tx_data = 8'h55;
      mcu_uart_tx_wr   = 1'b1;
      @(negedge clk_bus);
      mcu_uart_tx_wr   = 1'b0;
      mcu_uart_tx_mode = 1'b0;
      `WAIT_GT(nrp < rpb + 3, 5000, "the tsconf mode frame never reached mcu_emu");
      if (rplog[rpb] !== 24'hFC0107 || rplog[rpb + 1] !== 24'hFC0212 ||
          rplog[rpb + 2] !== 24'hFC0355) begin
         $display("tb_mcu_emu: FAIL the ignored frames are %6h %6h %6h, expected fc0107 fc0212 fc0355",
                  rplog[rpb], rplog[rpb + 1], rplog[rpb + 2]);
         $finish;
      end
      #20000;                           // several frame times: a strobe for
                                        // any of the three would be logged
      if (ntx !== n0) begin
         $display("tb_mcu_emu: FAIL %0d of the three ignored frames raised uart_tx_stb",
                  ntx - n0);
         $finish;
      end

      // uart_rx_send: every byte for the machine becomes one CMD_UART frame
      // with the emulator's own idx - kg_mcu_uart shows it, and its
      // uart_rx_idx resets to 0, so the first byte has to carry 1 to be seen
      rx_byte(8'hA5);
      rx_byte(8'h3C);
      rx_byte(8'h77);
      `WAIT_GT(nrx < 3, 5000, "a byte for the machine never arrived");
      if (rxlog[0] !== 16'h01A5 || rxlog[1] !== 16'h023C ||
          rxlog[2] !== 16'h0377) begin
         $display("tb_mcu_emu: FAIL the machine got %4h %4h %4h, expected 01a5 023c 0377",
                  rxlog[0], rxlog[1], rxlog[2]);
         $finish;
      end
      // two bytes in consecutive clocks: both are queued, both arrive, the
      // first one first
      rx_byte_two(8'hD7, 8'hE8);
      `WAIT_GT(nrx < 5, 5000, "the second of two back-to-back bytes was lost");
      if (rxlog[3] !== 16'h04D7 || rxlog[4] !== 16'h05E8) begin
         $display("tb_mcu_emu: FAIL the pair arrived as %4h %4h, expected 04d7 05e8",
                  rxlog[3], rxlog[4]);
         $finish;
      end

      // uart_rx_in_burst: a byte that arrives while a keyboard report burst
      // is going out waits for the burst
      n0 = nfrm;
      @(negedge clk);
      kb_report  = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h08};
      kb_changed = 1'b1;
      @(negedge clk);
      kb_changed = 1'b0;
      `WAIT_GT(dut.kb_pend !== 1'b1, 5000, "the keyboard report burst never started");
      #1000;                              // one frame into the burst
      @(negedge clk);
      if (dut.kb_pend !== 1'b1)
         `FAIL("the byte did not arrive inside the keyboard report burst")
      uart_rx_data = 8'hB1;
      uart_rx_stb  = 1'b1;
      @(negedge clk);
      uart_rx_stb  = 1'b0;
      `WAIT_GT(KB_STATUS !== 8'h08, 60000, "the keyboard report did not arrive");
      `WAIT_GT(nrx < 6, 5000, "the byte queued during the burst never arrived");
      if (rxlog[5] !== 16'h06B1) begin
         $display("tb_mcu_emu: FAIL the queued byte arrived as %4h expected 06b1", rxlog[5]);
         $finish;
      end
      // the burst stayed whole: seven CMD_KBD frames in a row, and the byte's
      // CMD_UART frame only after them
      f0 = -1;
      f1 = -1;
      for (i = n0; i < nfrm; i = i + 1)
         if (flog[i][23:16] === 8'h01 && f0 < 0) f0 = i;
      if (f0 < 0) `FAIL("no CMD_KBD frame of the report was logged")
      for (i = f0; i < f0 + 7; i = i + 1)
         if (flog[i][23:16] !== 8'h01) begin
            $display("tb_mcu_emu: FAIL frame %0d of the report is %6h, the burst was split",
                     i - f0, flog[i]);
            $finish;
         end
      for (i = f0; i < nfrm; i = i + 1)
         if (flog[i][23:16] === 8'hFC && f1 < 0) f1 = i;
      if (f1 < 0) `FAIL("the queued byte's CMD_UART frame never went out")
      if (f1 <= f0 + 6)
         `FAIL("the CMD_UART frame went out inside the report burst")

      // uart_rx_fifo_full: ten bytes inside one frame time. The queue is
      // eight deep, so the tenth - the newest - is dropped and the nine
      // earlier ones are all delivered in order: losing the oldest instead
      // would show as a wrong first byte, a deeper queue as a tenth delivery,
      // a one-deep latch as a single one
      `WAIT_GT(dut.waiting === 1'b1 || dut.ur_cnt !== 4'd0, 20000,
               "the byte queue never went idle");
      // No write into the DUT to keep the polls out of the first slot: the
      // arbiter already puts a queued byte before a poll, so the frame whose
      // shift register holds this byte's own word *is* the frame the rest
      // arrive under - wait for it on the DUT's busy flag, bounded by clock
      // edges. A poll that won the slot first only makes the wait longer.
      // (this case's bytes carry idx 0x07.., the frames of the earlier cases
      // used 0x01..0x06, so the first frame to watch for is FC 07 A0)
      rx_byte(8'hA0);         // this byte is the frame the rest arrive under
      `WAIT_GT(!(dut.waiting === 1'b1 && dut.tx_word === 24'hFC07A0), 5000,
               "the queue's first byte never got its frame");
      for (i = 1; i < 10; i = i + 1)
         rx_byte(8'hA0 + i);
      if (dut.waiting !== 1'b1)
         `FAIL("the ten bytes did not arrive inside one frame time")
      if (dut.ur_cnt !== 4'd8) begin
         $display("tb_mcu_emu: FAIL the queue holds %0d entries, expected 8", dut.ur_cnt);
         $finish;
      end
      // nine of them reach the machine: the byte in flight plus the eight
      // queued ones, with the idx running on from the earlier cases
      `WAIT_GT(nrx < 15, 20000, "fewer than nine of the ten bytes arrived");
      for (i = 0; i < 9; i = i + 1) begin
         wexp = ((7 + i) << 8) | (8'hA0 + i);
         if (rxlog[6 + i] !== wexp) begin
            $display("tb_mcu_emu: FAIL byte %0d arrived as %4h expected %4h",
                     i, rxlog[6 + i], wexp);
            $finish;
         end
      end
      // and nothing else follows: the dropped byte is gone
      `WAIT_GT(dut.waiting === 1'b1 || dut.ur_cnt !== 4'd0, 20000,
               "the byte queue never drained");
      #20000;
      if (nrx !== 15) begin
         $display("tb_mcu_emu: FAIL %0d of the ten bytes arrived, expected 9", nrx - 6);
         $finish;
      end
      // the queue still works after a drop, and the dropped byte consumed no
      // idx: the next byte carries the next one
      rx_byte(8'hB0);
      `WAIT_GT(nrx < 16, 5000, "the queue stopped delivering after a byte was dropped");
      if (rxlog[15] !== 16'h10B0) begin
         $display("tb_mcu_emu: FAIL the byte after the drop arrived as %4h expected 10b0",
                  rxlog[15]);
         $finish;
      end

      // --------------------------------------------------------------
      // uart_interleaves_mouse_burst: the four-frame CMD_MOUSE report is one
      // burst, and a byte that arrives while it is going out is delivered
      // after its last frame. uart_rx_in_burst shows this for the keyboard
      // source; the mouse's branch sits directly above the queue's, so this
      // is the case that proves the queue waits behind it.
      // (idx 0x11.. were the bytes above; ps2_mouse_ext[7:0] is the wheel)
      n0 = nfrm;
      ps2_mouse     = {1'b1, 8'd0, 8'd12, 8'd5};   // toggle, Y 0, X 12,
      ps2_mouse_ext = 9'd1;                        // buttons 5: the word is
                                                   // [23:16] Y, [15:8] X and
                                                   // [2:0] the buttons
      `WAIT_GT(dut.ms_go !== 1'b1, 20000, "the mouse report never started");
      rx_byte(8'hC1);
      if (dut.ms_go !== 1'b1)
         `FAIL("the byte arrived after the mouse burst, not during it")
      `WAIT_GT(dut.ur_cnt !== 4'd0 || dut.waiting === 1'b1, 300,
               "the byte queued during the mouse burst never went out");
      burst_after_byte(8'h02, 4, n0);
      if (nrx !== 17) begin
         $display("tb_mcu_emu: FAIL the mouse case leaves %0d bytes delivered, expected 17", nrx);
         $finish;
      end
      if (rxlog[16] !== 16'h11C1) begin
         $display("tb_mcu_emu: FAIL the byte of the mouse case arrived as %4h expected 11c1", rxlog[16]);
         $finish;
      end

      // --------------------------------------------------------------
      // uart_interleaves_joy_burst: the same for the four-frame CMD_JOY
      // report (the joystick branch, right below the mouse's)
      n0 = nfrm;
      joy0 = 17'h1FFFF;         // stick connected, every button pressed
      `WAIT_GT(dut.jy_go !== 1'b1, 20000, "the joystick report never started");
      rx_byte(8'hC2);
      if (dut.jy_go !== 1'b1)
         `FAIL("the byte arrived after the joystick burst, not during it")
      `WAIT_GT(dut.ur_cnt !== 4'd0 || dut.waiting === 1'b1, 300,
               "the byte queued during the joystick burst never went out");
      burst_after_byte(8'h03, 4, n0);
      if (nrx !== 18) begin
         $display("tb_mcu_emu: FAIL the joystick case leaves %0d bytes delivered, expected 18", nrx);
         $finish;
      end
      if (rxlog[17] !== 16'h12C2) begin
         $display("tb_mcu_emu: FAIL the byte of the joystick case arrived as %4h expected 12c2", rxlog[17]);
         $finish;
      end

      // --------------------------------------------------------------
      // uart_interleaves_rtc_burst: the seven-frame CMD_RTC refresh that
      // follows the first toggle of RTC[64] (an HPS time update). The longest
      // burst of the three, and the branch closest above the queue's; the DUT
      // fires it on the first toggle only, so this is the one case that uses
      // it (the periodic one is RTC_CLKS, beyond this run)
      n0 = nfrm;
      rtc = {1'b1, rtc[63:0]};
      `WAIT_GT(dut.rt_go !== 1'b1, 20000, "the RTC refresh never started");
      rx_byte(8'hC3);
      if (dut.rt_go !== 1'b1)
         `FAIL("the byte arrived after the RTC burst, not during it")
      `WAIT_GT(dut.ur_cnt !== 4'd0 || dut.waiting === 1'b1, 300,
               "the byte queued during the RTC burst never went out");
      burst_after_byte(8'hFA, 7, n0);
      if (nrx !== 19) begin
         $display("tb_mcu_emu: FAIL the RTC case leaves %0d bytes delivered, expected 19", nrx);
         $finish;
      end
      if (rxlog[18] !== 16'h13C3) begin
         $display("tb_mcu_emu: FAIL the byte of the RTC case arrived as %4h expected 13c3", rxlog[18]);
         $finish;
      end

      // --------------------------------------------------------------
      // uart_rx_push_with_freeing_pop: a byte that arrives in the very clock a
      // FULL queue gives up its head has a slot waiting for it before the next
      // arbiter decision, so it is accepted - the queue stays in order and the
      // byte joins its tail. Filling to eight works as in uart_rx_fifo_full;
      // the tenth byte is the injection, armed to fire on the next pop - the
      // clock in which the frame carrying the first fill byte takes its head,
      // with all eight slots full. With the drop-everything-while-full rule
      // it disappears: nine of the ten arrive, and the case waits for a tenth
      // that never comes
      rx_byte(8'hC0);            // the byte whose frame the rest arrive under
      // (this byte's idx is 0x14: the frames of the earlier cases used
      // 0x01..0x13, so this is the word to see in the shift register)
      `WAIT_GT(!(dut.waiting === 1'b1 && dut.tx_word === 24'hFC14C0), 300,
               "the first byte of the pop case never got its frame");
      inj_arm  = 1'b1;           // armed for the pop that ends this frame
      inj_data = 8'hC4;
      for (jj = 1; jj <= 8; jj = jj + 1)
         rx_byte(8'hC0 + ((jj >= 4) ? (jj + 1) : jj));   // C1 C2 C3 C5 .. C9
      // the premise on the wire: still inside the frame, queue full, so the
      // armed byte can only land on the pop clock
      if (dut.waiting !== 1'b1 || dut.ur_cnt !== 4'd8) begin
         $display("tb_mcu_emu: FAIL before the injection the link is busy %b and the queue holds %0d entries, expected busy and 8", dut.waiting, dut.ur_cnt);
         $finish;
      end
      `WAIT_GT(dut.ur_cnt !== 4'd0 || dut.waiting === 1'b1, 300,
               "the bytes of the pop case never all went out");
      if (inj_cnt !== 1 || inj_full !== 1) begin
         $display("tb_mcu_emu: FAIL the injection happened %0d times (%0d on a full queue), expected 1 and 1", inj_cnt, inj_full);
         $finish;
      end
      // all ten arrive, in the queue's order, the injected one last, and no
      // idx is used twice
      `WAIT_GT(nrx < 29, 300, "a byte of the pop case was lost");
      for (jj = 0; jj < 10; jj = jj + 1) begin
         if (jj == 9)              bexp = 8'hC4;   // the injected byte
         else if (jj >= 4)         bexp = 8'hC0 + jj + 1;
         else                      bexp = 8'hC0 + jj;
         wexp = ((16'h14 + jj) << 8) | bexp;
         if (rxlog[19 + jj] !== wexp) begin
            $display("tb_mcu_emu: FAIL pop-case byte %0d arrived as %4h expected %4h",
                     jj, rxlog[19 + jj], wexp);
            $finish;
         end
      end
      if (nrx !== 29) begin
         $display("tb_mcu_emu: FAIL the pop case delivered %0d bytes, expected 10",
                  nrx - 19);
         $finish;
      end

      $display("tb_mcu_emu: PASS");
      $finish;
   end

   // global timeout
   initial begin
      #1_900_000_000;
      $display("tb_mcu_emu: FAIL timeout");
      $finish;
   end

endmodule
