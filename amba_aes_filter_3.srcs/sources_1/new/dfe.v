module dfe #(
    parameter DATA_WIDTH = 12
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,

    input  wire signed [DATA_WIDTH-1:0] din,     // from FIR
    input  wire signed [DATA_WIDTH-1:0] dfe_coeff, // feedback weight

    output reg  signed [DATA_WIDTH-1:0] dout     // corrected output
);

    // Previous symbol decision (+1 or -1)
    reg signed [1:0] prev_decision;

    reg signed [DATA_WIDTH-1:0] feedback;

    always @(posedge clk) begin
        if (rst) begin
            prev_decision <= 0;
            dout <= 0;
        end else if (enable) begin
            // Feedback computation
            feedback <= prev_decision * dfe_coeff;

            // Subtract feedback
            dout <= din - feedback;

            // Decision device (simple slicer)
            if (dout >= 0)
                prev_decision <= 2'sd1;
            else
                prev_decision <= -2'sd1;
        end else begin
            dout <= din;           // bypass
            prev_decision <= 0;
        end
    end

endmodule