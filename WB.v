`include "lib/defines.vh"
module WB(
    input wire clk,
    input wire rst,
    // input wire flush,
    input wire [`StallBus-1:0] stall,

    input wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus,

    output wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus,

    output wire [31:0] debug_wb_pc,
    output wire [3:0] debug_wb_rf_wen,
    output wire [4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata 
);

    reg [`MEM_TO_WB_WD-1:0] mem_to_wb_bus_r;

    always @ (posedge clk) begin
        if (rst) begin
            mem_to_wb_bus_r <= `MEM_TO_WB_WD'b0;
        end
        // else if (flush) begin
        //     mem_to_wb_bus_r <= `MEM_TO_WB_WD'b0;
        // end
        else if (stall[4]==`Stop && stall[5]==`NoStop) begin
            mem_to_wb_bus_r <= `MEM_TO_WB_WD'b0;
        end
        else if (stall[4]==`NoStop) begin
            mem_to_wb_bus_r <= mem_to_wb_bus;
        end
    end

    wire [31:0] wb_pc;
    wire rf_we;
    wire [4:0] rf_waddr;
    wire [31:0] rf_wdata;
    wire [31:0] badvaddr;
    wire is_in_delayslot;
    wire [4:0] excepttype;

    wire lo_we, hi_we;
    wire [31:0] lo_wdata, hi_wdata;

    // upper exception fields are consumed by CP0 in core
    assign {
        badvaddr,         // 173:142
        is_in_delayslot,  //141
        excepttype,       //140:136
        lo_we,            //135
        lo_wdata,         //134:103
        hi_we,            //102
        hi_wdata,         //101:70
        wb_pc,            //69:38
        rf_we,            //37
        rf_waddr,         //36:32
        rf_wdata          //31:0
    } = mem_to_wb_bus_r;

    assign wb_to_rf_bus = {
        lo_we,    //103
        lo_wdata,   //102:71
        hi_we,      //70
        hi_wdata,   //69:38
        rf_we,
        rf_waddr,
        rf_wdata
    };

    assign debug_wb_pc = wb_pc;
    assign debug_wb_rf_wen = {4{rf_we}};
    assign debug_wb_rf_wnum = rf_waddr;
    assign debug_wb_rf_wdata = rf_wdata;

    // Debug: watch k1 writeback near failure
    always @(posedge clk) begin
        if (rf_we && rf_waddr==5'd27) begin
            $display("[WB][%t] pc=%h wnum=%0d wdata=%h", $time, wb_pc, rf_waddr, rf_wdata);
        end
        // Targeted trace near failing testpoint in 0xbfc082xx region
        if (rf_we && wb_pc>=32'hbfc0_8240 && wb_pc<=32'hbfc0_8290) begin
            $display("[WB73][%t] pc=%h wnum=%0d wdata=%h", $time, wb_pc, rf_waddr, rf_wdata);
        end
        if (hi_we) begin
            $display("[WB][%t] HI write pc=%h data=%h", $time, wb_pc, hi_wdata);
        end
    end

    
endmodule