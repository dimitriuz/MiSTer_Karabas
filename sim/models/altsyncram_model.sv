// altsyncram_model.sv - SIM MODEL of the Quartus altsyncram instance
// sys/sd_card.sv puts its sector buffer in, so the unmodified card can be
// simulated without the Quartus libraries. Only the shapes and the behaviour
// sd_card uses are modelled: two independent clocked ports of 8-bit words
// over one memory (BIDIR_DUAL_PORT, 2048 words), port A with an unregistered
// address and an unregistered output (q_a follows address_a combinationally,
// which is how hps_io reads and writes its disk byte buffer), port B with its
// address registered on clock1 and an unregistered output (q_b follows the
// address of the previous clock). A write goes through on its port's clock
// edge; the other parameters exist so sd_card's defparams bind.
`default_nettype none

module altsyncram #(
    parameter integer numwords_a = 2048,
    parameter integer widthad_a = 11,
    parameter integer width_a = 8,
    parameter integer numwords_b = 2048,
    parameter integer widthad_b = 11,
    parameter integer width_b = 8,
    parameter address_reg_b = "CLOCK1",
    parameter operation_mode = "BIDIR_DUAL_PORT",
    parameter clock_enable_input_a = "BYPASS",
    parameter clock_enable_input_b = "BYPASS",
    parameter clock_enable_output_a = "BYPASS",
    parameter clock_enable_output_b = "BYPASS",
    parameter indata_reg_b = "CLOCK1",
    parameter intended_device_family = "Cyclone V",
    parameter lpm_type = "altsyncram",
    parameter outdata_aclr_a = "NONE",
    parameter outdata_aclr_b = "NONE",
    parameter outdata_reg_a = "UNREGISTERED",
    parameter outdata_reg_b = "UNREGISTERED",
    parameter power_up_uninitialized = "FALSE",
    parameter read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    parameter read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    parameter width_byteena_a = 1,
    parameter width_byteena_b = 1,
    parameter wrcontrol_wraddress_reg_b = "CLOCK1"
) (
    input  wire        clock0,
    input  wire        clock1,
    input  wire [widthad_a-1:0] address_a,
    input  wire [width_a-1:0]   data_a,
    input  wire        wren_a,
    output wire [width_a-1:0]   q_a,
    input  wire [widthad_b-1:0] address_b,
    input  wire [width_b-1:0]   data_b,
    input  wire        wren_b,
    output wire [width_b-1:0]   q_b,
    input  wire        aclr0,
    input  wire        aclr1,
    input  wire        byteena_a,
    input  wire        byteena_b,
    input  wire        clocken0,
    input  wire        clocken1,
    input  wire        clocken2,
    input  wire        clocken3,
    input  wire        addressstall_a,
    input  wire        addressstall_b,
    input  wire        rden_a,
    input  wire        rden_b,
    output wire  [1:0] eccstatus
);

    localparam integer WORDS = (numwords_a > numwords_b) ? numwords_a : numwords_b;

    reg [width_a-1:0] mem [0:WORDS-1];
    reg [widthad_b-1:0] addr_b = {widthad_b{1'b0}};

    always @(posedge clock0)
        if (wren_a)
            mem[address_a] <= data_a;

    assign q_a = mem[address_a];

    always @(posedge clock1) begin
        addr_b <= address_b;
        if (wren_b)
            mem[address_b] <= data_b;
    end

    assign q_b = mem[addr_b];
    assign eccstatus = 2'b00;

endmodule

`default_nettype wire