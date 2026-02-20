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
    output master_hclk,  // Gated clock for master
    output slave1_hclk,  // Gated clock for slave 1
    output slave2_hclk,  // Gated clock for slave 2
    output slave3_hclk,  // Gated clock for slave 3
    output slave4_hclk   // Gated clock for slave 4
);

    // Clock gating uses latches to avoid glitches.
    // Gate enable is updated on falling edge of hclk.

    // Master clock gating: gate when not enabled
    reg master_gate;
    always @(enable or hclk) begin
        if (!hclk) master_gate <= enable;
    end
    assign master_hclk = hclk & master_gate;

    // Slave clock gating: gate when not selected
    reg slave1_gate, slave2_gate, slave3_gate, slave4_gate;
    always @(hsel_1 or hclk) begin
        if (!hclk) slave1_gate <= hsel_1;
    end
    always @(hsel_2 or hclk) begin
        if (!hclk) slave2_gate <= hsel_2;
    end
    always @(hsel_3 or hclk) begin
        if (!hclk) slave3_gate <= hsel_3;
    end
    always @(hsel_4 or hclk) begin
        if (!hclk) slave4_gate <= hsel_4;
    end
    assign slave1_hclk = hclk & slave1_gate;
    assign slave2_hclk = hclk & slave2_gate;
    assign slave3_hclk = hclk & slave3_gate;
    assign slave4_hclk = hclk & slave4_gate;

endmodule</content>
<parameter name="filePath">c:\Users\abrah\amba_aes_filter_clk\amba_aes_filter_3.srcs\sources_1\new\ahb_clock_gate.v