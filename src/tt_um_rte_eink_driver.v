/*
 * Copyright (c) 2025 R. Timothy Edwards
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

`include "simple_spi_master.v"

/* This E-Ink display driver project is based on the Adafruit ThinkInk 2.13"
 * e-ink display board with the SSD1680 chipset.  The code is converted from
 * The Adafruit driver found at https://github.com/adafruit/Adafruit_EPD
 * (originally written in C++ and adapted here to verilog).
 */

module tt_um_rte_eink_driver (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock (assume 50MHz maximum)
    input  wire       rst_n     // reset_n - low to reset
);

    // Registers and wires used by this module
    reg  dcb;		// Data/Command signal to the e-ink display
    reg  resetb;	// e-ink reset (not to be confused with digital reset)
    reg  write;		// Set to 1 to initiate an SPI write
    reg  stream;	// Apply/release CSB with this bit
    reg  strmdly;	// Stream signal, delayed and extended
    reg [7:0] data_out;	// Data to transmit to slave via the SPI master module

    reg [4:0]  state;   // Primary state machine for the display state
    reg [15:0] counter;	// Address counter for the 250x122 display (30500 < 32768)
    reg [3:0]  timer;	// Use to extend counter to count 10ms delays

    wire status;	// Wait status from the SPI master module
    wire [7:0] data_in; // Data from slave (SRAM) returned from SPI master module
    wire busy;		// "Busy" signal returned from the e-ink display
    wire csb;		// Display SPI slave select
    reg  sramcsb;	// SRAM SPI slave select
    wire sck;		// SPI clock
    wire mosi;		// SDO from SPI master
    wire mosienb;	// SDO enable (sense negative) from SPI master
    reg  passthru;	// Pass-through mode
    reg  maskcsb;	// Mask display CSB for accessing SRAM only

    reg  [7:0] inbuf;	// Buffered inputs
    reg  [7:0] inval;	// Double-buffered inputs

    wire [4:0] xpos;
    wire [3:0] ypos;

    // Unused signals
    wire spi_err_unused;
    wire miso;

    // Output assignment (see the README file)
    assign uo_out  = {7'b0, miso};	// Low bit is a copy of uio_in[2]
    assign uio_out = {dcb, 1'b0, resetb, sramcsb, sck, 1'b0, mosi, csb};
    // 101110?1 <---  out,  in,   out,    out, out,  in,  ~mosienb, out
    assign uio_oe  = {6'b101110, ~mosienb, 1'b1};

    assign busy = uio_in[6];
    assign miso = uio_in[2];		// SRAM not being used, but assign
					// a pin anyway.

    // List all unused inputs to prevent warnings
    wire _unused = &{ena, 1'b0};

    // Convenience function for pulling X and Y values for a coarse
    // 32 x 16 grid out of the counter values.
    assign xpos = counter[11:7];
    assign ypos = counter[3:0];

    /* SPI write operation:
     * (1) Set "data_out" to the byte value to send
     * (2) Toggle "write" high
     * (3) Wait for "status" to go low
     */

    /* Operations of this system, based on input bit value:
     * Each operation sets a pattern in the display space on SRAM
     * and then refreshes the display to show that pattern.
     *
     * inval = 0x00:  Idle (do nothing)
     * inval = 0x01:  Blank white
     * inval = 0x02:  Solid black
     * inval = 0x04:  Diagonal stripes
     * inval = 0x08:  Checkerboard pattern
     *
     * (That's all for now. . .)
     */
  
    /* State machine states:
     * IDLE:  Value on reset;  nothing happens, wait for an input
     *
     */
    `define IDLE    5'd0
    `define HWRESET 5'd1
    `define WAIT0   5'd2
    `define STARTR  5'd3
    `define WRITER  5'd4
    `define WAITR   5'd5
    `define WAITB   5'd6
    `define WAITX   5'd7
    `define START1  5'd8
    `define START2  5'd9
    `define WRITE2  5'd10
    `define WAIT2   5'd11
    `define WAIT3   5'd12
    `define START3  5'd13
    `define START4  5'd14
    `define WRITE4  5'd15
    `define WAIT4   5'd16
    `define END4    5'd17
    `define START5  5'd18
    `define START6  5'd19
    `define WRITE6  5'd20
    `define WAIT6   5'd21
    `define WAIT7   5'd22
    `define THRU    5'd23
    `define STARTS1 5'd24
    `define STARTS2 5'd25
    `define STARTS3 5'd26
    `define WRITES2 5'd27
    `define WAITS2  5'd28

    /* Various long-term counts used in the code that are helpful to
     * change to low values in simulation.
     */
    /* Number of bytes to transfer for the complete display.  The display
     * is 250x122 pixels, but address space is 250x128 = 32000 bits,
     * divided by 8 bits per byte = 4000 = hex 0xfa0
     */
    `define DISPLAY_BYTES 16'hfa0
    // `define DISPLAY_BYTES 16'h200		// simulation only

    /* Delay value used to count out 10ms for hardware reset.
     * At 50MHz clock, a 15-bit counter is 655us.  Counting
     * this inside another loop of 15 results in a 9.83ms delay.
     */
    `define DELAY_655US 16'h7fff
    // `define DELAY_655US 16'h0001		// simulation only

    /* The prescaler is set to 2 to ensure a clock rate low enough for
     * the device.  The device maximum clock rate is 20MHz, so this
     * could be set to 1 and would still work.  Note that if the SRAM
     * is used, its maximum clock rate is 2.5MHz, requiring a prescale
     * value of 4.
     */
    `define PRESCALER 8'd2

    /* "stream" is applied for one clock cycle but signal needs to be
     * stable for several clock cycles, so use "strmdly" as a latched
     * value of "stream" and don't release it for as long as "status" is
     * zero.
     */
    always @(posedge clk or negedge rst_n) begin
	if (rst_n == 1'b0) begin     
	    strmdly <= 1'b0;
	end else begin
	    if (stream == 1'b0)
		strmdly <= stream;
	    else if (status == 1'b1)
		strmdly <= stream;
	end
    end

    always @(posedge clk or negedge rst_n) begin
	if (rst_n == 1'b0) begin     
	    resetb <= 1'b1;		// Do not reset the e-ink display!
	    dcb <= 1'b1;		// Set display SPI to data mode
	    inbuf <= 8'b0;		// Clear input buffer 1
	    inval <= 8'b0;		// Clear input buffer 2
	    write <= 1'b0;		// No write operation
	    stream <= 1'b0;		// No streaming (yet)
	    state <= `IDLE;		// Initialize state machine
	    counter <= 0;		// Reset the bit counter
	    timer <= 0;			// Reset the delay counter
	    data_out <= 0;		// Clear data byte to SPI
	    sramcsb <= 1'b1;		// Do not access SRAM by default
	    passthru <= 0;		// No pass-through mode by default
	    maskcsb <= 0;		// Do not mask the display CSB by default
	end else begin
	    inval <= inbuf;		// Double-buffer the input state
	    inbuf <= ui_in;		// Capture input state

	    /* case-based operation */

	    case (state)
		`IDLE : begin
	 	    /* Setting the upper bits of inval to 1 puts the
		     * driver into pass-through mode, and enables the
		     * SRAM SPI interface, and allows the SRAM to be
		     * accessed for writes
		     */
		    if (inbuf[7:4] == 4'b1111) begin
			passthru <= 1'b1;
			sramcsb <= 1'b0;
			state <= `THRU;
		    end

		    /* Refresh the display on any input change, with
		     * the display corresponding to the input value
		     */
		    else if ((inval != inbuf) && (inbuf != 0))
			state <= `STARTS1;

		    else
			sramcsb <= 1'b1;
		end

		`THRU : begin
		    /* Setting inval back to zero clears pass-through mode,
		     * clears sramcsb, and returns to idle mode.
		     * 
		     */
		    if (inbuf == 0) begin
			passthru <= 1'b0;
			sramcsb <= 1'b1;
			state <= `IDLE;
		    end
		end

		/* The following is a set of commands to pass to the SRAM
		 * to put it in sequential read mode.  Values will be read
		 * continuously while the display is written, allowing a
		 * mode where the display is generated from the SRAM
		 * contents (with an address offset).
		 */

		`STARTS1: begin
		    counter <= 0;
		    timer <= 0;
		    maskcsb <= 1'b1;		// Disable the display's SPI
		    state <= `STARTS2;
		end

		`STARTS2 : begin
		    sramcsb <= 1'b0;		// Access the SRAM
		    state <= `STARTS3;
		end

		`STARTS3 : begin
		    case (counter[5:0])
			0: data_out <= 8'h01;	// Write SRAM status register
			1: data_out <= 8'h40;	// Sequential mode
			2: data_out <= 8'h03;	// Stream read
			3: data_out <= 8'h00;	// Address zero (high)
			4: data_out <= 8'h00;	// Address zero (low)
		    endcase;
		    state <= `WRITES2;
		end
		
		`WRITES2 : begin
		    if (status == 1'b1) begin
			state <= `WAITS2;
		    	write <= 1'b0;
		    end else begin
		        write <= 1'b1;
		    end
		end

		`WAITS2 : begin
		    write <= 1'b0;
		    if (status == 1'b0) begin

			/* End transmission before each subsequent command */
			case (counter[5:0])
			    1: sramcsb <= 1'b1;		/* End command */
			endcase;

			counter <= counter + 1;
			if (counter == 4) begin
		    	    maskcsb <= 1'b0;		// Enable the display's SPI
			    state <= `HWRESET;
			end else
			    state <= `STARTS2;
		    end
		end

		/* A hardware reset is required to pull the display out of
		 * deep sleep mode.
		 */

		`HWRESET : begin
		    resetb <= 1'b0;	/* Apply hardware reset */
		    state <= `WAIT0;
		    counter <= 0;
		    timer <= 0;
		end

		`WAIT0 : begin			/* 10ms reset + 10ms idle */
		    if (counter == `DELAY_655US) begin
			timer <= timer + 1;
			counter <= 0;
			if (timer == 4'hf) begin
			    resetb <= 1'b1;	/* Release hardware reset */
			    if (resetb == 1'b1)
				state <= `STARTR;
			end
		    end else begin
		        counter <= counter + 1;
		    end
		end

		/* Apply the soft reset command, then wait for busy to	*/
		/* go low, then wait an additional 10ms.		*/

		`STARTR: begin
		    counter <= 0;
		    timer <= 0;
		    dcb <= 1'b0;		// Command mode
		    data_out <= 8'h12;		// Soft reset
		    state <= `WRITER;
		end

		`WRITER: begin
		    stream <= 1'b1;	/* Start (or continue) transmission */
		    if (status == 1'b1) begin
			state <= `WAITR;
		    	write <= 1'b0;
		    end else begin
		        write <= 1'b1;
		    end
		end

		`WAITR: begin
		    write <= 1'b0;
		    if (status == 1'b0) begin
			stream <= 1'b0;		/* End transmission */
			state <= `WAITB;
		    end
		end

		`WAITB : begin
		    if (busy == 1'b0)
			state <= `WAITX;
		end

		`WAITX : begin			/* 10ms idle */
		    if (counter == `DELAY_655US) begin
			timer <= timer + 1;
			counter <= 0;
			if (timer == 4'hf) begin
			    state <= `START1;
			end
		    end else begin
		        counter <= counter + 1;
		    end
		end

		/* Following is a sequence of commands and data */
		/* There are 30 bytes to send, followed by all pixel data */

		`START1: begin
		    counter <= 0;
		    timer <= 0;
		    dcb <= 1'b0;		// Command mode
		    state <= `START2;
		end

		`START2 : begin
		    case (counter[5:0])
			0: data_out <= 8'h11;	// RAM data entry mode
			1: data_out <= 8'h03;
			2: data_out <= 8'h3c;	// Border color
			3: data_out <= 8'h05;
			4: data_out <= 8'h2c;	// Write Vcom
			5: data_out <= 8'h36;
			6: data_out <= 8'h03;	// Gate voltage
			7: data_out <= 8'h17;
			8: data_out <= 8'h04;	// Source voltage
			9: data_out <= 8'h41;
			10: data_out <= 8'h00;
			11: data_out <= 8'h32;
			12: data_out <= 8'h4e;	// Set X count
			13: data_out <= 8'h00;
			14: data_out <= 8'h4f;	// Set Y count
			15: data_out <= 8'h00;
			16: data_out <= 8'h00;
			17: data_out <= 8'h44;	// Set X position
			18: data_out <= 8'h00;
			19: data_out <= 8'h0f;
			20: data_out <= 8'h45;	// Set Y position
			21: data_out <= 8'h00;
			22: data_out <= 8'h00;
			23: data_out <= 8'hf9;
			24: data_out <= 8'h00;
			25: data_out <= 8'h01;	// Driver control
			26: data_out <= 8'hf9;
			27: data_out <= 8'h00;
			28: data_out <= 8'h00;
			29: data_out <= 8'h24;	// Stream write
		    endcase;
		    state <= `WRITE2;
		end

		`WRITE2 : begin
		    stream <= 1'b1;	/* Start (or continue) transmission */
		    if (status == 1'b1) begin
			state <= `WAIT2;
		    	write <= 1'b0;
		    end else begin
		        write <= 1'b1;
		    end
		end

		`WAIT2 : begin
		    write <= 1'b0;
		    if (status == 1'b0) begin

			/* End transmission before each subsequent command */
			case (counter[5:0])
			    1, 3, 5, 7, 11, 13, 16, 19, 24, 28:
			    begin
				stream <= 1'b0;		/* End transmission */
				dcb <= 1'b0;		/* Return to command */
			    end
			endcase;

			/* 1st byte of a transmission is command, the rest data */
			case (counter[5:0])
			    0, 2, 4, 6, 8, 12, 14, 17, 20, 25, 29:
				dcb <= 1'b1;		/* Switch to data */
			endcase;

			counter <= counter + 1;
			if (counter == 29)
			    state <= `START3;
			else
			    state <= `START2;
		    end
		end

		`START3: begin
		    counter <= 0;
		    dcb <= 1'b1;		// Data mode
		    state <= `START4;
		end

		`START4 : begin
		    /* Display pattern definitions
		     * Note that the display is vertical and the demo board
		     * is silkscreened such that the display is in a horizontal
		     * orientation when the text is facing up.  So data appears
		     * on the display as running top to bottom and right to left.
		     * The height of the display is then 122 which maps to 128
		     * bits in memory with the last 6 bits unused, or 16 bytes.
		     * So counter[3:0] (4 bits) is the Y position, in bytes, and
		     * counter[11:4] (8 bits) is the X position,in bits.  A grid
		     * of 32 x 16 can be addressed by Y = counter[3:0], X =
		     * counter[11:7], byte value is always either 0x00 or 0xff,
		     * and the same value must repeat over all values of
		     * counter[6:4].
		     */

		    if (inval[0] == 1'b1) data_out <= 8'hff;		// White
		    else if (inval[1] == 1'b1) data_out <= 8'h00;	// Black
		    else if (inval[2] == 1'b1) begin
			data_out <= {8{counter[7]}};			// V Stripes
		    end else if (inval[3] == 1'b1) begin
			data_out <= {8{counter[0]}};			// H Stripes
		    end else if (inval[4] == 1'b1) begin
			data_out <= {8{counter[0] ^ counter[6]}};	// Checker S
		    end else if (inval[5] == 1'b1) begin
			// data_out <= {8{counter[1] ^ counter[7]}};	// (Checker M)
			data_out <= data_in;				// SRAM data
		    end else if (inval[6] == 1'b1) begin
			data_out <= {8{counter[2] ^ counter[8]}};	// Checker L
		    end else if (inval[7] == 1'b1) begin
			// data_out <= {8{counter[3] ^ counter[9]}};	// (Checker XL)

			// Demonstration of a drawn pattern on a 32 x 16 coarse grid
			// Note: xpos = counter[11:7], ypos = counter[3:0]
			case (ypos)
			    0, 15:
				data_out <= (xpos >= 14 && xpos <= 18) ? 8'h00 : 8'hff;
			    1, 14:
				data_out <= (xpos == 12 || xpos == 13 ||
					     xpos == 19 || xpos == 20) ? 8'h00 : 8'hff;
			    2, 13:
				data_out <= (xpos == 11 || xpos == 21) ? 8'h00 : 8'hff;
			    3:
				data_out <= (xpos == 10 || xpos == 22) ? 8'h00 : 8'hff;
			    4, 5:
				data_out <= (xpos == 9 || xpos == 14 ||
					     xpos == 18 || xpos == 23) ? 8'h00 : 8'hff;
			    6:
				data_out <= (xpos == 8 || xpos == 14 ||
					     xpos == 18 || xpos == 24) ? 8'h00 : 8'hff;
			    7, 8:
				data_out <= (xpos == 8 || xpos == 24) ? 8'h00 : 8'hff;
			    9:
				data_out <= (xpos == 8 || xpos == 11 ||
					     xpos == 21 || xpos == 24) ? 8'h00 : 8'hff;
			    10:
				data_out <= (xpos == 9 || xpos == 12 ||
					     xpos == 20 || xpos == 23) ? 8'h00 : 8'hff;
			    11:
				data_out <= (xpos == 9 || xpos == 23 ||
					     xpos == 13 || xpos == 14 ||
					     xpos == 18 || xpos == 19) ? 8'h00 : 8'hff;
			    12:
				data_out <= (xpos == 10 || xpos == 22 ||
					    (xpos >= 15 && xpos <= 17)) ? 8'h00 : 8'hff;
			endcase
		    end
		    state <= `WRITE4;
		end

		`WRITE4 : begin
		    if (status == 1'b1) begin
			state <= `WAIT4;
		        write <= 1'b0;
		    end else begin
		        write <= 1'b1;
		    end
		end

		`WAIT4 : begin
		    write <= 1'b0;
		    if (status == 1'b0) begin
			counter <= counter + 1;
			if (counter == (`DISPLAY_BYTES - 1))
			    state <= `END4;
			else
			    state <= `START4;
		    end
		end

		`END4 : begin
		    stream <= 1'b0;		/* End transmission */
		    state <= `START5;
		end

		/* Following is a sequence of commands and data */
		/* There are 5 bytes to send, followed by returning to idle */

		`START5: begin
		    counter <= 0;
		    dcb <= 1'b0;		// Command mode
		    state <= `START6;
		end

		`START6 : begin
		    case (counter[5:0])
			0: data_out <= 8'h22;	// Disp Ctrl2
			1: data_out <= 8'hf4;
			2: data_out <= 8'h20;	// Master activate
			3: data_out <= 8'h10;	// Deep sleep
			4: data_out <= 8'h01;
		    endcase;
		    stream <= 1'b1;	/* Start (or continue) transmission */
		    state <= `WRITE6;
		end

		`WRITE6 : begin
		    if (status == 1'b1) begin
			state <= `WAIT6;
		        write <= 1'b0;
		    end else begin
		        write <= 1'b1;
		    end
		end

		`WAIT6 : begin
		    write <= 1'b0;
		    if (status == 1'b0) begin
			/* End transmission before each subsequent command */
			case (counter[2:0])
			    1, 3, 4:
			    begin
				stream <= 1'b0;		/* End transmission */
				dcb <= 1'b0;		/* Return to command */
			    end
			endcase;

			/* 1st byte of transmission is command, the rest data */
			case (counter[2:0])
			    0, 2, 4:
				dcb <= 1'b1;		/* Switch to data */
			endcase;

			counter <= counter + 1;
			if (counter == 3) begin
			    state <= `WAIT7;
			end else if (counter == 4) begin
			    state <= `IDLE;
			end else begin
			    state <= `START6;
			end
		    end
		end

		`WAIT7 : begin
		    stream <= 1'b0;	/* End transmission */
		    if (busy == 1'b0)
			state <= `START6;
		end

		default :
		    state <= `IDLE;
	    endcase
	end
    end

    /* Instantiate the SPI master */

    simple_spi_master spi (
	.resetn(rst_n),
	.clk(clk),

	/* Prescaler:  The SSD1680 specifies a write mode maximum of 20MHz
	 * and a read mode maximum of 2.5MHz.  So use the lower rate, which
	 * means a prescaler of 20 from a clock of 50MHz.
	 */
	.prescaler(`PRESCALER),	// Prescaler value
	.invsck(1'b0),		// Inverted SCK (standard noninverted clock)
	.invcsb(1'b0),		// Inverted CSB (CSB is sense negative)
	.mlb(1'b0),		// msb/lsb first (always msb first)
	.stream(strmdly),	// Stream mode (apply/resease as needed)
	.mode(1'b0),		// SCK edge (default, mode 0)
	.enable(1'b1),		// Enable/disable (always enabled)

	.passthru(passthru),	// Pass-through mode (for SRAM)
	.pass_sck(ui_in[0]),	// Pass-through clock
	.pass_mosi(ui_in[1]),	// Pass-through data out
	.maskcsb(maskcsb),	// Mask display CSB for accessing SRAM only

	.reg_dat_we(write),	// Write enable
	.reg_dat_re(1'b0),	// [e-ink display does not send data]
	.reg_dat_di(data_out),	// Data in to slave (8 bits)
	.reg_dat_do(data_in),	// Data out from slave (8 bits, coming from SRAM)
	.reg_dat_wait(status),	// Busy

	.err_out(spi_err_unused),	// Error condition (unused)

	.sdi(miso), 		// SPI input
	.csb(csb),		// SPI select (display)
	.sck(sck),		// SPI clock
	.sdo(mosi),		// SPI output
	.sdoenb(mosienb)	// SPI output enable (sense negative)
);

endmodule
