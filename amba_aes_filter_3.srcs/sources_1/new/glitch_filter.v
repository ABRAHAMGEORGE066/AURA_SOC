module glitch_filter #(
    parameter DATA_WIDTH = 12,
    parameter STABLE_CNT = 3   // number of stable cycles required
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         enable,
    input  wire signed [DATA_WIDTH-1:0] din,
    output reg  signed [DATA_WIDTH-1:0] dout
);

    reg signed [DATA_WIDTH-1:0] last_sample;
    reg [$clog2(STABLE_CNT+1)-1:0] stable_count;

    always @(posedge clk) begin
        if (rst) begin
            dout         <= 0;
            last_sample  <= 0;
            stable_count <= 0;
        end else if (enable) begin
            if (din == last_sample) begin
                if (stable_count < STABLE_CNT)
                    stable_count <= stable_count + 1;
            end else begin
                stable_count <= 0;
                last_sample  <= din;
            end

            // Update output only when stable
            if (stable_count == STABLE_CNT-1)
                dout <= din;
        end else begin
            dout <= din;  // bypass
        end
    end

endmodule