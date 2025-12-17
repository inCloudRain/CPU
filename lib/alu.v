`include "defines.vh"
module alu(
    input wire [11:0] alu_control,
    input wire [31:0] alu_src1,
    input wire [31:0] alu_src2,
    output wire [31:0] alu_result
);

    wire op_add;
    wire op_sub;
    wire op_slt;
    wire op_sltu;
    wire op_and;
    wire op_nor;
    wire op_or;
    wire op_xor;
    wire op_sll;
    wire op_srl;
    wire op_sra;
    wire op_lui;

    assign {op_add, op_sub, op_slt, op_sltu,
            op_and, op_nor, op_or, op_xor,
            op_sll, op_srl, op_sra, op_lui} = alu_control;
    
    wire [31:0] add_sub_result;
    wire [31:0] slt_result;
    wire [31:0] sltu_result;
    wire [31:0] and_result;
    wire [31:0] nor_result;
    wire [31:0] or_result;
    wire [31:0] xor_result;
    wire [31:0] sll_result;
    wire [31:0] srl_result;
    wire [31:0] sra_result;
    wire [31:0] lui_result;

    assign and_result = alu_src1 & alu_src2;
    assign or_result = alu_src1 | alu_src2;
    assign nor_result = ~or_result;
    assign xor_result = alu_src1 ^ alu_src2;
    assign lui_result = {alu_src2[15:0], 16'b0};

    wire [31:0] adder_a;
    wire [31:0] adder_b;
    wire        adder_cin;
    wire [31:0] adder_result;
    wire        adder_cout;

    assign adder_a = alu_src1;
    assign adder_b = (op_sub | op_slt | op_sltu) ? ~alu_src2 : alu_src2;
    assign adder_cin = (op_sub | op_slt | op_sltu) ? 1'b1 : 1'b0;
    assign {adder_cout, adder_result} = adder_a + adder_b + adder_cin;

    assign add_sub_result = adder_result;

    assign slt_result[31:1] = 31'b0;
    assign slt_result[0] = (alu_src1[31] & ~alu_src2[31]) 
                         | (~(alu_src1[31]^alu_src2[31]) & adder_result[31]);
    
    assign sltu_result[31:1] = 31'b0;
    assign sltu_result[0] = ~adder_cout;

    assign sll_result = alu_src2 << alu_src1[4:0];
    assign srl_result = alu_src2 >> alu_src1[4:0];
    assign sra_result = ($signed(alu_src2)) >>> alu_src1[4:0];

    reg [31:0] result_reg;
    always @(*) begin
        case (1'b1)
            op_add:     result_reg = add_sub_result;
            op_sub:     result_reg = add_sub_result;
            op_slt:     result_reg = slt_result;
            op_sltu:    result_reg = sltu_result;
            op_and:     result_reg = and_result;
            op_nor:     result_reg = nor_result;
            op_or:      result_reg = or_result;
            op_xor:     result_reg = xor_result;
            op_sll:     result_reg = sll_result;
            op_srl:     result_reg = srl_result;
            op_sra:     result_reg = sra_result;
            op_lui:     result_reg = lui_result;
            default:    result_reg = 32'b0;
        endcase
    end
    assign alu_result = result_reg;
endmodule