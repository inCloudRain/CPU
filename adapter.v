`include "lib/defines.vh"

module adapter(
	input  wire        clk,
	input  wire        resetn,

	// Instruction SRAM-like interface
	input  wire        inst_sram_en,
	input  wire [3:0]  inst_sram_wen,
	input  wire [31:0] inst_sram_addr,
	input  wire [31:0] inst_sram_wdata,
	output reg  [31:0] inst_sram_rdata,

	// Data SRAM-like interface
	input  wire        data_sram_en,
	input  wire [3:0]  data_sram_wen,
	input  wire [31:0] data_sram_addr,
	input  wire [31:0] data_sram_wdata,
	output reg  [31:0] data_sram_rdata,

	output wire        stallreq_for_axi,

	// AXI master interface
	output wire [3:0]  arid,
	output wire  [31:0] araddr,
	output wire [3:0]  arlen,
	output wire [2:0]  arsize,
	output wire [1:0]  arburst,
	output wire [1:0]  arlock,
	output wire [3:0]  arcache,
	output wire [2:0]  arprot,
	output reg         arvalid,
	input  wire        arready,
	input  wire [3:0]  rid,
	input  wire [31:0] rdata,
	input  wire [1:0]  rresp,
	input  wire        rlast,
	input  wire        rvalid,
	output reg         rready,

	output wire [3:0]  awid,
	output reg  [31:0] awaddr,
	output wire [3:0]  awlen,
	output wire [2:0]  awsize,
	output wire [1:0]  awburst,
	output wire [1:0]  awlock,
	output wire [3:0]  awcache,
	output wire [2:0]  awprot,
	output reg         awvalid,
	input  wire        awready,

	output wire [3:0]  wid,
	output reg  [31:0] wdata,
	output reg  [3:0]  wstrb,
	output wire        wlast,
	output reg         wvalid,
	input  wire        wready,

	input  wire [3:0]  bid,
	input  wire [1:0]  bresp,
	input  wire        bvalid,
	output reg         bready
);

	localparam ST_IDLE  = 3'd0;
	localparam ST_AR    = 3'd1;
	localparam ST_R     = 3'd2;
	localparam ST_WRITE = 3'd3;
	localparam ST_B     = 3'd4;
	localparam ST_GET   = 3'd5;

	reg [2:0]  state;
	reg        cur_is_inst;

	wire data_write_req = data_sram_en && |data_sram_wen;
	wire data_read_req  = data_sram_en && ~|data_sram_wen;
	wire inst_read_req  = inst_sram_en && ~|inst_sram_wen;

	reg to_write_data, to_read_data, to_read_inst;
	reg [31:0] inst_addr, data_addr;

	assign araddr  = cur_is_inst ? inst_addr : data_addr;

	assign arid    = 4'd0;
	assign arlen   = 4'd0;
	assign arsize  = 3'd2;    // 4-byte beats
	assign arburst = 2'b01;   // INCR
	assign arlock  = 2'b00;
	assign arcache = 4'd0;
	assign arprot  = 3'd0;

	assign awid    = 4'd0;
	assign awlen   = 4'd0;
	assign awsize  = 3'd2;
	assign awburst = 2'b01;
	assign awlock  = 2'b00;
	assign awcache = 4'd0;
	assign awprot  = 3'd0;

	assign wid     = 4'd0;
	assign wlast   = wvalid;

	assign stallreq_for_axi = to_write_data || to_read_data || to_read_inst;

	always @(posedge clk) begin
		if (!resetn) begin
			state           = ST_IDLE;
			cur_is_inst     = 1'b0;
			inst_addr          = 32'b0;
			data_addr          = 32'b0;
			arvalid         = 1'b0;
			rready          = 1'b0;
			awaddr          = 32'b0;
			awvalid         = 1'b0;
			wdata           = 32'b0;
			wstrb           = 4'b0;
			wvalid          = 1'b0;
			bready          = 1'b0;
			inst_sram_rdata = 32'b0;
			data_sram_rdata = 32'b0;
			to_write_data	= 1'b0;
			to_read_data	= 1'b0;
			to_read_inst	= 1'b0;
		end else begin
			case (state)
				ST_IDLE: begin
					arvalid = 1'b0;
					rready  = 1'b0;
					awvalid = 1'b0;
					wvalid  = 1'b0;
					bready  = 1'b0;
					if(~to_write_data && ~to_read_data && ~to_read_inst) begin
						to_write_data	= data_write_req;
						to_read_data	= data_read_req;
						to_read_inst	= inst_read_req;
						data_addr       = data_sram_addr;
						inst_addr       = inst_sram_addr;
					end
					if (to_write_data) begin
						cur_is_inst = 1'b0;
						awaddr      = data_sram_addr;
						wdata       = data_sram_wdata;
						wstrb       = data_sram_wen;
						awvalid     = 1'b1;
						wvalid      = 1'b1;
						state       = ST_WRITE;
					end else if (to_read_data) begin
						cur_is_inst = 1'b0;
						arvalid     = 1'b1;
						state       = ST_AR;
					end else if (to_read_inst) begin
						cur_is_inst = 1'b1;
						arvalid     = 1'b1;
						state       = ST_AR;
					end else begin
						state = ST_IDLE;
					end
				end
				ST_AR: begin
					if (arvalid && arready) begin
						arvalid = 1'b0;
						rready  = 1'b1;
						state   = ST_R;
					end
				end
				ST_R: begin
					if (rvalid && rready) begin
						if (cur_is_inst) begin
							inst_sram_rdata = rdata;
						end else begin
							data_sram_rdata = rdata;
						end
						if (rlast) begin
							rready = 1'b0;
							to_read_data = ~cur_is_inst ? 1'b0 : to_read_data;
							to_read_inst = cur_is_inst ? 1'b0 : to_read_inst;
							state  = ST_IDLE;
						end
					end
				end
				ST_WRITE: begin
					if (awvalid && awready) begin
						awvalid = 1'b0;
					end
					if (wvalid && wready) begin
						wvalid = 1'b0;
					end
					if (!awvalid && !wvalid) begin
						bready = 1'b1;
						state  = ST_B;
					end
				end
				ST_B: begin
					if (bvalid && bready) begin
						bready = 1'b0;
						to_write_data = 1'b0;
						state  = ST_IDLE;
					end
				end
				default: begin
					state = ST_IDLE;
				end
			endcase
		end
	end

endmodule
