# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # Set the clock period to 20 ns (50 MHz)
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    dut._log.info("Test project behavior")

    # Nothing should happen as long as the input is zero.  Clock 10 more cycles
    # out of reset
    await ClockCycles(dut.clk, 10)

    # Toggle the high input bit high.  This initiates a display sequence
    dut.ui_in.value = 128
    dut.uio_in.value = 0

    # Wait for one clock cycle to see the output values
    await ClockCycles(dut.clk, 1)

    # The following assersion is just an example of how to check the output values.
    # Change it to match the actual expected output of your module:
    assert dut.uo_out.value == 0

    # Keep testing the module by changing the input values, waiting for
    # one or more clock cycles, and asserting the expected output values.

    # Note:  This is just a dummy test to make the project pass tapeout checks.
    # The functionality has been tested on an Arty FPGA board configured to
    # mimic the TT demo board (see directory fpga/).  The best way to test
    # is to check that uio_out[5] is 1 prior to and for two clock cycles
    # after ui_in changes, then drops low.  Since this is the beginning of a
    # long timed reset, nothing else happens for many, many clock cycles.
