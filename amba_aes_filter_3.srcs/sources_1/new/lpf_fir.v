
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
    reg signed [DATA_WIDTH+3:0] acc_div; // pipeline register for division
    reg signed [DATA_WIDTH-1:0] dout_pipe; // second pipeline stage for output

    always @(posedge clk) begin
        if (rst) begin
            x0 <= 0; x1 <= 0; x2 <= 0; x3 <= 0; x4 <= 0;
            acc  <= 0;
            acc_div <= 0;
            dout_pipe <= 0;
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
            acc_div <= acc / 9;
            dout_pipe <= acc_div;
            dout <= dout_pipe;
        end else begin
            dout <= din;   // bypass
        end
    end

endmodule