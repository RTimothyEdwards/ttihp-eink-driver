/*
 * tt_um_rte_eink_driver_wrapper.v
 *
 * Wrapper for Arty A7 board around the
 * TinyTapeout project tt_um_rte_eink_driver.v
 *
 * What this wrapper adds:
 *
 * (1) Divide-by-2 on the clock to match the TinyTapeout
 *     development board running at 50MHz
 * (2) Bidirectional pin handling
 *
 */

// Point this to the Tiny Tapeout project and uncomment
`include "../src/tt_um_rte_eink_driver.v"

// Note that this creates new signal name "uio_inout" which is
// what must be connected to the eight pins in the "JB" PMOD
// in the Arty board configuration file.

module tt_um_rte_eink_driver_wrapper (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    inout  wire [7:0] uio_inout,// Bidirectional input and output
    input  wire       clk,      // clock
    input  wire       rst_n     // reset - low to reset
);

    reg clk2;

    wire [7:0] uio_oe;
    wire [7:0] uio_in;
    wire [7:0] uio_out;

    // Instantiate the Tiny Tapeout project

    tt_um_rte_eink_driver project (
	.ui_in(ui_in),		// 8-bit input
	.uo_out(uo_out),	// 8-bit output
	.uio_in(uio_in),	// 8-bit bidirectional (in)
	.uio_out(uio_out),	// 8-bit bidirectional (out)
	.uio_oe(uio_oe),	// 8-bit bidirectional (enable)
	.clk(clk2),		// halved clock
	.rst_n(rst_n)		// inverted reset
    );

    // Handle bidirectional I/Os
    generate
        genvar i;
        for (i = 0; i < 8; i = i + 1)
            assign uio_inout[i] = uio_oe[i] ? uio_out[i] : 1'bz;
    endgenerate
    assign uio_in = uio_inout;

    // Invert reset to project, and halve the clock

    always @(posedge clk) begin
	if (rst_n) begin
	    clk2 <= ~clk2;
	end else begin
	    clk2 <= 0;
	end
    end

endmodule;

