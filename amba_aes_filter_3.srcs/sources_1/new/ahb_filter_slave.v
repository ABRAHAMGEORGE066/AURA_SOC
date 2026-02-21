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
    output reg hresp
);

    // Register map (word offsets, byte-addressable via haddr):
    // 0x00 - DATA_IN   (write only)  : push 32-bit sample to input FIFO
    // 0x04 - DATA_OUT  (read only)   : pop 32-bit filtered sample from output FIFO
    // 0x08 - CONTROL   (R/W)         : bit0 = FILTER_ENABLE, bit1 = BYPASS
    // 0x0C - STATUS    (R)           : bit0 = IN_VALID, bit1 = OUT_VALID
    // 0x10 - COEFF[0]  (R/W)         : fir coeff 0
    // 0x14 - COEFF[1]  ... up to TAP_NUM

    parameter DATA_WIDTH = 12;
    parameter FIFO_DEPTH = 8; // entries
    parameter TAP_NUM = 7;    // fir_equalizer TAP_NUM
    localparam PIPELINE_LAT = 4; // estimated cycles for filtered output to appear

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

    // Instantiate filter chain: LPF -> Glitch -> DC
    wire signed [DATA_WIDTH-1:0] lpf_out, glitch_out, dc_out;
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

    // Instantiate lpf_fir, glitch_filter, dc_offset_filter
    lpf_fir #(.DATA_WIDTH(DATA_WIDTH)) inst_lpf (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(filter_din), .dout(lpf_out)
    );

    glitch_filter #(.DATA_WIDTH(DATA_WIDTH)) inst_glitch (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(lpf_out), .dout(glitch_out)
    );

    dc_offset_filter #(.DATA_WIDTH(DATA_WIDTH)) inst_dc (
        .clk(hclk), .rst(!hresetn), .enable(filter_enable), .din(glitch_out), .dout(dc_out)
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
        end else begin
            // Default ready behavior
            if (!hsel) begin
                hreadyout <= 1'b1;
            end

            // AHB write handling (single-beat writes)
            if (hsel && hready && (htrans == T_NONSEQ || htrans == T_SEQ) && hwrite) begin
                case (haddr[5:2]) // use lower word address bits (16-byte windows)
                    4'h0: begin // 0x00 DATA_IN (write pushes into in_fifo)
                        // Always push to input FIFO for filter tests
                        if (in_count < FIFO_DEPTH) begin
                            in_fifo[in_tail] <= hwdata;
                            in_tail <= (in_tail + 1) % FIFO_DEPTH;
                            in_count <= in_count + 1;
                            hreadyout <= 1'b1;
                            $display("%0t AHBFILTER: push in_fifo[%0d]=%08h in_count=%0d", $time, in_tail, hwdata, in_count+1);
                        end else begin
                            hreadyout <= 1'b0;
                        end
                    end
                    4'h2: begin // 0x08 CONTROL
                        control_reg <= hwdata;
                        hreadyout <= 1'b1;
                    end
                    4'h4, 4'h5, 4'h6, 4'h7, 4'h8, 4'h9, 4'hA: begin // coeffs at 0x10,0x14,...
                        // index = (haddr-0x10)/4
                        coeffs[(haddr[5:2]-4)] <= $signed(hwdata[DATA_WIDTH-1:0]);
                        hreadyout <= 1'b1;
                    end
                    default: begin
                        hreadyout <= 1'b1;
                    end
                endcase
            end

            // AHB read handling
            if (hsel && hready && (htrans == T_NONSEQ || htrans == T_SEQ) && !hwrite) begin
                case (haddr[5:2])
                    4'h0: begin // 0x00 DATA_IN (read not meaningful)
                        hrdata <= 32'h0; hreadyout <= 1'b1;
                    end
                    4'h1: begin // 0x04 DATA_OUT (read pops from out_fifo if available)
                        if (out_count > 0) begin
                            hrdata <= out_fifo[out_head];
                            out_head <= (out_head + 1) % FIFO_DEPTH;
                            out_count <= out_count - 1;
                        end else begin
                            hrdata <= 32'h0;
                        end
                        hreadyout <= 1'b1;
                    end
                    4'h2: begin // CONTROL read
                        hrdata <= control_reg; hreadyout <= 1'b1;
                    end
                    4'h3: begin // STATUS
                        // Pack counts into STATUS: [15:8]=in_count, [7:0]=out_count
                        hrdata <= {16'd0, in_count[7:0], out_count[7:0]};
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
                    // package dc_out as 32-bit sign-extended value
                    tmp_cap = {{(32-DATA_WIDTH){dc_out[DATA_WIDTH-1]}}, dc_out};
                    out_fifo[out_tail] <= tmp_cap;
                    out_tail <= (out_tail + 1) % FIFO_DEPTH;
                    out_count <= out_count + 1;
                    $display("%0t AHBFILTER: CAPTURE out_fifo[%0d]=%08h out_count=%0d", $time, out_tail, tmp_cap, out_count+1);
                    // allow subsequent outputs to be captured each cycle
                end
            end
        end
    end
endmodule
