//
// Communication module to MT32-pi (external MIDI emulator on RPi)
// (C) 2020 Sorgelig, Kitrinx
//
// https://github.com/dwhinham/mt32-pi
//

module mt32pi
(
	input             CLK_AUDIO,

	input             CLK_VIDEO,
	input             CE_PIXEL,
	input             VGA_VS,
	input             VGA_DE,

	input       [6:0] USER_IN,
	output      [6:0] USER_OUT,

	input             reset,
	input             midi_tx,
	output            midi_rx,

	output reg [15:0] mt32_i2s_r,
	output reg [15:0] mt32_i2s_l,

	output reg        mt32_available,

	input       [2:0] mt32_synth_req,  // 0 = FluidSynth/GM (0xA2), 1 = Munt (0xA1), 2 = EmuSC (0xA3), 3 = Nuked SC-55 (0xA4), 4 = MU50 (0xA5)
	input       [1:0] mt32_rom_req,
	input      [15:0] mt32_sf_req,

	input       [1:0] mt32_lcd_type,   // 0 = Auto, 1 = SSD1306 (whole frame in one I2C transfer), 2 = SH1106 (page by page), 3 = HD44780 (PCF8574 I2C)
	input       [1:0] mt32_hd_size,    // HD44780 size: 0 = 20x4, 1 = 16x2, 2 = 20x2, 3 = 16x4

	output reg  [7:0] mt32_mode,
	output reg  [7:0] mt32_rom,
	output reg  [7:0] mt32_sf,
	output reg        mt32_newmode,

	output reg        mt32_lcd_en,
	output reg        mt32_lcd_pix,
	output reg        mt32_lcd_update
);

//
// Pin | USB Name | Signal
// ----+----------+--------------
// 0   | D+       | I/O I2C_SDA / RX (midi in)
// 1   | D-       | O   TX (midi out)
// 2   | TX-      | I   I2S_WS (1 == right)
// 3   | GND_d    | I   I2C_SCL
// 4   | RX+      | I   I2S_BCLK
// 5   | RX-      | I   I2S_DAT
// 6   | TX+      | -   none
//

assign USER_OUT[0]   = sda_out;
assign USER_OUT[1]   = midi_tx;
assign USER_OUT[6:2] = '1;


//
// crossed/straight cable selection
//

generate
	genvar i;
	for(i = 0; i<2; i++) begin : clk_rate
		wire clk_in = i ? USER_IN[6] : USER_IN[4];
		reg [4:0] cnt;
		always @(posedge CLK_AUDIO) begin : clkr
			reg       clk_sr, clk, old_clk;
			reg [4:0] cnt_tmp;

			clk_sr <= clk_in;
			if (clk_sr == clk_in) clk <= clk_sr;

			if(~&cnt_tmp) cnt_tmp <= cnt_tmp + 1'd1;
			else cnt <= '1;

			old_clk <= clk;
			if(~old_clk & clk) begin
				cnt <= cnt_tmp;
				cnt_tmp <= 0;
			end
		end
	end
	
	reg crossed;
	always @(posedge CLK_AUDIO) crossed <= (clk_rate[0].cnt <= clk_rate[1].cnt);
endgenerate

wire   i2s_ws   = crossed ? USER_IN[2] : USER_IN[5];
wire   i2s_data = crossed ? USER_IN[5] : USER_IN[2];
wire   i2s_bclk = crossed ? USER_IN[4] : USER_IN[6];
assign midi_rx  = ~mt32_available ? USER_IN[0] : crossed ? USER_IN[6] : USER_IN[4];


//
// i2s receiver
//

always @(posedge CLK_AUDIO) begin : i2s_proc
	reg [15:0] i2s_buf = 0;
	reg  [4:0] i2s_cnt = 0;
	reg        clk_sr;
	reg        i2s_clk = 0;
	reg        old_clk, old_ws;
	reg        i2s_next = 0;

	// Debounce clock
	clk_sr <= i2s_bclk;
	if (clk_sr == i2s_bclk) i2s_clk <= clk_sr;

	// Latch data and ws on rising edge
	old_clk <= i2s_clk;
	if (i2s_clk && ~old_clk) begin

		if (~i2s_cnt[4]) begin
			i2s_cnt <= i2s_cnt + 1'd1;
			i2s_buf[~i2s_cnt[3:0]] <= i2s_data;
		end

		// Word Select will change 1 clock before the new word starts
		old_ws <= i2s_ws;
		if (old_ws != i2s_ws) i2s_next <= 1;
	end

	if (i2s_next) begin
		i2s_next <= 0;
		i2s_cnt <= 0;
		i2s_buf <= 0;

		if (i2s_ws) mt32_i2s_l <= i2s_buf;
		else        mt32_i2s_r <= i2s_buf;
	end
	
	if (reset) begin
		i2s_buf    <= 0;
		mt32_i2s_l <= 0;
		mt32_i2s_r <= 0;
	end
end


//
// i2c slave
//

reg        sda_out;
reg  [7:0] lcd_data[1024];
reg        lcd_sz;
reg  [2:0] lcd_page;   // SH1106: current page (set by command 0xB0..0xB7)
reg        sh_detect;  // SH1106 detected: SSD1306 driver never sends page commands 0xB0..0xB7
reg        hd_detect;  // HD44780 detected: PCF8574 backpack answered on address 0x27 / 0x3F
wire       is_hd     = (mt32_lcd_type == 2'd3) | ((mt32_lcd_type == 2'd0) & hd_detect);
wire       is_sh1106 = ~is_hd & ((mt32_lcd_type == 2'd2) | ((mt32_lcd_type == 2'd0) & sh_detect));
reg        hd;                 // current I2C transfer is addressed to the HD44780 backpack
reg        pcf_tgl = 0;        // toggles for every byte written to the backpack
reg  [7:0] pcf_byte;

reg        reset_r  = 0;
wire [7:0] mode_req = reset_r ? 8'hA0 :
                      (mt32_synth_req == 3'd1) ? 8'hA1 :   // MT-32 (Munt)
                      (mt32_synth_req == 3'd2) ? 8'hA3 :   // EmuSC
                      (mt32_synth_req == 3'd3) ? 8'hA4 :   // Nuked SC-55
                      (mt32_synth_req == 3'd4) ? 8'hA5 :   // MU50
                                                 8'hA2;    // FluidSynth / current GM engine
wire [7:0] rom_req  = {6'd0, mt32_rom_req};

always @(posedge CLK_AUDIO) begin : i2c_slave
	reg        sda_sr, scl_sr;
	reg        old_sda, old_scl;
	reg        sda, scl;
	reg  [7:0] tmp;
	reg  [3:0] cnt = 0;
	reg [10:0] bcnt = 0;
	reg        ack;
	reg        i2c_rw;
	reg        disp, dispdata;
	reg  [2:0] div;
	reg        old_reset;
	
	old_reset <= reset;
	if(old_reset & ~reset) sda_out <= 1;

	div <= div + 1'd1;
	if(!div) begin
		sda_sr <= USER_IN[0];
		if(sda_sr == USER_IN[0]) sda <= sda_sr;
		old_sda <= sda;

		scl_sr <= USER_IN[3];
		if(scl_sr == USER_IN[3]) scl <= scl_sr;
		old_scl <= scl;

		//start
		if(old_scl & scl & old_sda & ~sda) begin
			cnt <= 9;
			bcnt <= 0;
			ack <= 0;
			i2c_rw <= 0;
			disp <= 0;
			hd <= 0;
			dispdata <= 0;
		end

		//stop
		if(old_scl & scl & ~old_sda & sda) begin
			cnt <= 0;
			if(dispdata) begin
				lcd_sz <= is_sh1106 ? 1'b1 : ~bcnt[9];   // SH1106 is always 128x64
				mt32_lcd_update <= ~mt32_lcd_update;
			end
		end

		//data latch
		if(~old_scl && scl && cnt) begin
			tmp <= {tmp[6:0], sda};
			cnt <= cnt - 1'd1;
		end

		if(!cnt) sda_out <= 1;

		//data set
		if(old_scl && ~scl) begin
			sda_out <= 1;
			if(cnt == 1) begin
				if(!bcnt) begin
					if(tmp[7:1] == 'h45 || tmp[7:1] == 'h3c || tmp[7:1] == 'h27 || tmp[7:1] == 'h3f) begin
						disp <= (tmp[7:1] == 'h3c);
						hd   <= (tmp[7:1] == 'h27 || tmp[7:1] == 'h3f);
						sda_out <= 0;
						mt32_available <= 1;
						ack <= 1;
						i2c_rw <= tmp[0];
						bcnt <= bcnt + 1'd1;
						cnt <= 10;
					end
					else begin
						// wrong address, stop
						cnt <= 0;
					end
				end
				else if(ack) begin
					if(~i2c_rw) begin
						if(disp) begin
							if(bcnt == 1) dispdata <= (tmp[7:6] == 2'b01);
							else if(dispdata) lcd_data[is_sh1106 ? {lcd_page, bcnt[6:0] - 2'd2} : bcnt[9:0] - 2'd2] <= tmp;
							else if(bcnt == 2 && tmp[7:3] == 5'b10110) begin lcd_page <= tmp[2:0]; sh_detect <= 1; end   // SH1106 page address command
						end
						else if(hd) begin
							if(bcnt == 1) begin
								pcf_byte  <= tmp;
								pcf_tgl   <= ~pcf_tgl;
								mt32_lcd_update <= ~mt32_lcd_update;   // keeps "LCD-Auto" overlay alive
								hd_detect <= 1;
							end
						end
						else begin
							if(bcnt == 1) mt32_mode <= tmp;
							if(bcnt == 2) mt32_rom  <= tmp;
							if(bcnt == 3) mt32_sf   <= tmp;
							if(bcnt == 3) mt32_newmode <= ~mt32_newmode;
						end
					end
					if(~&bcnt) bcnt <= bcnt + 1'd1;
					sda_out <= 0;
					cnt <= 10;
				end
			end
			else if(i2c_rw && ack && cnt && ~disp && ~hd) begin
				if(bcnt == 1) sda_out <= mode_req    [cnt[2:0] - 2'd2];
				if(bcnt == 2) sda_out <= rom_req     [cnt[2:0] - 2'd2];
				if(bcnt == 3) sda_out <= mt32_sf_req [cnt[2:0] - 2'd2];
				if(bcnt == 3) reset_r <= 0;
			end
		end
	end

	if(reset) begin
		reset_r <= 1;
		sh_detect <= 0;
		hd_detect <= 0;
		mt32_available <= 0;
	end
end


//
// HD44780 character LCD (PCF8574 I2C backpack) emulation
//
// PCF8574 byte: D7..D4 = data nibble, bit3 = backlight, bit2 = E, bit1 = RW, bit0 = RS
// The nibble is latched on the falling edge of E.
//

reg  [7:0] hd_ddram [0:127];
reg  [4:0] hd_cgram [0:63];

// Power-up defaults: blank screen and the "narrow" bar-graph characters that mt32-pi loads once at its own start
// (the Pi may have sent them before this core was started, so they must be available without a CGRAM write)
initial begin : hd_ram_init
	integer i;
	for(i = 0; i < 128; i = i + 1) hd_ddram[i] = 8'h20;
	for(i = 0; i < 64;  i = i + 1) hd_cgram[i] = ((i % 8) >= (7 - (i / 8))) ? 5'b01110 : 5'b00000;
end

reg        pcf_tgl_d  = 0;
reg  [7:0] pcf_last   = 0;
reg        hd_sync    = 1;  // 4-bit mode assumed (the Pi may have initialized the LCD before the core was started)
reg        hd_hi_pend = 0;  // high nibble received
reg  [3:0] hd_hi;
reg        hd_cg      = 0;  // CGRAM addressed
reg        hd_inc     = 1;  // entry mode: increment
reg  [6:0] hd_addr    = 0;
reg        hd_clr     = 0;
reg  [6:0] hd_clr_cnt = 0;

always @(posedge CLK_AUDIO) begin : hd44780_proc
	reg        we, cgwe, do_nib, rs;
	reg  [6:0] wa;
	reg  [7:0] wd;
	reg  [7:0] b;
	reg  [3:0] nib;

	we = 0; cgwe = 0; do_nib = 0; rs = 0; nib = 0; wa = 0; wd = 0; b = 0;

	pcf_tgl_d <= pcf_tgl;
	if(pcf_tgl_d != pcf_tgl) begin
		pcf_last <= pcf_byte;
		if(pcf_last[2] & ~pcf_byte[2]) begin
			do_nib = 1;
			nib    = pcf_last[7:4];
			rs     = pcf_last[0];
		end
	end

	if(hd_clr) begin
		// clear display: fill DDRAM with spaces
		we = 1; wa = hd_clr_cnt; wd = 8'h20;
		hd_clr_cnt <= hd_clr_cnt + 1'd1;
		if(&hd_clr_cnt) hd_clr <= 0;
	end
	else if(do_nib) begin
		if(!hd_sync) begin
			// 8-bit mode init sequence (0x3,0x3,0x3), then 0x2 switches to 4-bit mode
			if(!rs && nib == 4'h2) begin
				hd_sync    <= 1;
				hd_hi_pend <= 0;
			end
		end
		else if(!hd_hi_pend) begin
			hd_hi      <= nib;
			hd_hi_pend <= 1;
		end
		else begin
			hd_hi_pend <= 0;
			b = {hd_hi, nib};
			if(rs) begin
				// data write
				if(hd_cg) cgwe = 1;
				else begin
					we = 1; wa = hd_addr; wd = b;
				end
				hd_addr <= hd_inc ? hd_addr + 1'd1 : hd_addr - 1'd1;
			end
			else if(b[7]) begin hd_cg <= 0; hd_addr <= b[6:0];        end  // set DDRAM address
			else if(b[6]) begin hd_cg <= 1; hd_addr <= {1'b0, b[5:0]}; end  // set CGRAM address
			else if(b[5]) begin if(b[4]) hd_sync <= 0;                 end  // function set: 8-bit => re-init
			else if(b == 8'h01) begin hd_clr <= 1; hd_clr_cnt <= 0; hd_addr <= 0; hd_cg <= 0; hd_inc <= 1; end  // clear
			else if(b[7:1] == 7'b0000001) begin hd_addr <= 0; hd_cg <= 0; end                                   // home
			else if(b[7:2] == 6'b000001)  begin hd_inc <= b[1];           end  // entry mode set
		end
	end

	if(we)   hd_ddram[wa] <= wd;
	if(cgwe) hd_cgram[hd_addr[5:0]] <= b[4:0];

	if(reset) begin
		hd_sync    <= 1;
		hd_hi_pend <= 0;
		hd_clr     <= 0;
		hd_cg      <= 0;
		hd_inc     <= 1;
	end
end

// 6x8 font (ASCII 0x20..0x80, 97 characters x 8 rows, bit 5 = leftmost pixel), from mt32-pi font6x8.h
localparam [4655:0] HD_FONT = 4656'hffffffffffff0001087c81000001027c210000c08204208c00410400410400620840820601f20409f00000e04f45100001128429100000a55545100000429145100000d4d145100000310411f10401e04e40f00001041061600000104f44f00001041e45e00000e45144e00001145165600001555555e00000e10410410c01251851241000c48208600200e10410c00401145165641000e04f44f00000410411f10300e41f44e00000f45144f04100f41040f00001e45145e41000f44f04e00000000000210601f00000000000000001128400e08208208e00411f11f29100e20820820e01f40810205f00410429145101144a10a45100a55555145100429145145100e45145145100410410411f00e44139044e01149479145e00d49545144e01041079145e00e45145144e0114535594510114515556d101f41041041001149461449100c48208208700e10410410e0114517d145100f4515d044e01041079041f01f41079041f01c49145149c00e45041044e01e45179145e01145f45144e00e41755744e00400408144e01020408421000001f01f00000210840810200810c00c30000030c00c30000c0813d144e00e45139144e00820810205f00e45179020600e44105e41f00209f48a18200e44108409f01f20408144e00e10410430400e45955344e00040810204000c3000000000000007c000000810c0000000001047c410000011539510000810208210800210820810200000000810c00d49521448c0034c81026580047853943c400a29f29f28a00000000a28a004000104104000000000000;

reg  [5:0] hd_font [0:1023];
initial begin : font_init
	integer i;
	for(i = 0; i < 1024; i = i + 1) hd_font[i] = (i < 776) ? HD_FONT[i*6 +: 6] : 6'd0;
end


// HD44780 renderer state
	reg [2:0] hd_xin;
	reg [4:0] hd_col;
	reg [6:0] hd_base;
	reg [6:0] s0_addr;  reg [2:0] s0_xin, s0_y;  reg s0_en;
	reg [7:0] s1_code;  reg [2:0] s1_xin, s1_y;  reg s1_en;
	reg [5:0] s2_fnt;   reg [4:0] s2_cg;  reg s2_iscg;  reg [2:0] s2_xin;  reg s2_en;
	reg       s3_pix, s3_en;
	wire      hd_c20 = ~mt32_hd_size[0];
	wire      hd_r4  = ~(mt32_hd_size[1] ^ mt32_hd_size[0]);
	// font index: ASCII 0x20..0x7F -> 0..95, 0xFF (full block) -> 96, everything else blank
	wire [6:0] s1_idx = (s1_code >= 8'h20 && s1_code <= 8'h7F) ? (s1_code[6:0] - 7'h20) : (s1_code == 8'hFF) ? 7'd96 : 7'd0;

always @(posedge CLK_VIDEO) begin
	reg old_de, old_vs;
	reg [7:0] hcnt;
	reg [6:0] vcnt;
	reg [7:0] sh;
   reg CE_PIXEL2;	

 CE_PIXEL2 <= ~CE_PIXEL2;	
	
	if(CE_PIXEL) begin
		old_de <= VGA_DE;
		old_vs <= VGA_VS;

		if(~&hcnt) hcnt <= hcnt + 1'd1;
		sh <= (sh << 1) | (~old_de & VGA_DE);
		if(sh[7]) hcnt <= 0;

		if(old_de & ~VGA_DE & ~&vcnt) vcnt <= vcnt + 1'd1;
		if(~old_vs & VGA_VS) vcnt <= 0;

		// ---- HD44780 text renderer: 6x8 cells, double height, 4 pipeline stages ----
		if(sh[7]) begin
			hd_xin <= 0;
			hd_col <= 0;
		end
		else if(hd_xin == 5) begin
			hd_xin <= 0;
			hd_col <= hd_col + 1'd1;
		end
		else hd_xin <= hd_xin + 1'd1;

		// stage 0: DDRAM address of the cell under the beam
		case(vcnt[5:4])
			2'd0: hd_base = 7'h00;
			2'd1: hd_base = 7'h40;
			2'd2: hd_base = hd_c20 ? 7'h14 : 7'h10;
			2'd3: hd_base = hd_c20 ? 7'h54 : 7'h50;
		endcase
		s0_addr <= hd_base + hd_col;
		s0_xin  <= hd_xin;
		s0_y    <= vcnt[3:1];
		s0_en   <= mt32_available & ~hcnt[7] & (hd_r4 ? !vcnt[6] : !vcnt[6:5]) & (hd_col < (hd_c20 ? 5'd20 : 5'd16));

		// stage 1: character code
		s1_code <= hd_ddram[s0_addr];
		s1_xin  <= s0_xin;
		s1_y    <= s0_y;
		s1_en   <= s0_en;

		// stage 2: glyph row (font ROM / CGRAM)
		s2_fnt  <= hd_font[{s1_idx, s1_y}];
		s2_cg   <= hd_cgram[{s1_code[2:0], s1_y}];
		s2_iscg <= (s1_code[7:4] == 4'd0);
		s2_xin  <= s1_xin;
		s2_en   <= s1_en;

		// stage 3: pixel
		s3_pix  <= s2_iscg ? (s2_xin == 0 ? 1'b0 : s2_cg[3'd5 - s2_xin]) : s2_fnt[3'd5 - s2_xin];
		s3_en   <= s2_en;

		if(is_hd) begin
			mt32_lcd_en  <= s3_en;
			mt32_lcd_pix <= s3_pix;
		end
		else begin
			mt32_lcd_en  <= mt32_available & ~hcnt[7] && (lcd_sz ? !vcnt[6] : !vcnt[6:5]);
			mt32_lcd_pix <= lcd_data[{vcnt[5:3],hcnt[6:0]}][vcnt[2:0]];
		end
		
	end
end

endmodule 

/*
always @(posedge CLK_VIDEO) begin
    reg old_de, old_vs;
    reg [7:0] hcnt;
    reg [6:0] vcnt;
    reg [7:0] sh;
    reg pixel_skip; // Флаг пропуска такта для сжатия по горизонтали
    reg line_skip;  // Флаг пропуска строк для сжатия по вертикали

    if(CE_PIXEL) begin
        old_de <= VGA_DE;
        old_vs <= VGA_VS;
        
        pixel_skip <= ~pixel_skip;
        
        // Сжимаем по горизонтали: увеличиваем счетчик только каждый 2-й пиксель
        if (pixel_skip && ~& hcnt) hcnt <= hcnt + 1'd1;
        
        sh <= (sh << 1) | (~ old_de & VGA_DE);
        if(sh[7]) begin
            hcnt <= 0;
            pixel_skip <= 0;
        end
        
        // Сжимаем по вертикали: считаем только каждую вторую строку видеосигнала
        if(old_de & ~ VGA_DE) begin
            line_skip <= ~line_skip;
            if (line_skip && ~& vcnt) vcnt <= vcnt + 1'd1;
        end
        
        if(~ old_vs & VGA_VS) begin
            vcnt <= 0;
            line_skip <= 0;
        end

        mt32_lcd_en <= mt32_available & ~ hcnt[7] && (lcd_sz ? ! vcnt[6] : ! vcnt[6:5]);
        mt32_lcd_pix <= lcd_data[{vcnt[5:3], hcnt[6:0]}][vcnt[2:0]];
    end
end

endmodule
*/