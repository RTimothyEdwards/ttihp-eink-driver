//-------------------------------------
// Testbench for tt_um_rte_eink_driver
//-------------------------------------

`default_nettype none

`timescale 1 ns / 1 ps

`include "tt_um_rte_eink_driver.v"

module tt_um_rte_eink_driver_tb;

    reg ena;
    reg clk;
    reg rst_n;
    reg [7:0] ui_in;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    /* Named signals for viewing in gtkwave */
    wire	mosi;	// e-ink display SPI input data
    wire	dcb;	// e-ink display command/data
    wire	sck;	// SPI clock
    wire	csb;	// e-ink display SPI select (sense negative)
    wire	resetb;	// e-ink display reset (sense negative)

    reg		busy;	// e-ink display busy

    initial begin
	$dumpfile("tt_um_rte_eink_driver_tb.vcd");
	$dumpvars(0, tt_um_rte_eink_driver_tb);

	ena <= 0;
	clk <= 0;
	rst_n <= 0;
	ui_in <= 0;
	busy <= 0;

	// Enable the project (this signal is unused by the project)
	#100;
	ena <= 1;

	// Bring project out of reset
	#500;
	rst_n <= 1;

	// Run for a few clock cycles
	#10000;

	// Apply an input, run for a while
	ui_in <= 1;
	#1500000;

	// Release the input, run for a while
	ui_in <= 0;
	#10000;
	ui_in <= 2;
	#1500000;

	ui_in <= 0;
	#10000;
	ui_in <= 4;
	#1500000;

	ui_in <= 0;
	#10000;
	ui_in <= 8;
	#1500000;

	$finish;
    end

    // 10ns half cycle = 20ns cycle = 50MHz clock
    always #10 clk <= (clk === 1'b0);

    tt_um_rte_eink_driver dut (
	.ui_in(ui_in),
	.uo_out(uo_out),
	.uio_in(8'h00),		// Keep at zero (unused)
	.uio_out(uio_out),
	.uio_oe(uio_oe),
	.ena(ena),
	.clk(clk),
	.rst_n(rst_n)
    );

    assign mosi   = uio_out[1];
    assign dcb    = uio_out[7];
    assign sck    = uio_out[3];
    assign csb    = uio_out[0];
    assign resetb = uio_out[5];

    assign uio_out[6] = busy;
    assign uio_out[2] = 1'b0;
    assign uio_out[4] = 1'b0;

    // To do: instantiate e-ink display as an SPI slave module.
    // The module will acknowledge commands and assert "busy" as needed.

endmodule;
