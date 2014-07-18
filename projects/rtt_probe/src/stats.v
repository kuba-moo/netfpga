///////////////////////////////////////////////////////////////////////////////
// vim:set shiftwidth=3 softtabstop=3 expandtab:
// $Id: module_template 2008-03-13 gac1 $
//
// Module: module_template.v
// Project: NF2.1
// Description: defines a module for the user data path
//
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module stats
   #(
      parameter DATA_WIDTH = 64,
      parameter CTRL_WIDTH = DATA_WIDTH/8,
      parameter UDP_REG_SRC_WIDTH = 2
   )
   (
      input  [DATA_WIDTH-1:0]             in_data,
      input  [CTRL_WIDTH-1:0]             in_ctrl,
      input                               in_wr,
      output                              in_rdy,

      output [DATA_WIDTH-1:0]             out_data,
      output [CTRL_WIDTH-1:0]             out_ctrl,
      output                              out_wr,
      input                               out_rdy,

      // --- Register interface
      input                               reg_req_in,
      input                               reg_ack_in,
      input                               reg_rd_wr_L_in,
      input  [`UDP_REG_ADDR_WIDTH-1:0]    reg_addr_in,
      input  [`CPCI_NF2_DATA_WIDTH-1:0]   reg_data_in,
      input  [UDP_REG_SRC_WIDTH-1:0]      reg_src_in,

      output                              reg_req_out,
      output                              reg_ack_out,
      output                              reg_rd_wr_L_out,
      output  [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_out,
      output  [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_out,
      output  [UDP_REG_SRC_WIDTH-1:0]     reg_src_out,

      // misc
      input                                reset,
      input                                clk
   );

   // Define the log2 function
   `LOG2_FUNC

   //--------------------- Internal Parameter-------------------------
   localparam WAIT_HDRS      = 1;
   localparam DROP_TIMESTAMP = 2;
   localparam MAKE_SPACE_FOR_TX_TS = 512;
   localparam THRU           = 4;

   localparam SAVE_RX_TS     = 8;
   localparam SAVE_TX_TS     = 16;
   localparam WRITE_STAT     = 32;

   localparam RO_HDRS        = 64;
   localparam RO_DATA        = 128;
   localparam RO_END         = 256;

   //------------------------- Signals-------------------------------

   wire [DATA_WIDTH-1:0]         in_fifo_data;
   wire [CTRL_WIDTH-1:0]         in_fifo_ctrl;

   wire                          in_fifo_nearly_full;
   wire                          in_fifo_empty;

   reg                           in_fifo_rd_en;
   reg                           out_wr_int;
   reg [DATA_WIDTH-1:0] 	 out_data_int;
   reg [CTRL_WIDTH-1:0] 	 out_ctrl_int;

   wire [DATA_WIDTH-1:0] 	 header_wo_ts;
   wire [15:0] 			 pkt_byte_len_wo_ts;
   wire [15:0] 			 pkt_word_len_wo_ts;

   reg [9:0] 			 state;
   reg [9:0] 			 state_nxt;

   reg [31:0] 			 stat_rx_ts;
   reg [31:0] 			 stat_rx_ts_nxt;
   wire [31:0] 			 stat_tx_ts;

   wire [63:0] 			 stat_fifo_dout_p0;
   wire [63:0] 			 stat_fifo_dout_p1;
   wire [1:0] 			 stat_fifo_re;
   wire [1:0] 			 stat_fifo_we;
   wire [1:0]			 stat_fifo_full;
   wire [1:0]			 stat_fifo_empty;

   reg 	[1:0]			 stat_sel;
   reg 	[1:0]			 stat_sel_nxt;
   reg 				 stat_curr_re;
   reg 				 stat_curr_we;
   wire 			 stat_curr_full;
   wire 			 stat_curr_empty;

   reg [2:0] 			 reg_counters;
   reg [`CPCI_NF2_DATA_WIDTH-1:0] reg_marker;

   //------------------------- Local assignments -------------------------------

   assign in_rdy     = !in_fifo_nearly_full;
   assign out_wr     = out_wr_int;
   assign out_ctrl   = out_ctrl_int;
   assign out_data   = out_data_int;

   assign pkt_byte_len_wo_ts = in_fifo_data[`IOQ_BYTE_LEN_POS + 15:`IOQ_BYTE_LEN_POS] - 16;
   assign pkt_word_len_wo_ts = in_fifo_data[`IOQ_WORD_LEN_POS + 15:`IOQ_WORD_LEN_POS] - 2;
   assign header_wo_ts = {in_fifo_data[`IOQ_DST_PORT_POS + 15:`IOQ_DST_PORT_POS],
			  pkt_word_len_wo_ts,
			  in_fifo_data[`IOQ_SRC_PORT_POS + 15:`IOQ_SRC_PORT_POS],
			  pkt_byte_len_wo_ts};

   assign stat_fifo_re = {2{stat_curr_re}} & stat_sel;
   assign stat_fifo_we = {2{stat_curr_we}} & stat_sel;
   assign stat_curr_full = |(stat_fifo_full & stat_sel);
   assign stat_curr_empty = |(stat_fifo_empty & stat_sel);

   // @rx_ts is at the beginning of packet, so we need to save it
   // @tx_ts is at the end, so we just fire @stat_fifo_we at the right time
   assign stat_tx_ts = in_fifo_data[31:0];

   //------------------------- Modules-------------------------------

   fallthrough_small_fifo #(
      .WIDTH(CTRL_WIDTH+DATA_WIDTH),
      .MAX_DEPTH_BITS(2)
   ) input_fifo (
      .din           ({in_ctrl, in_data}),   // Data in
      .wr_en         (in_wr),                // Write enable
      .rd_en         (in_fifo_rd_en),        // Read the next word
      .dout          ({in_fifo_ctrl, in_fifo_data}),
      .full          (),
      .nearly_full   (in_fifo_nearly_full),
      .prog_full     (),
      .empty         (in_fifo_empty),
      .reset         (reset),
      .clk           (clk)
   );

   time_fifo stat_fifo_p0 (
      .din({stat_rx_ts,stat_tx_ts}),
      .rd_en(stat_fifo_re[0]),
      .dout(stat_fifo_dout_p0),
      .wr_en(stat_fifo_we[0]),

      .empty(stat_fifo_empty[0]),
      .full(stat_fifo_full[0]),

      .clk(clk));

   time_fifo stat_fifo_p1 (
      .din({stat_rx_ts,stat_tx_ts}),
      .rd_en(stat_fifo_re[1]),
      .dout(stat_fifo_dout_p1),
      .wr_en(stat_fifo_we[1]),

      .empty(stat_fifo_empty[1]),
      .full(stat_fifo_full[1]),

      .clk(clk));

   generic_regs
   #(
      .UDP_REG_SRC_WIDTH   (UDP_REG_SRC_WIDTH),
      .TAG                 (`STATS_BLOCK_ADDR),           // Tag -- eg. MODULE_TAG
      .REG_ADDR_WIDTH      (`STATS_REG_ADDR_WIDTH),       // Width of block addresses -- eg. MODULE_REG_ADDR_WIDTH
      .NUM_COUNTERS        (3),                 // Number of counters
      .NUM_SOFTWARE_REGS   (0),                 // Number of sw regs
      .NUM_HARDWARE_REGS   (1)                  // Number of hw regs
   ) stats_regs (
      .reg_req_in       (reg_req_in),
      .reg_ack_in       (reg_ack_in),
      .reg_rd_wr_L_in   (reg_rd_wr_L_in),
      .reg_addr_in      (reg_addr_in),
      .reg_data_in      (reg_data_in),
      .reg_src_in       (reg_src_in),

      .reg_req_out      (reg_req_out),
      .reg_ack_out      (reg_ack_out),
      .reg_rd_wr_L_out  (reg_rd_wr_L_out),
      .reg_addr_out     (reg_addr_out),
      .reg_data_out     (reg_data_out),
      .reg_src_out      (reg_src_out),

      // --- counters interface
      .counter_updates  (reg_counters),
      .counter_decrement(),

      // --- SW regs interface
      .software_regs    (),

      // --- HW regs interface
      .hardware_regs    (reg_marker),

      .clk              (clk),
      .reset            (reset)
    );

   //------------------------- Logic-------------------------------
   always @* begin
      state_nxt = state;
      stat_sel_nxt = stat_sel;
      stat_rx_ts_nxt = stat_rx_ts;
      out_data_int = in_fifo_data;
      out_ctrl_int = in_fifo_ctrl;

      out_wr_int = 0;
      in_fifo_rd_en = 0;
      stat_curr_we = 0;
      stat_curr_re = 0;

      case (state)
	WAIT_HDRS: begin
	   if (!in_fifo_empty && out_rdy) begin
	      in_fifo_rd_en = 1;

	      if (in_fifo_data[`IOQ_DST_PORT_POS+3] ||     // 2 -> 00 00 00 10 = CPUq0
		  in_fifo_data[`IOQ_DST_PORT_POS+1]) begin // 8 -> 00 00 10 00 = CPUq1
		 stat_sel_nxt = {in_fifo_data[`IOQ_DST_PORT_POS+3],in_fifo_data[`IOQ_DST_PORT_POS+1]};

		 // don't forward this packet

		 state_nxt = SAVE_RX_TS;
	      end
	      else begin
		 out_wr_int = 1;
		 out_data_int = header_wo_ts;

		 state_nxt = DROP_TIMESTAMP;
	      end
	   end
	end // case: WAIT_HDRS

	DROP_TIMESTAMP: begin
	   if (!in_fifo_empty) begin
	      in_fifo_rd_en = 1;

	      state_nxt = MAKE_SPACE_FOR_TX_TS;
	   end
	end

	MAKE_SPACE_FOR_TX_TS: begin
	   if (!in_fifo_empty) begin
	      in_fifo_rd_en = 1;

	      state_nxt = THRU;
	   end
	end

	THRU: begin
	   if (!in_fifo_empty && out_rdy) begin
	      in_fifo_rd_en = 1;
              out_wr_int = 1;

	      if (|in_fifo_ctrl)
		state_nxt = WAIT_HDRS;
	   end
	end



	SAVE_RX_TS: begin
	   if (!in_fifo_empty) begin
	      in_fifo_rd_en = 1;
	      stat_rx_ts_nxt = in_fifo_data[31:0];

	      state_nxt = SAVE_TX_TS;
	   end
	end

	SAVE_TX_TS: begin
	   if (!in_fifo_empty) begin
	      in_fifo_rd_en = 1;

	      if (|in_fifo_ctrl) begin
		 stat_curr_we = 1;

		 state_nxt = WRITE_STAT;
	      end
	   end
	end // case: SAVE_TX_TS

	WRITE_STAT: begin
	   if (stat_curr_full)
	      state_nxt = RO_HDRS;
	   else
	      state_nxt = WAIT_HDRS;
	end

	RO_HDRS: begin
	   if (out_rdy) begin
              out_wr_int = 1;
	      out_ctrl_int = `IO_QUEUE_STAGE_NUM;
	      out_data_int = 64'h0010008100000401;

	      stat_curr_re = 1;

	      state_nxt = RO_DATA;
	   end
	end

	RO_DATA: begin
	   if (out_rdy) begin
              out_wr_int = 1;
	      out_ctrl_int = 8'h00;
	      if (stat_sel[0])
		out_data_int = stat_fifo_dout_p0;
	      else
		out_data_int = stat_fifo_dout_p1;

	      stat_curr_re = 1;

	      if (stat_curr_empty)
		state_nxt = RO_END;
	   end
	end // case: RO_DATA

	RO_END: begin
	   if (out_rdy) begin
              out_wr_int = 1;
	      out_ctrl_int = 8'hff; // make it identical to RO_HDRS, 8'h80 would suffice
	      out_data_int = {32{stat_sel}};

	      state_nxt = WAIT_HDRS;
	   end
	end

      endcase
   end

   always @(posedge clk) begin
      state <= state_nxt;
      stat_sel <= stat_sel_nxt;
      stat_rx_ts <= stat_rx_ts_nxt;

      reg_counters[0] <= (state == WAIT_HDRS) && (state_nxt == DROP_TIMESTAMP);
      reg_counters[1] <= (state == WAIT_HDRS) && (state_nxt == SAVE_RX_TS);
      reg_counters[2] <= (state == RO_END) && (state_nxt == WAIT_HDRS);

      reg_marker <= 32'haabbccdd;

      if (reset)
	state <= WAIT_HDRS;
   end

endmodule
