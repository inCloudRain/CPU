`include "lib/defines.vh"
module MEM(
    input wire clk,
    input wire rst,
    // input wire flush,
    input wire [`StallBus-1:0] stall,

    input wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus,
    input wire [31:0] data_sram_rdata,

    output wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus
);

    reg [`EX_TO_MEM_WD-1:0] ex_to_mem_bus_r;

    always @ (posedge clk) begin
        if (rst) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        // else if (flush) begin
        //     ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        // end
        else if (stall[3]==`Stop && stall[4]==`NoStop) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        else if (stall[3]==`NoStop) begin
            ex_to_mem_bus_r <= ex_to_mem_bus;
        end
    end

    wire [31:0] mem_pc;
    wire data_ram_en;
    wire [3:0] data_ram_wen;
    wire sel_rf_res;
    wire rf_we;
    wire [4:0] rf_waddr;
    wire [31:0] rf_wdata;
    wire [31:0] ex_result;
    wire [31:0] mem_result;

    wire lo_we, hi_we;
    wire [31:0] lo_wdata, hi_wdata;

    wire [3:0] data_ram_sel;
    wire inst_lb, inst_lbu, inst_lh, inst_lhu;

    assign {
        data_ram_sel,         // 149:146
        inst_lb, inst_lbu, inst_lh, inst_lhu, // 145:142
        lo_we,          // 141
        lo_wdata,       // 140:109
        hi_we,          // 108
        hi_wdata,       // 107:76
        mem_pc,         // 75:44
        data_ram_en,    // 43
        data_ram_wen,   // 42:39
        sel_rf_res,     // 38
        rf_we,          // 37
        rf_waddr,       // 36:32
        ex_result       // 31:0
    } =  ex_to_mem_bus_r;

    //接受访存结果
    wire [7:0]  b_data;
    wire [15:0] h_data;
    wire [31:0] w_data;

    assign b_data = data_ram_sel[3] ? data_sram_rdata[31:24] : 
                    data_ram_sel[2] ? data_sram_rdata[23:16] :
                    data_ram_sel[1] ? data_sram_rdata[15: 8] : 
                    data_ram_sel[0] ? data_sram_rdata[ 7: 0] : 8'b0;
    assign h_data = data_ram_sel[2] ? data_sram_rdata[31:16] :
                    data_ram_sel[0] ? data_sram_rdata[15: 0] : 16'b0;
    assign w_data = data_sram_rdata;

    assign mem_result = inst_lb     ? {{24{b_data[7]}},b_data} :
                        inst_lbu    ? {{24{1'b0}},b_data} :
                        inst_lh     ? {{16{h_data[15]}},h_data} :
                        inst_lhu    ? {{16{1'b0}},h_data} :
                        w_data;
    assign rf_wdata = sel_rf_res ? mem_result : ex_result;

    assign mem_to_wb_bus = {
        lo_we,      // 135
        lo_wdata,   // 134:103
        hi_we,      // 102
        hi_wdata,   // 101:70
        mem_pc,     // 69:38
        rf_we,      // 37
        rf_waddr,   // 36:32
        rf_wdata    // 31:0
    };




endmodule