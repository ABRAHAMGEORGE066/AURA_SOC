`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: ahb_aes_slave
// Description: AHB Slave wrapper for AES Encryption
//              Implements memory-mapped registers for Key, Plaintext, and Ciphertext.
//////////////////////////////////////////////////////////////////////////////////

module ahb_aes_slave(
    input  wire hclk,
    input  wire hresetn,
    input  wire hsel,
    input  wire [31:0] haddr,
    input  wire hwrite,
    input  wire [2:0] hsize,
    input  wire [2:0] hburst,
    input  wire [3:0] hprot,
    input  wire [1:0] htrans,
    input  wire hmastlock,
    input  wire [31:0] hwdata,
    input  wire hready,
    output reg  hreadyout,
    output reg  [31:0] hrdata,
    output reg  hresp
    );

    // Address Map (Byte Offsets)
    // 0x00-0x0F: Key (128-bit)
    // 0x10-0x1F: Plaintext (128-bit)
    // 0x20     : Control (Bit 0 = Start)
    // 0x30-0x3F: Ciphertext (128-bit)

    reg [127:0] key;
    reg [127:0] plaintext;
    reg [127:0] ciphertext;
    reg start;
    reg busy;
    
    // Simulation timer for behavioral model
    reg [3:0] timer;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            hreadyout <= 1'b1;
            hresp <= 1'b0;
            hrdata <= 32'h0;
            key <= 128'h0;
            plaintext <= 128'h0;
            ciphertext <= 128'h0;
            start <= 1'b0;
            busy <= 1'b0;
            timer <= 0;
        end else begin
            // Default AHB outputs
            hreadyout <= 1'b1; 
            hresp <= 1'b0;     
            start <= 1'b0;     // Auto-clear start signal

            // --- AHB Write Handling ---
            // Check for Select, Write, Ready, and Valid Transfer (NONSEQ or SEQ)
            if (hsel && hwrite && hready && (htrans[1] == 1'b1)) begin
                case (haddr[7:0]) // Decode lower 8 bits of address
                    8'h00: key[127:96] <= hwdata;
                    8'h04: key[95:64]  <= hwdata;
                    8'h08: key[63:32]  <= hwdata;
                    8'h0C: key[31:0]   <= hwdata;
                    
                    8'h10: plaintext[127:96] <= hwdata;
                    8'h14: plaintext[95:64]  <= hwdata;
                    8'h18: plaintext[63:32]  <= hwdata;
                    8'h1C: plaintext[31:0]   <= hwdata;
                    
                    8'h20: begin
                        if (hwdata[0]) begin
                            start <= 1'b1;
                            busy <= 1'b1;
                            timer <= 4'd10; // Simulate processing latency
                        end
                    end
                endcase
            end

            // --- AHB Read Handling ---
            if (hsel && !hwrite && hready && (htrans[1] == 1'b1)) begin
                case (haddr[7:0])
                    8'h00: hrdata <= key[127:96];       8'h04: hrdata <= key[95:64];
                    8'h08: hrdata <= key[63:32];        8'h0C: hrdata <= key[31:0];
                    8'h10: hrdata <= plaintext[127:96]; 8'h14: hrdata <= plaintext[95:64];
                    8'h18: hrdata <= plaintext[63:32];  8'h1C: hrdata <= plaintext[31:0];
                    8'h20: hrdata <= {31'b0, busy};
                    8'h30: hrdata <= ciphertext[127:96]; 8'h34: hrdata <= ciphertext[95:64];
                    8'h38: hrdata <= ciphertext[63:32];  8'h3C: hrdata <= ciphertext[31:0];
                    default: hrdata <= 32'h0;
                endcase
            end

            // --- Behavioral AES Logic (XOR) ---
            if (busy) begin
                if (timer > 0) timer <= timer - 1;
                else begin busy <= 1'b0; ciphertext <= key ^ plaintext; end
            end
        end
    end
endmodule