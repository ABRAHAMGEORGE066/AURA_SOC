`timescale 1ns / 1ps

//======================================================================
// MODULE: fec_decoder
// DESCRIPTION: Hamming(17,12) Forward Error Correction Decoder
//              Computes a 5-bit syndrome from the received codeword.
//              If syndrome != 0 it identifies the exact bit-position of
//              a single-bit error and flips that bit (SEC – Single Error
//              Correction).  The 12 data bits are then extracted from
//              the corrected codeword.
//
// Syndrome mapping:
//   syndrome = {s4,s3,s2,s1,s0}  (syndrome[0]=s0 is LSB)
//   syndrome value = 1-indexed position of the erroneous bit
//   syndrome == 0  → no error
//   syndrome == k  → codeword[k-1] is in error → flip it
//
//   s0 = XOR of codeword bits at positions 1,3,5,7,9,11,13,15,17
//      = cw[0]^cw[2]^cw[4]^cw[6]^cw[8]^cw[10]^cw[12]^cw[14]^cw[16]
//   s1 = XOR of positions 2,3,6,7,10,11,14,15
//      = cw[1]^cw[2]^cw[5]^cw[6]^cw[9]^cw[10]^cw[13]^cw[14]
//   s2 = XOR of positions 4,5,6,7,12,13,14,15
//      = cw[3]^cw[4]^cw[5]^cw[6]^cw[11]^cw[12]^cw[13]^cw[14]
//   s3 = XOR of positions 8,9,10,11,12,13,14,15
//      = cw[7]^cw[8]^cw[9]^cw[10]^cw[11]^cw[12]^cw[13]^cw[14]
//   s4 = XOR of positions 16,17
//      = cw[15]^cw[16]
//======================================================================
module fec_decoder #(
    parameter DATA_WIDTH     = 12,
    parameter CODEWORD_WIDTH = 17
)(
    input  wire                             clk,
    input  wire                             rst,
    input  wire                             enable,
    input  wire [CODEWORD_WIDTH-1:0]        codeword_in,    // received (possibly corrupted) codeword
    output reg  signed [DATA_WIDTH-1:0]     dout,           // corrected 12-bit data
    output reg  [4:0]                       syndrome,       // syndrome of last decode
    output reg                              error_detected, // 1 = error found
    output reg                              error_corrected // 1 = single-bit error corrected
);

    //------------------------------------------------------------------
    // Syndrome computation – combinational, runs on codeword_in
    //------------------------------------------------------------------
    wire s0 = codeword_in[0]^codeword_in[2]^codeword_in[4]^codeword_in[6]^
              codeword_in[8]^codeword_in[10]^codeword_in[12]^codeword_in[14]^
              codeword_in[16];
    wire s1 = codeword_in[1]^codeword_in[2]^codeword_in[5]^codeword_in[6]^
              codeword_in[9]^codeword_in[10]^codeword_in[13]^codeword_in[14];
    wire s2 = codeword_in[3]^codeword_in[4]^codeword_in[5]^codeword_in[6]^
              codeword_in[11]^codeword_in[12]^codeword_in[13]^codeword_in[14];
    wire s3 = codeword_in[7]^codeword_in[8]^codeword_in[9]^codeword_in[10]^
              codeword_in[11]^codeword_in[12]^codeword_in[13]^codeword_in[14];
    wire s4 = codeword_in[15]^codeword_in[16];

    // syndrome value = s0*1 + s1*2 + s2*4 + s3*8 + s4*16
    // = 1-indexed bit-position of the error (0 → no error)
    wire [4:0] syn = {s4, s3, s2, s1, s0};

    //------------------------------------------------------------------
    // Bit-error correction – combinational
    // If syn != 0 and within codeword range, flip cw[syn-1]
    //------------------------------------------------------------------
    reg [CODEWORD_WIDTH-1:0] cw_corr;
    always @(*) begin : correction_logic
        cw_corr = codeword_in;
        if (syn != 5'd0 && syn <= 5'd17)
            cw_corr[syn - 1] = ~codeword_in[syn - 1];
    end

    //------------------------------------------------------------------
    // Registered output (1 clock cycle latency)
    // Extract the 12 data bits from corrected codeword positions
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            dout            <= {DATA_WIDTH{1'b0}};
            syndrome        <= 5'd0;
            error_detected  <= 1'b0;
            error_corrected <= 1'b0;
        end else if (enable) begin
            syndrome        <= syn;
            error_detected  <= (syn != 5'd0);
            error_corrected <= (syn != 5'd0);   // single-bit errors are always correctable

            // Extract data from corrected codeword (non-power-of-2 positions)
            dout[0]  <= cw_corr[2];   // pos  3
            dout[1]  <= cw_corr[4];   // pos  5
            dout[2]  <= cw_corr[5];   // pos  6
            dout[3]  <= cw_corr[6];   // pos  7
            dout[4]  <= cw_corr[8];   // pos  9
            dout[5]  <= cw_corr[9];   // pos 10
            dout[6]  <= cw_corr[10];  // pos 11
            dout[7]  <= cw_corr[11];  // pos 12
            dout[8]  <= cw_corr[12];  // pos 13
            dout[9]  <= cw_corr[13];  // pos 14
            dout[10] <= cw_corr[14];  // pos 15
            dout[11] <= cw_corr[16];  // pos 17
        end else begin
            dout            <= {DATA_WIDTH{1'b0}};
            syndrome        <= 5'd0;
            error_detected  <= 1'b0;
            error_corrected <= 1'b0;
        end
    end

endmodule
