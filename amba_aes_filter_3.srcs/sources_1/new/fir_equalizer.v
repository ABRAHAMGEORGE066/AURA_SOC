module fir_equalizer #(
    parameter DATA_WIDTH = 12,
    parameter TAP_NUM    = 7
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,
    input  wire signed [DATA_WIDTH-1:0] din,
    output reg  signed [DATA_WIDTH-1:0] dout
);

    integer i;

    // Shift register for samples
    reg signed [DATA_WIDTH-1:0] shift_reg [0:TAP_NUM-1];

    // Accumulator
    reg signed [DATA_WIDTH+5:0] acc;

    // Preset symmetric coefficients: [-32, -64, 128, 256, 128, -64, -32]
    // Normalized by 256 (see FILTER_CHAIN_ARCHITECTURE.md)
    reg signed [DATA_WIDTH-1:0] coeff [0:TAP_NUM-1];
    initial begin
        coeff[0] = -32;
        coeff[1] = -64;
        coeff[2] =  128;
        coeff[3] =  256;
        coeff[4] =  128;
        coeff[5] = -64;
        coeff[6] = -32;
    end

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

            // FIR MAC with preset coefficients
            acc = 0;
            for (i = 0; i < TAP_NUM; i = i + 1)
                acc = acc + shift_reg[i] * coeff[i];

            // Scale output (divide by 256)
            dout <= acc >>> 8;
        end else begin
            dout <= din;   // bypass
        end
    end

endmodule