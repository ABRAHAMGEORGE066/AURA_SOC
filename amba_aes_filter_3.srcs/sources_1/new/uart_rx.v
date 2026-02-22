module uart_rx #(
    parameter CLK_FREQ = 100000000,
    parameter BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst_n,
    input wire rx,
    output reg [7:0] dout,
    output reg done
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam IDLE = 0, START = 1, DATA = 2, STOP = 3;

    reg [1:0] state;
    reg [13:0] clk_cnt;
    reg [2:0] bit_idx;
    reg [7:0] rx_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            clk_cnt <= 0;
            bit_idx <= 0;
            dout <= 0;
            done <= 0;
        end else begin
            done <= 0;
            case (state)
                IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (rx == 0) state <= START;
                end
                START: begin
                    if (clk_cnt == (CLKS_PER_BIT - 1) / 2) begin
                        if (rx == 0) begin
                            clk_cnt <= 0;
                            state <= DATA;
                        end else state <= IDLE;
                    end else clk_cnt <= clk_cnt + 1;
                end
                DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        rx_data[bit_idx] <= rx;
                        if (bit_idx == 7) state <= STOP;
                        else bit_idx <= bit_idx + 1;
                    end else clk_cnt <= clk_cnt + 1;
                end
                STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        state <= IDLE;
                        dout <= rx_data;
                        done <= 1;
                    end else clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end
endmodule