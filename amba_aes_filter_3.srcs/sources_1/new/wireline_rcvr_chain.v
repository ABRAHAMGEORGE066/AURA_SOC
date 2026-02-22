`timescale 1ns / 1ps

//======================================================================
// MODULE: wireline_rcvr_chain
// DESCRIPTION: Wireline receiver filter chain for AHB protocol
//              Implements proper signal processing pipeline for data recovery
//              Filter Order: CTLE -> DC Offset Removal -> FIR Equalizer -> 
//                           DFE -> Glitch Filter -> LPF
//======================================================================

module wireline_rcvr_chain #(
    parameter DATA_WIDTH = 12
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,
    input  wire signed [DATA_WIDTH-1:0] data_in,
    // Stage 7 FEC control inputs
    input  wire                         fec_err_inject, // 1 = inject a bit error (testing only)
    input  wire [4:0]                   fec_err_bit,    // which codeword bit (0-16) to flip
    // Filtered + FEC-corrected output
    output wire signed [DATA_WIDTH-1:0] data_out,
    // FEC status outputs
    output wire [4:0]                   fec_syndrome,
    output wire                         fec_error_detected,
    output wire                         fec_error_corrected
);

    // Internal signals connecting filter stages
    wire signed [DATA_WIDTH-1:0] ctle_out;
    wire signed [DATA_WIDTH-1:0] dc_offset_out;
    wire signed [DATA_WIDTH-1:0] fir_eq_out;
    wire signed [DATA_WIDTH-1:0] dfe_out;
    wire signed [DATA_WIDTH-1:0] glitch_out;
    wire signed [DATA_WIDTH-1:0] lpf_out;    // LPF output feeds into FEC encoder

    // FEC pipeline signals (Hamming(17,12))
    localparam FEC_CW_WIDTH = 17;
    wire [FEC_CW_WIDTH-1:0] fec_encoded_cw; // encoder output (registered)
    wire [FEC_CW_WIDTH-1:0] fec_channel_cw; // codeword after optional error injection

    //==================================================================
    // STAGE 1: CTLE (Continuous Time Linear Equalizer)
    // Purpose: High-frequency peaking/emphasis to compensate for 
    //          channel attenuation at high frequencies
    //==================================================================
    ctle #(
        .DATA_WIDTH(DATA_WIDTH),
        .ALPHA_SHIFT(2)        // Controls peaking strength
    ) ctle_stage (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .din(data_in),
        .dout(ctle_out)
    );

    //==================================================================
    // STAGE 2: DC Offset Removal
    // Purpose: Remove DC component and low-frequency drift from signal
    //          Improves signal centering for subsequent stages
    //==================================================================
    dc_offset_filter #(
        .DATA_WIDTH(DATA_WIDTH),
        .ALPHA_SHIFT(4)        // Controls HPF cutoff frequency
    ) dc_offset_stage (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .din(ctle_out),
        .dout(dc_offset_out)
    );

    //==================================================================
    // STAGE 3: FIR Equalizer
    // Purpose: Linear channel equalization using preset/adaptive taps
    //          Compensates for frequency-dependent channel response
    //==================================================================
    fir_equalizer #(
        .DATA_WIDTH(DATA_WIDTH),
        .TAP_NUM(7)            // 7-tap FIR filter
    ) fir_eq_stage (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .din(dc_offset_out),
        .dout(fir_eq_out)
    );

    //==================================================================
    // STAGE 4: DFE (Decision Feedback Equalizer)
    // Purpose: Non-linear equalization using previous decisions
    //          Reduces Inter-Symbol Interference (ISI) more effectively
    //          than linear equalization for severe channel distortion
    //==================================================================
    dfe #(
        .DATA_WIDTH(DATA_WIDTH),
        .DFE_COEFF(64)         // feedback weight
    ) dfe_stage (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .din(fir_eq_out),
        .dout(dfe_out)
    );

    //==================================================================
    // STAGE 5: Glitch Filter (Median/Spike Removal)
    // Purpose: Remove isolated noise spikes while preserving edges
    //          Median filtering effective against impulse noise
    //==================================================================
    glitch_filter #(
        .DATA_WIDTH(DATA_WIDTH),
        .STABLE_CNT(3)         // stable cycles before accepting new value
    ) glitch_stage (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .din(dfe_out),
        .dout(glitch_out)
    );

    //==================================================================
    // STAGE 6: LPF (Low-Pass FIR Filter)
    // Purpose: Final low-pass filtering to smooth signal and remove
    //          residual high-frequency noise and aliases
    //==================================================================
    lpf_fir #(
        .DATA_WIDTH(DATA_WIDTH)
    ) lpf_stage (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .din(glitch_out),
        .dout(lpf_out)       // feeds into FEC encoder (Stage 7)
    );

    //==================================================================
    // STAGE 7: FEC – Hamming(17,12) Forward Error Correction
    // Purpose: Encode LPF output into a Hamming codeword, optionally
    //          inject a single-bit channel error (for testing), then
    //          decode and correct any single-bit error.  The corrected
    //          data becomes the final data_out of the chain.
    //          Adds 2 clock cycles of pipeline latency.
    //          Total chain latency: 8 clock cycles.
    //==================================================================
    fec_encoder #(
        .DATA_WIDTH(DATA_WIDTH),
        .CODEWORD_WIDTH(FEC_CW_WIDTH)
    ) fec_enc_stage (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .din(lpf_out),
        .codeword(fec_encoded_cw)
    );

    // Optional single-bit error injection – simulates a corrupted channel bit
    genvar fec_gi;
    generate
        for (fec_gi = 0; fec_gi < FEC_CW_WIDTH; fec_gi = fec_gi + 1) begin : fec_inj
            assign fec_channel_cw[fec_gi] =
                (fec_err_inject && (fec_err_bit == fec_gi))
                ? ~fec_encoded_cw[fec_gi]
                :  fec_encoded_cw[fec_gi];
        end
    endgenerate

    fec_decoder #(
        .DATA_WIDTH(DATA_WIDTH),
        .CODEWORD_WIDTH(FEC_CW_WIDTH)
    ) fec_dec_stage (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .codeword_in(fec_channel_cw),
        .dout(data_out),
        .syndrome(fec_syndrome),
        .error_detected(fec_error_detected),
        .error_corrected(fec_error_corrected)
    );

endmodule
