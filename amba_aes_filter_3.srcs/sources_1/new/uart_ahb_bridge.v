module uart_ahb_bridge (
    input wire hclk,
    input wire hresetn,
    
    // UART Interface
    input wire [7:0] rx_data,
    input wire rx_dv,
    output reg [7:0] tx_data,
    output reg tx_start,
    input wire tx_busy,

    // AHB Master Interface
    output reg [31:0] haddr,
    output reg [31:0] hwdata,
    output reg hwrite,
    output reg [1:0] htrans,
    output reg [2:0] hsize,
    output reg [2:0] hburst,
    output reg [3:0] hprot,
    input wire hready,
    input wire [31:0] hrdata,
    input wire [1:0] hresp
);

    // State Machine
    localparam IDLE = 0, GET_ADDR = 1, GET_DATA = 2, AHB_SETUP = 3, AHB_ACCESS = 4, SEND_RESP = 5, SEND_DATA = 6, AHB_DATA_PHASE = 7, TX_WAIT = 8;
    
    reg [3:0] state;
    reg [2:0] byte_cnt;
    reg [7:0] cmd;
    reg [31:0] addr_reg;
    reg [31:0] data_reg;
    reg [31:0] read_data_reg;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            state <= IDLE;
            haddr <= 0;
            hwdata <= 0;
            hwrite <= 0;
            htrans <= 0; // IDLE
            hsize <= 3'b010; // 32-bit
            hburst <= 0;
            hprot <= 4'b0011;
            tx_start <= 0;
            byte_cnt <= 0;
        end else begin
            tx_start <= 0; // Default
            
            case (state)
                IDLE: begin
                    htrans <= 0;
                    byte_cnt <= 0;
                    if (rx_dv) begin
                        cmd <= rx_data;
                        if (rx_data == 8'h57 || rx_data == 8'h52) // 'W' or 'R'
                            state <= GET_ADDR;
                    end
                end

                GET_ADDR: begin
                    if (rx_dv) begin
                        addr_reg <= {addr_reg[23:0], rx_data};
                        byte_cnt <= byte_cnt + 1;
                        if (byte_cnt == 3) begin
                            byte_cnt <= 0;
                            if (cmd == 8'h57) state <= GET_DATA; // Write
                            else state <= AHB_SETUP;             // Read
                        end
                    end
                end

                GET_DATA: begin
                    if (rx_dv) begin
                        data_reg <= {data_reg[23:0], rx_data};
                        byte_cnt <= byte_cnt + 1;
                        if (byte_cnt == 3) begin
                            state <= AHB_SETUP;
                        end
                    end
                end

                AHB_SETUP: begin
                    haddr <= addr_reg;
                    hwrite <= (cmd == 8'h57);
                    htrans <= 2'b10; // NONSEQ
                    hsize <= 3'b010; // 32-bit
                    hburst <= 0;     // SINGLE
                    hprot <= 4'b0011; // Non-cacheable, Non-bufferable, Privileged, Data
                    if (cmd == 8'h57) hwdata <= data_reg; // Setup data for write
                    state <= AHB_ACCESS;
                end

                AHB_ACCESS: begin
                    // Address Phase
                    if (hready) begin
                        htrans <= 0; // IDLE for Data Phase
                        state <= AHB_DATA_PHASE;
                    end
                end

                AHB_DATA_PHASE: begin
                    // Data Phase
                    if (hready) begin
                        if (!hwrite) begin
                            read_data_reg <= hrdata; // Capture read data
                            state <= SEND_DATA;
                            byte_cnt <= 3; // Send MSB first
                        end else begin
                            state <= SEND_RESP; // Send Ack
                        end
                    end
                end

                SEND_RESP: begin
                    if (!tx_busy) begin
                        tx_data <= 8'h4B; // 'K' for OK
                        tx_start <= 1;
                        state <= IDLE;
                    end
                end

                SEND_DATA: begin
                    if (!tx_busy) begin
                        case (byte_cnt)
                            3: tx_data <= read_data_reg[31:24];
                            2: tx_data <= read_data_reg[23:16];
                            1: tx_data <= read_data_reg[15:8];
                            0: tx_data <= read_data_reg[7:0];
                        endcase
                        tx_start <= 1;
                        state <= TX_WAIT;
                    end
                end

                TX_WAIT: begin
                    if (tx_busy) begin
                        if (byte_cnt == 0) begin
                            state <= IDLE;
                        end else begin
                            byte_cnt <= byte_cnt - 1;
                            state <= SEND_DATA;
                        end
                    end
                end
            endcase
        end
    end
endmodule