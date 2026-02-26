module fpga_top (
    input wire CLK100MHZ,
    input wire btnC,      // Reset (Active High on Basys3)
    input wire RsRx,
    output wire RsTx,
    output wire [15:0] LED
);

    // Clock and Reset
    wire hclk = CLK100MHZ;
    wire hresetn = ~btnC; // Convert active-high btn to active-low reset

    // UART Signals
    wire [7:0] rx_data, tx_data;
    wire rx_dv, tx_start, tx_busy;

    // AHB Master Signals (from Bridge)
    wire [31:0] haddr, hwdata, hrdata;
    wire hwrite, hready;
    wire [1:0] htrans, hresp;
    wire [2:0] hsize, hburst;
    wire [3:0] hprot;

    // Slave Selects
    wire hsel_s1, hsel_s2, hsel_s3, hsel_s4, hsel_sys;
    wire [31:0] hrdata_s1, hrdata_s2, hrdata_s3, hrdata_s4;
    wire hready_s1, hready_s2, hready_s3, hready_s4;
    wire [1:0] hresp_s1, hresp_s2, hresp_s3, hresp_s4;

    // -------------------------------------------------------------------------
    // UART Modules
    // -------------------------------------------------------------------------
    uart_rx #(.BAUD_RATE(115200)) u_rx (
        .clk(hclk), .rst_n(hresetn), .rx(RsRx), .dout(rx_data), .done(rx_dv)
    );

    uart_tx #(.BAUD_RATE(115200)) u_tx (
        .clk(hclk), .rst_n(hresetn), .start(tx_start), .din(tx_data), .tx(RsTx), .busy(tx_busy)
    );

    uart_ahb_bridge u_bridge (
        .hclk(hclk), .hresetn(hresetn),
        .rx_data(rx_data), .rx_dv(rx_dv),
        .tx_data(tx_data), .tx_start(tx_start), .tx_busy(tx_busy),
        .haddr(haddr), .hwdata(hwdata), .hwrite(hwrite),
        .htrans(htrans), .hsize(hsize), .hburst(hburst), .hprot(hprot),
        .hready(hready), .hrdata(hrdata), .hresp(hresp)
    );

    // -------------------------------------------------------------------------
    // AHB Interconnect (Decoder & Mux)
    // -------------------------------------------------------------------------
    // Address Map:
    // Slave 1 (RAM):    0x0000_0000 - 0x0000_03FF
    // Slave 2 (RAM):    0x1000_0000 - 0x1000_03FF
    // Slave 3 (Filter): 0x4000_0000 - 0x4000_03FF
    // Slave 4 (AES):    0x5000_0000 - 0x5000_03FF
    // System Reg:       0xE000_0000 (Bit 0: Clock Gating Enable)

    assign hsel_s1 = (haddr[31:16] == 16'h0000);
    assign hsel_s2 = (haddr[31:16] == 16'h1000);
    assign hsel_s3 = (haddr[31:16] == 16'h4000);
    assign hsel_s4 = (haddr[31:16] == 16'h5000);
    assign hsel_sys = (haddr[31:16] == 16'hE000);

    // System Control Register (Clock Gating Enable)
    reg cg_enable;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            cg_enable <= 0;  // Reset: clock gating disabled
        else
            cg_enable <= 0;  // Clock gating always disabled
    end

    // Clock Gating Logic
    // Gate clock if: CG Enabled AND Slave Not Selected AND Slave Ready (Idle)
        // Clock gating disabled: clocks always ON
        wire clk_s1 = hclk;
        wire clk_s2 = hclk;
        wire clk_s3 = hclk;
        wire clk_s4 = hclk;

    // Muxing Read Data
    reg [31:0] mux_hrdata;
    reg mux_hready;
    reg [1:0] mux_hresp;

    always @(*) begin
        if (hsel_s1) begin
            mux_hrdata = hrdata_s1; mux_hready = hready_s1; mux_hresp = hresp_s1;
        end else if (hsel_s2) begin
            mux_hrdata = hrdata_s2; mux_hready = hready_s2; mux_hresp = hresp_s2;
        end else if (hsel_s3) begin
            mux_hrdata = hrdata_s3; mux_hready = hready_s3; mux_hresp = hresp_s3;
        end else if (hsel_s4) begin
            mux_hrdata = hrdata_s4; mux_hready = hready_s4; mux_hresp = hresp_s4;
        end else if (hsel_sys) begin
            mux_hrdata = {31'b0, cg_enable}; mux_hready = 1'b1; mux_hresp = 2'b00;
        end else begin
            mux_hrdata = 0; mux_hready = 1; mux_hresp = 0; // Default OK
        end
    end

    assign hrdata = mux_hrdata;
    assign hready = mux_hready;
    assign hresp  = mux_hresp;

    // -------------------------------------------------------------------------
    // Slaves
    // -------------------------------------------------------------------------
    
    // Slave 1: Generic RAM
    ahb_slave u_slave1 (
        .hclk(clk_s1), .hresetn(hresetn), .hsel(hsel_s1), .haddr(haddr), .hwrite(hwrite),
        .htrans(htrans), .hsize(hsize), .hburst(hburst), .hprot(hprot), .hwdata(hwdata),
        .hready(hready), .hreadyout(hready_s1), .hresp(hresp_s1), .hrdata(hrdata_s1)
    );

    // Slave 2: Generic RAM
    ahb_slave u_slave2 (
        .hclk(clk_s2), .hresetn(hresetn), .hsel(hsel_s2), .haddr(haddr), .hwrite(hwrite),
        .htrans(htrans), .hsize(hsize), .hburst(hburst), .hprot(hprot), .hwdata(hwdata),
        .hready(hready), .hreadyout(hready_s2), .hresp(hresp_s2), .hrdata(hrdata_s2)
    );

    // Slave 3: Filter Chain Slave
    ahb_filter_slave u_slave3 (
        .hclk(clk_s3), .hresetn(hresetn), .hsel(hsel_s3), .haddr(haddr), .hwrite(hwrite),
        .htrans(htrans), .hsize(hsize), .hburst(hburst), .hprot(hprot), .hwdata(hwdata),
        .hready(hready), .hreadyout(hready_s3), .hresp(hresp_s3), .hrdata(hrdata_s3)
    );

    // Slave 4: AES Slave
    ahb_aes_slave u_slave4 (
        .hclk(clk_s4), .hresetn(hresetn), .hsel(hsel_s4), .haddr(haddr), .hwrite(hwrite),
        .htrans(htrans), .hsize(hsize), .hburst(hburst), .hprot(hprot), .hwdata(hwdata),
        .hready(hready), .hreadyout(hready_s4), .hresp(hresp_s4), .hrdata(hrdata_s4)
    );

    // Status LEDs
    assign LED[0] = hresetn;
    assign LED[1] = rx_dv;
    assign LED[2] = tx_busy;
    assign LED[3] = hsel_s3; // Filter selected
    assign LED[15:4] = haddr[11:0]; // Show lower address bits

endmodule