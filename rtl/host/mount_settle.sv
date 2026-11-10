// mount_settle.sv - when the machine may start, against hps_io's mounts.
//
// Main mounts an MGL's files some time after the core starts, and a mount
// resets the card's queued transfer (sys/sd_card.sv clears its sector
// pointers) and img_src's mount registers. The machine's ROM probes both
// drives within its first few hundred milliseconds; a probe that is in
// flight when a mount lands never finishes, and the machine stops on the
// loader screen with the Drive line drawn.
//
// So the machine's start is held from two sides:
// - after a disk mount, for SETTLE clocks (1.34 s at 50 MHz), so the ROM
//   probes a settled card and a settled image;
// - before any disk mount has been seen, for at most BUDGET clocks (3 s),
//   so a core loaded with no file still boots, and so that a mount that
//   arrives late cannot be overtaken by the machine's probe.
//
// The old rule (settle only, starting from zero) released the machine at
// power-up, before hps_io had mounted anything: on the board that is the
// boot that stops on the Drive line, about one time in three (the mount
// lands after the probe has begun), and holding until a mount actually
// arrives is what removes it. Only the disk slots count; the tape is not
// one the ROM probes.
module mount_settle #(
    parameter integer SETTLE_CLKS = 26'h3FFFFFF,   // 1.34 s at 50 MHz
    parameter integer BUDGET_CLKS = 28'd150000000  // 3 s at 50 MHz
) (
    input  wire clk,
    input  wire reset,          // power-on reset only
    input  wire [3:0] mounted,  // hps_io img_mounted, one bit per slot
    output wire settled
);

localparam integer SW = $clog2(BUDGET_CLKS + 2);

reg [SW-1:0] wait_cnt = BUDGET_CLKS[SW-1:0];

wire disk_mount = |mounted[3:1];

always @(posedge clk) begin
    if (reset) begin
        wait_cnt <= BUDGET_CLKS[SW-1:0];
    end else begin
        if (disk_mount) begin
            wait_cnt <= SETTLE_CLKS[SW-1:0];
        end else if (wait_cnt != 0) begin
            wait_cnt <= wait_cnt - 1'b1;
        end
    end
end

assign settled = (wait_cnt == 0);

endmodule