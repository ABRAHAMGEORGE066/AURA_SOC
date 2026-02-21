`timescale 1ns / 1ps
`include "ahb_clock_gate.v"

//======================================================================
// MODULE: ahb_top
// DESCRIPTION: Top-level module connecting all AHB components.
//======================================================================
module ahb_top(
  input hclk,
  input hresetn,
  input enable,
  input [31:0] data_in,
  input [31:0] addr,
  input wr,
  input [1:0] slave_sel,
  input [2:0] burst_type,

  output [31:0] data_out,
  output [31:0] hwdata,
  output [31:0] hrdata,
  output [1:0] htrans,
  output hreadyout_mon 
);

    // --- Bus Signals ---
    wire [1:0] sel;
    wire [31:0] haddr;
    wire hwrite;
    wire [3:0] hprot;
    wire [2:0] hsize;
    wire [2:0] hburst;
    wire hmastlock;
    wire hready;

    // --- Slave Signals ---
    wire [31:0] hrdata_1, hrdata_2, hrdata_3, hrdata_4;
    wire hreadyout_1, hreadyout_2, hreadyout_3, hreadyout_4;
    wire hresp_1, hresp_2, hresp_3, hresp_4;

    // --- Decoder & Mux Signals ---
    wire hsel_1, hsel_2, hsel_3, hsel_4;
    wire hreadyout;
    wire hresp;

    // Clock gating: instantiate ahb_clock_gate
    wire master_hclk;
    wire slave1_hclk;
    wire slave2_hclk;
    wire slave3_hclk;
    wire slave4_hclk;

    ahb_clock_gate clk_gate_inst(
        .hclk(hclk),
        .hresetn(hresetn),
        .enable(enable),
        .hsel_1(hsel_1),
        .hsel_2(hsel_2),
        .hsel_3(hsel_3),
        .hsel_4(hsel_4),
        .master_hclk(master_hclk),
        .slave1_hclk(slave1_hclk),
        .slave2_hclk(slave2_hclk),
        .slave3_hclk(slave3_hclk),
        .slave4_hclk(slave4_hclk)
    );

    // Connect internal hreadyout to the monitoring port
    assign hreadyout_mon = hreadyout;

    // --- Master Instantiation ---
    ahb_mastern mastern(
        .hclk(master_hclk), .hresetn(hresetn), .enable(enable),
        .data_in(data_in), .addr(addr), .wr(wr),
        .burst_type(burst_type), .hreadyout(hreadyout), .hresp(hresp),
        .hrdata(hrdata), .slave_sel(slave_sel), .sel(sel),
        .haddr(haddr), .hsize(hsize), .hwrite(hwrite), .hburst(hburst),
        .hprot(hprot), .htrans(htrans), .hmastlock(hmastlock),
        .hready(hready), .hwdata(hwdata), .dout(data_out)
    );

    // --- Decoder Instantiation ---
    ahb_decoder decoder(.sel(sel), .hsel_1(hsel_1), .hsel_2(hsel_2), .hsel_3(hsel_3), .hsel_4(hsel_4));

    // --- Slave Instantiations ---
    ahb_slave slave_1(.hclk(slave1_hclk), .hresetn(hresetn), .hsel(hsel_1), .haddr(haddr), .hwrite(hwrite), .hsize(hsize), .hburst(hburst), .hprot(hprot), .htrans(htrans), .hmastlock(hmastlock), .hwdata(hwdata), .hready(hready), .hreadyout(hreadyout_1), .hresp(hresp_1), .hrdata(hrdata_1));
    ahb_slave slave_2(.hclk(slave2_hclk), .hresetn(hresetn), .hsel(hsel_2), .haddr(haddr), .hwrite(hwrite), .hsize(hsize), .hburst(hburst), .hprot(hprot), .htrans(htrans), .hmastlock(hmastlock), .hwdata(hwdata), .hready(hready), .hreadyout(hreadyout_2), .hresp(hresp_2), .hrdata(hrdata_2));
    // Replace generic memory slave with filter slave (keeps AES slave untouched in slot 4)
    ahb_filter_slave slave_3(.hclk(slave3_hclk), .hresetn(hresetn), .hsel(hsel_3), .haddr(haddr), .hwrite(hwrite), .hsize(hsize), .hburst(hburst), .hprot(hprot), .htrans(htrans), .hmastlock(hmastlock), .hwdata(hwdata), .hready(hready), .hreadyout(hreadyout_3), .hresp(hresp_3), .hrdata(hrdata_3));
    ahb_crypto_slave slave_4(.hclk(hclk), .hresetn(hresetn), .hsel(hsel_4), .haddr(haddr), .hwrite(hwrite), .hsize(hsize), .hburst(hburst), .hprot(hprot), .htrans(htrans), .hmastlock(hmastlock), .hwdata(hwdata), .hready(hready), .hreadyout(hreadyout_4), .hresp(hresp_4), .hrdata(hrdata_4));

    // --- Mux Instantiation ---
    ahb_mux mux(.hrdata_1(hrdata_1), .hrdata_2(hrdata_2), .hrdata_3(hrdata_3), .hrdata_4(hrdata_4), .hreadyout_1(hreadyout_1), .hreadyout_2(hreadyout_2), .hreadyout_3(hreadyout_3), .hreadyout_4(hreadyout_4), .hresp_1(hresp_1), .hresp_2(hresp_2), .hresp_3(hresp_3), .hresp_4(hresp_4), .sel(sel), .hrdata(hrdata), .hreadyout(hreadyout), .hresp(hresp));
endmodule


//======================================================================
// MODULE: ahb_mastern (FINAL CORRECTED LOGIC)
//======================================================================
module ahb_mastern(
    input hclk, input hresetn, input enable, input [31:0] data_in,
    input [31:0] addr, input wr, input [2:0] burst_type, input hreadyout,
    input hresp, input [31:0] hrdata, input [1:0] slave_sel,
    output reg [1:0] sel, output reg [31:0] haddr, output reg hwrite,
    output reg [2:0] hsize, output reg [2:0] hburst, output reg [3:0] hprot,
    output reg [1:0] htrans, output reg hmastlock, output reg hready,
    output reg [31:0] hwdata, output reg [31:0] dout
);
    
    parameter IDLE = 2'b00, ADDR_PHASE = 2'b01, DATA_PHASE = 2'b10;
    parameter T_IDLE = 2'b00, T_NONSEQ = 2'b10, T_SEQ = 2'b11;

    reg [1:0] present_state, next_state;
    reg [3:0] burst_count;
    reg [31:0] current_addr;
    reg [31:0] base_addr;
    reg current_wr;
    reg [31:0] bus_haddr;

    // FSM state register
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) present_state <= IDLE;
        else present_state <= next_state;
    end

    // Registered logic for transaction properties
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            burst_count <= 4'd0;
            current_addr <= 32'd0;
            base_addr <= 32'd0;
            current_wr <= 1'b0;
            dout <= 32'd0;
        end else if (present_state == IDLE && next_state == ADDR_PHASE) begin
            current_addr <= addr;
            base_addr <= addr;
            current_wr <= wr;
            case (burst_type)
                3'b011: burst_count <= 4'd4; // INCR4
                default: burst_count <= 4'd1;
            endcase
        end else if (present_state == DATA_PHASE && hreadyout && burst_count > 1) begin
            // Latch read data on the rising edge when slave indicates ready
            if (!current_wr) dout <= hrdata;
            // Advance burst address/count after capturing data for this beat
            current_addr <= current_addr + 4;
            burst_count <= burst_count - 1;
        end else if (present_state == DATA_PHASE && hreadyout && burst_count == 1) begin
            if (!current_wr) dout <= hrdata;
            burst_count <= 0;
        end
    end

    // Combinational logic for outputs and next state
    always @(*) begin
        // Default assignments
        next_state = present_state;
    sel = slave_sel; hwrite = current_wr;
    // compute bus address so slave sees correct address for each beat
    if (present_state == ADDR_PHASE) begin
        bus_haddr = base_addr;
    end else if (present_state == DATA_PHASE) begin
        // beat_index = (burst_size - burst_count)
        bus_haddr = base_addr + ((burst_type_to_size(burst_type) - burst_count) << 2);
    end else begin
        bus_haddr = base_addr;
    end
    haddr = bus_haddr;
    hburst = burst_type; hsize = 3'b010; hprot = 4'b0011;
    hmastlock = 1'b0; hready = 1'b1; hwdata = data_in;
    htrans = T_IDLE;

        case (present_state)
            IDLE: begin
                if (enable) next_state = ADDR_PHASE;
                else next_state = IDLE;
            end
            ADDR_PHASE: begin
                htrans = T_NONSEQ;
                next_state = DATA_PHASE;
            end
            DATA_PHASE: begin
                // This logic correctly handles the wait state

                if (hreadyout) begin // Check if slave is ready BEFORE proceeding
                    // Read data is captured on the rising clock in the registered
                    // always block (dout <= hrdata when hreadyout). Do not
                    // drive dout combinationally here.

                    if (burst_count > 1) begin
                        htrans = T_SEQ; 
                        next_state = DATA_PHASE; // Continue burst
                    end else begin
                        htrans = T_IDLE; 
                        next_state = IDLE; // End of transaction
                    end
                end else begin // Slave is NOT ready, so we must WAIT
                    // Keep the transfer active (NONSEQ for first beat, SEQ for others)
                    // This ensures the slave knows the transfer is still happening.
                    htrans = (burst_count == burst_type_to_size(burst_type)) ? T_NONSEQ : T_SEQ;
                    next_state = DATA_PHASE; // Stay in the data phase
                end
            end
        endcase
    end
    
    // Helper function to determine original burst size
    function [3:0] burst_type_to_size(input [2:0] btype);
        case(btype)
            3'b011: burst_type_to_size = 4'd4;
            3'b101: burst_type_to_size = 4'd8;
            3'b111: burst_type_to_size = 4'd16;
            default: burst_type_to_size = 4'd1;
        endcase
    endfunction

endmodule


//======================================================================
// MODULE: ahb_slave
//======================================================================
module ahb_slave(
    input hclk, input hresetn, input hsel, input [31:0] haddr,
    input hwrite, input [2:0] hsize, input [2:0] hburst, input [3:0] hprot,
    input [1:0] htrans, input hmastlock, input [31:0] hwdata, input hready,
    output reg hreadyout, output reg [31:0] hrdata, output reg hresp
);
    reg [31:0] mem_arr[31:0];
    reg [4:0]  addr_reg;
    reg read_in_progress;
    parameter T_IDLE = 2'b00, T_NONSEQ = 2'b10, T_SEQ = 2'b11;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            hreadyout <= 1'b1; hresp <= 1'b0; hrdata <= 32'd0;
            addr_reg <= 5'd0; read_in_progress <= 1'b0;
        end else begin
            if (hsel && hready && (htrans == T_NONSEQ || htrans == T_SEQ)) begin
                if (hwrite) begin
                    mem_arr[haddr[6:2]] <= hwdata;
                    hrdata <= hwdata; // Immediate read-after-write
                    hreadyout <= 1'b1;
                end else begin
                    addr_reg <= haddr[6:2];
                    hrdata <= mem_arr[haddr[6:2]];
                    hreadyout <= 1'b1;
                end
            end else if (!hsel) begin
                hreadyout <= 1'b1;
            end
        end
    end
endmodule


//======================================================================
// MODULE: ahb_decoder
//======================================================================
module ahb_decoder(input [1:0] sel, output reg hsel_1, output reg hsel_2, output reg hsel_3, output reg hsel_4);
    always@(*) begin
        case(sel)
            2'b00: {hsel_1, hsel_2, hsel_3, hsel_4} = 4'b1000;
            2'b01: {hsel_1, hsel_2, hsel_3, hsel_4} = 4'b0100;
            2'b10: {hsel_1, hsel_2, hsel_3, hsel_4} = 4'b0010;
            2'b11: {hsel_1, hsel_2, hsel_3, hsel_4} = 4'b0001;
            default: {hsel_1, hsel_2, hsel_3, hsel_4} = 4'b0000;
        endcase
    end
endmodule


//======================================================================
// MODULE: ahb_mux
//======================================================================
module ahb_mux(
    input [31:0] hrdata_1, input [31:0] hrdata_2, input [31:0] hrdata_3, input [31:0] hrdata_4,
    input hreadyout_1, input hreadyout_2, input hreadyout_3, input hreadyout_4,
    input [1:0] sel, input hresp_1, input hresp_2, input hresp_3, input hresp_4,
    output reg[31:0] hrdata, output reg hreadyout, output reg hresp
);
    always@(*) begin
        case(sel)
            2'b00: {hrdata, hreadyout, hresp} = {hrdata_1, hreadyout_1, hresp_1};
            2'b01: {hrdata, hreadyout, hresp} = {hrdata_2, hreadyout_2, hresp_2};
            2'b10: {hrdata, hreadyout, hresp} = {hrdata_3, hreadyout_3, hresp_3};
            2'b11: {hrdata, hreadyout, hresp} = {hrdata_4, hreadyout_4, hresp_4};
            default: {hrdata, hreadyout, hresp} = {32'h0, 1'b1, 1'b0};
        endcase
    end
endmodule


//======================================================================
// MODULE: ahb_crypto_slave
// DESCRIPTION: A simple AHB slave that performs an AES encrypt of a 128-bit
// block assembled from consecutive 32-bit writes. On the first read after a
// completed write sequence it returns the ciphertext; on the next read it
// returns the original plaintext (decrypted back).
//======================================================================
module ahb_crypto_slave(
    input hclk, input hresetn, input hsel, input [31:0] haddr,
    input hwrite, input [2:0] hsize, input [2:0] hburst, input [3:0] hprot,
    input [1:0] htrans, input hmastlock, input [31:0] hwdata, input hready,
    output reg hreadyout, output reg [31:0] hrdata, output reg hresp
);
    // We will assemble a 128-bit block from four 32-bit writes to offsets 0..3
    reg [127:0] plaintext;
    reg [127:0] ciphertext;
    reg [1:0] word_count;
    reg write_complete;
    reg serve_cipher_next; // legacy flag (kept for initial compat)
    reg [3:0] cipher_served; // per-word flags: 1 if ciphertext for that word has been served
    reg [3:0] plain_served;  // per-word flags: 1 if plaintext for that word has been served
    reg [4:0] addr_reg;
    // temporaries used inside procedural block (must be declared at module scope in Verilog)
    reg [3:0] mask;
    reg [3:0] new_plain_served;

    // fixed 128-bit key for AES (example). In real use provide externally.
    localparam [127:0] AES_KEY = 128'h0f1571c947d9e8590cb7add6af7f6798;

    // Wires to connect to AES_Encrypt module (expects 128-bit inputs/outputs)
    wire [127:0] aes_out;

    // instantiate AES encrypt module (from AES_Encrypt.v). Use parameter defaults.
    AES_Encrypt aes_enc(.in(plaintext), .key(AES_KEY), .out(aes_out));

    // simple state machine to handle AHB read wait state for one cycle
    parameter T_IDLE = 2'b00, T_NONSEQ = 2'b10, T_SEQ = 2'b11;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            plaintext <= 128'd0;
            ciphertext <= 128'd0;
            word_count <= 2'd0;
            write_complete <= 1'b0;
            serve_cipher_next <= 1'b0;
            cipher_served <= 4'b0000;
            plain_served <= 4'b0000;
            hreadyout <= 1'b1;
            hrdata <= 32'd0;
            hresp <= 1'b0;
            addr_reg <= 5'd0;
        end else begin
            if (!hsel) begin
                hreadyout <= 1'b1;
            end

            // Handle write transactions: write 32-bit words into plaintext
            if (hsel && hready && (htrans == T_NONSEQ || htrans == T_SEQ) && hwrite) begin
                // Use low address bits [3:2] to select word 0..3
                case (haddr[3:2])
                    2'd0: plaintext[127:96] <= hwdata;
                    2'd1: plaintext[95:64]  <= hwdata;
                    2'd2: plaintext[63:32]  <= hwdata;
                    2'd3: plaintext[31:0]   <= hwdata;
                endcase
                // Only latch ciphertext after all 4 words are written
                if (haddr[3:2] == 2'd3) begin
                    #1; // Wait one cycle for AES output to stabilize
                    ciphertext <= aes_out;
                    write_complete <= 1'b1;
                    serve_cipher_next <= 1'b1;
                    cipher_served <= 4'b0000;
                    plain_served <= 4'b0000;
                end
                hreadyout <= 1'b1;
            end

            // Handle read transactions: return ciphertext first, then plaintext
            if (hsel && hready && (htrans == T_NONSEQ || htrans == T_SEQ) && !hwrite) begin
                addr_reg <= haddr[6:2];
                mask = 4'b0001 << haddr[3:2];

                if (write_complete) begin
                    if (!(cipher_served & mask)) begin
                        case (haddr[3:2])
                            2'd0: hrdata <= ciphertext[127:96];
                            2'd1: hrdata <= ciphertext[95:64];
                            2'd2: hrdata <= ciphertext[63:32];
                            2'd3: hrdata <= ciphertext[31:0];
                        endcase
                        hreadyout <= 1'b1;
                        cipher_served <= cipher_served | mask;
                    end else if (!(plain_served & mask)) begin
                        case (haddr[3:2])
                            2'd0: hrdata <= plaintext[127:96];
                            2'd1: hrdata <= plaintext[95:64];
                            2'd2: hrdata <= plaintext[63:32];
                            2'd3: hrdata <= plaintext[31:0];
                        endcase
                        hreadyout <= 1'b1;
                        new_plain_served = plain_served | mask;
                        plain_served <= new_plain_served;
                        if (&new_plain_served) begin
                            write_complete <= 1'b0;
                        end
                    end else begin
                        // both served -> return zeros
                        hrdata <= 32'd0;
                        hreadyout <= 1'b1;
                    end
                end else begin
                    // If no data available, return zeros
                    hrdata <= 32'd0;
                    hreadyout <= 1'b1;
                end
            end
        end
    end
endmodule