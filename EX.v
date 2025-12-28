`include "lib/defines.vh"
module EX(
    input wire clk,
    input wire rst,
    input wire flush,
    input wire [`StallBus-1:0] stall,

    input wire [`ID_TO_EX_WD-1:0] id_to_ex_bus,

    output wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus,

    input wire [31:0] cp0_rdata,
    output wire [4:0] cp0_raddr,
    output wire [2:0] cp0_rsel,

    output wire data_sram_en,
    output wire [3:0] data_sram_wen,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,

    output wire stallreq_for_ex
);

    reg [`ID_TO_EX_WD-1:0] id_to_ex_bus_r;

    always @ (posedge clk) begin
        if (rst || flush) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        else if (stall[2]==`Stop && stall[3]==`NoStop) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        else if (stall[2]==`NoStop) begin
            id_to_ex_bus_r <= id_to_ex_bus;
        end
    end

    wire ov_en;
    wire [31:0] ex_pc;
    wire [11:0] alu_op;
    wire [4:0] sel_alu_src1;    //rs, pc, sa_zero_extend, lo_data, hi_data
    wire [3:0] sel_alu_src2;    //rt, imm_sign_extend, 32'b8, imm_zero_extend
    wire data_ram_en;
    wire [3:0] data_ram_wen;
    wire rf_we;
    wire [4:0] rf_waddr;
    wire sel_rf_res;
    wire [31:0] rf_rdata1, rf_rdata2, lo_data, hi_data;
    wire is_in_delayslot;

    wire inst_mul, inst_mulu, inst_div, inst_divu;
    wire inst_lb, inst_lbu, inst_lh, inst_lhu;
    wire inst_sb, inst_sh;
    wire lo_we, hi_we;
    wire cp0_re, cp0_we;
    wire [4:0] cp0_addr;
    wire [2:0] cp0_sel;
    wire [31:0] badvaddr_in;
    wire [4:0] excepttype_in;
    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;
    wire has_exception;

    assign {
        ov_en,             //349
        rf_rdata2,         //348:317
        rf_rdata1,         //316:285
        sel_rf_res,        //284
        rf_waddr,          //283:279
        rf_we,             //278
        data_ram_wen,      //277:274
        data_ram_en,       //273
        sel_alu_src2,      //272:269
        sel_alu_src1,      //268:264
        alu_op,            //263:252
        ex_pc,             //251:220
        inst_mul, inst_mulu, inst_div, inst_divu, //219:216
        hi_we,             //215
        lo_we,             //214
        hi_data,           //213:182
        lo_data,           //181:150
        inst_lb, inst_lbu, inst_lh, inst_lhu, //149:146
        inst_sb, inst_sh,  //145:144
        cp0_sel,           //143:141
        cp0_addr,          //140:136
        cp0_we,            //135
        cp0_re,            //134
        badvaddr_in,       //133:102
        is_in_delayslot,   //101
        excepttype_in,     //100:96
        sa_zero_extend,    //95:64
        imm_zero_extend,   //63:32
        imm_sign_extend    //31:0
    } = id_to_ex_bus_r;

    wire [31:0] alu_src1, alu_src2;
    wire [31:0] alu_result, ex_result;

    assign alu_src1 = sel_alu_src1[1] ? ex_pc :
                      sel_alu_src1[2] ? sa_zero_extend :
                      sel_alu_src1[3] ? lo_data :
                      sel_alu_src1[4] ? hi_data : rf_rdata1;

    assign alu_src2 = sel_alu_src2[1] ? imm_sign_extend :
                      sel_alu_src2[2] ? 32'd8 :
                      sel_alu_src2[3] ? imm_zero_extend : rf_rdata2;
    
    alu u_alu(
    	.alu_control (alu_op ),
        .alu_src1    (alu_src1    ),
        .alu_src2    (alu_src2    ),
        .alu_result  (alu_result  )
    );

    assign ex_result = cp0_re ? cp0_rdata : alu_result;

    assign cp0_raddr = cp0_addr;
    assign cp0_rsel  = cp0_sel;

    // overflow detection
    wire add_overflow;
    wire sub_overflow;
    wire [31:0] add_tmp = alu_src1 + alu_src2;
    wire [31:0] sub_tmp = alu_src1 - alu_src2;
    assign add_overflow = ov_en && alu_op[11] && ((alu_src1[31]==alu_src2[31]) && (add_tmp[31]!=alu_src1[31]));
    assign sub_overflow = ov_en && alu_op[10] && ((alu_src1[31]!=alu_src2[31]) && (sub_tmp[31]!=alu_src1[31]));

    //发出访存请求
    wire [3:0] byte_sel;
    wire [3:0] data_ram_sel;
    decoder_2_4 u_decoder_2_4(
        .in  (ex_result[1:0]),
        .out (byte_sel      )
    );
    assign data_ram_sel = inst_sb | inst_lb | inst_lbu ? byte_sel :
                          inst_sh | inst_lh | inst_lhu ? {{2{byte_sel[2]}},{2{byte_sel[0]}}} :
                          4'b1111;

    // Alignment checks early in EX to block memory side effects on bad addresses
    wire is_sw = data_ram_en && data_ram_wen==4'b1111 && data_ram_sel==4'b1111;
    wire is_sh = data_ram_en && data_ram_wen==4'b1111 && (data_ram_sel==4'b0011 || data_ram_sel==4'b1100);
    wire is_lw = sel_rf_res && ~(inst_lb|inst_lbu|inst_lh|inst_lhu);
    wire misalign_lw = is_lw && (ex_result[1:0]!=2'b00);
    wire misalign_sw = is_sw && (ex_result[1:0]!=2'b00);
    wire misalign_lh = (inst_lh|inst_lhu) && ex_result[0];
    wire misalign_sh = is_sh && ex_result[0];
    // Mask memory requests when the pipeline is being flushed (exceptions)
    assign data_sram_en    = data_ram_en & ~flush & ~has_exception;
    assign data_sram_wen   = (data_ram_wen & data_ram_sel) & {4{~flush & ~has_exception}};
    assign data_sram_addr  = ex_result;
    assign data_sram_wdata = inst_sb ? {4{rf_rdata2[7:0]}}  :
                             inst_sh ? {2{rf_rdata2[15:0]}} : rf_rdata2;

    // MUL part
    wire [63:0] mul_result;
    wire mul_signed = inst_mul;

    mul u_mul(
    	.clk        (clk            ),
        .resetn     (~rst           ),
        .mul_signed (mul_signed     ),
        .ina        (rf_rdata1      ), // 乘法源操作数1
        .inb        (rf_rdata2      ), // 乘法源操作数2
        .result     (mul_result     ) // 乘法结果 64bit
    );

    // DIV part
    wire [63:0] div_result;
    wire div_ready_i;
    reg stallreq_for_div;
    assign stallreq_for_ex = stallreq_for_div;

    reg [31:0] div_opdata1_o;
    reg [31:0] div_opdata2_o;
    reg div_start_o;
    reg signed_div_o;

    div u_div(
    	.rst          (rst          ),
        .clk          (clk          ),
        .signed_div_i (signed_div_o ),
        .opdata1_i    (div_opdata1_o    ),
        .opdata2_i    (div_opdata2_o    ),
        .start_i      (div_start_o      ),
        .annul_i      (1'b0      ),
        .result_o     (div_result     ), // 除法结果 64bit
        .ready_o      (div_ready_i      )
    );

    always @ (*) begin
        if (rst) begin
            stallreq_for_div = `NoStop;
            div_opdata1_o = `ZeroWord;
            div_opdata2_o = `ZeroWord;
            div_start_o = `DivStop;
            signed_div_o = 1'b0;
        end
        else begin
            stallreq_for_div = `NoStop;
            div_opdata1_o = `ZeroWord;
            div_opdata2_o = `ZeroWord;
            div_start_o = `DivStop;
            signed_div_o = 1'b0;
            case ({inst_div,inst_divu})
                2'b10:begin
                    if (div_ready_i == `DivResultNotReady) begin
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStart;
                        signed_div_o = 1'b1;
                        stallreq_for_div = `Stop;
                    end
                    else if (div_ready_i == `DivResultReady) begin
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b1;
                        stallreq_for_div = `NoStop;
                    end
                    else begin
                        div_opdata1_o = `ZeroWord;
                        div_opdata2_o = `ZeroWord;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                end
                2'b01:begin
                    if (div_ready_i == `DivResultNotReady) begin
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStart;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `Stop;
                    end
                    else if (div_ready_i == `DivResultReady) begin
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                    else begin
                        div_opdata1_o = `ZeroWord;
                        div_opdata2_o = `ZeroWord;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                end
                default:begin
                end
            endcase
        end
    end

    // mul_result 和 div_result 可以直接使用

    wire [31:0] lo_wdata, hi_wdata;
    assign lo_wdata = inst_mul || inst_mulu ? mul_result[31:0] :
                      inst_div || inst_divu ? div_result[31:0] :
                      rf_rdata1;
    assign hi_wdata = inst_mul || inst_mulu ? mul_result[63:32] :
                      inst_div || inst_divu ? div_result[63:32] :
                      rf_rdata1;

    wire [4:0] excepttype_out = (excepttype_in!=5'b0) ? excepttype_in :
                                misalign_lw ? `EXC_ADEL :
                                misalign_sw ? `EXC_ADES :
                                misalign_lh ? `EXC_ADEL :
                                misalign_sh ? `EXC_ADES :
                                (add_overflow||sub_overflow) ? `EXC_OV :
                                5'b0;
    assign has_exception = (excepttype_out!=5'b0);
    wire [31:0] badvaddr_out = (misalign_lw | misalign_sw | misalign_lh | misalign_sh) ? ex_result : badvaddr_in;
    wire [31:0] cp0_wdata = rf_rdata2;

    assign ex_to_mem_bus = {
        badvaddr_out,    //228:197
        excepttype_out,  //196:192
        is_in_delayslot, //191
        ex_pc,           //190:159
        cp0_we,          //158
        cp0_addr,        //157:153
        cp0_sel,         //152:150
        cp0_wdata,       //149:118
        data_ram_sel,    //117:114
        inst_lb, inst_lbu, inst_lh, inst_lhu, //113:110
        hi_wdata,        //109:78
        hi_we,           //77
        lo_wdata,        //76:45
        lo_we,           //44
        data_ram_wen,    //43:40
        data_ram_en,     //39
        sel_rf_res,      //38
        rf_we,           //37
        rf_waddr,        //36:32
        ex_result        //31:0
    };

endmodule