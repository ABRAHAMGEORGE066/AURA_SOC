`timescale 1ns / 1ps

//======================================================================
// MODULE: tmr_voter
// DESCRIPTION: Triple Modular Redundancy (TMR) Majority Voter
//
// Architecture:
//   Three independent instances of the same logic block (A, B, C)
//   process the same input in parallel.  The voter selects the output
//   agreed upon by at least 2-of-3 instances – bitwise majority logic:
//
//     voted_out[i] = (A[i] & B[i]) | (B[i] & C[i]) | (A[i] & C[i])
//
// This is PURELY COMBINATIONAL – zero clock-cycle latency.
// A fault in any ONE of the three copies is silently overruled by
// the other two without waiting for retransmission (unlike FEC).
//
// Status outputs:
//   tmr_mismatch    – high whenever any bit differs across instances
//   tmr_voter_ab    – high when A and B disagree on at least one bit
//   tmr_voter_bc    – high when B and C disagree on at least one bit
//   tmr_voter_ac    – high when A and C disagree on at least one bit
//   tmr_error_mask  – per-bit OR of minority-vote disagreement flags
//                     bit[i]=1 means the three copies disagreed on bit i
//
// Parameters:
//   DATA_WIDTH – width of each input/output (default 12 to match the
//                12-bit signed filter data path in this SoC)
//======================================================================
module tmr_voter #(
    parameter DATA_WIDTH = 12
)(
    // Three independent copies of the same data
    input  wire signed [DATA_WIDTH-1:0] in_a,     // Copy A output
    input  wire signed [DATA_WIDTH-1:0] in_b,     // Copy B output
    input  wire signed [DATA_WIDTH-1:0] in_c,     // Copy C output

    // Majority-voted result (2-of-3 agreement per bit)
    output wire signed [DATA_WIDTH-1:0] voted_out,

    // Status / fault detection
    output wire                         tmr_mismatch,   // any disagreement
    output wire                         tmr_err_ab,     // A != B on any bit
    output wire                         tmr_err_bc,     // B != C on any bit
    output wire                         tmr_err_ac,     // A != C on any bit
    output wire [DATA_WIDTH-1:0]        tmr_error_mask  // per-bit disagreement
);

    //------------------------------------------------------------------
    // Bit-wise majority logic  (2-of-3 per bit, zero latency)
    //   voted[i] = (A[i] AND B[i]) OR (B[i] AND C[i]) OR (A[i] AND C[i])
    //------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < DATA_WIDTH; gi = gi + 1) begin : vote_bits
            assign voted_out[gi] = (in_a[gi] & in_b[gi])
                                 | (in_b[gi] & in_c[gi])
                                 | (in_a[gi] & in_c[gi]);
        end
    endgenerate

    //------------------------------------------------------------------
    // Per-bit disagreement: bit is '1' when all three are NOT identical
    // (i.e., at least one copy disagrees with the other two)
    //   mismatch[i] = A[i] XOR B[i]  OR  B[i] XOR C[i]
    //------------------------------------------------------------------
    assign tmr_error_mask = (in_a ^ in_b) | (in_b ^ in_c);

    //------------------------------------------------------------------
    // Pair-wise mismatch flags (any-bit level)
    //------------------------------------------------------------------
    assign tmr_err_ab   = (in_a != in_b);
    assign tmr_err_bc   = (in_b != in_c);
    assign tmr_err_ac   = (in_a != in_c);

    // Global mismatch: any of the three pairs disagrees
    assign tmr_mismatch = tmr_err_ab | tmr_err_bc | tmr_err_ac;

endmodule
