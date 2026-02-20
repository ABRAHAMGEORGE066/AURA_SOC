module ctle #(
    parameter DATA_WIDTH = 12,
    parameter ALPHA_SHIFT = 2   // controls peaking strength
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,
    input  wire signed [DATA_WIDTH-1:0] din,
    output reg  signed [DATA_WIDTH-1:0] dout
);

    reg signed [DATA_WIDTH-1:0] prev_sample;
    reg signed [DATA_WIDTH:0]   diff;
    reg signed [DATA_WIDTH+1:0] boosted;

    always @(posedge clk) begin
        if (rst) begin
            prev_sample <= 0;
            dout        <= 0;
        end else if (enable) begin
            diff      <= din - prev_sample;             // High-frequency content
            boosted   <= din + (diff >>> ALPHA_SHIFT);  // HF boost
            dout      <= boosted[DATA_WIDTH-1:0];
            prev_sample <= din;
        end else begin
            dout <= din;     // bypass
            prev_sample <= din;
        end
    end

endmodule