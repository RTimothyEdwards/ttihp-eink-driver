`default_nettype none
// SPDX-FileCopyrightText: 2019 Efabless Corporation
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// SPDX-License-Identifier: Apache-2.0
//----------------------------------------------------------------------------
// (Adapted from) Module: simple_spi_master
//
//----------------------------------------------------------------------------
// Copyright (C) 2019 efabless, inc.
//
// This source file may be used and distributed without
// restriction provided that this copyright statement is not
// removed from the file and that any derivative work contains
// the original copyright notice and the associated disclaimer.
//
// This source file is free software; you can redistribute it
// and/or modify it under the terms of the GNU Lesser General
// Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any
// later version.
//
// This source is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE.  See the GNU Lesser General Public License for more
// details.
//
//--------------------------------------------------------------------
// 
// resetn: active low async reset
// clk:    master clock (before prescaler)
// stream:
//     0 = apply/release CSB separately for each byte
//     1 = apply CSB until stream bit is cleared
// mlb:
//     0 = msb 1st
//     1 = lsb 1st
// invsck:
//     0 = normal SCK
//     1 = inverted SCK
// invcsb:
//     0 = normal CSB (active low)
//     1 = inverted CSB (active high)
// mode:
//     0 = read and change data on opposite SCK edges
//     1 = read and change data on the same SCK edge
// enable:
//     0 = disable the SPI master
//     1 = enable the SPI master
// irqena:
//     0 = disable interrupt
//     1 = enable interrupt
// prescaler: count (in master clock cycles) of 1/2 SCK cycle.
//
// reg_dat_we:
//     1 = data write enable
// reg_dat_re:
//     1 = data read enable
// reg_dat_*: Signaling for read/write of data register
//
// err_out:  Indicates attempt to read/write before data ready
//	(failure to wait for reg_dat_wait to clear)
//
// Between "mode" and "invsck", all four standard SPI modes are supported
//
//--------------------------------------------------------------------

module simple_spi_master (
    input wire   resetn,
    input wire   clk,	 // master clock (assume 100MHz)

    input wire [7:0] prescaler,	// Prescaler value
    input wire     invsck,		// Inverted SCK
    input wire     invcsb,		// Inverted CSB
    input wire     mlb,		// msb/lsb first
    input wire     stream,		// Stream mode
    input wire     mode,		// SCK edge
    input wire     enable,		// Enable/disable

    input wire 	 	reg_dat_we,	// Write enable
    input wire 	 	reg_dat_re,	// Read enable
    input wire [7:0] 	reg_dat_di,	// Data in (8 bits)
    output wire [7:0] 	reg_dat_do,	// Data out (8 bits)
    output wire	 	reg_dat_wait,	// Busy

    output reg	 err_out,	// Error condition

    input  wire	 sdi,	 // SPI input
    output wire	 csb,	 // SPI chip select
    output wire	 sck,	 // SPI clock
    output reg	 sdo,	 // SPI output
    output wire  sdoenb  // SPI output enable (sense negative)
);

    parameter IDLE   = 2'b00;	    
    parameter SENDL  = 2'b01; 
    parameter SENDH  = 2'b10; 
    parameter FINISH = 2'b11; 

    reg	      done;
    reg       hsck, icsb;
    reg [1:0] state;
    reg       isck;
 
    reg [7:0] treg, rreg, d_latched;
    reg [2:0] nbit;
    reg [7:0] count;

    // Define behavior for inverted SCK and inverted CSB
    assign    	  csb = (enable == 1'b0) ? 1'bz : (invcsb) ? ~icsb : icsb;
    assign	  sck = (enable == 1'b0) ? 1'bz : (invsck) ? ~isck : isck;

    // No bidirectional 3-pin mode defined, so SDO is enabled whenever CSB is low.
    assign	  sdoenb = (enable == 1'b0) ? 1'b1 : icsb;

    assign reg_dat_wait = ~done;
    assign reg_dat_do = done ? rreg : ~0;

    // Watch for read and write enables on clk, not hsck, so as not to
    // miss them.  Change on clk negative edge, so signal is established
    // before the rising edge of hclk.

    reg w_latched, r_latched;

    always @(negedge clk or negedge resetn) begin
        if (resetn == 1'b0) begin
	    err_out <= 1'b0;
            w_latched <= 1'b0;
            r_latched <= 1'b0;
	    d_latched <= 8'd0;
        end else begin
            // Clear latches on SEND, otherwise latch when seen
            if (state == SENDL || state == SENDH) begin
	        if (reg_dat_we == 1'b0) begin
		    w_latched <= 1'b0;
	        end
	    end else begin
	        if (reg_dat_we == 1'b1) begin
		    if (done == 1'b0 && w_latched == 1'b1) begin
		        err_out <= 1'b1;
		    end else begin
		        w_latched <= 1'b1;
		        d_latched <= reg_dat_di;
		        err_out <= 1'b0;
		    end
	        end
	    end

	    if (reg_dat_re == 1'b1) begin
	        if (r_latched == 1'b1) begin
		    r_latched <= 1'b0;
	        end else begin
		    err_out <= 1'b1;	// byte not available
	        end
	    end else if (state == FINISH) begin
	        r_latched <= 1'b1;
	    end if (state == SENDL || state == SENDH) begin
	        if (r_latched == 1'b1) begin
		    err_out <= 1'b1;	// last byte was never read
	        end else begin
		    r_latched <= 1'b0;
	        end
	    end
        end
    end

    // State transition.

    always @(posedge hsck or negedge resetn) begin
        if (resetn == 1'b0) begin
	    state <= IDLE;
	    nbit <= 3'd0;
	    icsb <= 1'b1;
	    done <= 1'b1;
        end else begin
	    if (state == IDLE) begin
	        if (w_latched == 1'b1) begin
		    state <= SENDL;
		    nbit <= 3'd0;
		    icsb <= 1'b0;
		    done <= 1'b0;
	        end else begin
	            icsb <= ~stream;
	        end
	    end else if (state == SENDL) begin
	        state <= SENDH;
	    end else if (state == SENDH) begin
	        nbit <= nbit + 1;
                if (nbit == 3'd7) begin
		    done <= 1'b1;
		    state <= FINISH;
	        end else begin
	            state <= SENDL;
	        end
	    end else if (state == FINISH) begin
	        icsb <= ~stream;
	        done <= 1'b1;
	        state <= IDLE;
	    end
        end
    end
 
    // Set up internal clock.  The enable bit gates the internal clock
    // to shut down the master SPI when disabled.

    always @(posedge clk or negedge resetn) begin
        if (resetn == 1'b0) begin
	    count <= 8'd0;
	    hsck <= 1'b0;
        end else begin
	    if (enable == 1'b0) begin
 	        count <= 8'd0;
	    end else begin
	        count <= count + 1; 
                if (count == prescaler) begin
		    hsck <= ~hsck;
		    count <= 8'd0;
	        end // count
	    end // enable
        end // resetn
    end // always
 
    // sck is half the rate of hsck

    always @(posedge hsck or negedge resetn) begin
        if (resetn == 1'b0) begin
	    isck <= 1'b0;
        end else begin
	    if (state == IDLE || state == FINISH)
	        isck <= 1'b0;
	    else
	        isck <= ~isck;
        end // resetn
    end // always

    // Main procedure:  read, write, shift data

    always @(posedge hsck or negedge resetn) begin
        if (resetn == 1'b0) begin
	    rreg <= 8'hff;
	    treg <= 8'hff;
	    sdo <= 1'b0;
        end else begin 
	    if (isck == 1'b0 && (state == SENDL || state == SENDH)) begin
	        if (mlb == 1'b1) begin
		    // LSB first, sdi@msb -> right shift
		    rreg <= {sdi, rreg[7:1]};
	        end else begin
		    // MSB first, sdi@lsb -> left shift
		    rreg <= {rreg[6:0], sdi};
	        end
	    end // read on ~isck

            if (w_latched == 1'b1) begin
	        if (mlb == 1'b1) begin
		    treg <= {d_latched[7], d_latched[7:1]};
		    sdo <= d_latched[0];
	        end else begin
		    treg <= {d_latched[6:0], d_latched[0]};
		    sdo <= d_latched[7];
	        end // mlb
	    end else if ((mode ^ isck) == 1'b1) begin
	        if (mlb == 1'b1) begin
		    // LSB first, shift right
		    treg <= {treg[7], treg[7:1]};
		    sdo <= treg[0];
	        end else begin
		    // MSB first shift LEFT
		    treg <= {treg[6:0], treg[0]};
		    sdo <= treg[7];
	        end // mlb
	    end // write on mode ^ isck
        end // resetn
    end // always
 
endmodule
`default_nettype wire
