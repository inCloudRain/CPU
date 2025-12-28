`define IF_TO_ID_WD 34
`define ID_TO_EX_WD 350
`define EX_TO_MEM_WD 229
`define MEM_TO_WB_WD 174
`define BR_WD 33
`define DATA_SRAM_WD 69
`define WB_TO_RF_WD 104

`define StallBus 6
`define NoStop 1'b0
`define Stop 1'b1

`define ZeroWord 32'b0

// Exception codes (match A03 spec)
// Use a non-zero internal code for interrupts so they propagate through
// the pipeline control logic (the CP0 will still report ExcCode=0).
`define EXC_INT   5'h10
`define EXC_ADEL  5'h04
`define EXC_ADES  5'h05
`define EXC_SYS   5'h08
`define EXC_BP    5'h09
`define EXC_RI    5'h0a
`define EXC_OV    5'h0c
`define EXC_TR    5'h0d
`define EXC_ERET  5'h1f


//除法div
`define DivFree 2'b00
`define DivByZero 2'b01
`define DivOn 2'b10
`define DivEnd 2'b11
`define DivResultReady 1'b1
`define DivResultNotReady 1'b0
`define DivStart 1'b1
`define DivStop 1'b0

// CP0 register select encodings
`define CP0_INDEX     5'd0
`define CP0_BADVADDR  5'd8
`define CP0_COUNT     5'd9
`define CP0_COMPARE   5'd11
`define CP0_STATUS    5'd12
`define CP0_CAUSE     5'd13
`define CP0_EPC       5'd14
`define CP0_CONFIG    5'd16