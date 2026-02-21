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

    // Safe clock gating: use flip-flop based enable, no latches
    // Gated clocks are AND of hclk and enable signals registered on rising edge
    reg master_gate;
    reg slave1_gate, slave2_gate, slave3_gate, slave4_gate;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            master_gate <= 1'b0;
            slave1_gate <= 1'b0;
            slave2_gate <= 1'b0;
            slave3_gate <= 1'b0;
            slave4_gate <= 1'b0;
        end else begin
            master_gate <= enable;
            slave1_gate <= hsel_1;
            slave2_gate <= hsel_2;
            slave3_gate <= hsel_3;
            slave4_gate <= hsel_4;
        end
    end

    assign master_hclk = hclk & master_gate;
    assign slave1_hclk = hclk & slave1_gate;
    assign slave2_hclk = hclk & slave2_gate;
    assign slave3_hclk = hclk & slave3_gate;
    assign slave4_hclk = hclk & slave4_gate;

endmodule
