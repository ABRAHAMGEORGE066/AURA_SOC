// ahb_crypto_slave.v
// Stub for AHB-Lite crypto slave (AES example)

// AHB-Lite Crypto Slave with AES_Encrypt integration
module ahb_crypto_slave(
    input hclk,
    input hresetn,
    input hsel,
    input [31:0] haddr,
    input hwrite,
    input [2:0] hsize,
    input [2:0] hburst,
    input [3:0] hprot,
    input [1:0] htrans,
    input hmastlock,
    input [31:0] hwdata,
    input hready,
    output reg hreadyout,
    output reg hresp,
    output reg [31:0] hrdata
);
    // Register map (word offsets):
    // 0x00 - AES_KEY0 (W0)
    // 0x04 - AES_KEY1 (W1)
    // 0x08 - AES_KEY2 (W2)
    // 0x0C - AES_KEY3 (W3)
    // 0x10 - AES_PT0  (W0)
    // 0x14 - AES_PT1  (W1)
    // 0x18 - AES_PT2  (W2)
    // 0x1C - AES_PT3  (W3)
    // 0x20 - AES_CTRL (bit0=start)
    // 0x24 - AES_CT0  (R, W0)
    // 0x28 - AES_CT1  (R, W1)
    // 0x2C - AES_CT2  (R, W2)
    // 0x30 - AES_CT3  (R, W3)
    // 0x34 - AES_STATUS (bit0=done)

    reg [127:0] aes_key;
    reg [127:0] aes_pt;
    reg [127:0] aes_ct;
    reg aes_start, aes_done;
    reg [4:0] state;

    // Register shadow for AHB
    reg [31:0] key_regs [0:3];
    reg [31:0] pt_regs [0:3];
    reg [31:0] ct_regs [0:3];

    // AES_Encrypt instance
    wire [127:0] aes_out;
    reg aes_go;
    AES_Encrypt aes_core(
        .in(aes_pt),
        .key(aes_key),
        .out(aes_out)
    );

    // State machine for AES operation
    localparam S_IDLE = 0, S_START = 1, S_WAIT = 2, S_DONE = 3;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            hreadyout <= 1'b1;
            hresp <= 1'b0;
            hrdata <= 32'b0;
            aes_key <= 128'b0;
            aes_pt <= 128'b0;
            aes_ct <= 128'b0;
            aes_start <= 1'b0;
            aes_done <= 1'b0;
            aes_go <= 1'b0;
            state <= S_IDLE;
            key_regs[0] <= 0; key_regs[1] <= 0; key_regs[2] <= 0; key_regs[3] <= 0;
            pt_regs[0] <= 0; pt_regs[1] <= 0; pt_regs[2] <= 0; pt_regs[3] <= 0;
            ct_regs[0] <= 0; ct_regs[1] <= 0; ct_regs[2] <= 0; ct_regs[3] <= 0;
        end else begin
            hreadyout <= 1'b1;
            hresp <= 1'b0;
            // AHB Write
            if (hsel && hready && (htrans == 2'b10 || htrans == 2'b11) && hwrite) begin
                case (haddr[6:2])
                    5'h0: key_regs[0] <= hwdata;
                    5'h1: key_regs[1] <= hwdata;
                    5'h2: key_regs[2] <= hwdata;
                    5'h3: key_regs[3] <= hwdata;
                    5'h4: pt_regs[0]  <= hwdata;
                    5'h5: pt_regs[1]  <= hwdata;
                    5'h6: pt_regs[2]  <= hwdata;
                    5'h7: pt_regs[3]  <= hwdata;
                    5'h8: begin // AES_CTRL
                        aes_start <= 1'b1;
                        aes_done <= 1'b0;
                        // Latch key and plaintext
                        aes_key <= {key_regs[0], key_regs[1], key_regs[2], key_regs[3]};
                        aes_pt  <= {pt_regs[0], pt_regs[1], pt_regs[2], pt_regs[3]};
                        state <= S_START;
                    end
                    default: ;
                endcase
            end
            // AHB Read
            if (hsel && hready && (htrans == 2'b10 || htrans == 2'b11) && !hwrite) begin
                case (haddr[6:2])
                    5'h9:  hrdata <= ct_regs[0]; // 0x24
                    5'hA:  hrdata <= ct_regs[1]; // 0x28
                    5'hB:  hrdata <= ct_regs[2]; // 0x2C
                    5'hC:  hrdata <= ct_regs[3]; // 0x30
                    5'hD:  hrdata <= {31'b0, aes_done}; // 0x34 STATUS
                    default: hrdata <= 32'b0;
                endcase
            end
            // AES operation state machine
            case (state)
                S_IDLE: begin
                    aes_go <= 1'b0;
                    if (aes_start) begin
                        aes_go <= 1'b1;
                        state <= S_START;
                        aes_start <= 1'b0;
                    end
                end
                S_START: begin
                    // Start AES operation (combinational in this core)
                    aes_ct <= aes_out;
                    ct_regs[0] <= aes_out[127:96];
                    ct_regs[1] <= aes_out[95:64];
                    ct_regs[2] <= aes_out[63:32];
                    ct_regs[3] <= aes_out[31:0];
                    aes_done <= 1'b1;
                    state <= S_DONE;
                end
                S_DONE: begin
                    // Wait for next start
                    if (!aes_start) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
