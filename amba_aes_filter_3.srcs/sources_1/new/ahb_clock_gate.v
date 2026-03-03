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

    // Clock enable logic:
    //   enable=0 (gating OFF) : all CEs = 1 → clocks always run (high power mode)
    //   enable=1 (gating ON)  : CE = 1 only when that slave is selected (low power mode)
    assign master_ce  = ~enable | (hsel_1 | hsel_2 | hsel_3 | hsel_4);
    assign slave1_ce  = ~enable | hsel_1;
    assign slave2_ce  = ~enable | hsel_2;
    assign slave3_ce  = ~enable | hsel_3;
    assign slave4_ce  = ~enable | hsel_4;

endmodule