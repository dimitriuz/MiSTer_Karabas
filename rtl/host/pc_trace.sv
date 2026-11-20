// pc_trace.sv - a flight recorder of the CPU's instruction fetches, for the debug UART.
//
// When `trig` (clk_bus, one pulse: fdc_trace saw a run of >= 512 data reads end) arrives
// while `enable` is on, the next DEPTH opcode fetches (`fetch` = M1 and MREQ low) are stored
// as {address (sampled one clk_bus after the strobe rises), opcode byte (the CPU data input
// two clk_bus before the strobe falls)}. When the buffer is full the bytes go out on the
// same UART byte port as fdc_trace, once the other sender is idle:
//   'P' 'C'  then DEPTH records of address high, address low, opcode.
// One shot: a second capture needs `enable` to go low and high again.
`default_nettype none

module pc_trace #(
    parameter integer BYTE_CLKS = 4400,
    parameter integer AW        = 12               // DEPTH = 2 ** AW
) (
    input  wire        clk_bus,
    input  wire        clk_sys,
    input  wire        enable,
    input  wire        trig,
    input  wire        fetch,
    input  wire [15:0] a,
    input  wire  [7:0] di,                         // the CPU's data input (the opcode at a fetch)
    input  wire        other_idle,                 // clk_sys: fdc_trace has nothing to send
    output reg   [7:0] tx_data = 8'd0,
    output reg         tx_wr   = 1'b0
);
    localparam integer DEPTH = 1 << AW;

    // ---------------- clk_bus: record ----------------
    reg [1:0] en_s = 2'b00;
    always @(posedge clk_bus) en_s <= {en_s[0], enable};
    wire en_b = en_s[1];

    reg [23:0] mem [0:DEPTH - 1];
    reg [AW:0] wp = {(AW + 1){1'b0}};
    reg        armed = 1'b0, full = 1'b0, done_tgl = 1'b0;
    reg        f_q = 1'b0, f_d = 1'b0;
    reg [15:0] a_l = 16'd0;
    reg  [7:0] di1 = 8'd0, di2 = 8'd0;
    always @(posedge clk_bus) begin
        f_q <= fetch;
        f_d <= fetch && !f_q;                      // the strobe rose one clock ago: a is stable
        if (f_d) a_l <= a;
        di1 <= di; di2 <= di1;
        if (!en_b) begin armed <= 1'b0; full <= 1'b0; wp <= {(AW + 1){1'b0}}; end
        else begin
            if (trig && !armed && !full) armed <= 1'b1;
            if (armed && f_q && !fetch) begin          // the strobe has just fallen: store the fetch
                mem[wp[AW-1:0]] <= {a_l, di2};
                wp <= wp + 1'b1;
                if (wp == DEPTH - 1) begin armed <= 1'b0; full <= 1'b1; done_tgl <= ~done_tgl; end
            end
        end
    end

    // ---------------- clk_sys: send ----------------
    reg [2:0] d_s = 3'd0;
    always @(posedge clk_sys) d_s <= {d_s[1:0], done_tgl};
    wire go = d_s[2] != d_s[1];

    localparam [2:0] S_IDLE = 3'd0, S_WAIT = 3'd1, S_HEAD = 3'd2, S_HI = 3'd3, S_LO = 3'd4, S_OP = 3'd5;
    reg [2:0]  st = S_IDLE;
    reg [AW:0] rp = {(AW + 1){1'b0}};
    reg [23:0] q = 24'd0;
    reg [12:0] tmr = 13'd0;
    reg        h2 = 1'b0;
    always @(posedge clk_sys) q <= mem[rp[AW-1:0]];

    always @(posedge clk_sys) begin
        tx_wr <= 1'b0;
        if (tmr != 13'd0) tmr <= tmr - 13'd1;
        case (st)
        S_IDLE: if (go) begin rp <= {(AW + 1){1'b0}}; h2 <= 1'b0; st <= S_WAIT; end
        S_WAIT: if (other_idle && tmr == 13'd0) st <= S_HEAD;
        S_HEAD: if (tmr == 13'd0) begin
            tx_data <= h2 ? 8'h43 : 8'h50;
            tx_wr <= 1'b1; tmr <= BYTE_CLKS;
            h2 <= 1'b1;
            if (h2) st <= S_HI;
        end
        S_HI: if (tmr == 13'd0) begin
            tx_data <= q[23:16]; tx_wr <= 1'b1; tmr <= BYTE_CLKS; st <= S_LO;
        end
        S_LO: if (tmr == 13'd0) begin
            tx_data <= q[15:8]; tx_wr <= 1'b1; tmr <= BYTE_CLKS; st <= S_OP;
        end
        S_OP: if (tmr == 13'd0) begin
            tx_data <= q[7:0]; tx_wr <= 1'b1; tmr <= BYTE_CLKS;
            rp <= rp + 1'b1;
            st <= (rp == DEPTH - 1) ? S_IDLE : S_HI;
        end
        default: st <= S_IDLE;
        endcase
    end
endmodule
