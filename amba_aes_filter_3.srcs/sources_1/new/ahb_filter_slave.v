`timescale 1ns / 1ps
//======================================================================
// MODULE: ahb_filter_slave
// DESCRIPTION: Memory-mapped AHB slave that exposes a small FIFO-based
// interface to the filter chain modules in the repository. It provides
// registers for data in (write), data out (read), control, status and
// coefficient space for the FIR equalizer.
//
// Note: This is a pragmatic integration example. The filter chain is
// driven in streaming mode: consecutive writes to DATA_IN are streamed
// into the filters; after a fixed pipeline latency filtered outputs are
// produced and pushed into DATA_OUT FIFO. The design assumes the master
// will read outputs or poll status. Adjust pipeline latency or buffering
// for your real timing requirements.
//======================================================================
module ahb_filter_slave(
    input  hclk,
    input  hresetn,
    input  hsel,
    input  [31:0] haddr,
    input  hwrite,
    input  [2:0] hsize,
    input  [2:0] hburst,
    input  [3:0] hprot,
    input  [1:0] htrans,
    input  hmastlock,
    input  [31:0] hwdata,
    input  hready,
    output reg hreadyout,
    output reg [31:0] hrdata,
    output reg hresp,
    // Watchdog register I/O (routed through ahb_top from ahb_watchdog)
    input  wire [3:0]  wdg_status_in,        // timeout_flags: sticky flag per slave
    input  wire [31:0] wdg_fault_cnt_in,     // total_timeouts: cumulative event counter
    output wire [3:0]  wdg_force_rst_out,    // SW force-reset trigger to watchdog
    output wire [7:0]  wdg_timeout_cfg_out   // SW programmable timeout threshold
);

    // Register map (word offsets, byte-addressable via haddr):
    // 0x00 - DATA_IN   (write only)  : push 32-bit sample to input FIFO
    // 0x04 - DATA_OUT  (read only)   : pop 32-bit filtered sample from output FIFO
    // 0x08 - CONTROL   (R/W)         : bit0 = FILTER_ENABLE, bit1 = BYPASS
    // 0x0C - STATUS    (R)           : bit0 = IN_VALID, bit1 = OUT_VALID
    // 0x10 - COEFF[0]  (R/W)         : fir coeff 0
    // 0x14 - COEFF[1]  ... up to TAP_NUM
    // 0x2C - FEC_CONTROL (R/W)       : bit0=err_inject_en, bits[5:1]=err_bit
    // 0x30 - FEC_STATUS  (R)         : bit0=err_detected, bit1=err_corrected
    // 0x34 - FEC_SYNDROME(R)         : 5-bit last syndrome
    // 0x38 - FEC_ERR_CNT (R)         : cumulative corrected error count
    // 0x40 - DC_TMR_STATUS      (R)   : bit0=mismatch, bit1=err_ab, bit2=err_bc, bit3=err_ac
    // 0x44 - DC_TMR_ERR_CNT    (R)   : cumulative DC offset filter TMR mismatch events
    // 0x48 - DC_TMR_CONTROL    (R/W) : bit0=inject_b, bit1=inject_c
    // 0x50 - LPF_TMR_STATUS    (R)   : bit0=mismatch, bit1=err_ab, bit2=err_bc, bit3=err_ac
    // 0x54 - LPF_TMR_ERR_CNT  (R)   : cumulative LPF TMR mismatch events
    // 0x58 - LPF_TMR_CONTROL  (R/W) : bit0=inject_b, bit1=inject_c
    // 0x60 - GLITCH_TMR_STATUS  (R)  : bit0=mismatch, bit1=err_ab, bit2=err_bc, bit3=err_ac
    // 0x64 - GLITCH_TMR_ERR_CNT(R)  : cumulative Glitch filter TMR mismatch events
    // 0x68 - GLITCH_TMR_CONTROL(R/W): bit0=inject_b, bit1=inject_c
    // 0x70 - WDG_STATUS      (R)   : [3:0] sticky timeout flags {slv4,slv3,slv2,slv1}
    // 0x74 - WDG_FAULT_CNT  (R)   : cumulative watchdog events (timeouts + force-resets)
    // 0x78 - WDG_FORCE_RST  (R/W) : write bit N to force-reset slave N+1 (self-clears on slave reset)
    // 0x7C - WDG_TIMEOUT_CFG(R/W) : [7:0] threshold in cycles (0=watchdog HW disabled, default=200)

    parameter DATA_WIDTH = 12;
    parameter FIFO_DEPTH = 8; // entries
    parameter TAP_NUM = 7;    // fir_equalizer TAP_NUM
    localparam PIPELINE_LAT = 6; // filter(3 cyc) + TMR(0 cyc, combinational) + FEC enc+dec(2 cyc) + 1 margin

    // Simple AHB single-beat handling (similar to ahb_slave)
    parameter T_IDLE = 2'b00, T_NONSEQ = 2'b10, T_SEQ = 2'b11;

    // Internal FIFOs (simple synchronous circular buffers)
    reg [31:0] in_fifo [0:FIFO_DEPTH-1];
    reg [3:0]  in_head, in_tail; // pointers small width
    reg [3:0]  in_count;

    reg [31:0] out_fifo [0:FIFO_DEPTH-1];
    reg [3:0]  out_head, out_tail;
    reg [3:0]  out_count;

    // Control/status registers
    reg [31:0] control_reg; // bit0 enable, bit1 bypass
    wire filter_enable = control_reg[0];

    // FIR coefficients storage
    reg signed [DATA_WIDTH-1:0] coeffs [0:TAP_NUM-1];

    // Local signals for streaming the pipeline
    reg streaming; // when 1 we are feeding samples to filters each cycle
    reg [3:0] samples_to_feed; // remaining samples to feed in current streaming op

    // Instantiate filter chain: LPF(x3/TMR) -> Glitch(x3/TMR) -> DC(x3/TMR) -> FEC
    // Every filter stage is triplicated; majority voters add ZERO pipeline latency.

    // LPF TMR wires
    wire signed [DATA_WIDTH-1:0] lpf_out_a, lpf_out_b, lpf_out_c;
    wire signed [DATA_WIDTH-1:0] lpf_voted_out;
    wire                         lpf_mismatch_w, lpf_err_ab_w, lpf_err_bc_w, lpf_err_ac_w;
    wire        [DATA_WIDTH-1:0] lpf_error_mask_w;

    // Glitch TMR wires
    wire signed [DATA_WIDTH-1:0] glitch_out_a, glitch_out_b, glitch_out_c;
    wire signed [DATA_WIDTH-1:0] glitch_voted_out;
    wire                         glitch_mismatch_w, glitch_err_ab_w, glitch_err_bc_w, glitch_err_ac_w;
    wire        [DATA_WIDTH-1:0] glitch_error_mask_w;

    // DC TMR wires
    wire signed [DATA_WIDTH-1:0] dc_out_a, dc_out_b, dc_out_c;
    wire signed [DATA_WIDTH-1:0] tmr_voted_out;
    wire                         tmr_mismatch_w;
    wire                         tmr_err_ab_w, tmr_err_bc_w, tmr_err_ac_w;
    wire        [DATA_WIDTH-1:0] tmr_error_mask_w;
    wire signed [DATA_WIDTH-1:0] feed_sample;

    // Simple converter from 32-bit input to DATA_WIDTH signed sample
    // Convention: use lower DATA_WIDTH bits as signed two's complement
    function signed [DATA_WIDTH-1:0] to_sample(input [31:0] w);
        begin
            to_sample = $signed(w[DATA_WIDTH-1:0]);
        end
    endfunction

    // Feeding register (drives the filter chain din)
    reg signed [DATA_WIDTH-1:0] filter_din;
    reg [31:0] tmp_out;
    reg [31:0] tmp_cap;

    // FEC control and status registers
    reg  [31:0] fec_control_reg;              // bit0=err_inject_en, bits[5:1]=err_bit
    wire        fec_err_inject = fec_control_reg[0];
    wire [4:0]  fec_err_bit    = fec_control_reg[5:1];
    reg  [31:0] fec_error_count;              // cumulative corrected error counter

    // TMR control and status registers
    reg  [31:0] tmr_control_reg;  // bit0 = tmr_inject_b (force copy-B to +MAX for testing)
                                  // bit1 = tmr_inject_c (force copy-C to +MAX for testing)
    wire        tmr_inject_b = tmr_control_reg[0]; // test: corrupt copy B (forces to 12'h7FF)
    wire        tmr_inject_c = tmr_control_reg[1]; // test: corrupt copy C (forces to 12'h7FF)
    reg  [31:0] tmr_error_count;  // cumulative DC TMR mismatch event counter

    // LPF TMR control and status registers (addresses 0x58 / 0x54 / 0x50)
    reg  [31:0] lpf_tmr_control_reg;
    wire        lpf_inject_b = lpf_tmr_control_reg[0];
    wire        lpf_inject_c = lpf_tmr_control_reg[1];
    reg  [31:0] lpf_tmr_error_count;

    // Glitch TMR control and status registers (addresses 0x68 / 0x64 / 0x60)
    reg  [31:0] glitch_tmr_control_reg;
    wire        glitch_inject_b = glitch_tmr_control_reg[0];
    wire        glitch_inject_c = glitch_tmr_control_reg[1];
    reg  [31:0] glitch_tmr_error_count;

    // Watchdog interface registers (0x70 - 0x7C)
    reg  [3:0]  wdg_force_rst_reg;    // SW force-reset trigger (bit N = slave N+1)
    reg  [7:0]  wdg_timeout_cfg_reg;  // SW timeout threshold (0=disabled, default=200 cycles)
    assign wdg_force_rst_out   = wdg_force_rst_reg;
    assign wdg_timeout_cfg_out = wdg_timeout_cfg_reg;

    // FEC pipeline wires  (Hamming(17,12))
    localparam FEC_CW_WIDTH = 17;
    wire [FEC_CW_WIDTH-1:0] fec_encoded_cw;  // encoder output
    wire [FEC_CW_WIDTH-1:0] fec_channel_cw;  // codeword after optional error injection
    wire signed [DATA_WIDTH-1:0] fec_dout;   // FEC-corrected output
    wire [4:0]  fec_syndrome_w;
    wire        fec_error_detected_w;
    wire        fec_error_corrected_w;

    // -----------------------------------------------------------------
    // LPF TMR Stage: Three identical lpf_fir instances + 2-of-3 voter.
    // All copies receive filter_din simultaneously. A stuck fault in one
    // copy is overruled by the other two with ZERO latency.
    // -----------------------------------------------------------------
    lpf_fir #(.DATA_WIDTH(DATA_WIDTH)) inst_lpf_a (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(filter_din), .dout(lpf_out_a)
    );
    wire signed [DATA_WIDTH-1:0] lpf_out_b_raw;
    lpf_fir #(.DATA_WIDTH(DATA_WIDTH)) inst_lpf_b (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(filter_din), .dout(lpf_out_b_raw)
    );
    assign lpf_out_b = lpf_inject_b ? {1'b0, {(DATA_WIDTH-1){1'b1}}} : lpf_out_b_raw;
    wire signed [DATA_WIDTH-1:0] lpf_out_c_raw;
    lpf_fir #(.DATA_WIDTH(DATA_WIDTH)) inst_lpf_c (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(filter_din), .dout(lpf_out_c_raw)
    );
    assign lpf_out_c = lpf_inject_c ? {1'b0, {(DATA_WIDTH-1){1'b1}}} : lpf_out_c_raw;
    tmr_voter #(.DATA_WIDTH(DATA_WIDTH)) inst_lpf_tmr (
        .in_a(lpf_out_a), .in_b(lpf_out_b), .in_c(lpf_out_c),
        .voted_out(lpf_voted_out),
        .tmr_mismatch(lpf_mismatch_w), .tmr_err_ab(lpf_err_ab_w),
        .tmr_err_bc(lpf_err_bc_w),     .tmr_err_ac(lpf_err_ac_w),
        .tmr_error_mask(lpf_error_mask_w)
    );

    // -----------------------------------------------------------------
    // Glitch TMR Stage: Three identical glitch_filter instances + voter.
    // Input: lpf_voted_out (fault-corrected LPF output).
    // -----------------------------------------------------------------
    glitch_filter #(.DATA_WIDTH(DATA_WIDTH)) inst_glitch_a (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(lpf_voted_out), .dout(glitch_out_a)
    );
    wire signed [DATA_WIDTH-1:0] glitch_out_b_raw;
    glitch_filter #(.DATA_WIDTH(DATA_WIDTH)) inst_glitch_b (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(lpf_voted_out), .dout(glitch_out_b_raw)
    );
    assign glitch_out_b = glitch_inject_b ? {1'b0, {(DATA_WIDTH-1){1'b1}}} : glitch_out_b_raw;
    wire signed [DATA_WIDTH-1:0] glitch_out_c_raw;
    glitch_filter #(.DATA_WIDTH(DATA_WIDTH)) inst_glitch_c (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(lpf_voted_out), .dout(glitch_out_c_raw)
    );
    assign glitch_out_c = glitch_inject_c ? {1'b0, {(DATA_WIDTH-1){1'b1}}} : glitch_out_c_raw;
    tmr_voter #(.DATA_WIDTH(DATA_WIDTH)) inst_glitch_tmr (
        .in_a(glitch_out_a), .in_b(glitch_out_b), .in_c(glitch_out_c),
        .voted_out(glitch_voted_out),
        .tmr_mismatch(glitch_mismatch_w), .tmr_err_ab(glitch_err_ab_w),
        .tmr_err_bc(glitch_err_bc_w),     .tmr_err_ac(glitch_err_ac_w),
        .tmr_error_mask(glitch_error_mask_w)
    );

    // -----------------------------------------------------------------
    // TMR Stage: Triple Modular Redundancy on DC Offset Filter
    // Three identical dc_offset_filter instances (A, B, C) all receive
    // the same glitch_out input.  A tmr_voter performs bit-wise 2-of-3
    // majority voting with ZERO latency.  The voted output feeds FEC.
    //
    // Test injection:
    //   TMR_CONTROL bit0 = tmr_inject_b -> forces copy-B output to 0
    //   TMR_CONTROL bit1 = tmr_inject_c -> forces copy-C output to 0
    //
    // Register map additions:
    //   0x40  TMR_STATUS   (R)   bit0=mismatch, bit1=err_ab, bit2=err_bc, bit3=err_ac
    //   0x44  TMR_ERR_CNT  (R)   cumulative mismatch event count
    //   0x48  TMR_CONTROL  (R/W) bit0=inject_b, bit1=inject_c
    // -----------------------------------------------------------------

    // Copy A – always clean (golden reference)
    dc_offset_filter #(.DATA_WIDTH(DATA_WIDTH)) inst_dc_a (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable),
        .din(glitch_voted_out), .dout(dc_out_a)
    );

    // Copy B – can be corrupted (forced to MAX_POSITIVE) via TMR_CONTROL bit0
    wire signed [DATA_WIDTH-1:0] dc_out_b_raw;
    dc_offset_filter #(.DATA_WIDTH(DATA_WIDTH)) inst_dc_b (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable),
        .din(glitch_voted_out), .dout(dc_out_b_raw)
    );
    // Inject: force to +MAX (0x7FF) so it always diverges from settled-near-zero output
    assign dc_out_b = tmr_inject_b ? {1'b0, {(DATA_WIDTH-1){1'b1}}} : dc_out_b_raw;

    // Copy C – can be corrupted (forced to MAX_POSITIVE) via TMR_CONTROL bit1
    wire signed [DATA_WIDTH-1:0] dc_out_c_raw;
    dc_offset_filter #(.DATA_WIDTH(DATA_WIDTH)) inst_dc_c (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable),
        .din(glitch_voted_out), .dout(dc_out_c_raw)
    );
    // Inject: force to +MAX (0x7FF) so it always diverges from settled-near-zero output
    assign dc_out_c = tmr_inject_c ? {1'b0, {(DATA_WIDTH-1){1'b1}}} : dc_out_c_raw;

    // Majority voter (combinational, zero latency)
    tmr_voter #(.DATA_WIDTH(DATA_WIDTH)) inst_tmr (
        .in_a(dc_out_a),
        .in_b(dc_out_b),
        .in_c(dc_out_c),
        .voted_out(tmr_voted_out),
        .tmr_mismatch(tmr_mismatch_w),
        .tmr_err_ab(tmr_err_ab_w),
        .tmr_err_bc(tmr_err_bc_w),
        .tmr_err_ac(tmr_err_ac_w),
        .tmr_error_mask(tmr_error_mask_w)
    );

    // -----------------------------------------------------------------
    // FEC Stage: Hamming(17,12) encode → optional error inject → decode
    // Input is now tmr_voted_out (majority-voted DC output) instead of
    // a single dc_out, providing layered fault tolerance:
    //   TMR handles stuck/divergent hardware faults (zero latency)
    //   FEC handles single-bit transmission errors (2-cycle latency)
    // Register map:
    //   0x2C  FEC_CONTROL  (R/W) bit0=err_inject_en, bits[5:1]=err_bit
    //   0x30  FEC_STATUS   (R)   bit0=err_detected,  bit1=err_corrected
    //   0x34  FEC_SYNDROME (R)   5-bit last syndrome
    //   0x38  FEC_ERR_CNT  (R)   cumulative corrected error count
    // -----------------------------------------------------------------
    fec_encoder #(.DATA_WIDTH(DATA_WIDTH), .CODEWORD_WIDTH(FEC_CW_WIDTH)) inst_fec_enc (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable),
        .din(tmr_voted_out), .codeword(fec_encoded_cw)  // TMR output feeds FEC
    );

    genvar fec_gi;
    generate
        for (fec_gi = 0; fec_gi < FEC_CW_WIDTH; fec_gi = fec_gi + 1) begin : fec_inj_loop
            assign fec_channel_cw[fec_gi] =
                (fec_err_inject && (fec_err_bit == fec_gi))
                ? ~fec_encoded_cw[fec_gi]
                :  fec_encoded_cw[fec_gi];
        end
    endgenerate

    fec_decoder #(.DATA_WIDTH(DATA_WIDTH), .CODEWORD_WIDTH(FEC_CW_WIDTH)) inst_fec_dec (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable),
        .codeword_in(fec_channel_cw),
        .dout(fec_dout),
        .syndrome(fec_syndrome_w),
        .error_detected(fec_error_detected_w),
        .error_corrected(fec_error_corrected_w)
    );

    // We'll stream inputs into filter_din when streaming==1. Captured outputs
    // will appear after PIPELINE_LAT cycles; because we're streaming one
    // sample per cycle the outputs will appear one-per-cycle after the
    // initial latency. A counter delays the capture of first valid output.
    reg [$clog2(PIPELINE_LAT+1)-1:0] latency_cnt;
    reg pipeline_active;

    integer i;

    // AHB read/write behavior and FIFO push/pop
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            in_head <= 0; in_tail <= 0; in_count <= 0;
            out_head <= 0; out_tail <= 0; out_count <= 0;
            control_reg <= 0; hreadyout <= 1'b1; hrdata <= 32'd0; hresp <= 1'b0;
            streaming <= 1'b0; samples_to_feed <= 0; pipeline_active <= 1'b0; latency_cnt <= 0;
            filter_din <= 0;
            for (i=0; i<TAP_NUM; i=i+1) coeffs[i] <= 0;
            fec_control_reg <= 32'd0;
            fec_error_count <= 32'd0;
            tmr_control_reg       <= 32'd0;
            tmr_error_count       <= 32'd0;
            lpf_tmr_control_reg   <= 32'd0;
            lpf_tmr_error_count   <= 32'd0;
            glitch_tmr_control_reg <= 32'd0;
            glitch_tmr_error_count <= 32'd0;
            wdg_force_rst_reg   <= 4'd0;
            wdg_timeout_cfg_reg <= 8'd200;   // default: 200 clock cycles
        end else begin
            // Default ready behavior
            if (!hsel) begin
                hreadyout <= 1'b1;
            end

            // AHB write handling (single-beat writes)
            if (hsel && hready && (htrans == T_NONSEQ || htrans == T_SEQ) && hwrite) begin
                case (haddr[6:2]) // 5-bit word address index (covers 0x00..0x7C)
                    5'h0: begin // 0x00 DATA_IN (write pushes into in_fifo)
                        if (control_reg[0] == 1'b0) begin
                            // Bypass fast-path: directly push into output FIFO (sign-extend lower DATA_WIDTH bits)
                            if (out_count < FIFO_DEPTH) begin
                                // prepare sign-extended value
                                tmp_out = {{(32-DATA_WIDTH){hwdata[DATA_WIDTH-1]}}, hwdata[DATA_WIDTH-1:0]};
                                out_fifo[out_tail] <= tmp_out;
                                out_tail <= (out_tail + 1) % FIFO_DEPTH;
                                out_count <= out_count + 1;
                                hreadyout <= 1'b1;
                                $display("%0t AHBFILTER: BYPASS push out_fifo[%0d]=%08h out_count=%0d", $time, out_tail, tmp_out, out_count+1);
                            end else begin
                                // OUT FIFO full -> wait
                                hreadyout <= 1'b0;
                            end
                        end else begin
                            if (in_count < FIFO_DEPTH) begin
                                in_fifo[in_tail] <= hwdata;
                                in_tail <= (in_tail + 1) % FIFO_DEPTH;
                                in_count <= in_count + 1;
                                hreadyout <= 1'b1;
                                $display("%0t AHBFILTER: push in_fifo[%0d]=%08h in_count=%0d", $time, in_tail, hwdata, in_count+1);
                            end else begin
                                // FIFO full -> insert wait
                                hreadyout <= 1'b0;
                            end
                        end
                    end
                    5'h2: begin // 0x08 CONTROL
                        control_reg <= hwdata;
                        hreadyout <= 1'b1;
                    end
                    5'h4, 5'h5, 5'h6, 5'h7, 5'h8, 5'h9, 5'hA: begin // coeffs at 0x10,0x14,...
                        // index = (haddr-0x10)/4
                        coeffs[(haddr[6:2]-4)] <= $signed(hwdata[DATA_WIDTH-1:0]);
                        hreadyout <= 1'b1;
                    end
                    5'hB: begin // 0x2C FEC_CONTROL: bit0=err_inject_en, bits[5:1]=err_bit
                        fec_control_reg <= hwdata;
                        hreadyout <= 1'b1;
                    end
                    5'h12: begin // 0x48 DC_TMR_CONTROL: bit0=inject_b, bit1=inject_c
                        tmr_control_reg <= hwdata;
                        hreadyout <= 1'b1;
                    end
                    5'h16: begin // 0x58 LPF_TMR_CONTROL: bit0=inject_b, bit1=inject_c
                        lpf_tmr_control_reg <= hwdata;
                        hreadyout <= 1'b1;
                    end
                    5'h1A: begin // 0x68 GLITCH_TMR_CONTROL: bit0=inject_b, bit1=inject_c
                        glitch_tmr_control_reg <= hwdata;
                        hreadyout <= 1'b1;
                    end
                    5'h1E: begin // 0x78 WDG_FORCE_RST: write bit N to force-reset slave N+1
                        wdg_force_rst_reg <= hwdata[3:0];
                        hreadyout <= 1'b1;
                    end
                    5'h1F: begin // 0x7C WDG_TIMEOUT_CFG: programmable stall-cycle threshold
                        wdg_timeout_cfg_reg <= hwdata[7:0];
                        hreadyout <= 1'b1;
                    end
                    default: begin
                        hreadyout <= 1'b1;
                    end
                endcase
            end
            if (hsel && hready && (htrans == T_NONSEQ || htrans == T_SEQ) && !hwrite) begin
                case (haddr[6:2]) // 5-bit word address index
                    5'h0: begin // 0x00 DATA_IN (read not meaningful)
                        hrdata <= 32'h0; hreadyout <= 1'b1;
                    end
                    5'h1: begin // 0x04 DATA_OUT (read pops from out_fifo if available)
                        if (out_count > 0) begin
                            hrdata <= out_fifo[out_head];
                            out_head <= (out_head + 1) % FIFO_DEPTH;
                            out_count <= out_count - 1;
                        end else begin
                            hrdata <= 32'h0;
                        end
                        hreadyout <= 1'b1;
                    end
                    5'h2: begin // CONTROL read
                        hrdata <= control_reg; hreadyout <= 1'b1;
                    end
                    5'h3: begin // STATUS
                        // Pack counts into STATUS: [15:8]=in_count, [7:0]=out_count
                        // FIX: Manually pad with zeros instead of selecting [7:0] from 4-bit signals
                        hrdata <= {16'd0, 4'b0, in_count, 4'b0, out_count};
                        hreadyout <= 1'b1;
                    end
                    5'hB: begin // 0x2C FEC_CONTROL read-back
                        hrdata <= fec_control_reg; hreadyout <= 1'b1;
                    end
                    5'hC: begin // 0x30 FEC_STATUS (bit0=err_detected, bit1=err_corrected)
                        hrdata <= {30'd0, fec_error_corrected_w, fec_error_detected_w};
                        hreadyout <= 1'b1;
                    end
                    5'hD: begin // 0x34 FEC_SYNDROME (last syndrome value)
                        hrdata <= {27'd0, fec_syndrome_w};
                        hreadyout <= 1'b1;
                    end
                    5'hE: begin // 0x38 FEC_ERR_COUNT (cumulative corrected errors)
                        hrdata <= fec_error_count;
                        hreadyout <= 1'b1;
                    end
                    5'h10: begin // 0x40 TMR_STATUS (bit0=mismatch, bit1=err_ab, bit2=err_bc, bit3=err_ac)
                        hrdata <= {28'd0, tmr_err_ac_w, tmr_err_bc_w, tmr_err_ab_w, tmr_mismatch_w};
                        hreadyout <= 1'b1;
                    end
                    5'h11: begin // 0x44 TMR_ERR_COUNT (cumulative mismatch events)
                        hrdata <= tmr_error_count;
                        hreadyout <= 1'b1;
                    end
                    5'h12: begin // 0x48 DC_TMR_CONTROL read-back
                        hrdata <= tmr_control_reg;
                        hreadyout <= 1'b1;
                    end
                    5'h14: begin // 0x50 LPF_TMR_STATUS
                        hrdata <= {28'd0, lpf_err_ac_w, lpf_err_bc_w, lpf_err_ab_w, lpf_mismatch_w};
                        hreadyout <= 1'b1;
                    end
                    5'h15: begin // 0x54 LPF_TMR_ERR_COUNT
                        hrdata <= lpf_tmr_error_count;
                        hreadyout <= 1'b1;
                    end
                    5'h16: begin // 0x58 LPF_TMR_CONTROL read-back
                        hrdata <= lpf_tmr_control_reg;
                        hreadyout <= 1'b1;
                    end
                    5'h18: begin // 0x60 GLITCH_TMR_STATUS
                        hrdata <= {28'd0, glitch_err_ac_w, glitch_err_bc_w, glitch_err_ab_w, glitch_mismatch_w};
                        hreadyout <= 1'b1;
                    end
                    5'h19: begin // 0x64 GLITCH_TMR_ERR_COUNT
                        hrdata <= glitch_tmr_error_count;
                        hreadyout <= 1'b1;
                    end
                    5'h1A: begin // 0x68 GLITCH_TMR_CONTROL read-back
                        hrdata <= glitch_tmr_control_reg;
                        hreadyout <= 1'b1;
                    end
                    5'h1C: begin // 0x70 WDG_STATUS: sticky timeout flags per slave
                        hrdata <= {28'd0, wdg_status_in};
                        hreadyout <= 1'b1;
                    end
                    5'h1D: begin // 0x74 WDG_FAULT_CNT: cumulative watchdog event count
                        hrdata <= wdg_fault_cnt_in;
                        hreadyout <= 1'b1;
                    end
                    5'h1E: begin // 0x78 WDG_FORCE_RST read-back
                        hrdata <= {28'd0, wdg_force_rst_reg};
                        hreadyout <= 1'b1;
                    end
                    5'h1F: begin // 0x7C WDG_TIMEOUT_CFG read-back
                        hrdata <= {24'd0, wdg_timeout_cfg_reg};
                        hreadyout <= 1'b1;
                    end
                    default: begin
                        hrdata <= 32'h0; hreadyout <= 1'b1;
                    end
                endcase
            end

            // Processing: if not currently streaming and there's input and space on output,
            // start a streaming transfer of as many input words as possible.
            if (!streaming) begin
                if ((in_count > 0) && (out_count < FIFO_DEPTH)) begin
                    // start streaming all available inputs or up to FIFO capacity
                    samples_to_feed <= (in_count <= (FIFO_DEPTH - out_count)) ? in_count : (FIFO_DEPTH - out_count);
                    streaming <= 1'b1;
                    pipeline_active <= 1'b0;
                    latency_cnt <= 0;
                end
            end else begin
                // streaming active: feed one sample per cycle while samples_to_feed>0
                if (samples_to_feed > 0) begin
                    // pop from in_fifo and drive filter_din
                    filter_din <= to_sample(in_fifo[in_head]);
                    in_head <= (in_head + 1) % FIFO_DEPTH;
                    in_count <= in_count - 1;
                    samples_to_feed <= samples_to_feed - 1;
                    pipeline_active <= 1'b1;
                    // advance latency counter until PIPELINE_LAT reached
                    if (latency_cnt < PIPELINE_LAT) latency_cnt <= latency_cnt + 1;
                end else begin
                    // all inputs fed, wait for pipeline to flush remaining outputs
                    if (pipeline_active) begin
                        if (latency_cnt < PIPELINE_LAT) latency_cnt <= latency_cnt + 1;
                        else begin
                            // pipeline drained for this burst
                            streaming <= 1'b0;
                            pipeline_active <= 1'b0;
                            latency_cnt <= 0;
                        end
                    end
                end
            end

            // Capture filtered output each cycle once pipeline latency passed
            // and push into out_fifo if space available.
            if (pipeline_active && (latency_cnt >= PIPELINE_LAT)) begin
                if (out_count < FIFO_DEPTH) begin
                    // package FEC-corrected output as 32-bit sign-extended value
                    tmp_cap = {{(32-DATA_WIDTH){fec_dout[DATA_WIDTH-1]}}, fec_dout};
                    out_fifo[out_tail] <= tmp_cap;
                    out_tail <= (out_tail + 1) % FIFO_DEPTH;
                    out_count <= out_count + 1;
                    $display("%0t AHBFILTER: CAPTURE out_fifo[%0d]=%08h out_count=%0d", $time, out_tail, tmp_cap, out_count+1);
                    // allow subsequent outputs to be captured each cycle
                end
            end

            // Increment FEC error counter each time a bit-error is corrected
            if (fec_error_corrected_w)
                fec_error_count <= fec_error_count + 1;

            // Increment mismatch counters each cycle any copy disagrees (per stage)
            if (tmr_mismatch_w)
                tmr_error_count <= tmr_error_count + 1;
            if (lpf_mismatch_w)
                lpf_tmr_error_count <= lpf_tmr_error_count + 1;
            if (glitch_mismatch_w)
                glitch_tmr_error_count <= glitch_tmr_error_count + 1;
        end
    end
endmodule
