`include "lib/defines.vh"
module MEM(
    input wire clk,
    input wire rst,
    input wire [`StallBus-1:0] stall,

    input wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus,
    input wire [31:0] data_sram_rdata,

    input wire [31:0] cp0_status,
    input wire [31:0] cp0_cause,
    input wire [31:0] cp0_epc,
    input wire [31:0] cp0_badvaddr,
    input wire        timer_int,

    output wire       flush,
    output wire [31:0] new_pc,

    output wire       cp0_we,
    output wire [4:0] cp0_waddr,
    output wire [2:0] cp0_wsel,
    output wire [31:0] cp0_wdata,

    output wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus
);

    reg [`EX_TO_MEM_WD-1:0] ex_to_mem_bus_r;

    always @ (posedge clk) begin
        if (rst) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        else if (flush) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        else if (stall[3]==`Stop && stall[4]==`NoStop) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        else if (stall[3]==`NoStop) begin
            ex_to_mem_bus_r <= ex_to_mem_bus;
        end
    end

    wire [31:0] badvaddr_in;
    wire [4:0]  excepttype_in;
    wire is_in_delayslot;
    wire [31:0] mem_pc;
    wire cp0_we_in;
    wire [4:0] cp0_addr_in;
    wire [2:0] cp0_sel_in;
    wire [31:0] cp0_wdata_in;
    wire [3:0] data_ram_sel;
    wire inst_lb, inst_lbu, inst_lh, inst_lhu;
    wire [31:0] hi_wdata, lo_wdata;
    wire hi_we, lo_we;
    wire [3:0] data_ram_wen;
    wire data_ram_en;
    wire sel_rf_res;
    wire rf_we_in;
    wire [4:0] rf_waddr_in;
    wire [31:0] ex_result;

    assign {
        badvaddr_in,    //228:197
        excepttype_in,  //196:192
        is_in_delayslot,//191
        mem_pc,         //190:159
        cp0_we_in,      //158
        cp0_addr_in,    //157:153
        cp0_sel_in,     //152:150
        cp0_wdata_in,   //149:118
        data_ram_sel,   //117:114
        inst_lb, inst_lbu, inst_lh, inst_lhu, //113:110
        hi_wdata,       //109:78
        hi_we,          //77
        lo_wdata,       //76:45
        lo_we,          //44
        data_ram_wen,   //43:40
        data_ram_en,    //39
        sel_rf_res,     //38
        rf_we_in,       //37
        rf_waddr_in,    //36:32
        ex_result       //31:0
    } = ex_to_mem_bus_r;

    // 接受访存结果
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

    wire [31:0] mem_result = inst_lb     ? {{24{b_data[7]}},b_data} :
                              inst_lbu   ? {{24{1'b0}},b_data} :
                              inst_lh    ? {{16{h_data[15]}},h_data} :
                              inst_lhu   ? {{16{1'b0}},h_data} :
                              w_data;

    // 对齐检查
    wire is_sw = data_ram_en && data_ram_wen==4'b1111 && data_ram_sel==4'b1111;
    wire is_sh = data_ram_en && data_ram_wen==4'b1111 && (data_ram_sel==4'b0011 || data_ram_sel==4'b1100);
    wire is_sb = data_ram_en && data_ram_wen==4'b1111 && (data_ram_sel==4'b0001 || data_ram_sel==4'b0010 || data_ram_sel==4'b0100 || data_ram_sel==4'b1000);
    wire is_lw = sel_rf_res && ~(inst_lb|inst_lbu|inst_lh|inst_lhu);
    wire misalign_lw = is_lw && (ex_result[1:0]!=2'b00);
    wire misalign_sw = is_sw && (ex_result[1:0]!=2'b00);
    wire misalign_lh = (inst_lh|inst_lhu) && ex_result[0];
    wire misalign_sh = is_sh && ex_result[0];

    wire adel_load = misalign_lw | misalign_lh;
    wire ades_store = misalign_sw | misalign_sh;

    // 中断判定
    // Use the sticky TI bit (CAUSE[30]) so timer interrupts are not lost when IE/IM are enabled later
    wire [7:0] ip = {cp0_cause[15] | cp0_cause[30], cp0_cause[14:8]};
    wire [7:0] im = cp0_status[15:8];
    wire int_pending = (excepttype_in==5'b0) && (cp0_status[1]==1'b0) && (cp0_status[0]==1'b1) && (|(ip & im));

    reg [4:0] excepttype_final;
    reg [31:0] badvaddr_final;

    always @(*) begin
        excepttype_final = excepttype_in;
        badvaddr_final   = badvaddr_in;

        // Align/addr errors take priority and must carry the fault address
        if (adel_load) begin
            excepttype_final = `EXC_ADEL;
            badvaddr_final   = ex_result;
        end else if (ades_store) begin
            excepttype_final = `EXC_ADES;
            badvaddr_final   = ex_result;
        end else if (excepttype_in==`EXC_ADEL || excepttype_in==`EXC_ADES) begin
            badvaddr_final = (badvaddr_in!=32'b0) ? badvaddr_in : ex_result;
        end else if (excepttype_in==5'b0 && int_pending) begin
            excepttype_final = `EXC_INT;
        end
    end

    wire has_exception = (excepttype_final!=5'b0);
    assign flush = has_exception;
    assign new_pc = (excepttype_final==`EXC_ERET) ? cp0_epc : 32'hbfc0_0380;

    // Debug: print exception info during simulation
    always @(posedge clk) begin
        if (!rst && has_exception) begin
            $display("[MEM][%t] exc=%0h pc=%h badvaddr=%h ex_res=%h load=%b store=%b int_pend=%b ds=%b", $time,
                     excepttype_final, mem_pc, badvaddr_final, ex_result, sel_rf_res, data_ram_en && |data_ram_wen, int_pending, is_in_delayslot);
        end
        // Trace when interrupts become pending to catch missed handler entries
        if (!rst && int_pending) begin
            $display("[MEM][%t] INT pending pc=%h status=%h cause=%h", $time, mem_pc, cp0_status, cp0_cause);
        end
           // Debug window around handler re-entry and failing store/load sequences
           if (!rst && ((mem_pc>=32'hbfc0_8144 && mem_pc<=32'hbfc0_8220) ||
                     (mem_pc>=32'hbfc0_8240 && mem_pc<=32'hbfc0_8290))) begin
              $display("[DBG73][%t] pc=%h ex_res=%h sel_rf_res=%b data_en=%b data_wen=%b data_sel=%b rdata=%h", $time,
                  mem_pc, ex_result, sel_rf_res, data_ram_en, data_ram_wen, data_ram_sel, data_sram_rdata);
           end
        // Debug snapshot for failing testpoint investigation
        if (!rst && mem_pc==32'hbfc0_17f8) begin
            $display("[DBG][%t] pc=%h sel_rf_res=%b inst_lb=%b inst_lbu=%b inst_lh=%b inst_lhu=%b data_ram_en=%b data_ram_wen=%b ex_result=%h misalign_lw=%b", $time,
                     mem_pc, sel_rf_res, inst_lb, inst_lbu, inst_lh, inst_lhu, data_ram_en, data_ram_wen, ex_result, (sel_rf_res && (ex_result[1:0]!=2'b00) && ~(inst_lb|inst_lbu|inst_lh|inst_lhu)));
        end
        // Trace the soft-interrupt wait loop to observe why int_pending is not asserted
        if (!rst && mem_pc==32'hbfc0_c9c4) begin
            $display("[DBG77][%t] pc=%h status=%h cause=%h ip=%b im=%b exc_in=%0h int_pend=%b", $time,
                     mem_pc, cp0_status, cp0_cause, ip, im, excepttype_in, int_pending);
        end
    end

    // 写回与CP0写
    wire rf_we = has_exception ? 1'b0 : rf_we_in;
    wire [31:0] rf_wdata = sel_rf_res ? mem_result : ex_result;

    assign cp0_we    = has_exception ? 1'b0 : cp0_we_in;
    assign cp0_waddr = cp0_addr_in;
    assign cp0_wsel  = cp0_sel_in;
    assign cp0_wdata = cp0_wdata_in;

    assign mem_to_wb_bus = {
        badvaddr_final,   //173:142
        is_in_delayslot,  //141
        excepttype_final, //140:136
        lo_we,            //135
        lo_wdata,         //134:103
        hi_we,            //102
        hi_wdata,         //101:70
        mem_pc,           //69:38
        rf_we,            //37
        rf_waddr_in,      //36:32
        rf_wdata          //31:0
    };

endmodule