`include "defines.vh"
module cp0(
    input  wire        clk,
    input  wire        rst,

    // write by mtc0
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [2:0]  wsel,
    input  wire [31:0] wdata,

    // read by mfc0
    input  wire [4:0]  raddr,
    input  wire [2:0]  rsel,
    output reg  [31:0] rdata,

    // exception interface
    input  wire [4:0]  excepttype_i,
    input  wire        is_in_delayslot_i,
    input  wire [31:0] current_inst_addr_i,
    input  wire [31:0] badvaddr_i,

    input  wire [5:0]  ext_int_i,
    input  wire        timer_int_i,

    output reg  [31:0] count_o,
    output reg  [31:0] compare_o,
    output reg  [31:0] status_o,
    output reg  [31:0] cause_o,
    output reg  [31:0] epc_o,
    output reg  [31:0] badvaddr_o,
    output wire        timer_int_o
);

    wire [7:0] im_mask;
    wire       exl;

    assign im_mask = status_o[15:8] | status_o[7:0];
    assign exl     = status_o[1];

    // Count / Compare / TI
    always @(posedge clk) begin
        if (rst) begin
            count_o <= 32'b0;
        end else begin
            count_o <= count_o + 1'b1;
        end
    end

    wire set_ti = (compare_o != 32'b0) && (count_o == compare_o);
    assign timer_int_o = set_ti;

    // Map the internal interrupt code back to ExcCode=0 when updating CAUSE
    wire [4:0] cause_code = (excepttype_i == `EXC_INT) ? 5'b0 : excepttype_i;

    // registers write by mtc0
    always @(posedge clk) begin
        if (rst) begin
            compare_o   <= 32'b0;
            status_o    <= 32'h0040_0000; // BEV=1 default high bits cleared
            cause_o     <= 32'b0;
            epc_o       <= 32'b0;
            badvaddr_o  <= 32'b0;
        end else begin
            // TI sticky until compare written or status EXL change by exception handling
            if (set_ti) begin
                cause_o[30] <= 1'b1;
            end

            if (we) begin
                case (waddr)
                    `CP0_COUNT:   count_o   <= wdata;
                    `CP0_COMPARE: begin
                        compare_o    <= wdata;
                        cause_o[30]  <= 1'b0; // clear TI on write compare
                    end
                    `CP0_STATUS:  status_o  <= wdata;
                    `CP0_EPC:     epc_o     <= wdata;
                    `CP0_CAUSE:   cause_o[9:8] <= wdata[9:8]; // software int
                    `CP0_BADVADDR: badvaddr_o <= wdata;
                    default: ;
                endcase
                $display("[CP0][%t] mtc0 waddr=%0d wsel=%0d wdata=%h status=%h compare=%h count=%h", $time, waddr, wsel, wdata, status_o, compare_o, count_o);
            end

            // external interrupt pending bits
            cause_o[15:10] <= {timer_int_i, ext_int_i[4:0]};
            cause_o[23]    <= 1'b0; // CE

            // exception handling side effects
            if (excepttype_i != 5'b0 && excepttype_i != `EXC_ERET) begin
                status_o[1]   <= 1'b1;  // set EXL
                cause_o[6:2]  <= cause_code;
                cause_o[31]   <= is_in_delayslot_i;
                cause_o[30]   <= (excepttype_i == `EXC_INT) ? 1'b0 : cause_o[30];
                epc_o         <= is_in_delayslot_i ? (current_inst_addr_i - 32'd4) : current_inst_addr_i;
                if (excepttype_i==`EXC_ADEL || excepttype_i==`EXC_ADES)
                    badvaddr_o <= badvaddr_i;
            end else if (excepttype_i == `EXC_ERET) begin
                status_o[1] <= 1'b0; // clear EXL
            end
        end
    end

    wire [31:0] badvaddr_rdata = (excepttype_i==`EXC_ADEL || excepttype_i==`EXC_ADES) ? badvaddr_i : badvaddr_o;

    // read mux
    always @(*) begin
        case (raddr)
            `CP0_COUNT:   rdata = count_o;
            `CP0_COMPARE: rdata = compare_o;
            `CP0_STATUS:  rdata = status_o;
            `CP0_CAUSE:   rdata = cause_o;
            `CP0_EPC:     rdata = epc_o;
            `CP0_BADVADDR:rdata = badvaddr_rdata;
            `CP0_CONFIG:  rdata = 32'h0000_0001; // default config
            default:      rdata = 32'b0;
        endcase
    end

endmodule
