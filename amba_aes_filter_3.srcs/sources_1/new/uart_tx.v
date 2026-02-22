module uart_tx #(
    parameter CLK_FREQ = 100000000,
    parameter BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [7:0] din,
    output reg tx,
    output reg busy
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam IDLE = 0, START = 1, DATA = 2, STOP = 3;

    reg [1:0] state;
    reg [13:0] clk_cnt;
    reg [2:0] bit_idx;
    reg [7:0] tx_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            tx <= 1;
            busy <= 0;
            clk_cnt <= 0;
            bit_idx <= 0;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1;
                    if (start) begin
                        state <= START;
                        tx_data <= din;
                        busy <= 1;
                        clk_cnt <= 0;
                    end else busy <= 0;
                end
                START: begin
                    tx <= 0;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        state <= DATA;
                        bit_idx <= 0;
                    end else clk_cnt <= clk_cnt + 1;
                end
                DATA: begin
                    tx <= tx_data[bit_idx];
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= 0;
                        if (bit_idx == 7) state <= STOP;
                        else bit_idx <= bit_idx + 1;
                    end else clk_cnt <= clk_cnt + 1;
                end
                STOP: begin
                    tx <= 1;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        state <= IDLE;
                        busy <= 0;
                    end else clk_cnt <= clk_cnt + 1;
                end
            endcase
        end
    end
endmodule