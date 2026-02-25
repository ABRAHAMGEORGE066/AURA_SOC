// ahb_decoder.v
// Simple 2-to-4 decoder for AHB slave selection
module ahb_decoder(
    input [1:0] sel,
    output reg hsel_1,
    output reg hsel_2,
    output reg hsel_3,
    output reg hsel_4
);
    always @(*) begin
        hsel_1 = (sel == 2'b00);
        hsel_2 = (sel == 2'b01);
        hsel_3 = (sel == 2'b10);
        hsel_4 = (sel == 2'b11);
    end
endmodule
