`include "lib/defines.vh"
module CTRL(
    input wire rst,
    input wire stallreq_for_ex,
    input wire stallreq_for_axi,
    input wire stallreq_for_load,

    // output reg flush,
    // output reg [31:0] new_pc,
    output reg [`StallBus-1:0] stall
);  
    always @ (*) begin
        if (rst) begin
            stall = `StallBus'b0;
        end else if (stallreq_for_axi) begin
            stall = `StallBus'b11111;
        end else if (stallreq_for_load) begin
            stall = `StallBus'b111; // 暂停IF, ID, EX
        end else if (stallreq_for_ex) begin
            stall = `StallBus'b1111; // 暂停IF, ID, EX, MEM
        end else begin
            stall = `StallBus'b0;
        end
    end

endmodule