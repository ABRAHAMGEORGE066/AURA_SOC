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
    output wire signed [DATA_WIDTH-1:0] data_out
);

    // Internal signals connecting filter stages
    wire signed [DATA_WIDTH-1:0] ctle_out;
    wire signed [DATA_WIDTH-1:0] dc_offset_out;
    wire signed [DATA_WIDTH-1:0] fir_eq_out;
    wire signed [DATA_WIDTH-1:0] dfe_out;
    wire signed [DATA_WIDTH-1:0] glitch_out;
    // wire signed [DATA_WIDTH-1:0] lpf_out;  // final output

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
        .NUM_TAPS(7)           // 7-tap FIR filter
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
        .NUM_TAPS(4)           // 4-tap feedback filter
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
        .THRESHOLD(512)        // Spike detection threshold
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
        .dout(data_out)
    );

endmodule
