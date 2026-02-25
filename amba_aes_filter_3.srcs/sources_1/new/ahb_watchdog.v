`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ahb_watchdog
// Description: Multi-slave Bus Monitor Watchdog
//              - Monitors 4 slaves for hready timeouts
//              - Generates individual resets on timeout or force signal
//////////////////////////////////////////////////////////////////////////////////

module ahb_watchdog(
    input  wire        hclk,
    input  wire        hresetn,
    
    // Monitored Signals (concatenated for 4 slaves)
    // [3]=Slave4, [2]=Slave3, [1]=Slave2, [0]=Slave1
    input  wire [3:0]  hsel,
    input  wire [3:0]  hreadyout,
    
    // Outputs
    output reg  [3:0]  slv_rst_n,       // Individual active-low resets
    output reg  [3:0]  timeout_flags,   // Sticky flags for timeouts
    output reg  [31:0] total_timeouts,  // Global counter
    
    // Configuration
    input  wire [3:0]  force_reset,     // Force reset for specific slave
    input  wire [7:0]  timeout_cfg      // Timeout threshold (cycles)
);

    integer i;
    reg [31:0] counters [3:0];
    reg [3:0]  reset_counters [3:0]; // For pulse width
    
    localparam RST_PULSE_WIDTH = 4'd10;
    
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            slv_rst_n <= 4'b1111;
            timeout_flags <= 4'b0000;
            total_timeouts <= 32'd0;
            for (i = 0; i < 4; i = i + 1) begin
                counters[i] <= 32'd0;
                reset_counters[i] <= 4'd0;
            end
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                // 1. Handle Reset Pulse Generation
                if (reset_counters[i] > 0) begin
                    slv_rst_n[i] <= 1'b0; // Active low reset
                    reset_counters[i] <= reset_counters[i] - 1;
                end else begin
                    slv_rst_n[i] <= 1'b1;
                end

                // 2. Watchdog Logic
                // If slave selected and not ready, increment counter
                if (hsel[i] && !hreadyout[i]) begin
                    counters[i] <= counters[i] + 1;
                end else begin
                    counters[i] <= 32'd0;
                end

                // 3. Trigger Conditions
                // Condition A: Timeout exceeded (and cfg is not 0)
                // Condition B: Force reset requested
                if ((timeout_cfg > 0 && counters[i] > {24'b0, timeout_cfg}) || force_reset[i]) begin
                    // Only trigger if not already resetting
                    if (reset_counters[i] == 0) begin
                        reset_counters[i] <= RST_PULSE_WIDTH;
                        // If it was a timeout (not just force), set flag and increment total
                        if (force_reset[i] == 0) begin
                            timeout_flags[i] <= 1'b1;
                            total_timeouts <= total_timeouts + 1;
                        end
                    end
                    counters[i] <= 32'd0; // Reset counter
                end
            end
        end
    end

endmodule