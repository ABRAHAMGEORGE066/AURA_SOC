module dc_offset_filter #(
    parameter DATA_WIDTH = 12,
    parameter ALPHA_SHIFT = 4   // Controls cutoff frequency
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     enable,
    input  wire signed [DATA_WIDTH-1:0] din,
    output reg  signed [DATA_WIDTH-1:0] dout
);

    reg signed [DATA_WIDTH-1:0] avg;

    always @(posedge clk) begin
        if (rst) begin
            avg  <= 0;
            dout <= 0;
        end else if (enable) begin
            avg  <= avg + ((din - avg) >>> ALPHA_SHIFT);
            dout <= din - avg;
        end else begin
            dout <= din;  // bypass
        end
    end

endmodule