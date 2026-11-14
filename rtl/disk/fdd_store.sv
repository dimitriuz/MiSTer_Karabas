// fdd_store.sv - the floppy image store of the VG93 drives (stage 4c): the
// images of the two drives in DDR3 behind ddr_arb (master 1), the track
// builder that formats the 6250-byte tracks the drives read, the write-back
// of the sectors the drives wrote, and the drain of the dirty blocks back to
// the host. Everything is gs_clk (clk); the clocks clk_bus and clk_sys only
// clock the far side of the dual-clock buffers, and every crossing to or
// from them is a toggle with a two-flop synchroniser (the img_src rule).
//
// DDR map (the ruling, matching ddram_model): one 2 MiB window per drive at
// byte 0x3800_0000: ddr_addr = {4'b0011, 1'b1, 5'd0, drive, offset[20:3]},
// one 64-bit line per request (burstcnt is the arbiter's 1). Image bytes and
// patched sectors are written one byte at a time with be = 1 << offset[2:0]
// and the byte replicated in every lane (the gs_mem shape; the model keeps
// lane v of din at word bit 8*v); reads take whole lines with be all ones.
// The master protocol is gs_mem's: address, data and be set up on one edge,
// strobe and req raised on the next and held to the accept (busy low),
// where the strobe falls; a read keeps req up to its dout_ready.
//
// Fill (from fdd_src, one event at a time, the host waits for fill_ack
// before the next): a 32-bit word whose top two bits are the kind.
//   0 config: {drive, kind[1:0] (0 TRD, 1 CP/M, 2 FDI), tracks[6:0], sides}
//     - and it clears the drive's state: ready, dirty bitmap, position
//     table count. That is also the eject.
//   1 byte:   {addr[21:0], data[7:0]}: addr[21]=0 is an image byte at
//     drive_base + addr[20:0]; addr[21]=1, addr[20]=1 is an FDI track
//     header byte {1,1, track[7:0], byte[2:0]} (bytes 0..3 the DataOffset
//     LE, byte 4 the sector count); addr[21]=1, addr[20]=0 is a sector
//     record byte {1,0, track[7:0], sector[4:0], byte[2:0]} (C,H,R,N,flags,
//     offset lo, offset hi). Table bytes belong to the drive last
//     configured.
//   2 ready:  {drive} - track building starts.
// Tracks are capped at 84 (the table holds 84*2 blocks), sides at 2, sectors
// per track at 32; Main itself rejects images whose track does not fit.
//
// Track builder: on a request whose echo it answers, the builder reads the
// track's sectors from DDR (TRD: 16x256 at ((track*2+side)*16+sec)*256 with
// H=0; CP/M: 5x1024 at ((track*2+side)*5+sec)*1024 with H=side; FDI: the
// table block track*2+side, offsets relative to the table's DataOffset, H
// from the record) and formats each sector exactly as mk_disk.reftrack
// writes it - 10x4E, 12x00, 3xA1 + FE + C,H,R,N + CRC, 22x4E, 12x00, 3xA1 +
// FB + data + CRC, 60x4E, CCITT-FFFF over the three A1s, the mark and the
// data, high byte first - a flags-0x40 FDI sector emitting the ID block and
// the tail only. The track buffer (8192x9 per drive, {sync, byte}, sync 1
// only at the six A1s) is written whole and padded to 6250 with 4E. Each
// sector records {buffer offset of its data, file offset, ok} in the
// drive's position table, and the ack answers {ready, echo} - ready 0 (no
// image mounted, the track beyond the mounted geometry, an FDI block with
// no sectors) acks without building, which is what an empty drive looks
// like to the chip.
//
// Write-back: on wr_tgl (the written sector sitting in the 1024x8 buffer,
// port A clocked by clk_bus, exactly as floppy.sv drives it) the sector is
// found in the position table - TRD and CP/M by R (R-1), FDI by matching
// C,H,R,N against the table records of the built block - and then, byte by
// byte: read from the write buffer (its port B, three clocks per byte:
// present, wait, take - the altsyncram registers its read address), written
// to DDR at the file offset, and patched into the track buffer (the port A
// the builder also owns; the two never run at once). After the data the
// recomputed CRC goes into the buffer too (CCITT over {A1,A1,A1,FB,data}).
// TRD and CP/M then mark the touched 512-byte blocks dirty (one block for a
// 256-byte sector, two for a 1024-byte one); an FDI drive is volatile - the
// patched bytes stay in DDR and never drain. wr_ack_tgl answers either way,
// also when the sector cannot be found.
//
// Drain: one block in flight. A scan finds a dirty block, reads its 512
// bytes from DDR into the drain buffer (port A; the host reads port B on
// clk_sys), toggles {drive, block} to the host and waits: the block's dirty
// bit falls with the host's ack, so a config (which clears the bitmap)
// landing mid-drain simply removes the block, and the host's late ack of it
// is consumed harmlessly. One in flight means a drop can never orphan a
// toggle and an eject can never hang the store.
`default_nettype none

module fdd_store (
    input  wire        clk, reset,          // gs_clk (the DDRAM_CLK domain)
    input  wire        clk_bus,             // the track/write buffers' far side
    input  wire        clk_sys,             // the drain buffer's far side
    // ddr_arb master 1
    output wire [28:0] f_addr,
    output wire [63:0] f_din,
    output wire  [7:0] f_be,
    output reg         f_req,
    output reg         f_rd,
    output reg         f_we,
    input  wire        f_busy,
    input  wire [63:0] f_dout,
    input  wire        f_dout_ready,
    // fill (the fdd_src side, toggle handshake)
    input  wire        fill_tgl,
    input  wire [31:0] fill_word,
    output reg         fill_ack_tgl,
    // the floppy side (floppy.sv, clk_bus toggles; buffer port B pins)
    input  wire        trk_req_tgl,
    input  wire [8:0]  trk_req,             // {drive, side, track[6:0]}
    output reg         trk_ack_tgl,
    output reg  [9:0]  trk_ack,             // {ready, echo}
    input  wire [12:0] trk_addr_b,
    output wire [8:0]  trk_q_b,
    input  wire [9:0]  wr_addr,             // write buffer port A (clk_bus)
    input  wire [7:0]  wr_data,
    input  wire        wr_we,
    input  wire [35:0] wr_info,             // {drive,side,track,C,H,R,N[2:0]}
    input  wire        wr_tgl,
    output reg         wr_ack_tgl,
    // the drain host (fdd_src, clk_sys)
    input  wire [8:0]  drn_addr_b,
    output wire [7:0]  drn_q_b,
    output reg         drn_tgl,
    output reg  [11:0] drn_info,            // {drive, block[10:0]}
    input  wire        drn_ack_tgl
);

    localparam [9:0]  BASE   = {4'b0011, 1'b1, 5'd0};  // word 0x0700_0000 top
    localparam [1:0]  K_TRD  = 2'd0, K_CPM = 2'd1, K_FDI = 2'd2;
    localparam [6:0]  LAST   = 7'd83;        // the 84-track cap
    localparam [12:0] TRKEND = 13'd6250;     // bytes of one built track

    // ---------------- reset synchroniser ----------------
    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk or posedge reset) begin
        if (reset) rst_sync <= 2'b11;
        else       rst_sync <= {rst_sync[0], 1'b0};
    end
    wire rst = rst_sync[1];

    // ---------------- the track CRC (floppy's crc_byte, the same chain) --
    function [15:0] crc_byte(input [15:0] crc, input [7:0] b);
        integer i;
        begin
            crc_byte = crc ^ {b, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                crc_byte = crc_byte[15] ? {crc_byte[14:0], 1'b0} ^ 16'h1021
                                        : {crc_byte[14:0], 1'b0};
        end
    endfunction
    wire [15:0] crc_a13 =
        crc_byte(crc_byte(crc_byte(16'hFFFF, 8'hA1), 8'hA1), 8'hA1);

    // ---------------- the FDI table RAM (both drives, one read port) ----
    // One flat byte array; the fill byte addresses land on it directly.
    // Block stride 228: sector records at 0..223 (32 x 7), the 5-byte track
    // header at 220..224 - the header lies in the padding stride leaves
    // after sector 31's record (records use 7 of every 8), so the two can
    // never collide. 168 blocks (84 tracks x 2 sides) x 2 drives.
    reg [7:0]  tbl [0:76607];
    reg [16:0] t_addr;
    reg [7:0]  t_q;                          // registered read, one clock
    always @(posedge clk) t_q <= tbl[t_addr];

    function [16:0] blk_base(input d, input [7:0] t);
        begin blk_base = ((d ? 17'd168 : 17'd0) + {9'd0, t}) * 17'd228; end
    endfunction

    // ---------------- drive state ----------------
    reg [1:0]    cfg_k2    [0:1];
    reg          cfg_ready [0:1];
    reg          cfg_drv;                  // last configured (owns table bytes)
    reg [4095:0] dirty;                  // {drive, block[10:0]}: 512 B each
    reg [5:0]    pos_cnt   [0:1];
    reg [7:0]    pos_ti    [0:1];          // table block the positions came from
    reg [12:0]   pos_buf    [0:127];      // indexed {drive, sector[5:0]}
    reg [20:0]   pos_file   [0:127];
    reg          pos_ok     [0:127];
    wire         dirty_any = |dirty;

    // ---------------- the DDR micro-ops ----------------
    reg [28:0] d_addr;
    reg [63:0] d_din;
    reg  [7:0] d_be;
    reg  [6:0] dret;
    reg [63:0] lc_reg;                     // the line a read brought back
    assign f_addr = d_addr;
    assign f_din  = d_din;
    assign f_be   = d_be;

    // ---------------- buffer ports ----------------
    reg        tk_we;                      // track buffer port A (clk)
    reg        tk_drv;
    reg [12:0] tk_waddr;
    reg [8:0]  tk_wdata;
    reg [9:0]  wr_raddr;                   // write buffer port B address (clk)
    wire [7:0] wr_q_b;
    reg        dn_we;                      // drain buffer port A (clk)
    reg [8:0]  dn_waddr;
    reg [7:0]  dn_wdata;
    reg        stream_drv;                 // the drive the track mux answers for

    // ---------------- handshake samplers (clk_bus / clk_sys edges) ----
    reg fill_s1 = 1'b0, fill_s2 = 1'b0, fill_seen = 1'b0, fill_pend = 1'b0;
    reg [31:0] fill_pay = 32'd0;
    reg trq_s1 = 1'b0, trq_s2 = 1'b0, trq_seen = 1'b0, req_new = 1'b0;
    reg [8:0] req_cur = 9'd0;
    reg wrq_s1 = 1'b0, wrq_s2 = 1'b0, wrq_seen = 1'b0, wrq_pend = 1'b0;
    reg [35:0] wrq_pay = 36'd0;
    reg dna_s1 = 1'b0, dna_s2 = 1'b0, dna_seen = 1'b0, dna_pend = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            fill_s1 <= 1'b0; fill_s2 <= 1'b0; fill_seen <= 1'b0;
            trq_s1  <= 1'b0; trq_s2  <= 1'b0; trq_seen  <= 1'b0;
            wrq_s1  <= 1'b0; wrq_s2  <= 1'b0; wrq_seen  <= 1'b0;
            dna_s1  <= 1'b0; dna_s2  <= 1'b0; dna_seen  <= 1'b0;
        end
        else begin
            fill_s1 <= fill_tgl;    fill_s2 <= fill_s1;
            trq_s1  <= trk_req_tgl; trq_s2  <= trq_s1;
            wrq_s1  <= wr_tgl;      wrq_s2  <= wrq_s1;
            dna_s1  <= drn_ack_tgl; dna_s2  <= dna_s1;
        end
    end

    // ---------------- the work registers ----------------
    reg [6:0]  state;
    reg        b_drv, b_side, b_nodata;
    reg [6:0]  b_trk;
    reg [7:0]  b_ti;
    reg [1:0]  b_k2;
    reg [5:0]  b_cnt, b_sec;
    reg [2:0]  b_hi, b_tb;
    reg [12:0] b_bufp;
    reg [20:0] b_fbase;
    reg [2:0]  b_N;
    reg [10:0] b_len, b_i;
    reg [6:0]  b_c;
    reg [7:0]  b_C, b_H, b_R;
    reg [15:0] crc_id, crc_dat;
    reg [31:0] b_doff;
    reg [7:0]  b_rolo;

    reg        w_drv, w_side;
    reg [7:0]  w_C, w_H, w_R;
    reg [2:0]  w_N;
    reg [5:0]  w_sec;
    reg [2:0]  w_sc;
    reg [20:0] w_fbase;
    reg [12:0] w_bufp;
    reg [10:0] w_len, w_i;
    reg [7:0]  w_dat;
    reg [15:0] w_crc;

    reg [11:0] dn_ptr;
    reg        dn_inflight;
    reg        dn_drv;
    reg [10:0] dn_blk;
    reg [5:0]  dn_ln;
    reg [2:0]  dn_b;

    // ---------------- states ----------------
    localparam [6:0] S_IDLE   = 7'd0,
                     S_DW0    = 7'd1,  S_DW1    = 7'd2,
                     S_DR0    = 7'd3,  S_DR1    = 7'd4,  S_DR2   = 7'd5,
                     S_B_HDR0 = 7'd8,  S_B_HDR1 = 7'd9,  S_B_HRW = 7'd6,
                     S_B_RRW  = 7'd7,
                     S_B_R0   = 7'd10, S_B_R1   = 7'd11, S_B_SEC = 7'd12,
                     S_B_G1   = 7'd13, S_B_S1   = 7'd14, S_B_ID  = 7'd15,
                     S_B_IC   = 7'd16, S_B_G3   = 7'd17, S_B_G4  = 7'd18,
                     S_B_S2   = 7'd19, S_B_FB   = 7'd20, S_B_DT  = 7'd21,
                     S_B_DT2  = 7'd22, S_B_DC   = 7'd23, S_B_G5  = 7'd24,
                     S_B_PAD  = 7'd25,
                     S_B_ACK0 = 7'd26, S_B_ACK1 = 7'd27,
                     S_B_NR0  = 7'd28, S_B_NR1 = 7'd29,
                     S_W_ST   = 7'd30,
                     S_W_R0   = 7'd31, S_W_R1   = 7'd32, S_W_R2  = 7'd33,
                     S_W_R3   = 7'd34, S_W_C0   = 7'd35, S_W_C1   = 7'd36,
                     S_W_DRT  = 7'd37, S_W_ACK  = 7'd38,
                     S_W_SC0  = 7'd39, S_W_SC1  = 7'd40,
                     S_D_SC   = 7'd41, S_D_W8   = 7'd42,
                     S_D_T0   = 7'd43, S_D_T1   = 7'd44, S_D_T2 = 7'd45,
                     S_W_SCW  = 7'd46;
    wire [20:0] b_fo = b_fbase + {10'd0, b_i};   // this data byte, file addr
    wire [20:0] w_fo = w_fbase + {10'd0, w_i};   // written byte, file addr
    wire [20:0] w_end = w_fbase + {10'd0, w_len} - 21'd1;  // last byte written
    wire [2:0]  w_Nc = (w_N > 3'd3) ? 3'd3 : w_N;  // the 1024-byte ceiling

    // the id byte the builder emits in S_B_ID (FE C H R N)
    reg [7:0] id_b;
    always @(*) begin
        if      (b_c == 7'd0) id_b = 8'hFE;
        else if (b_c == 7'd1) id_b = b_C;
        else if (b_c == 7'd2) id_b = b_H;
        else if (b_c == 7'd3) id_b = b_R;
        else                  id_b = {4'd0, b_N};
    end

    // --------------------------------------------------------------------
    always @(posedge clk) begin
        tk_we <= 1'b0;                     // buffer writes pulse for one clock
        dn_we <= 1'b0;

        if (rst) begin
            state       <= S_IDLE;
            f_req <= 1'b0; f_rd <= 1'b0; f_we <= 1'b0;
            fill_ack_tgl <= 1'b0; trk_ack_tgl <= 1'b0; trk_ack <= 10'd0;
            wr_ack_tgl <= 1'b0;  drn_tgl <= 1'b0;  drn_info <= 12'd0;
            fill_pend <= 1'b0; req_new <= 1'b0;
            wrq_pend <= 1'b0;  dna_pend <= 1'b0;
            dn_inflight <= 1'b0;
        end
        else begin
            // ---- handshake events (every state sees them) ----
            if (fill_s2 != fill_seen) begin
                fill_seen <= fill_s2;
                fill_pay  <= fill_word;
                fill_pend <= 1'b1;
            end
            if (trq_s2 != trq_seen) begin
                trq_seen <= trq_s2;
                req_cur  <= trk_req;
                req_new  <= 1'b1;
            end
            if (wrq_s2 != wrq_seen) begin
                wrq_seen <= wrq_s2;
                wrq_pay  <= wr_info;
                wrq_pend <= 1'b1;
            end
            if (dna_s2 != dna_seen) begin
                dna_seen <= dna_s2;
                dna_pend <= 1'b1;
            end

            case (state)
            // ==================== the scheduler ====================
            S_IDLE: begin
                if (dna_pend) begin        // an acked block stops being dirty
                    dna_pend <= 1'b0;
                    if (dn_inflight) begin
                        dirty[{dn_drv, dn_blk}] <= 1'b0;
                        dn_inflight <= 1'b0;
                    end
                end
                if (fill_pend) begin
                    fill_pend    <= 1'b0;
                    fill_ack_tgl <= ~fill_ack_tgl;
                    case (fill_pay[31:30])
                        2'd0: begin                 // config: mounts, ejects
                            cfg_k2[fill_pay[29]]   <= fill_pay[28:27];
                            cfg_ready[fill_pay[29]] <= 1'b0;
                            dirty[{fill_pay[29], 11'd0} +: 2048] <= 2048'd0;
                            pos_cnt[fill_pay[29]]   <= 6'd0;
                            cfg_drv                 <= fill_pay[29];
                        end
                        2'd1: begin                 // one image/table byte
                            if (!fill_pay[29]) begin            // image byte
                                d_addr <= {BASE, cfg_drv, fill_pay[28:11]};
                                d_din  <= {8{fill_pay[7:0]}};
                                d_be   <= 8'd1 << fill_pay[10:8];
                                dret   <= S_IDLE;
                                state  <= S_DW0;
                            end
                            else if (fill_pay[28] &&
                                     fill_pay[18:11] <= 8'd167) begin
                                tbl[blk_base(cfg_drv, fill_pay[18:11])
                                     + 17'd220 + {14'd0, fill_pay[10:8]}]
                                    <= fill_pay[7:0];           // header byte
                            end
                            else if (!fill_pay[28] &&
                                     fill_pay[23:16] <= 8'd167 &&
                                     fill_pay[15:11] <= 5'd31) begin
                                tbl[blk_base(cfg_drv, fill_pay[23:16])
                                     + {12'd0, fill_pay[15:11]} * 17'd7
                                     + {14'd0, fill_pay[10:8]}]
                                    <= fill_pay[7:0];           // record byte
                            end
                        end
                        2'd2:
                            cfg_ready[fill_pay[29]] <= 1'b1;     // ready
                        default: ;
                    endcase
                end
                else if (req_new) begin
                    req_new    <= 1'b0;
                    b_drv      <= req_cur[8];
                    b_side     <= req_cur[7];
                    b_trk      <= req_cur[6:0];
                    b_ti       <= {req_cur[7:0], 1'b0} + {8'd0, req_cur[7]};
                    b_k2       <= cfg_k2[req_cur[8]];
                    b_bufp     <= 13'd0;
                    stream_drv <= req_cur[8];
                    pos_ti[req_cur[8]] <= {req_cur[7:0], 1'b0}
                                          + {8'd0, req_cur[7]};
                    if (!cfg_ready[req_cur[8]] || req_cur[6:0] > LAST)
                        state <= S_B_NR0;
                    else if (cfg_k2[req_cur[8]] == K_FDI) begin
                        b_hi  <= 3'd0;
                        state <= S_B_HDR0;
                    end
                    else begin
                        b_cnt <= (cfg_k2[req_cur[8]] == K_CPM)
                                   ? 6'd5 : 6'd16;
                        pos_cnt[req_cur[8]] <= (cfg_k2[req_cur[8]] == K_CPM)
                                                  ? 6'd5 : 6'd16;
                        b_sec <= 6'd0;
                        state <= S_B_SEC;
                    end
                end
                else if (wrq_pend) begin
                    wrq_pend <= 1'b0;
                    w_drv    <= wrq_pay[35];
                    w_side   <= wrq_pay[34];
                    w_C      <= wrq_pay[26:19];
                    w_H      <= wrq_pay[18:11];
                    w_R      <= wrq_pay[10:3];
                    w_N      <= wrq_pay[2:0];
                    if (cfg_k2[wrq_pay[35]] == K_FDI) begin
                        w_sec <= 6'd0;
                        w_sc  <= 3'd0;
                        state <= (pos_cnt[wrq_pay[35]] == 6'd0)
                                   ? S_W_ACK : S_W_SC0;
                    end
                    else begin                 // R-1, marked dead if out of range
                        w_sec <= (wrq_pay[10:3] >= 8'd1 &&
                                  wrq_pay[10:3] <= {2'd0, pos_cnt[wrq_pay[35]]})
                                     ? wrq_pay[8:3] - 6'd1 : 6'd63;
                        state <= S_W_ST;
                    end
                end
                else if (dirty_any && !dn_inflight) begin
                    dn_ptr <= 12'd0;
                    state  <= S_D_SC;
                end
            end

            // ==================== the DDR micro-ops ====================
            S_DW0: begin
                f_we  <= 1'b1;
                f_req <= 1'b1;
                state <= S_DW1;
            end
            S_DW1: if (!f_busy) begin          // accepted on this edge
                f_we  <= 1'b0;
                f_req <= 1'b0;
                state <= dret;
            end
            S_DR0: begin
                f_rd  <= 1'b1;
                f_req <= 1'b1;
                state <= S_DR1;
            end
            S_DR1: if (!f_busy) begin          // accepted; req stays up
                f_rd  <= 1'b0;
                state <= S_DR2;
            end
            S_DR2: if (f_dout_ready) begin
                lc_reg <= f_dout;
                f_req  <= 1'b0;
                state  <= dret;
            end

            // ==================== the track builder ====================
            // FDI header: DataOffset in bytes 0..3 (of 21 bits), count at 4
            S_B_HDR0: begin
                t_addr <= blk_base(b_drv, b_ti) + 17'd220 + {14'd0, b_hi};
                state  <= S_B_HRW;
            end
            S_B_HDR1: begin
                if (b_hi < 3'd4) begin
                    b_doff[{b_hi, 3'd0} +: 8] <= t_q;
                    b_hi <= b_hi + 3'd1;
                    state <= S_B_HDR0;
                end
                else begin
                    b_sec <= 6'd0;
                    if (t_q == 8'd0) state <= S_B_NR0;
                    else begin
                        b_cnt          <= (t_q > 8'd32) ? 6'd32 : t_q[5:0];
                        pos_cnt[b_drv] <= (t_q > 8'd32) ? 6'd32 : t_q[5:0];
                        state          <= S_B_SEC;
                    end
                end
            end
            S_B_HRW: state <= S_B_HDR1;
            // one FDI sector record into the id registers
            S_B_R0: begin
                t_addr <= blk_base(b_drv, b_ti)
                          + {12'd0, b_sec} * 17'd7 + {14'd0, b_tb};
                state  <= S_B_RRW;
            end
            S_B_RRW: state <= S_B_R1;
            S_B_R1: begin
                case (b_tb)
                    3'd0: b_C <= t_q;
                    3'd1: b_H <= t_q;
                    3'd2: b_R <= t_q;
                    3'd3: b_N <= (t_q[2:0] > 3'd3) ? 3'd3 : t_q[2:0];
                    3'd4: b_nodata <= t_q[6];
                    3'd5: b_rolo <= t_q;
                    default: ;
                endcase
                if (b_tb != 3'd6) begin
                    b_tb  <= b_tb + 3'd1;
                    state <= S_B_R0;
                end
                else begin
                    b_fbase <= b_doff[20:0] + {5'd0, t_q, b_rolo};
                    b_len   <= 11'd128 << b_N;
                    pos_buf [{b_drv, b_sec}]  <= b_bufp + 13'd70;
                    pos_file[{b_drv, b_sec}]  <= b_doff[20:0]
                                                 + {5'd0, t_q, b_rolo};
                    pos_ok  [{b_drv, b_sec}]  <= !t_q[6];
                    b_i   <= 11'd0;
                    b_c   <= 7'd0;
                    state <= S_B_G1;
                end
            end
            // sector start for TRD / CP/M: the geometry decides everything
            S_B_SEC: begin
                b_c <= 7'd0;
                b_i <= 11'd0;
                if (b_k2 == K_FDI) begin
                    b_tb  <= 3'd0;
                    state <= S_B_R0;
                end
                else begin
                    b_nodata <= 1'b0;
                    if (b_k2 == K_CPM) begin
                        b_N     <= 3'd3;
                        b_H     <= {7'd0, b_side};
                        b_fbase <= {1'b0, ({b_ti, 2'd0} + b_ti + {4'd0, b_sec}),
                                    10'd0};
                        pos_buf [{b_drv, b_sec}]  <= b_bufp + 13'd70;
                        pos_file[{b_drv, b_sec}]  <= {1'b0, ({b_ti, 2'd0} + b_ti
                                                              + {4'd0, b_sec}),
                                                      10'd0};
                    end
                    else begin
                        b_N     <= 3'd1;
                        b_H     <= 8'd0;
                        b_fbase <= {2'd0, b_ti, b_sec[3:0], 8'd0};
                        pos_buf [{b_drv, b_sec}]  <= b_bufp + 13'd70;
                        pos_file[{b_drv, b_sec}]  <= {2'd0, b_ti,
                                                      b_sec[3:0], 8'd0};
                    end
                    b_C   <= b_trk;
                    b_R   <= {2'd0, b_sec} + 8'd1;
                    b_len <= (b_k2 == K_CPM) ? 11'd1024 : 11'd256;
                    pos_ok[{b_drv, b_sec}] <= 1'b1;
                    state <= S_B_G1;
                end
            end
            // 10x4E then 12x00
            S_B_G1: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp; tk_wdata <= {1'b0, (b_c < 7'd10) ? 8'h4E : 8'h00};
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd21) begin b_c <= 7'd0; state <= S_B_S1; end
                else b_c <= b_c + 7'd1;
            end
            // 3x A1, sync 1; the id crc chain is seeded to cover them
            S_B_S1: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp; tk_wdata <= {1'b1, 8'hA1};
                crc_id   <= crc_a13;
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd2) begin b_c <= 7'd0; state <= S_B_ID; end
                else b_c <= b_c + 7'd1;
            end
            // FE C H R N
            S_B_ID: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp; tk_wdata <= {1'b0, id_b};
                crc_id   <= crc_byte(crc_id, id_b);
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd4) begin b_c <= 7'd0; state <= S_B_IC; end
                else b_c <= b_c + 7'd1;
            end
            // the id CRC, high byte first; a no-data sector ends here
            S_B_IC: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp;
                tk_wdata <= {1'b0, b_c[0] ? crc_id[7:0] : crc_id[15:8]};
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd1) begin
                    b_c   <= 7'd0;
                    state <= b_nodata ? S_B_G5 : S_B_G3;
                end
                else b_c <= b_c + 7'd1;
            end
            // 22x4E
            S_B_G3: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp; tk_wdata <= {1'b0, 8'h4E};
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd21) begin b_c <= 7'd0; state <= S_B_G4; end
                else b_c <= b_c + 7'd1;
            end
            // 12x00
            S_B_G4: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp; tk_wdata <= {1'b0, 8'h00};
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd11) begin b_c <= 7'd0; state <= S_B_S2; end
                else b_c <= b_c + 7'd1;
            end
            // 3x A1 again (the data crc chain starts from the same seed)
            S_B_S2: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp; tk_wdata <= {1'b1, 8'hA1};
                if (b_c == 7'd0) crc_dat <= crc_a13;
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd2) begin b_c <= 7'd0; state <= S_B_FB; end
                else b_c <= b_c + 7'd1;
            end
            // FB
            S_B_FB: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp; tk_wdata <= {1'b0, 8'hFB};
                crc_dat  <= crc_byte(crc_dat, 8'hFB);
                b_bufp   <= b_bufp + 13'd1;
                b_i      <= 11'd0;
                state    <= S_B_DT;
            end
            // the data: every new line is one DDR read
            S_B_DT: begin
                if (b_i == b_len) state <= S_B_DC;
                else if (b_i == 11'd0 || b_fo[2:0] == 3'd0) begin
                    d_addr <= {BASE, b_drv, b_fo[20:3]};
                    d_be   <= 8'hFF;
                    dret   <= S_B_DT2;
                    state  <= S_DR0;
                end
                else state <= S_B_DT2;
            end
            S_B_DT2: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp;
                tk_wdata <= {1'b0, lc_reg[{b_fo[2:0], 3'd0} +: 8]};
                crc_dat  <= crc_byte(crc_dat, lc_reg[{b_fo[2:0], 3'd0} +: 8]);
                b_bufp   <= b_bufp + 13'd1;
                b_i      <= b_i + 11'd1;
                state    <= S_B_DT;
            end
            // the data CRC, high byte first
            S_B_DC: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp;
                tk_wdata <= {1'b0, b_c[0] ? crc_dat[7:0] : crc_dat[15:8]};
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd1) begin b_c <= 7'd0; state <= S_B_G5; end
                else b_c <= b_c + 7'd1;
            end
            // the 4E tail, then the next sector
            S_B_G5: begin
                tk_we    <= 1'b1; tk_drv <= b_drv;
                tk_waddr <= b_bufp; tk_wdata <= {1'b0, 8'h4E};
                b_bufp   <= b_bufp + 13'd1;
                if (b_c == 7'd59) begin
                    b_c <= 7'd0;
                    if (b_sec + 6'd1 == b_cnt) state <= S_B_PAD;
                    else begin
                        b_sec <= b_sec + 6'd1;
                        b_tb  <= 3'd0;
                        state <= (b_k2 == K_FDI) ? S_B_R0 : S_B_SEC;
                    end
                end
                else b_c <= b_c + 7'd1;
            end
            // pad the rest of the buffer with 4E
            S_B_PAD: begin
                if (b_bufp == TRKEND) state <= S_B_ACK0;
                else begin
                    tk_we    <= 1'b1; tk_drv <= b_drv;
                    tk_waddr <= b_bufp; tk_wdata <= {1'b0, 8'h4E};
                    b_bufp   <= b_bufp + 13'd1;
                end
            end
            // the payload lands a clock before the toggle, so whoever
            // samples it on the toggle edge never sees a stale one
            S_B_ACK0: begin
                trk_ack <= {1'b1, b_drv, b_side, b_trk};
                state   <= S_B_ACK1;
            end
            S_B_ACK1: begin
                trk_ack_tgl <= ~trk_ack_tgl;
                state       <= S_IDLE;
            end
            S_B_NR0: begin
                trk_ack <= {1'b0, b_drv, b_side, b_trk};
                state   <= S_B_NR1;
            end
            S_B_NR1: begin
                trk_ack_tgl <= ~trk_ack_tgl;
                state       <= S_IDLE;
            end

            // ==================== the write-back ====================
            // FDI: the record whose C,H,R,N match carries the file offset.
            S_W_SC0: begin
                t_addr <= blk_base(w_drv, pos_ti[w_drv])
                          + {12'd0, w_sec} * 17'd7 + {14'd0, w_sc};
                state  <= S_W_SCW;
            end
            S_W_SC1: begin
                if ((w_sc == 3'd0 && t_q == w_C) ||
                    (w_sc == 3'd1 && t_q == w_H) ||
                    (w_sc == 3'd2 && t_q == w_R) ||
                    (w_sc == 3'd3 && t_q[2:0] == w_N)) begin
                    if (w_sc != 3'd3) begin
                        w_sc  <= w_sc + 3'd1;
                        state <= S_W_SC0;
                    end
                    else if (pos_ok[{w_drv, w_sec}]) begin
                        w_fbase <= pos_file[{w_drv, w_sec}];
                        w_bufp  <= pos_buf [{w_drv, w_sec}];
                        w_len   <= 11'd128 << w_Nc;
                        w_i     <= 11'd0;
                        w_crc   <= crc_byte(crc_a13, 8'hFB);
                        state   <= S_W_R0;
                    end
                    else state <= S_W_ACK;
                end
                else if (w_sec + 6'd1 >= pos_cnt[w_drv]) state <= S_W_ACK;
                else begin
                    w_sec <= w_sec + 6'd1;
                    w_sc  <= 3'd0;
                    state <= S_W_SC0;
                end
            end
            S_W_SCW: state <= S_W_SC1;
            // TRD / CP/M: R-1 was resolved on entry; a dead index acks clean
            S_W_ST: begin
                if (w_sec == 6'd63 || !pos_ok[{w_drv, w_sec}])
                    state <= S_W_ACK;
                else begin
                    w_fbase <= pos_file[{w_drv, w_sec}];
                    w_bufp  <= pos_buf [{w_drv, w_sec}];
                    w_len   <= 11'd128 << w_Nc;
                    w_i     <= 11'd0;
                    w_crc   <= crc_byte(crc_a13, 8'hFB);
                    state   <= S_W_R0;
                end
            end
            // one byte: read the write buffer (present, wait, take), then
            // the DDR byte write, then the track-buffer patch
            S_W_R0: begin
                wr_raddr <= w_i[9:0];
                state    <= S_W_R1;
            end
            S_W_R1: state <= S_W_R2;
            S_W_R2: begin
                w_dat  <= wr_q_b;
                d_addr <= {BASE, w_drv, w_fo[20:3]};
                d_din  <= {8{wr_q_b}};
                d_be   <= 8'd1 << w_fo[2:0];
                dret   <= S_W_R3;
                state  <= S_DW0;
            end
            S_W_R3: begin
                tk_we    <= 1'b1; tk_drv <= w_drv;
                tk_waddr <= w_bufp + {2'd0, w_i};
                tk_wdata <= {1'b0, w_dat};
                w_crc    <= crc_byte(w_crc, w_dat);
                if (w_i + 11'd1 == w_len) state <= S_W_C0;
                else begin w_i <= w_i + 11'd1; state <= S_W_R0; end
            end
            S_W_C0: begin
                tk_we    <= 1'b1; tk_drv <= w_drv;
                tk_waddr <= w_bufp + {2'd0, w_len};
                tk_wdata <= {1'b0, w_crc[15:8]};
                state    <= S_W_C1;
            end
            S_W_C1: begin
                tk_we    <= 1'b1; tk_drv <= w_drv;
                tk_waddr <= w_bufp + {2'd0, w_len} + 13'd1;
                tk_wdata <= {1'b0, w_crc[7:0]};
                state    <= cfg_k2[w_drv] == K_FDI ? S_W_ACK : S_W_DRT;
            end
            // the touched 512-byte blocks: one for a 256 B sector unless it
            // straddles, two for a 1024 B one
            S_W_DRT: begin
                // 512-byte blocks touched; the bitmap covers the first
                // MiB per drive, which every mountable geometry fits in
                if (!w_fbase[20]) begin
                    dirty[{w_drv, w_fbase[19:9]}] <= 1'b1;
                    if (!w_end[20] && (w_end[20:9] != {1'b0, w_fbase[19:9]}))
                        dirty[{w_drv, w_end[19:9]}] <= 1'b1;
                end
                state <= S_W_ACK;
            end
            S_W_ACK: begin
                wr_ack_tgl <= ~wr_ack_tgl;
                state      <= S_IDLE;
            end

            // ==================== the drain ====================
            S_D_SC: begin
                if (dirty[dn_ptr]) begin
                    dn_drv <= dn_ptr[11];
                    dn_blk <= dn_ptr[10:0];
                    dn_ln  <= 6'd0;
                    dn_b   <= 3'd0;
                    d_addr <= {BASE, dn_ptr[11], 1'b0, dn_ptr[10:0], 6'd0};
                    d_be   <= 8'hFF;
                    dret   <= S_D_W8;
                    state  <= S_DR0;
                end
                else if (dn_ptr == 12'd4095) state <= S_IDLE;
                else dn_ptr <= dn_ptr + 12'd1;
            end
            // 64 lines, eight bytes each, into the drain buffer
            S_D_W8: begin
                dn_we    <= 1'b1;
                dn_waddr <= {dn_ln, dn_b};
                dn_wdata <= lc_reg[{dn_b, 3'd0} +: 8];
                if (dn_b != 3'd7) dn_b <= dn_b + 3'd1;
                else if (dn_ln != 6'd63) begin
                    dn_ln  <= dn_ln + 6'd1;
                    dn_b   <= 3'd0;
                    d_addr <= {BASE, dn_drv, 1'b0, dn_blk, dn_ln + 6'd1};
                    d_be   <= 8'hFF;
                    dret   <= S_D_W8;
                    state  <= S_DR0;
                end
                else state <= S_D_T0;
            end
            S_D_T0: begin
                drn_info <= {dn_drv, dn_blk};
                state    <= S_D_T1;
            end
            S_D_T1: begin
                drn_tgl     <= 1'b1;
                dn_inflight <= 1'b1;
                state       <= S_D_T2;
            end
            S_D_T2: begin
                drn_tgl <= 1'b0;
                state   <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // --------------------------------------------------------------------
    // the track buffers: one 8192x9 per drive. Port A is the builder's and
    // the write-back patch's (clk); port B is the drive's (clk_bus). The
    // mux answers for the drive the last request came from, the way the
    // single-FDC bus lets only one drive stream at a time.
    wire [8:0] trk0_qb, trk1_qb;
    altsyncram u_trk0 (
        .clock0(clk), .clock1(clk_bus),
        .address_a(tk_waddr), .data_a(tk_wdata), .wren_a(tk_we && !tk_drv),
        .q_a(),
        .address_b(trk_addr_b), .data_b(9'd0), .wren_b(1'b0), .q_b(trk0_qb),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .eccstatus(),
        .rden_a(1'b1), .rden_b(1'b1)
    );
    altsyncram u_trk1 (
        .clock0(clk), .clock1(clk_bus),
        .address_a(tk_waddr), .data_a(tk_wdata), .wren_a(tk_we && tk_drv),
        .q_a(),
        .address_b(trk_addr_b), .data_b(9'd0), .wren_b(1'b0), .q_b(trk1_qb),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .eccstatus(),
        .rden_a(1'b1), .rden_b(1'b1)
    );
    defparam
        u_trk0.numwords_a = 8192, u_trk0.widthad_a = 13, u_trk0.width_a = 9,
        u_trk0.numwords_b = 8192, u_trk0.widthad_b = 13, u_trk0.width_b = 9,
        u_trk0.address_reg_b = "CLOCK1",
        u_trk0.clock_enable_input_a = "BYPASS",
        u_trk0.clock_enable_input_b = "BYPASS",
        u_trk0.clock_enable_output_a = "BYPASS",
        u_trk0.clock_enable_output_b = "BYPASS",
        u_trk0.indata_reg_b = "CLOCK1",
        u_trk0.intended_device_family = "Cyclone V",
        u_trk0.lpm_type = "altsyncram",
        u_trk0.operation_mode = "BIDIR_DUAL_PORT",
        u_trk0.outdata_aclr_a = "NONE", u_trk0.outdata_aclr_b = "NONE",
        u_trk0.outdata_reg_a = "UNREGISTERED",
        u_trk0.outdata_reg_b = "UNREGISTERED",
        u_trk0.power_up_uninitialized = "FALSE",
        u_trk0.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_trk0.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_trk0.width_byteena_a = 1, u_trk0.width_byteena_b = 1,
        u_trk0.wrcontrol_wraddress_reg_b = "CLOCK1",
        u_trk1.numwords_a = 8192, u_trk1.widthad_a = 13, u_trk1.width_a = 9,
        u_trk1.numwords_b = 8192, u_trk1.widthad_b = 13, u_trk1.width_b = 9,
        u_trk1.address_reg_b = "CLOCK1",
        u_trk1.clock_enable_input_a = "BYPASS",
        u_trk1.clock_enable_input_b = "BYPASS",
        u_trk1.clock_enable_output_a = "BYPASS",
        u_trk1.clock_enable_output_b = "BYPASS",
        u_trk1.indata_reg_b = "CLOCK1",
        u_trk1.intended_device_family = "Cyclone V",
        u_trk1.lpm_type = "altsyncram",
        u_trk1.operation_mode = "BIDIR_DUAL_PORT",
        u_trk1.outdata_aclr_a = "NONE", u_trk1.outdata_aclr_b = "NONE",
        u_trk1.outdata_reg_a = "UNREGISTERED",
        u_trk1.outdata_reg_b = "UNREGISTERED",
        u_trk1.power_up_uninitialized = "FALSE",
        u_trk1.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_trk1.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_trk1.width_byteena_a = 1, u_trk1.width_byteena_b = 1,
        u_trk1.wrcontrol_wraddress_reg_b = "CLOCK1";
    assign trk_q_b = stream_drv ? trk1_qb : trk0_qb;

    // the write buffer: port A is the drive's (clk_bus, exactly the pins
    // floppy.sv drives), port B the write-back reader's (clk).
    altsyncram u_wram (
        .clock0(clk_bus), .clock1(clk),
        .address_a(wr_addr), .data_a(wr_data), .wren_a(wr_we), .q_a(),
        .address_b(wr_raddr), .data_b(8'd0), .wren_b(1'b0), .q_b(wr_q_b),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .eccstatus(),
        .rden_a(1'b1), .rden_b(1'b1)
    );
    defparam
        u_wram.numwords_a = 1024, u_wram.widthad_a = 10, u_wram.width_a = 8,
        u_wram.numwords_b = 1024, u_wram.widthad_b = 10, u_wram.width_b = 8,
        u_wram.address_reg_b = "CLOCK1",
        u_wram.clock_enable_input_a = "BYPASS",
        u_wram.clock_enable_input_b = "BYPASS",
        u_wram.clock_enable_output_a = "BYPASS",
        u_wram.clock_enable_output_b = "BYPASS",
        u_wram.indata_reg_b = "CLOCK1",
        u_wram.intended_device_family = "Cyclone V",
        u_wram.lpm_type = "altsyncram",
        u_wram.operation_mode = "BIDIR_DUAL_PORT",
        u_wram.outdata_aclr_a = "NONE", u_wram.outdata_aclr_b = "NONE",
        u_wram.outdata_reg_a = "UNREGISTERED",
        u_wram.outdata_reg_b = "UNREGISTERED",
        u_wram.power_up_uninitialized = "FALSE",
        u_wram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_wram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_wram.width_byteena_a = 1, u_wram.width_byteena_b = 1,
        u_wram.wrcontrol_wraddress_reg_b = "CLOCK1";

    // the drain buffer: port A is the store's (clk), port B the host's
    // (clk_sys).
    altsyncram u_drn (
        .clock0(clk), .clock1(clk_sys),
        .address_a(dn_waddr), .data_a(dn_wdata), .wren_a(dn_we), .q_a(),
        .address_b(drn_addr_b), .data_b(8'd0), .wren_b(1'b0), .q_b(drn_q_b),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .eccstatus(),
        .rden_a(1'b1), .rden_b(1'b1)
    );
    defparam
        u_drn.numwords_a = 512, u_drn.widthad_a = 9, u_drn.width_a = 8,
        u_drn.numwords_b = 512, u_drn.widthad_b = 9, u_drn.width_b = 8,
        u_drn.address_reg_b = "CLOCK1",
        u_drn.clock_enable_input_a = "BYPASS",
        u_drn.clock_enable_input_b = "BYPASS",
        u_drn.clock_enable_output_a = "BYPASS",
        u_drn.clock_enable_output_b = "BYPASS",
        u_drn.indata_reg_b = "CLOCK1",
        u_drn.intended_device_family = "Cyclone V",
        u_drn.lpm_type = "altsyncram",
        u_drn.operation_mode = "BIDIR_DUAL_PORT",
        u_drn.outdata_aclr_a = "NONE", u_drn.outdata_aclr_b = "NONE",
        u_drn.outdata_reg_a = "UNREGISTERED",
        u_drn.outdata_reg_b = "UNREGISTERED",
        u_drn.power_up_uninitialized = "FALSE",
        u_drn.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_drn.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        u_drn.width_byteena_a = 1, u_drn.width_byteena_b = 1,
        u_drn.wrcontrol_wraddress_reg_b = "CLOCK1";

endmodule

`default_nettype wire
