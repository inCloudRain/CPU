`include "lib/defines.vh"
module ID(
    input wire clk,
    input wire rst,
    // input wire flush,
    input wire [`StallBus-1:0] stall,
    
    output wire stallreq,

    input wire [`IF_TO_ID_WD-1:0] if_to_id_bus,

    input wire [31:0] inst_sram_rdata,

    input wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus, //来自WB段的写寄存器指令

    input wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus, //EX/MEM段缓存，用于重定向

    input wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus, //MEM/WB段缓存，用于重定向

    output wire [`ID_TO_EX_WD-1:0] id_to_ex_bus,

    output wire [`BR_WD-1:0] br_bus,

    output wire stallreq_for_load
);

    reg [`IF_TO_ID_WD-1:0] if_to_id_bus_r;
    wire [31:0] inst;
    wire [31:0] id_pc;
    wire ce;    //取指使能（指令有效信号）

    wire wb_rf_we;  //写寄存器使能
    wire [4:0] wb_rf_waddr;
    wire [31:0] wb_rf_wdata;

    wire wb_lo_we, wb_hi_we;
    wire [31:0] lo_wdata, hi_wdata;

    always @ (posedge clk) begin
        if (rst) begin
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;        
        end
        // else if (flush) begin
        //     ic_to_id_bus <= `IC_TO_ID_WD'b0;
        // end
        else if (stall[1]==`Stop && stall[2]==`NoStop) begin
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;
        end
        else if (stall[1]==`NoStop) begin
            if_to_id_bus_r <= if_to_id_bus;
        end
    end
    
    assign inst = inst_sram_rdata;
    assign {
        ce,
        id_pc
    } = if_to_id_bus_r;
    assign {
        wb_lo_we,    //103
        lo_wdata,   //102:71
        wb_hi_we,      //70
        hi_wdata,   //69:38
        wb_rf_we,   // 37
        wb_rf_waddr,    // 36:32
        wb_rf_wdata // 31:0
    } = wb_to_rf_bus;

    //指令中各部分，详见A03
    wire [5:0] opcode;
    wire [4:0] rs,rt,rd,sa;
    wire [5:0] func;
    wire [15:0] imm;
    wire [25:0] instr_index;
    wire [19:0] code;
    wire [4:0] base;
    wire [15:0] offset;
    wire [2:0] sel;

    assign opcode = inst[31:26];
    assign rs = inst[25:21];
    assign rt = inst[20:16];
    assign rd = inst[15:11];
    assign sa = inst[10:6];
    assign func = inst[5:0];
    assign imm = inst[15:0];
    assign instr_index = inst[25:0];
    assign code = inst[25:6];
    assign base = inst[25:21];
    assign offset = inst[15:0];
    assign sel = inst[2:0];

    reg [4:0] sel_alu_src1;    //0-4: rs, pc, sa_zero_extend, LO, HI
    reg [3:0] sel_alu_src2;    //0-3: rt, imm_sign_extend, 32'b8, imm_zero_extend
    wire [11:0] alu_op;

    reg br_e;
    reg [31:0] br_addr;

    //写数据内存相关，不实际执行，送入后续段
    reg data_ram_en;
    reg [3:0] data_ram_wen;
    
    //写寄存器相关，不实际执行，送入后续段
    reg rf_we;
    wire [4:0] rf_waddr;
    reg sel_rf_res;    //0：alu结果；1：访存结果
    reg [2:0] sel_rf_dst;  //rd, rt, $31

    reg lo_we, hi_we;

    reg op_add, op_sub, op_slt, op_sltu;
    reg op_and, op_nor, op_or, op_xor;
    reg op_sll, op_srl, op_sra, op_lui;

    reg inst_mul, inst_mulu, inst_div, inst_divu;
    reg inst_lb, inst_lbu, inst_lh, inst_lhu;
    reg inst_sb, inst_sh;

    wire [31:0] rdata1, rdata2;

    regfile u_regfile(
    	.clk    (clk    ),
        .raddr1 (rs ),
        .rdata1 (rdata1 ),
        .raddr2 (rt ),
        .rdata2 (rdata2 ),
        .we     (wb_rf_we     ),
        .waddr  (wb_rf_waddr  ),
        .wdata  (wb_rf_wdata  )
    );
    reg [31:0] LO, HI;

    always @(posedge clk) begin
        if(rst) begin
            LO <= 32'b0;
            HI <= 32'b0;
        end
        else begin
            if(wb_lo_we) LO <= lo_wdata;
            if(wb_hi_we) HI <= hi_wdata;
        end
    end


    wire ex_to_mem_lwe = ex_to_mem_bus[141];
    wire [31:0] ex_to_mem_lwdata = ex_to_mem_bus[140:109];
    wire ex_to_mem_hwe = ex_to_mem_bus[108];
    wire [31:0] ex_to_mem_hwdata = ex_to_mem_bus[107:76];
    wire ex_to_mem_load = ex_to_mem_bus[38];
    wire ex_to_mem_rwe = ex_to_mem_bus[37];
    wire [4:0] ex_to_mem_rwaddr = ex_to_mem_bus[36:32];
    wire [31:0] ex_to_mem_rwdata = ex_to_mem_bus[31:0];

    wire mem_to_wb_lwe = mem_to_wb_bus[135];
    wire [31:0] mem_to_wb_lwdata = mem_to_wb_bus[134:103];
    wire mem_to_wb_hwe = mem_to_wb_bus[102];
    wire [31:0] mem_to_wb_hwdata = mem_to_wb_bus[101:70];
    wire mem_to_wb_rwe = mem_to_wb_bus[37];
    wire [4:0] mem_to_wb_rwaddr = mem_to_wb_bus[36:32];
    wire [31:0] mem_to_wb_rwdata = mem_to_wb_bus[31:0];
    wire [31:0] data1, data2, lo_data, hi_data;

    //读存停顿
    reg use_data1, use_data2;   //跳转指令使用，计算指令可通过sel_alu_src判断

    assign stallreq_for_load = ex_to_mem_load && 
                            ((use_data1 || sel_alu_src1[0]) && (ex_to_mem_rwaddr==rs) ||
                            (use_data2 || sel_alu_src2[0]) && (ex_to_mem_rwaddr==rt));

    //重定向
    assign lo_data = ex_to_mem_lwe ? ex_to_mem_lwdata :
                     mem_to_wb_lwe ? mem_to_wb_lwdata :
                     wb_lo_we ? lo_wdata :
                     LO;
    assign hi_data = ex_to_mem_hwe ? ex_to_mem_hwdata :
                     mem_to_wb_hwe ? mem_to_wb_hwdata :
                     wb_hi_we ? hi_wdata :
                     HI;
    assign data1 = ex_to_mem_rwe && ex_to_mem_rwaddr==rs ? ex_to_mem_rwdata :
                   mem_to_wb_rwe && mem_to_wb_rwaddr==rs ? mem_to_wb_rwdata :
                   wb_rf_we && wb_rf_waddr==rs ? wb_rf_wdata :
                   rdata1;
    assign data2 = ex_to_mem_rwe && ex_to_mem_rwaddr==rt ? ex_to_mem_rwdata :
                   mem_to_wb_rwe && mem_to_wb_rwaddr==rt ? mem_to_wb_rwdata :
                   wb_rf_we && wb_rf_waddr==rt ? wb_rf_wdata :
                   rdata2;

    always @ (*) begin  //译码核心
        //初始化，必须显式赋值
        sel_alu_src1 = 5'b0;
        sel_alu_src2 = 4'b0;
        sel_rf_dst = 3'b0;
        
        //绝大部分情况下的默认值，不显式赋默认值
        {op_add, op_sub, op_slt, op_sltu,
         op_and, op_nor, op_or, op_xor,
         op_sll, op_srl, op_sra, op_lui} = 12'b0;
        {inst_mul, inst_mulu, inst_div, inst_divu} = 4'b0;
        {lo_we, hi_we} = 2'b0;
        {inst_lb, inst_lbu, inst_lh, inst_lhu} = 4'b0;
        {inst_sb, inst_sh} = 2'b0;

        //计算指令默认值
        br_e = 1'b0;
        br_addr = 32'b0;
        data_ram_en = 1'b0;
        data_ram_wen = 4'b0;
        rf_we = 1'b1;
        sel_rf_res = 1'b0;
        case(opcode)
            6'b000000: begin
            case(func)  //R型计算指令
                6'b100000: begin   //add
                    op_add = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b100001: begin   //addu
                    op_add = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b100010: begin   //sub
                    op_sub = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b100011: begin   //subu
                    op_sub = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b010000: begin   //mfhi
                    op_add = 1'b1;
                    sel_alu_src1[4] = 1'b1; // HI
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b010001: begin   //mthi
                    rf_we = 1'b0;
                    hi_we = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                end
                6'b010010: begin   //mflo
                    op_add = 1'b1;
                    sel_alu_src1[3] = 1'b1; // LO
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b010011: begin   //mtlo
                    rf_we = 1'b0;
                    lo_we = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                end
                6'b011010: begin   //div
                    rf_we = 1'b0;
                    lo_we = 1'b1;
                    hi_we = 1'b1;
                    inst_div = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                end
                6'b011011: begin   //divu
                    rf_we = 1'b0;
                    lo_we = 1'b1;
                    hi_we = 1'b1;
                    inst_divu = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                end
                6'b011000: begin   //mul
                    rf_we = 1'b0;
                    lo_we = 1'b1;
                    hi_we = 1'b1;
                    inst_mul = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                end
                6'b011001: begin   //mulu
                    rf_we = 1'b0;
                    lo_we = 1'b1;
                    hi_we = 1'b1;
                    inst_mulu = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                end
                6'b100100: begin   //and
                    op_and = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b100101: begin   //or
                    op_or = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b100110: begin   //xor
                    op_xor = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b100111: begin   //nor
                    op_nor = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b101010: begin   //slt
                    op_slt = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b101011: begin   //sltu
                    op_sltu = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b000000: begin   //sll
                    op_sll = 1'b1;
                    sel_alu_src1[2] = 1'b1; // sa_zero_extend
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b000010: begin   //srl
                    op_srl = 1'b1;
                    sel_alu_src1[2] = 1'b1; // sa_zero_extend
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b000011: begin   //sra
                    op_sra = 1'b1;
                    sel_alu_src1[2] = 1'b1; // sa_zero_extend
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b000100: begin   //sllv
                    op_sll = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b000110: begin   //srlv
                    op_srl = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                6'b000111: begin   //srav
                    op_sra = 1'b1;
                    sel_alu_src1[0] = 1'b1; // rs
                    sel_alu_src2[0] = 1'b1; // rt
                    sel_rf_dst[0] = 1'b1;   // rd
                end
                //R型跳转指令
                6'b001000: begin  // jr
                    rf_we = 1'b0;
                    br_e = 1'b1;
                    br_addr = data1;
                end
                6'b001001: begin  // jalr
                    rf_we = 1'b1;
                    op_add = 1'b1;
                    sel_alu_src1[1] = 1'b1; // pc
                    sel_alu_src2[2] = 1'b1; // 32'd8
                    sel_rf_dst[0] = 1'b1;   // rd
                    br_e = 1'b1;
                    br_addr = data1;
                end
                default: begin
                    // 未定义R型func，全部无效
                    rf_we = 1'b0;
                end
            endcase end
            // I型计算指令
            6'b001000: begin   // addi
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b001001: begin   // addiu
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b001100: begin   // andi
                op_and = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[3] = 1'b1; // imm_zero_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b001101: begin   // ori
                op_or = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[3] = 1'b1; // imm_zero_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b001110: begin   // xori
                op_xor = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[3] = 1'b1; // imm_zero_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b001111: begin   // lui
                op_lui = 1'b1;
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b001010: begin   // slti
                op_slt = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b001011: begin   // sltiu
                op_sltu = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
        default: begin
            //跳转指令初始化
            br_addr = 32'b0;

            //跳转指令默认值
            br_e = 1'b1;
            data_ram_en = 1'b0;
            data_ram_wen = 4'b0;
            rf_we = 1'b0;
            sel_rf_res = 1'b0;
        case(opcode) //跳转指令
            6'b000001: begin // bltz, bgez
                case(rt)
                    5'b00000: begin // bltz
                        use_data1 = 1'b1;
                        br_e = ($signed(data1) < 0);
                        br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
                    end
                    5'b00001: begin // bgez
                        use_data1 = 1'b1;
                        br_e = ($signed(data1) >= 0);
                        br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
                    end
                    5'b10000: begin // bltzal
                        rf_we = 1'b1;
                        op_add = 1'b1;
                        sel_alu_src1[1] = 1'b1; // pc
                        sel_alu_src2[2] = 1'b1; // 32'b8
                        sel_rf_dst[2] = 1'b1;   // $31
                        use_data1 = 1'b1;
                        br_e = ($signed(data1) < 0);
                        br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
                    end
                    5'b10001: begin // bgezal
                        rf_we = 1'b1;
                        op_add = 1'b1;
                        sel_alu_src1[1] = 1'b1; // pc
                        sel_alu_src2[2] = 1'b1; // 32'b8
                        sel_rf_dst[2] = 1'b1;   // $31
                        use_data1 = 1'b1;
                        br_e = ($signed(data1) >= 0);
                        br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
                    end
                    default: begin
                        //理应永不到达
                        br_e = 1'b0;
                        br_addr = 32'b0;
                    end
                endcase
            end
            6'b000010: begin  // j
                br_addr = {id_pc[31:28], instr_index, 2'b00};
            end
            6'b000011: begin  // jal
                rf_we = 1'b1;
                op_add = 1'b1;
                sel_alu_src1[1] = 1'b1; // pc
                sel_alu_src2[2] = 1'b1; // 32'b8
                sel_rf_dst[2] = 1'b1;   // $31
                br_addr = {id_pc[31:28], instr_index, 2'b00};
            end
            6'b000100: begin  // beq
                use_data1 = 1'b1;
                use_data2 = 1'b1;
                br_e = (data1 == data2);
                br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
            end
            6'b000101: begin  // bne
                use_data1 = 1'b1;
                use_data2 = 1'b1;
                br_e = (data1 != data2);
                br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
            end
            6'b000110: begin  // blez
                use_data1 = 1'b1;
                br_e = ($signed(data1) <= 0);
                br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
            end
            6'b000111: begin  // bgtz
                use_data1 = 1'b1;
                br_e = ($signed(data1) > 0);
                br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
            end
        default: begin
            //读存指令默认值
            br_e = 1'b0;
            br_addr = 32'b0;
            data_ram_en = 1'b1;
            data_ram_wen = 4'b0;
            rf_we = 1'b1;
            sel_rf_res = 1'b1;
        case(opcode) //读存指令
            6'b100000: begin  //lb
                inst_lb = 1'b1;
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b100100: begin  //lbu
                inst_lbu = 1'b1;
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b100001: begin  //lh
                inst_lh = 1'b1;
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b100101: begin  //lhu
                inst_lhu = 1'b1;
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
            6'b100011: begin  //lw
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
                sel_rf_dst[1] = 1'b1;   // rt
            end
        default: begin
            //写存指令初始化
            data_ram_wen = 4'b0;
            //写存指令默认值
            br_e = 1'b0;
            br_addr = 32'b0;
            data_ram_en = 1'b1;
            rf_we = 1'b0;
            sel_rf_res = 1'b0;
        case(opcode) //写存指令
            6'b101000: begin  //sb
                inst_sb = 1'b1;
                data_ram_wen = 4'b1111;
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
            end
            6'b101001: begin  //sh
                inst_sh = 1'b1;
                data_ram_wen = 4'b1111;
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
            end
            6'b101011: begin  //sw
                data_ram_wen = 4'b1111;
                op_add = 1'b1;
                sel_alu_src1[0] = 1'b1; // rs
                sel_alu_src2[1] = 1'b1; // imm_sign_extend
            end
        endcase end endcase end endcase end endcase
    end

    assign alu_op = {op_add, op_sub, op_slt, op_sltu,
                     op_and, op_nor, op_or, op_xor,
                     op_sll, op_srl, op_sra, op_lui};

    // sel for regfile address
    assign rf_waddr = {5{sel_rf_dst[0]}} & rd 
                    | {5{sel_rf_dst[1]}} & rt
                    | {5{sel_rf_dst[2]}} & 5'd31;


    assign id_to_ex_bus = {
        inst_sb, inst_sh,  // 236:235
        inst_lb, inst_lbu, inst_lh, inst_lhu, // 234:231
        lo_data, hi_data,  // 230:167
        lo_we, hi_we,      // 166:165
        inst_mul, inst_mulu, inst_div, inst_divu, // 164 :161
        id_pc,             // 160:129
        inst,              // 128:97
        alu_op,            // 96:85
        sel_alu_src1,      // 84:80
        sel_alu_src2,      // 79:76
        data_ram_en,       // 75
        data_ram_wen,      // 74:71
        rf_we,             // 70
        rf_waddr,          // 69:65
        sel_rf_res,        // 64
        data1,             // 63:32
        data2              // 31:0
    };

    assign br_bus = {
        br_e,
        br_addr
    };
    


endmodule