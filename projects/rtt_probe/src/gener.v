///////////////////////////////////////////////////////////////////////////////
// vim:set shiftwidth=3 softtabstop=3 expandtab:
// $Id: gener 2014-07-17 moo1 $
//
// Module: gener.v
// Project: NF3.1
// Description: simple generator of random packets
//
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module gener
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

   localparam WAIT_HDRS_OR_TIME  = 1;
   localparam THRU               = 2;
   localparam GEN_HDRS           = 4;
   localparam GEN_MAC0           = 8;
   localparam GEN_MAC1           = 16;
   localparam GEN_BODY           = 32;
   localparam GEN_END            = 64;

   //------------------------- Signals-------------------------------

   wire [DATA_WIDTH-1:0]         in_fifo_data;
   wire [CTRL_WIDTH-1:0]         in_fifo_ctrl;

   reg [DATA_WIDTH-1:0] 	 out_data_int;
   reg [CTRL_WIDTH-1:0] 	 out_ctrl_int;

   wire                          in_fifo_nearly_full;
   wire                          in_fifo_empty;

   reg                           in_fifo_rd_en;
   reg                           out_wr_int;

   reg [6:0] 			 state;
   reg [6:0] 			 state_nxt;
   reg [15:0] 			 cnt;
   reg [15:0] 			 cnt_nxt;

   wire [31:0] 			 reg_frame_cnt;
   reg 				 r_flip_cnt_send_old;
   reg [31:0] 			 frame_cnt;
   reg [31:0] 			 frame_cnt_nxt;
   wire 			 frame_cnt_done;

   wire 			 can_start_frame;

   wire [DATA_WIDTH-1:0] 	 gen_pkt_hdr;

   reg 				 pkt_upcnt;
   wire [31:0] 			 reg_ifg;
   wire [31:0]			 reg_len;
   wire [31:0]			 reg_ctrl;
     wire 			   r_cont_send;
     wire 			   r_flip_cnt_send;
     wire 			   r_rng_seed_wr;
   wire [31:0]			 reg_hw_state;

   wire [31:0] 			 reg_rng_seed;
   wire [63:0] 			 rng_out;
   reg 				 rng_kick;

   //------------------------- Local assignments -------------------------------

   assign in_rdy     = !in_fifo_nearly_full;
   assign out_wr     = out_wr_int;

   assign out_ctrl   = out_ctrl_int;
   assign out_data   = out_data_int;

   assign gen_pkt_hdr = { 16'h05,        // dst
			  reg_len[18:3], // len words
			  16'h00,        // src - doesn't matter
			  reg_len[15:0]};// len bytes

   assign reg_hw_state = {cnt,          // 31:16
			  reg_len[7:4], // 15:12
			  frame_cnt_done, // 11
			  pkt_upcnt,    // 10
			  out_wr_int,   // 9
			  in_fifo_empty,// 8
			  out_rdy,      // 7
			  state         // 6:0
			  };

   assign r_cont_send     = reg_ctrl[0];
   assign r_flip_cnt_send = reg_ctrl[1];
   assign r_rng_seed_wr   = reg_ctrl[2];

   assign frame_cnt_done = !(|frame_cnt);
   assign can_start_frame = (r_cont_send || !frame_cnt_done) && (!(|cnt));

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

   generic_regs
   #(
      .UDP_REG_SRC_WIDTH   (UDP_REG_SRC_WIDTH),
      .TAG                 (`GENER_BLOCK_ADDR),       // Tag -- eg. MODULE_TAG
      .REG_ADDR_WIDTH      (`GENER_REG_ADDR_WIDTH),   // Width of block addresses -- eg. MODULE_REG_ADDR_WIDTH
      .NUM_COUNTERS        (1),                 // Number of counters
      .NUM_SOFTWARE_REGS   (5),                 // Number of sw regs
      .NUM_HARDWARE_REGS   (3)                  // Number of hw regs
   ) module_regs (
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
      .counter_updates  (pkt_upcnt),
      .counter_decrement(),

      // --- SW regs interface
      .software_regs    ({reg_frame_cnt, reg_rng_seed, reg_ifg, reg_len, reg_ctrl}),

      // --- HW regs interface
      .hardware_regs    ({reg_hw_state, rng_out}),

      .clk              (clk),
      .reset            (reset)
    );

   rng some_rng
     (
      .clk (clk),
      .seed_wr(r_rng_seed_wr),
      .seed(reg_rng_seed),
      .out(rng_out),
      .kick(rng_kick)
      );

   //------------------------- Logic-------------------------------

   always @(*) begin
      // Default values
      rng_kick = 0;
      pkt_upcnt = 0;
      out_wr_int = 0;
      in_fifo_rd_en = 0;
      out_ctrl_int = 8'h0;
      out_data_int = 64'h0a11223308014444;

      state_nxt = state;
      cnt_nxt = cnt;
      frame_cnt_nxt = frame_cnt;

      case (state)
	WAIT_HDRS_OR_TIME: begin
	   if (|cnt)
	     cnt_nxt = cnt - 1;

	   if (!in_fifo_empty && out_rdy) begin
	      out_wr_int = 1;
              in_fifo_rd_en = 1;

	      out_data_int = in_fifo_data;
	      out_ctrl_int = in_fifo_ctrl;

	      state_nxt = THRU;
	   end
	   else begin
	      if (can_start_frame)
		state_nxt = GEN_HDRS;
	   end
	end

	THRU: begin
	   if (|cnt)
	     cnt_nxt = cnt - 1;

	   if (!in_fifo_empty && out_rdy) begin
	      out_wr_int = 1;
              in_fifo_rd_en = 1;

	      out_data_int = in_fifo_data;
	      out_ctrl_int = in_fifo_ctrl;

	      if (|in_fifo_ctrl)
		state_nxt = WAIT_HDRS_OR_TIME;
	   end
	end

	GEN_HDRS: begin
	   if (out_rdy) begin
	      out_wr_int = 1;

	      out_ctrl_int = `IO_QUEUE_STAGE_NUM;
	      out_data_int = gen_pkt_hdr;

	      state_nxt = GEN_MAC0;
	   end
	end

	GEN_MAC0: begin
	   if (out_rdy) begin
	      out_wr_int = 1;

	      state_nxt = GEN_MAC1;
	   end
	end

	GEN_MAC1: begin
	   if (out_rdy) begin
	      out_wr_int = 1;

	      state_nxt = GEN_BODY;
	      cnt_nxt = reg_len[18:3] - 4; // already generated 2 MAC words + 1 in next cycle + 1 for GEN_END
	   end
	end

	GEN_BODY: begin
	   if (out_rdy) begin
	      out_wr_int = 1;

	      cnt_nxt = cnt - 1;

	      if (cnt == 0)
		state_nxt = GEN_END;
	   end
	end

	GEN_END: begin
	   if (out_rdy) begin
	      pkt_upcnt = 1;

	      out_wr_int = 1;

	      out_ctrl_int = 8'h01;
	      out_data_int = rng_out;

	      rng_kick = 1;
	      if (!frame_cnt_done)
		frame_cnt_nxt = frame_cnt - 1;

	      state_nxt = WAIT_HDRS_OR_TIME;
	      cnt_nxt = reg_ifg;
	   end
	end
      endcase
   end

   always @(posedge clk) begin
      state <= state_nxt;
      cnt <= cnt_nxt;

      r_flip_cnt_send_old <= r_flip_cnt_send;
      if (r_flip_cnt_send_old ^ r_flip_cnt_send)
	frame_cnt <= reg_frame_cnt;
      else
	frame_cnt <= frame_cnt_nxt;

      if (reset)
	state <= WAIT_HDRS_OR_TIME;
   end

endmodule
