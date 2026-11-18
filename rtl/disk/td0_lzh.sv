// td0_lzh.sv - the LZSS + adaptive Huffman decoder of a Teledisk "td" file
// (Okumura's LZHUF: N = 4096, F = 60, THRESHOLD = 2, no length word), the
// hardware twin of tools/td0.py's LzhDecoder. Everything is one clock.
//
// Interface, both sides pull-driven so neither can overrun:
//   init     one-clock pulse: rebuild the tree, fill the ring buffer, drop
//            the bit buffer. The decoder is ready for input when `need`
//            first rises.
//   need     level: the decoder waits for a compressed byte. The source
//            answers with a one-clock in_vld pulse and the byte in in_data
//            while need is high; need falls on the next clock.
//   out_req  level, held by the consumer: it wants a decoded byte. The
//            decoder answers with a one-clock out_vld pulse and the byte
//            in out_data (stable until the next request); the consumer
//            drops out_req on seeing it.
// A request that finds the decoder starved of input simply waits until the
// source supplies more bits; a source that has nothing more leaves `need`
// high for good (the caller's end of file).
//
// The model's arrays: freq[0..T] (16 bit), prnt[0..T+N_CHAR-1] and
// son[0..T-1] (10 bit), the ring (4096 x 8). Each is a block RAM with one
// registered read port, so every read costs a set-address state, a wait state
// and a use state; the speed is not the point (about 250 clocks a symbol, a
// disk is a second or two) but the update walk does one RAM operation a state
// so that every write has landed before the next read.
`default_nettype none

module td0_lzh (
    input  wire       clk,
    input  wire       rst,
    input  wire       init,
    output wire       need,
    input  wire       in_vld,
    input  wire [7:0] in_data,
    input  wire       out_req,
    output reg        out_vld,
    output reg  [7:0] out_data
);
    localparam [9:0] T = 10'd627, R = 10'd626, NCHAR = 10'd314;

    // ---------------- the RAMs ----------------
    reg [15:0] freq [0:627];
    reg  [9:0] prnt [0:940];
    reg  [9:0] son  [0:626];
    reg  [7:0] ring [0:4095];
    reg  [9:0]  ra_f, ra_p, ra_s;
    reg  [11:0] ra_r;
    reg  [15:0] fq;
    reg  [9:0]  pq, sq;
    reg  [7:0]  rq;
    reg         we_f, we_p, we_s, we_r;
    reg  [9:0]  wa_f, wa_p, wa_s;
    reg  [11:0] wa_r;
    reg  [15:0] wd_f;
    reg  [9:0]  wd_p, wd_s;
    reg  [7:0]  wd_r;

    always @(posedge clk) begin
        if (we_f) freq[wa_f] <= wd_f;
        fq <= freq[ra_f];
    end
    always @(posedge clk) begin
        if (we_p) prnt[wa_p] <= wd_p;
        pq <= prnt[ra_p];
    end
    always @(posedge clk) begin
        if (we_s) son[wa_s] <= wd_s;
        sq <= son[ra_s];
    end
    always @(posedge clk) begin
        if (we_r) ring[wa_r] <= wd_r;
        rq <= ring[ra_r];
    end

    // ---------------- the position code (the static table) ----------------
    // d_code / d_len of LZHUF: 256 entries in runs; derived the same way as
    // tools/td0.py, which is checked against the real tables' run lengths.
    reg [5:0] pcode;
    function [9:0] ptab(input [7:0] i);
        begin
            if      (i < 8'd32)  ptab = {6'd0,                         4'd3};
            else if (i < 8'd48)  ptab = {6'd1,                         4'd4};
            else if (i < 8'd64)  ptab = {6'd2,                         4'd4};
            else if (i < 8'd80)  ptab = {6'd3,                         4'd4};
            else if (i < 8'd144) ptab = {6'd4  + {3'd0, (i - 8'd80)  >> 3}, 4'd5};
            else if (i < 8'd192) ptab = {6'd12 + {2'd0, (i - 8'd144) >> 2}, 4'd6};
            else if (i < 8'd240) ptab = {6'd24 + {1'd0, (i - 8'd192) >> 1}, 4'd7};
            else                 ptab = {6'd48 + {2'd0, (i - 8'd240)},      4'd8};
        end
    endfunction

    // ---------------- the state ----------------
    localparam [6:0]
        S_IDLE = 7'd0,
        S_I1A = 7'd1, S_I1B = 7'd2, S_I1C = 7'd3,
        S_I2A = 7'd4, S_I2B = 7'd5, S_I2C = 7'd6, S_I2D = 7'd7, S_I2E = 7'd8,
        S_I2F = 7'd9, S_I2G = 7'd10, S_I2H = 7'd11, S_I3A = 7'd12, S_I3B = 7'd13,
        S_IR = 7'd14,
        S_GB = 7'd15,
        S_D0 = 7'd16, S_D1 = 7'd17, S_D2 = 7'd18, S_D3 = 7'd19, S_D4 = 7'd20,
        S_D5 = 7'd21, S_D6 = 7'd22, S_DS = 7'd23,
        S_P0 = 7'd24, S_P1 = 7'd25, S_P2 = 7'd26, S_P3 = 7'd27, S_P4A = 7'd28,
        S_P4B = 7'd29, S_P5 = 7'd30,
        S_C0 = 7'd31, S_C1 = 7'd32, S_C2 = 7'd33,
        S_OUT = 7'd34, S_OUT2 = 7'd35,
        S_U0 = 7'd36, S_U1 = 7'd37, S_U2 = 7'd38, S_U3 = 7'd39, S_U4 = 7'd40,
        S_U5 = 7'd41,
        S_L0 = 7'd42, S_L1 = 7'd43, S_L2 = 7'd44, S_L3 = 7'd45, S_L4 = 7'd46,
        S_SC1 = 7'd47, S_SC2 = 7'd48,
        S_SW0 = 7'd49, S_SW1 = 7'd50, S_SW2 = 7'd51, S_SW3 = 7'd52, S_SW4 = 7'd53,
        S_SW5 = 7'd54, S_SW6 = 7'd55, S_SW7 = 7'd56,
        S_W1 = 7'd57, S_W2 = 7'd58, S_W3 = 7'd59, S_W4 = 7'd60, S_W5 = 7'd61,
        S_W6 = 7'd62, S_NX0 = 7'd63, S_NX1 = 7'd64, S_NX2 = 7'd65,
        S_R1A = 7'd66, S_R1B = 7'd67, S_R1C = 7'd68, S_R1D = 7'd69, S_R1E = 7'd88,
        S_R2A = 7'd70, S_R2B = 7'd71, S_R2C = 7'd72, S_R2D = 7'd73, S_R2E = 7'd74,
        S_R2F = 7'd75, S_R2G = 7'd76, S_R2H = 7'd77, S_R2M = 7'd78, S_R2N = 7'd79,
        S_R2O = 7'd80, S_R2P = 7'd81, S_R2Q = 7'd82, S_R2S = 7'd83,
        S_R3A = 7'd84, S_R3B = 7'd85, S_R3C = 7'd86, S_R3D = 7'd87;

    reg [6:0]  st = S_IDLE;
    reg [6:0]  gb_ret, up_ret;
    reg [7:0]  bb;
    reg [3:0]  bn;
    reg        bitv;
    reg [9:0]  c, l, i, j, t, kk;
    reg [15:0] k, f, fa;
    reg [8:0]  sym;
    reg [9:0]  ss;
    reg [11:0] r, src;
    reg [13:0] ii;
    reg [3:0]  nb, pext;
    reg [5:0]  mcnt;
    reg        mflag, sfl;
    reg [7:0]  cv;
    reg [11:0] ri;

    wire [9:0] pt = ptab(ii[7:0]);
    assign need = (st == S_GB) && (bn == 4'd0);

    always @(posedge clk) begin
        we_f <= 1'b0; we_p <= 1'b0; we_s <= 1'b0; we_r <= 1'b0;
        out_vld <= 1'b0;

        if (rst) begin
            st <= S_IDLE; bn <= 4'd0;
        end
        else if (init) begin
            i  <= 10'd0;
            st <= S_I1A;
        end
        else case (st)
        S_IDLE: ;

        // ============ StartHuff ============
        S_I1A: begin we_f <= 1'b1; wa_f <= i; wd_f <= 16'd1;            st <= S_I1B; end
        S_I1B: begin we_s <= 1'b1; wa_s <= i; wd_s <= i + T;            st <= S_I1C; end
        S_I1C: begin
            we_p <= 1'b1; wa_p <= i + T; wd_p <= i;
            if (i == NCHAR - 10'd1) begin
                i <= 10'd0; j <= NCHAR; st <= S_I2A;
            end
            else begin i <= i + 10'd1; st <= S_I1A; end
        end
        S_I2A: begin
            if (j > R) st <= S_I3A;
            else begin ra_f <= i; st <= S_I2B; end
        end
        S_I2B: st <= S_I2C;
        S_I2C: begin fa <= fq; ra_f <= i + 10'd1; st <= S_I2D; end
        S_I2D: st <= S_I2E;
        S_I2E: begin we_f <= 1'b1; wa_f <= j; wd_f <= fa + fq;          st <= S_I2F; end
        S_I2F: begin we_s <= 1'b1; wa_s <= j; wd_s <= i;                st <= S_I2G; end
        S_I2G: begin we_p <= 1'b1; wa_p <= i; wd_p <= j;                st <= S_I2H; end
        S_I2H: begin
            we_p <= 1'b1; wa_p <= i + 10'd1; wd_p <= j;
            i <= i + 10'd2; j <= j + 10'd1; st <= S_I2A;
        end
        S_I3A: begin we_f <= 1'b1; wa_f <= T; wd_f <= 16'hFFFF;         st <= S_I3B; end
        S_I3B: begin
            we_p <= 1'b1; wa_p <= R; wd_p <= 10'd0;
            ri <= 12'd0; st <= S_IR;
        end
        S_IR: begin                                  // the ring: spaces, then zeros
            we_r <= 1'b1; wa_r <= ri; wd_r <= (ri < 12'd4036) ? 8'h20 : 8'h00;
            ri <= ri + 12'd1;
            if (ri == 12'd4095) begin
                r <= 12'd4036; bn <= 4'd0; st <= S_D0;
            end
        end

        // ============ one bit ============
        S_GB: begin
            if (bn == 4'd0) begin
                if (in_vld) begin bb <= in_data; bn <= 4'd8; end
            end
            else begin
                bitv <= bb[7]; bb <= {bb[6:0], 1'b0}; bn <= bn - 4'd1;
                st <= gb_ret;
            end
        end

        // ============ DecodeChar ============
        S_D0: begin ra_s <= R; st <= S_D1; end
        S_D1: st <= S_D2;
        S_D2: begin c <= sq; st <= S_D3; end
        S_D3: begin
            if (c < T) begin gb_ret <= S_D4; st <= S_GB; end
            else begin sym <= c[8:0] - T[8:0]; up_ret <= S_DS; st <= S_U0; end
        end
        S_D4: begin ra_s <= c + {9'd0, bitv}; st <= S_D5; end
        S_D5: st <= S_D6;
        S_D6: begin c <= sq; st <= S_D3; end

        // the symbol: a literal goes out, a match decodes its position
        S_DS: begin
            if (sym < 9'd256) begin
                cv <= sym[7:0]; mflag <= 1'b0; st <= S_OUT;
            end
            else begin
                nb <= 4'd0; ii <= 14'd0; st <= S_P1;
            end
        end

        // ============ DecodePosition ============
        S_P1: begin gb_ret <= S_P2; st <= S_GB; end
        S_P2: begin
            ii <= {ii[12:0], bitv}; nb <= nb + 4'd1;
            st <= (nb == 4'd7) ? S_P3 : S_P1;
        end
        S_P3: begin
            pcode <= pt[9:4];
            pext  <= pt[3:0] - 4'd2;
            nb    <= 4'd0;
            st    <= (pt[3:0] == 4'd2) ? S_P5 : S_P4A;
        end
        S_P4A: begin gb_ret <= S_P4B; st <= S_GB; end
        S_P4B: begin
            ii <= {ii[12:0], bitv}; nb <= nb + 4'd1;
            st <= (nb + 4'd1 == pext) ? S_P5 : S_P4A;
        end
        S_P5: begin
            src  <= r - ({pcode, 6'd0} | {6'd0, ii[5:0]}) - 12'd1;
            mcnt <= sym[5:0] + 6'd3;       // j = sym - 255 + 2 = sym - 253 (3..60)
            mflag <= 1'b1;
            st   <= S_C0;
        end
        S_C0: begin ra_r <= src; st <= S_C1; end
        S_C1: st <= S_C2;
        S_C2: begin cv <= rq; src <= src + 12'd1; st <= S_OUT; end

        // ============ the byte goes out, the ring takes it ============
        S_OUT: begin
            if (out_req) begin
                out_data <= cv; out_vld <= 1'b1;
                we_r <= 1'b1; wa_r <= r; wd_r <= cv; r <= r + 12'd1;
                st <= S_OUT2;
            end
        end
        S_OUT2: begin
            if (!mflag || mcnt == 6'd1) st <= S_D0;
            else begin mcnt <= mcnt - 6'd1; st <= S_C0; end
        end

        // ============ update(sym) ============
        S_U0: begin ra_f <= R; st <= S_U1; end
        S_U1: st <= S_U2;
        S_U2: begin
            if (fq == 16'h8000) st <= S_R1A; else st <= S_U3;
        end
        S_U3: begin ra_p <= {1'b0, sym} + T; st <= S_U4; end
        S_U4: st <= S_U5;
        S_U5: begin c <= pq; st <= S_L0; end

        S_L0: begin ra_f <= c; st <= S_L1; end
        S_L1: st <= S_L2;
        S_L2: begin
            k <= fq + 16'd1;
            we_f <= 1'b1; wa_f <= c; wd_f <= fq + 16'd1;
            ra_f <= c + 10'd1;
            st <= S_L3;
        end
        S_L3: st <= S_L4;
        S_L4: begin
            if (k > fq) begin l <= c + 10'd2; ra_f <= c + 10'd2; st <= S_SC1; end
            else st <= S_NX0;
        end
        S_SC1: st <= S_SC2;
        S_SC2: begin
            if (k > fq) begin l <= l + 10'd1; ra_f <= l + 10'd1; st <= S_SC1; end
            else begin l <= l - 10'd1; st <= S_SW0; end
        end
        S_SW0: begin ra_f <= l; st <= S_SW1; end
        S_SW1: st <= S_SW2;
        S_SW2: begin we_f <= 1'b1; wa_f <= c; wd_f <= fq; st <= S_SW3; end   // freq[c] = freq[l]
        S_SW3: begin
            we_f <= 1'b1; wa_f <= l; wd_f <= k;                               // freq[l] = k
            ra_s <= c; st <= S_SW4;
        end
        S_SW4: st <= S_SW5;
        S_SW5: begin i <= sq; ra_s <= l; st <= S_SW6; end                     // i = son[c]
        S_SW6: st <= S_SW7;
        S_SW7: begin j <= sq; st <= S_W1; end                                 // j = son[l]
        S_W1: begin we_p <= 1'b1; wa_p <= i; wd_p <= l; st <= S_W2; end
        S_W2: begin
            if (i < T) begin we_p <= 1'b1; wa_p <= i + 10'd1; wd_p <= l; end
            st <= S_W3;
        end
        S_W3: begin we_s <= 1'b1; wa_s <= l; wd_s <= i; st <= S_W4; end
        S_W4: begin we_p <= 1'b1; wa_p <= j; wd_p <= c; st <= S_W5; end
        S_W5: begin
            if (j < T) begin we_p <= 1'b1; wa_p <= j + 10'd1; wd_p <= c; end
            st <= S_W6;
        end
        S_W6: begin we_s <= 1'b1; wa_s <= c; wd_s <= j; c <= l; st <= S_NX0; end
        S_NX0: begin ra_p <= c; st <= S_NX1; end
        S_NX1: st <= S_NX2;
        S_NX2: begin
            c <= pq;
            st <= (pq == 10'd0) ? up_ret : S_L0;
        end

        // ============ reconstruct ============
        // 1: gather the leaves at the front, halving their counts
        S_R1A: begin i <= 10'd0; j <= 10'd0; st <= S_R1B; end
        S_R1B: begin
            if (i == T) begin i <= 10'd0; j <= NCHAR; st <= S_R2A; end
            else begin ra_s <= i; ra_f <= i; st <= S_R1C; end
        end
        S_R1C: st <= S_R1D;
        S_R1D: begin
            if (sq >= T) begin
                we_f <= 1'b1; wa_f <= j; wd_f <= (fq + 16'd1) >> 1;
                ss <= sq; st <= S_R1E;
            end
            else begin i <= i + 10'd1; st <= S_R1B; end
        end
        S_R1E: begin                                       // son[j] = ss
            we_s <= 1'b1; wa_s <= j; wd_s <= ss;
            j <= j + 10'd1; i <= i + 10'd1; st <= S_R1B;
        end
        // 2: the internal nodes, inserted in frequency order
        S_R2A: begin
            if (j == T) begin i <= 10'd0; st <= S_R3A; end
            else begin ra_f <= i; st <= S_R2B; end
        end
        S_R2B: st <= S_R2C;
        S_R2C: begin fa <= fq; ra_f <= i + 10'd1; st <= S_R2D; end
        S_R2D: st <= S_R2E;
        S_R2E: begin f <= fa + fq; kk <= j - 10'd1; st <= S_R2F; end
        S_R2F: begin ra_f <= kk; st <= S_R2G; end
        S_R2G: st <= S_R2H;
        S_R2H: begin
            if (f < fq && kk != 10'd0) begin
                kk <= kk - 10'd1; ra_f <= kk - 10'd1; st <= S_R2G;
            end
            else begin k <= {6'd0, kk} + 16'd1; t <= j; st <= S_R2M; end
        end
        S_R2M: begin                                       // shift [k, j) up by one
            if ({6'd0, t} == k) st <= S_R2Q;
            else begin ra_f <= t - 10'd1; ra_s <= t - 10'd1; st <= S_R2N; end
        end
        S_R2N: st <= S_R2O;
        S_R2O: begin we_f <= 1'b1; wa_f <= t; wd_f <= fq; ss <= sq; st <= S_R2P; end
        S_R2P: begin we_s <= 1'b1; wa_s <= t; wd_s <= ss; t <= t - 10'd1; st <= S_R2M; end
        S_R2Q: begin we_f <= 1'b1; wa_f <= k[9:0]; wd_f <= f; st <= S_R2S; end
        S_R2S: begin
            we_s <= 1'b1; wa_s <= k[9:0]; wd_s <= i;
            i <= i + 10'd2; j <= j + 10'd1; st <= S_R2A;
        end
        // 3: the parents
        S_R3A: begin ra_s <= i; st <= S_R3B; end
        S_R3B: st <= S_R3C;
        S_R3C: begin
            we_p <= 1'b1; wa_p <= sq; wd_p <= i;
            ss <= sq; sfl <= (sq < T);
            st <= S_R3D;
        end
        S_R3D: begin
            if (sfl) begin we_p <= 1'b1; wa_p <= ss + 10'd1; wd_p <= i; end
            if (i == T - 10'd1) st <= S_U3;
            else begin i <= i + 10'd1; st <= S_R3A; end
        end
        default: st <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
