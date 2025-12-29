`include "lib/defines.vh"
module mycpu_core(
    input wire clk,
    input wire rst,
    input wire [5:0] int,

    output wire inst_sram_en,
    output wire [3:0] inst_sram_wen,
    output wire [31:0] inst_sram_addr,
    output wire [31:0] inst_sram_wdata,
    input wire [31:0] inst_sram_rdata,

    output wire data_sram_en,
    output wire [3:0] data_sram_wen,
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata,
    input wire [31:0] data_sram_rdata,

    output wire [31:0] debug_wb_pc,
    output wire [3:0] debug_wb_rf_wen,
    output wire [4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata
);
    wire [`IF_TO_ID_WD-1:0]  if_to_id_bus;
    wire [`ID_TO_EX_WD-1:0]  id_to_ex_bus;
    wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus;
    wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus;
    wire [`BR_WD-1:0]        br_bus;
    wire [`WB_TO_RF_WD-1:0]  wb_to_rf_bus;

    // Data-side signals are driven by EX

    wire [`StallBus-1:0] stall;
    wire stallreq_for_load;
    wire stallreq_for_ex;

    wire flush;
    wire [31:0] new_pc;

    // CP0 interface
    wire        cp0_we;
    wire [4:0]  cp0_waddr;
    wire [2:0]  cp0_wsel;
    wire [31:0] cp0_wdata;
    wire [4:0]  cp0_raddr;
    wire [2:0]  cp0_rsel;
    wire [31:0] cp0_rdata;
    wire [31:0] cp0_status;
    wire [31:0] cp0_cause;
    wire [31:0] cp0_epc;
    wire [31:0] cp0_badvaddr;
    wire [31:0] cp0_count;
    wire [31:0] cp0_compare;
    wire        timer_int;

    IF u_IF(
        .clk            (clk            ),
        .rst            (rst            ),
        .stall          (stall          ),
        .flush          (flush          ),
        .new_pc         (new_pc         ),
        .br_bus         (br_bus         ),
        .if_to_id_bus   (if_to_id_bus   ),
        .inst_sram_en   (inst_sram_en   ),
        .inst_sram_wen  (inst_sram_wen  ),
        .inst_sram_addr (inst_sram_addr ),
        .inst_sram_wdata(inst_sram_wdata)
    );

    ID u_ID(
        .clk             (clk             ),
        .rst             (rst             ),
        .flush           (flush           ),
        .stall           (stall           ),
        .if_to_id_bus    (if_to_id_bus    ),
        .inst_sram_rdata (inst_sram_rdata ),
        .wb_to_rf_bus    (wb_to_rf_bus    ),
        .ex_to_mem_bus   (ex_to_mem_bus   ),
        .mem_to_wb_bus   (mem_to_wb_bus   ),
        .id_to_ex_bus    (id_to_ex_bus    ),
        .br_bus          (br_bus          ),
        .stallreq_for_load(stallreq_for_load)
    );

    EX u_EX(
        .clk             (clk             ),
        .rst             (rst             ),
        .flush           (flush           ),
        .stall           (stall           ),
        .id_to_ex_bus    (id_to_ex_bus    ),
        .ex_to_mem_bus   (ex_to_mem_bus   ),
        .cp0_rdata       (cp0_rdata       ),
        .cp0_raddr       (cp0_raddr       ),
        .cp0_rsel        (cp0_rsel        ),
        .data_sram_en    (data_sram_en     ),
        .data_sram_wen   (data_sram_wen    ),
        .data_sram_addr  (data_sram_addr   ),
        .data_sram_wdata (data_sram_wdata  ),
        .stallreq_for_ex (stallreq_for_ex )
    );

    MEM u_MEM(
        .clk             (clk             ),
        .rst             (rst             ),
        .stall           (stall           ),
        .ex_to_mem_bus   (ex_to_mem_bus   ),
        .data_sram_rdata (data_sram_rdata ),
        .cp0_status      (cp0_status      ),
        .cp0_cause       (cp0_cause       ),
        .cp0_epc         (cp0_epc         ),
        .flush           (flush           ),
        .new_pc          (new_pc          ),
        .cp0_we          (cp0_we          ),
        .cp0_waddr       (cp0_waddr       ),
        .cp0_wsel        (cp0_wsel        ),
        .cp0_wdata       (cp0_wdata       ),
        .mem_to_wb_bus   (mem_to_wb_bus   )
    );

    WB u_WB(
        .clk               (clk               ),
        .rst               (rst               ),
        .stall             (stall             ),
        .mem_to_wb_bus     (mem_to_wb_bus     ),
        .wb_to_rf_bus      (wb_to_rf_bus      ),
        .debug_wb_pc       (debug_wb_pc       ),
        .debug_wb_rf_wen   (debug_wb_rf_wen   ),
        .debug_wb_rf_wnum  (debug_wb_rf_wnum  ),
        .debug_wb_rf_wdata (debug_wb_rf_wdata )
    );

    CTRL u_CTRL(
        .rst              (rst              ),
        .stallreq_for_ex  (stallreq_for_ex  ),
        .stallreq_for_load(stallreq_for_load),
        .stall            (stall            )
    );

    cp0 u_cp0(
        .clk                 (clk                 ),
        .rst                 (rst                 ),
        .we                  (cp0_we              ),
        .waddr               (cp0_waddr           ),
        .wsel                (cp0_wsel            ),
        .wdata               (cp0_wdata           ),
        .raddr               (cp0_raddr           ),
        .rsel                (cp0_rsel            ),
        .rdata               (cp0_rdata           ),
        .excepttype_i        (mem_to_wb_bus[140:136]),
        .is_in_delayslot_i   (mem_to_wb_bus[141]  ),
        .current_inst_addr_i (mem_to_wb_bus[69:38]),
        .badvaddr_i          (mem_to_wb_bus[173:142]),
        .ext_int_i           (int                 ),
        .count_o             (cp0_count           ),
        .compare_o           (cp0_compare         ),
        .status_o            (cp0_status          ),
        .cause_o             (cp0_cause           ),
        .epc_o               (cp0_epc             ),
        .badvaddr_o          (cp0_badvaddr        ),
        .timer_int_o         (timer_int           )
    );

endmodule
