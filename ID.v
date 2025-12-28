`include "lib/defines.vh"
module ID(
    input wire clk,
    input wire rst,
    input wire flush,
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
    wire adel_if;

    reg is_in_delayslot;
    reg delay_slot_r;

    // Branch flags need to be declared before use in the pipeline register
    reg br_e;
    reg [31:0] br_addr;

    wire wb_rf_we;  //写寄存器使能
    wire [4:0] wb_rf_waddr;
    wire [31:0] wb_rf_wdata;

    wire wb_lo_we, wb_hi_we;
    wire [31:0] lo_wdata, hi_wdata;

    always @ (posedge clk) begin
        if (rst || flush) begin
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;        
            delay_slot_r   <= 1'b0;
        end
        else if (stall[1]==`Stop && stall[2]==`NoStop) begin
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;
            delay_slot_r   <= 1'b0;
        end
        else if (stall[1]==`NoStop) begin
            if_to_id_bus_r <= if_to_id_bus;
            delay_slot_r   <= br_e; // 当前指令为分支，则下一条为延迟槽
        end
    end
    
    assign inst = inst_sram_rdata;
    assign {
        adel_if,
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
    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;

    reg cp0_re, cp0_we;
    reg [4:0] cp0_addr;
    reg [2:0] cp0_sel;
    reg ov_en;


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

    reg [4:0] excepttype;
    reg [31:0] badvaddr;

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

    assign imm_sign_extend = {{16{imm[15]}},imm[15:0]};
    assign imm_zero_extend = {16'b0, imm[15:0]};
    assign sa_zero_extend  = {27'b0, sa};

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


    wire ex_to_mem_lwe = ex_to_mem_bus[44];
    wire [31:0] ex_to_mem_lwdata = ex_to_mem_bus[76:45];
    wire ex_to_mem_hwe = ex_to_mem_bus[77];
    wire [31:0] ex_to_mem_hwdata = ex_to_mem_bus[109:78];
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

    // Debug the first handler fetch to confirm the instruction value
    always @(posedge clk) begin
        if (!rst && id_pc==32'hbfc0_0380) begin
            $display("[ID][%t] pc=%h inst=%h ce=%b", $time, id_pc, inst, ce);
        end
    end

    //读存停顿
    reg use_data1, use_data2;   //跳转指令使用，计算指令可通过sel_alu_src判断

    assign stallreq_for_load = ex_to_mem_load && 
                               ((use_data1 || sel_alu_src1[0]) && (ex_to_mem_rwaddr==rs) ||
                                (use_data2 || sel_alu_src2[0]) && (ex_to_mem_rwaddr==rt));
    assign stallreq = 1'b0;
 
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
        // 初始化
        sel_alu_src1 = 5'b0;
        sel_alu_src2 = 4'b0;
        sel_rf_dst   = 3'b0;
        {op_add, op_sub, op_slt, op_sltu,
         op_and, op_nor, op_or, op_xor,
         op_sll, op_srl, op_sra, op_lui} = 12'b0;
        {inst_mul, inst_mulu, inst_div, inst_divu} = 4'b0;
        {lo_we, hi_we} = 2'b0;
        {inst_lb, inst_lbu, inst_lh, inst_lhu} = 4'b0;
        {inst_sb, inst_sh} = 2'b0;
        cp0_re = 1'b0;
        cp0_we = 1'b0;
        cp0_addr = rd;
        cp0_sel  = sel;
        ov_en = 1'b0;
        rf_we = 1'b0;
        sel_rf_res = 1'b0;
        data_ram_en = 1'b0;
        data_ram_wen = 4'b0;
        br_e = 1'b0;
        br_addr = 32'b0;
        excepttype = 5'b0;
        badvaddr = 32'b0;
        use_data1 = 1'b0;
        use_data2 = 1'b0;
        is_in_delayslot = delay_slot_r;

        // 取指异常
        if (adel_if) begin
            excepttype = `EXC_ADEL;
            badvaddr = id_pc;
        end

        if (ce && excepttype==5'b0) begin
            case(opcode)
                6'b000000: begin
                    case(func)
                        6'b100000: begin // add
                            op_add = 1'b1; ov_en = 1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b100001: begin // addu
                            op_add = 1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b100010: begin // sub
                            op_sub = 1'b1; ov_en = 1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b100011: begin // subu
                            op_sub = 1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b010000: begin // mfhi
                            op_add = 1'b1; sel_alu_src1[4]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b010001: begin // mthi
                            hi_we = 1'b1; sel_alu_src1[0]=1'b1;
                        end
                        6'b010010: begin // mflo
                            op_add = 1'b1; sel_alu_src1[3]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b010011: begin // mtlo
                            lo_we = 1'b1; sel_alu_src1[0]=1'b1;
                        end
                        6'b011010: begin // div
                            lo_we=1'b1; hi_we=1'b1; inst_div=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1;
                        end
                        6'b011011: begin // divu
                            lo_we=1'b1; hi_we=1'b1; inst_divu=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1;
                        end
                        6'b011000: begin // mul
                            lo_we=1'b1; hi_we=1'b1; inst_mul=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1;
                        end
                        6'b011001: begin // mulu
                            lo_we=1'b1; hi_we=1'b1; inst_mulu=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1;
                        end
                        6'b100100: begin // and
                            op_and=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b100101: begin // or
                            op_or=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b100110: begin // xor
                            op_xor=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b100111: begin // nor
                            op_nor=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b101010: begin // slt
                            op_slt=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b101011: begin // sltu
                            op_sltu=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b000000: begin // sll
                            op_sll=1'b1; sel_alu_src1[2]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b000010: begin // srl
                            op_srl=1'b1; sel_alu_src1[2]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b000011: begin // sra
                            op_sra=1'b1; sel_alu_src1[2]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b000100: begin // sllv
                            op_sll=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b000110: begin // srlv
                            op_srl=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b000111: begin // srav
                            op_sra=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[0]=1'b1; sel_rf_dst[0]=1'b1; rf_we=1'b1;
                        end
                        6'b001000: begin // jr
                            br_e = 1'b1; br_addr = data1;
                        end
                        6'b001001: begin // jalr
                            rf_we=1'b1; op_add=1'b1; sel_alu_src1[1]=1'b1; sel_alu_src2[2]=1'b1; sel_rf_dst[0]=1'b1; br_e=1'b1; br_addr=data1;
                        end
                        6'b001100: begin // syscall
                            excepttype = `EXC_SYS;
                        end
                        6'b001101: begin // break
                            excepttype = `EXC_BP;
                        end
                        default: begin
                            excepttype = `EXC_RI;
                        end
                    endcase
                end
                6'b001000: begin // addi
                    op_add=1'b1; ov_en=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                end
                6'b001001: begin // addiu
                    op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                end
                6'b001100: begin // andi
                    op_and=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[3]=1'b1; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                end
                6'b001101: begin // ori
                    op_or=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[3]=1'b1; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                end
                6'b001110: begin // xori
                    op_xor=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[3]=1'b1; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                end
                6'b001111: begin // lui
                    op_lui=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                end
                6'b001010: begin // slti
                    op_slt=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                end
                6'b001011: begin // sltiu
                    op_sltu=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                end
                6'b000001: begin // bltz/bgez
                    use_data1=1'b1;
                    case(rt)
                        5'b00000: begin br_e=($signed(data1)<0); end
                        5'b00001: begin br_e=($signed(data1)>=0); end
                        5'b10000: begin br_e=($signed(data1)<0); rf_we=1'b1; op_add=1'b1; sel_alu_src1[1]=1'b1; sel_alu_src2[2]=1'b1; sel_rf_dst[2]=1'b1; end
                        5'b10001: begin br_e=($signed(data1)>=0); rf_we=1'b1; op_add=1'b1; sel_alu_src1[1]=1'b1; sel_alu_src2[2]=1'b1; sel_rf_dst[2]=1'b1; end
                        default: br_e=1'b0;
                    endcase
                    br_addr = id_pc + 4 + {{14{imm[15]}}, imm, 2'b00};
                end
                6'b000010: begin br_e=1'b1; br_addr={id_pc[31:28], instr_index, 2'b00}; end // j
                6'b000011: begin br_e=1'b1; br_addr={id_pc[31:28], instr_index, 2'b00}; rf_we=1'b1; op_add=1'b1; sel_alu_src1[1]=1'b1; sel_alu_src2[2]=1'b1; sel_rf_dst[2]=1'b1; end // jal
                6'b000100: begin use_data1=1'b1; use_data2=1'b1; br_e=(data1==data2); br_addr=id_pc+4+{{14{imm[15]}},imm,2'b00}; end // beq
                6'b000101: begin use_data1=1'b1; use_data2=1'b1; br_e=(data1!=data2); br_addr=id_pc+4+{{14{imm[15]}},imm,2'b00}; end // bne
                6'b000110: begin use_data1=1'b1; br_e=($signed(data1)<=0); br_addr=id_pc+4+{{14{imm[15]}},imm,2'b00}; end // blez
                6'b000111: begin use_data1=1'b1; br_e=($signed(data1)>0); br_addr=id_pc+4+{{14{imm[15]}},imm,2'b00}; end // bgtz
                6'b100000: begin // lb
                    inst_lb=1'b1; data_ram_en=1'b1; sel_rf_res=1'b1; rf_we=1'b1; op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1;
                end
                6'b100100: begin // lbu
                    inst_lbu=1'b1; data_ram_en=1'b1; sel_rf_res=1'b1; rf_we=1'b1; op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1;
                end
                6'b100001: begin // lh
                    inst_lh=1'b1; data_ram_en=1'b1; sel_rf_res=1'b1; rf_we=1'b1; op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1;
                end
                6'b100101: begin // lhu
                    inst_lhu=1'b1; data_ram_en=1'b1; sel_rf_res=1'b1; rf_we=1'b1; op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1;
                end
                6'b100011: begin // lw
                    data_ram_en=1'b1; sel_rf_res=1'b1; rf_we=1'b1; op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1; sel_rf_dst[1]=1'b1;
                end
                6'b101000: begin // sb
                    inst_sb=1'b1; data_ram_en=1'b1; data_ram_wen=4'b1111; op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1;
                end
                6'b101001: begin // sh
                    inst_sh=1'b1; data_ram_en=1'b1; data_ram_wen=4'b1111; op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1;
                end
                6'b101011: begin // sw
                    data_ram_en=1'b1; data_ram_wen=4'b1111; op_add=1'b1; sel_alu_src1[0]=1'b1; sel_alu_src2[1]=1'b1;
                end
                6'b010000: begin // COP0
                    case(rs)
                        5'b00000: begin // mfc0
                            cp0_re=1'b1; cp0_we=1'b0; sel_rf_dst[1]=1'b1; rf_we=1'b1;
                        end
                        5'b00100: begin // mtc0
                            cp0_we=1'b1; cp0_re=1'b0;
                        end
                        5'b10000: begin // eret
                            if (inst[5:0]==6'b011000) begin
                                excepttype = `EXC_ERET;
                            end else begin
                                excepttype = `EXC_RI;
                            end
                        end
                        default: begin
                            excepttype = `EXC_RI;
                        end
                    endcase
                end
                default: begin
                    excepttype = `EXC_RI;
                end
            endcase
        end

        // 分支立即数的使用标记
        if (br_e) begin
            // nothing else
        end
    end

    assign alu_op = {op_add, op_sub, op_slt, op_sltu,
                     op_and, op_nor, op_or, op_xor,
                     op_sll, op_srl, op_sra, op_lui};

    // sel for regfile address
    assign rf_waddr = {5{sel_rf_dst[0]}} & rd 
                    | {5{sel_rf_dst[1]}} & rt
                    | {5{sel_rf_dst[2]}} & 5'd31;


    assign id_to_ex_bus = {
        ov_en,             //349
        data2,             //348:317
        data1,             //316:285
        sel_rf_res,        //284
        rf_waddr,          //283:279
        rf_we,             //278
        data_ram_wen,      //277:274
        data_ram_en,       //273
        sel_alu_src2,      //272:269
        sel_alu_src1,      //268:264
        alu_op,            //263:252
        id_pc,             //251:220
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
        badvaddr,          //133:102
        is_in_delayslot,   //101
        excepttype,        //100:96
        sa_zero_extend,    //95:64
        imm_zero_extend,   //63:32
        imm_sign_extend    //31:0
    };

    assign br_bus = {
        br_e,
        br_addr
    };
    


endmodule