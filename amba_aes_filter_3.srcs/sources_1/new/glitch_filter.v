module glitch_filter #(
    parameter DATA_WIDTH = 12,
    parameter THRESHOLD  = 512
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,
    input  wire signed [DATA_WIDTH-1:0] din,
    output reg  signed [DATA_WIDTH-1:0] dout
);

    reg signed [DATA_WIDTH-1:0] s1, s2;
    reg signed [DATA_WIDTH-1:0] median;
    reg signed [DATA_WIDTH:0]   diff;     // 1 bit wider for subtraction safety
    reg        [DATA_WIDTH-1:0] abs_diff;

    // 3-point median calculation
    always @* begin
        if ((din >= s1 && din <= s2) || (din <= s1 && din >= s2))
            median = din;
        else if ((s1 >= din && s1 <= s2) || (s1 <= din && s1 >= s2))
            median = s1;
        else
            median = s2;

        // Spike detection: Calculate absolute difference between current and previous
        diff = din - s1;
        abs_diff = (diff < 0) ? -diff : diff;
    end

    always @(posedge clk) begin
        if (rst) begin
            s1   <= 0;
            s2   <= 0;
            dout <= 0;
        end else if (enable) begin
            s1   <= din;
            s2   <= s1;
            // Only use median if the jump exceeds threshold (spike detected)
            if (abs_diff > THRESHOLD)
                dout <= median;
            else
                dout <= din;
        end else begin
            dout <= din;  // bypass
        end
    end

endmodule