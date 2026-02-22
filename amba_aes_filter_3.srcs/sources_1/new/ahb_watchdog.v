`timescale 1ns / 1ps
//======================================================================
// MODULE: ahb_watchdog
// DESCRIPTION: Per-slave AHB timeout watchdog and local reset controller.
//
// Operation:
//   Each of the 4 AHB slaves is monitored independently via a dedicated
//   8-bit up-counter.  The counter increments every clock cycle where:
//       hsel[N]      = 1   (slave N is targeted by an AHB transaction)
//     AND
//       hreadyout[N] = 0   (slave N is holding the bus / not responding)
//
//   If the counter reaches `timeout_cfg` consecutive stall-cycles, the
//   slave is declared unresponsive.  A local reset pulse is asserted
//   (slv_rst_n[N] = 0 for RST_PULSE_LEN clock cycles) for that slave
//   ONLY.  All other slaves and the master continue to run undisturbed.
//
//   Software can also trigger an immediate reset of any slave without
//   waiting for a hardware timeout by writing 1 to the corresponding
//   bit of the WDG_FORCE_RST register (mapped at address 0x78 inside
//   ahb_filter_slave).
//
//   Setting timeout_cfg = 0 disables the hardware timeout detection
//   (force-reset still works).
//
// Outputs:
//   slv_rst_n[3:0]  - per-slave active-low reset  (normally = hresetn)
//   timeout_flags   - sticky event flag per slave (cleared only by
//                     global hresetn)
//   total_timeouts  - cumulative count of all watchdog events across
//                     all four slaves (persists across local resets)
//
// Parameters:
//   TIMEOUT_THRESH  - default stall-cycle threshold (default 200)
//   RST_PULSE_LEN   - width of the local reset pulse in cycles (default 10)
//======================================================================
module ahb_watchdog #(
    parameter [7:0] TIMEOUT_THRESH = 8'd200,
    parameter [3:0] RST_PULSE_LEN  = 4'd10
)(
    input  wire        hclk,
    input  wire        hresetn,

    // Per-slave monitoring signals (index 0 = AHB Slave 1 … 3 = AHB Slave 4)
    input  wire [3:0]  hsel,
    input  wire [3:0]  hreadyout,

    // Per-slave isolated active-low resets
    // slv_rst_n[N] = hresetn AND NOT rst_active[N]
    output wire [3:0]  slv_rst_n,

    // Status / diagnostics (read via WDG registers in ahb_filter_slave)
    output reg  [3:0]  timeout_flags,    // sticky: set on any event, cleared by hresetn
    output reg  [31:0] total_timeouts,   // cumulative event counter (all slaves)

    // Software control inputs
    input  wire [3:0]  force_reset,      // bit N = 1 → force-reset slave N immediately
    input  wire [7:0]  timeout_cfg       // programmable threshold; 0 = HW detection disabled
);

    //------------------------------------------------------------------
    // Per-slave state registers
    //------------------------------------------------------------------
    reg [7:0] timeout_cnt_0, timeout_cnt_1, timeout_cnt_2, timeout_cnt_3;
    reg       rst_active_0,  rst_active_1,  rst_active_2,  rst_active_3;
    reg [3:0] rst_pcnt_0,    rst_pcnt_1,    rst_pcnt_2,    rst_pcnt_3;

    // Combinational per-slave reset output
    assign slv_rst_n[0] = hresetn & ~rst_active_0;
    assign slv_rst_n[1] = hresetn & ~rst_active_1;
    assign slv_rst_n[2] = hresetn & ~rst_active_2;
    assign slv_rst_n[3] = hresetn & ~rst_active_3;

    // Rising-edge detector for cumulative event counting
    reg  [3:0] rst_active_prev;
    wire [3:0] rst_active_cur = {rst_active_3, rst_active_2, rst_active_1, rst_active_0};

    //------------------------------------------------------------------
    // Per-slave watchdog FSM – Slave 0 (AHB Slave 1)
    //------------------------------------------------------------------
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            timeout_cnt_0 <= 8'd0; rst_active_0 <= 1'b0; rst_pcnt_0 <= 4'd0;
        end else if (rst_active_0) begin
            // Counting down the reset pulse
            if (rst_pcnt_0 > 4'd0) rst_pcnt_0 <= rst_pcnt_0 - 4'd1;
            else                    rst_active_0 <= 1'b0;
            timeout_cnt_0 <= 8'd0;
        end else begin
            if (force_reset[0]) begin
                // SW-triggered immediate reset
                rst_active_0  <= 1'b1;
                rst_pcnt_0    <= RST_PULSE_LEN - 4'd1;
                timeout_cnt_0 <= 8'd0;
            end else if (timeout_cfg != 8'd0 && hsel[0] && !hreadyout[0]) begin
                // Hardware timeout detection
                if (timeout_cnt_0 < timeout_cfg)
                    timeout_cnt_0 <= timeout_cnt_0 + 8'd1;
                else begin
                    rst_active_0  <= 1'b1;
                    rst_pcnt_0    <= RST_PULSE_LEN - 4'd1;
                    timeout_cnt_0 <= 8'd0;
                end
            end else begin
                timeout_cnt_0 <= 8'd0;  // slave responded or not selected
            end
        end
    end

    //------------------------------------------------------------------
    // Per-slave watchdog FSM – Slave 1 (AHB Slave 2)
    //------------------------------------------------------------------
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            timeout_cnt_1 <= 8'd0; rst_active_1 <= 1'b0; rst_pcnt_1 <= 4'd0;
        end else if (rst_active_1) begin
            if (rst_pcnt_1 > 4'd0) rst_pcnt_1 <= rst_pcnt_1 - 4'd1;
            else                    rst_active_1 <= 1'b0;
            timeout_cnt_1 <= 8'd0;
        end else begin
            if (force_reset[1]) begin
                rst_active_1  <= 1'b1;
                rst_pcnt_1    <= RST_PULSE_LEN - 4'd1;
                timeout_cnt_1 <= 8'd0;
            end else if (timeout_cfg != 8'd0 && hsel[1] && !hreadyout[1]) begin
                if (timeout_cnt_1 < timeout_cfg)
                    timeout_cnt_1 <= timeout_cnt_1 + 8'd1;
                else begin
                    rst_active_1  <= 1'b1;
                    rst_pcnt_1    <= RST_PULSE_LEN - 4'd1;
                    timeout_cnt_1 <= 8'd0;
                end
            end else begin
                timeout_cnt_1 <= 8'd0;
            end
        end
    end

    //------------------------------------------------------------------
    // Per-slave watchdog FSM – Slave 2 (AHB Slave 3 = filter slave)
    //------------------------------------------------------------------
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            timeout_cnt_2 <= 8'd0; rst_active_2 <= 1'b0; rst_pcnt_2 <= 4'd0;
        end else if (rst_active_2) begin
            if (rst_pcnt_2 > 4'd0) rst_pcnt_2 <= rst_pcnt_2 - 4'd1;
            else                    rst_active_2 <= 1'b0;
            timeout_cnt_2 <= 8'd0;
        end else begin
            if (force_reset[2]) begin
                rst_active_2  <= 1'b1;
                rst_pcnt_2    <= RST_PULSE_LEN - 4'd1;
                timeout_cnt_2 <= 8'd0;
            end else if (timeout_cfg != 8'd0 && hsel[2] && !hreadyout[2]) begin
                if (timeout_cnt_2 < timeout_cfg)
                    timeout_cnt_2 <= timeout_cnt_2 + 8'd1;
                else begin
                    rst_active_2  <= 1'b1;
                    rst_pcnt_2    <= RST_PULSE_LEN - 4'd1;
                    timeout_cnt_2 <= 8'd0;
                end
            end else begin
                timeout_cnt_2 <= 8'd0;
            end
        end
    end

    //------------------------------------------------------------------
    // Per-slave watchdog FSM – Slave 3 (AHB Slave 4 = crypto slave)
    //------------------------------------------------------------------
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            timeout_cnt_3 <= 8'd0; rst_active_3 <= 1'b0; rst_pcnt_3 <= 4'd0;
        end else if (rst_active_3) begin
            if (rst_pcnt_3 > 4'd0) rst_pcnt_3 <= rst_pcnt_3 - 4'd1;
            else                    rst_active_3 <= 1'b0;
            timeout_cnt_3 <= 8'd0;
        end else begin
            if (force_reset[3]) begin
                rst_active_3  <= 1'b1;
                rst_pcnt_3    <= RST_PULSE_LEN - 4'd1;
                timeout_cnt_3 <= 8'd0;
            end else if (timeout_cfg != 8'd0 && hsel[3] && !hreadyout[3]) begin
                if (timeout_cnt_3 < timeout_cfg)
                    timeout_cnt_3 <= timeout_cnt_3 + 8'd1;
                else begin
                    rst_active_3  <= 1'b1;
                    rst_pcnt_3    <= RST_PULSE_LEN - 4'd1;
                    timeout_cnt_3 <= 8'd0;
                end
            end else begin
                timeout_cnt_3 <= 8'd0;
            end
        end
    end

    //------------------------------------------------------------------
    // Global status: sticky flags + cumulative event counter.
    // Rising edge of rst_active_N marks a new watchdog event for slave N.
    // Flags are sticky until global hresetn (diagnostic latch).
    //------------------------------------------------------------------
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            rst_active_prev <= 4'd0;
            timeout_flags   <= 4'd0;
            total_timeouts  <= 32'd0;
        end else begin
            rst_active_prev <= rst_active_cur;

            // Sticky flag: set on rising edge of rst_active per slave
            if (rst_active_cur[0] & ~rst_active_prev[0]) timeout_flags[0] <= 1'b1;
            if (rst_active_cur[1] & ~rst_active_prev[1]) timeout_flags[1] <= 1'b1;
            if (rst_active_cur[2] & ~rst_active_prev[2]) timeout_flags[2] <= 1'b1;
            if (rst_active_cur[3] & ~rst_active_prev[3]) timeout_flags[3] <= 1'b1;

            // Cumulative counter: sum all new events this cycle
            // (handles simultaneous events on multiple slaves correctly)
            total_timeouts <= total_timeouts
                + {{31{1'b0}}, rst_active_cur[0] & ~rst_active_prev[0]}
                + {{31{1'b0}}, rst_active_cur[1] & ~rst_active_prev[1]}
                + {{31{1'b0}}, rst_active_cur[2] & ~rst_active_prev[2]}
                + {{31{1'b0}}, rst_active_cur[3] & ~rst_active_prev[3]};
        end
    end

endmodule
