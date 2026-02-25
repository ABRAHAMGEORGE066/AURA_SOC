// ahb_slave.v
// Simple AHB-Lite slave template for FPGA integration
module ahb_slave(
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
    // Simple memory-mapped register (example)
    reg [31:0] mem [0:3];
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            hreadyout <= 1'b1;
            hresp <= 1'b0;
            hrdata <= 32'b0;
        end else if (hsel && hready && (htrans == 2'b10 || htrans == 2'b11)) begin
            if (hwrite) begin
                mem[haddr[3:2]] <= hwdata;
                hreadyout <= 1'b1;
                hresp <= 1'b0;
            end else begin
                hrdata <= mem[haddr[3:2]];
                hreadyout <= 1'b1;
                hresp <= 1'b0;
            end
        end else begin
            hreadyout <= 1'b1;
            hresp <= 1'b0;
        end
    end
endmodule
