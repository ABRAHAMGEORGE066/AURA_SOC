`timescale 1ns / 1ps

//======================================================================
// MODULE: fec_encoder
// DESCRIPTION: Hamming(17,12) Forward Error Correction Encoder
//              Encodes 12-bit data into a 17-bit Hamming codeword.
//              5 parity bits protect 12 data bits (2^5=32 >= 12+5+1=18).
//              Supports single-bit error correction at the receiver.
//
// Codeword layout (1-indexed positions → 0-indexed codeword[]):
//   Pos  1  codeword[0]  : P1   (parity)
//   Pos  2  codeword[1]  : P2   (parity)
//   Pos  3  codeword[2]  : D[0] (data bit 0)
//   Pos  4  codeword[3]  : P4   (parity)
//   Pos  5  codeword[4]  : D[1]
//   Pos  6  codeword[5]  : D[2]
//   Pos  7  codeword[6]  : D[3]
//   Pos  8  codeword[7]  : P8   (parity)
//   Pos  9  codeword[8]  : D[4]
//   Pos 10  codeword[9]  : D[5]
//   Pos 11  codeword[10] : D[6]
//   Pos 12  codeword[11] : D[7]
//   Pos 13  codeword[12] : D[8]
//   Pos 14  codeword[13] : D[9]
//   Pos 15  codeword[14] : D[10]
//   Pos 16  codeword[15] : P16  (parity)
//   Pos 17  codeword[16] : D[11]
//
// Parity coverage (even parity):
//   P1  covers positions with bit0=1: 1,3,5,7,9,11,13,15,17
//       → P1 = D[0]^D[1]^D[3]^D[4]^D[6]^D[8]^D[10]^D[11]
//   P2  covers positions with bit1=1: 2,3,6,7,10,11,14,15
//       → P2 = D[0]^D[2]^D[3]^D[5]^D[6]^D[9]^D[10]
//   P4  covers positions with bit2=1: 4,5,6,7,12,13,14,15
//       → P4 = D[1]^D[2]^D[3]^D[7]^D[8]^D[9]^D[10]
//   P8  covers positions with bit3=1: 8,9,10,11,12,13,14,15
//       → P8 = D[4]^D[5]^D[6]^D[7]^D[8]^D[9]^D[10]
//   P16 covers positions with bit4=1: 16,17
//       → P16 = D[11]
//======================================================================
module fec_encoder #(
    parameter DATA_WIDTH     = 12,
    parameter CODEWORD_WIDTH = 17    // DATA_WIDTH(12) + parity bits(5)
)(
    input  wire                          clk,
    input  wire                          rst,
    input  wire                          enable,
    input  wire signed [DATA_WIDTH-1:0]  din,       // 12-bit filter output
    output reg  [CODEWORD_WIDTH-1:0]     codeword   // 17-bit Hamming codeword
);

    // Treat din as raw bits for parity calculation
    wire [DATA_WIDTH-1:0] d;
    assign d = din;

    //------------------------------------------------------------------
    // Combinational parity computation (even parity)
    //------------------------------------------------------------------
    wire p1  = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[11];
    wire p2  = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[10];
    wire p4  = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[10];
    wire p8  = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[10];
    wire p16 = d[11];  // only covers position 17, so P16 = D[11]

    //------------------------------------------------------------------
    // Registered codeword assembly (1 clock cycle latency)
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            codeword <= {CODEWORD_WIDTH{1'b0}};
        end else if (enable) begin
            codeword[0]  <= p1;     // pos 1  – P1
            codeword[1]  <= p2;     // pos 2  – P2
            codeword[2]  <= d[0];   // pos 3  – D[0]
            codeword[3]  <= p4;     // pos 4  – P4
            codeword[4]  <= d[1];   // pos 5  – D[1]
            codeword[5]  <= d[2];   // pos 6  – D[2]
            codeword[6]  <= d[3];   // pos 7  – D[3]
            codeword[7]  <= p8;     // pos 8  – P8
            codeword[8]  <= d[4];   // pos 9  – D[4]
            codeword[9]  <= d[5];   // pos 10 – D[5]
            codeword[10] <= d[6];   // pos 11 – D[6]
            codeword[11] <= d[7];   // pos 12 – D[7]
            codeword[12] <= d[8];   // pos 13 – D[8]
            codeword[13] <= d[9];   // pos 14 – D[9]
            codeword[14] <= d[10];  // pos 15 – D[10]
            codeword[15] <= p16;    // pos 16 – P16
            codeword[16] <= d[11];  // pos 17 – D[11]
        end else begin
            codeword <= {CODEWORD_WIDTH{1'b0}};
        end
    end

endmodule
