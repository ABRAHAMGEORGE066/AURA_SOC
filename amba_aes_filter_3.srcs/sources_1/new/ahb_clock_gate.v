//======================================================================
// MODULE: ahb_clock_gate
// DESCRIPTION: Clock gating unit for the AHB system. Gates clocks to
// master and slaves based on activity to save power.
//======================================================================
module ahb_clock_gate(
    input hclk,
    input hresetn,
    input enable,        // Master enable signal
    input hsel_1,        // Slave 1 select
    input hsel_2,        // Slave 2 select
    input hsel_3,        // Slave 3 select
    input hsel_4,        // Slave 4 select
    output master_ce,    // Clock enable for master
    output slave1_ce,    // Clock enable for slave 1
    output slave2_ce,    // Clock enable for slave 2
    output slave3_ce,    // Clock enable for slave 3
    output slave4_ce     // Clock enable for slave 4
);

    // For FPGA: Use clock enable signals instead of gating the clock
        // Clock gating disabled: all enables forced ON
        assign master_ce  = 1'b1;
        assign slave1_ce  = 1'b1;
        assign slave2_ce  = 1'b1;
        assign slave3_ce  = 1'b1;
        assign slave4_ce  = 1'b1;
    assign slave4_ce  = hsel_4;

endmodule