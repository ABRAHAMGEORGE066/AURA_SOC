module lpf_fir #(
    parameter DATA_WIDTH = 12
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,
    input  wire signed [DATA_WIDTH-1:0] din,
    output reg  signed [DATA_WIDTH-1:0] dout
);

    // Shift register for samples
    reg signed [DATA_WIDTH-1:0] x0, x1, x2, x3, x4;

    reg signed [DATA_WIDTH+3:0] acc;  // wider accumulator

    always @(posedge clk) begin
        if (rst) begin
            x0 <= 0; x1 <= 0; x2 <= 0; x3 <= 0; x4 <= 0;
            dout <= 0;
        end else if (enable) begin
            // Shift samples
            x4 <= x3;
            x3 <= x2;
            x2 <= x1;
            x1 <= x0;
            x0 <= din;

            // FIR computation: (1 2 3 2 1)/9
            acc  <= (x0 + (x1 <<< 1) + (x2 * 3) + (x3 <<< 1) + x4);
            dout <= acc / 9;
        end else begin
            dout <= din;   // bypass
        end
    end

endmodule