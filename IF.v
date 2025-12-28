`include "lib/defines.vh"
module IF(
    input wire clk,
    input wire rst,
    input wire [`StallBus-1:0] stall,

    input wire flush,
    input wire [31:0] new_pc,

    // input wire flush,
    // input wire [31:0] new_pc,

    input wire [`BR_WD-1:0] br_bus,

    output wire [`IF_TO_ID_WD-1:0] if_to_id_bus,

    output wire inst_sram_en,
    output wire [3:0] inst_sram_wen,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata
);
    reg [31:0] pc_reg;
    reg ce_reg; //取值使能
    wire [31:0] next_pc;
    wire br_e;  //跳转使能
    wire [31:0] br_addr;
    wire adel_if;

    assign {
        br_e,
        br_addr
    } = br_bus;


    always @ (posedge clk) begin
        if (rst) begin
            pc_reg      <= 32'hbfbf_fffc;
        end else begin
            if (flush) begin
                pc_reg <= new_pc;
            end else if (stall[0]==`NoStop) begin
                pc_reg <= next_pc;
            end
        end
    end

    always @ (posedge clk) begin
        if (rst) begin
            ce_reg <= 1'b0;
        end
        else if (stall[0]==`NoStop) begin
            ce_reg <= 1'b1;
        end
    end


    assign next_pc = br_e ? br_addr 
                   : pc_reg + 32'h4;

    assign adel_if = ce_reg && (pc_reg[1:0]!=2'b00);

    
    assign inst_sram_en = ce_reg && (stall[0]==`NoStop);
    assign inst_sram_wen = 4'b0;
    assign inst_sram_addr = pc_reg;
    assign inst_sram_wdata = 32'b0;
    assign if_to_id_bus = {
        adel_if,
        ce_reg,
        pc_reg
    };

endmodule