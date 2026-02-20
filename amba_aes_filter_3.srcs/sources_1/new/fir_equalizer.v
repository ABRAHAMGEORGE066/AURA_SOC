module fir_equalizer #(
    parameter DATA_WIDTH = 12,
    parameter TAP_NUM    = 7
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,
    input  wire signed [DATA_WIDTH-1:0] din,

    // Coefficients (to be later mapped to APB)
    input  wire signed [DATA_WIDTH-1:0] coeff [0:TAP_NUM-1],

    output reg  signed [DATA_WIDTH-1:0] dout
);

    integer i;

    // Shift register for samples
    reg signed [DATA_WIDTH-1:0] shift_reg [0:TAP_NUM-1];

    // Accumulator
    reg signed [DATA_WIDTH+5:0] acc;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < TAP_NUM; i = i + 1)
                shift_reg[i] <= 0;
            dout <= 0;
        end else if (enable) begin
            // Shift samples
            shift_reg[0] <= din;
            for (i = 1; i < TAP_NUM; i = i + 1)
                shift_reg[i] <= shift_reg[i-1];

            // FIR MAC
            acc = 0;
            for (i = 0; i < TAP_NUM; i = i + 1)
                acc = acc + shift_reg[i] * coeff[i];

            // Scale output
            dout <= acc >>> 4;   // scaling factor
        end else begin
            dout <= din;   // bypass
        end
    end

endmodule