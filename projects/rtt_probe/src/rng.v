module rng
  (
   input 	 clk,

   input 	 seed_wr,
   input [31:0]  seed,

   output [63:0] out,
   input 	 kick
   );

   //------------------------ Functions ------------------------------
   `LOG2_FUNC

   //------------------------- Signals -------------------------------

   reg [6:0] 	 cnt;
   reg [6:0] 	 cnt_nxt;

   reg [63:0] 	 rng;
   reg [63:0] 	 rng_nxt;
   wire 	 rng_feedback;

   //-------------------- Local assignments ---------------------------
   assign rng_feedback = rng[63] ^ rng[62] ^ rng[60] ^ rng[59];
   assign out = rng;

   always @(*) begin
      cnt_nxt = cnt;
      rng_nxt = rng;

      if (seed_wr)
	rng_nxt = { seed, seed };

      if (kick)
	cnt_nxt = 0;

      if (!cnt[6]) begin
	 rng_nxt = { rng[62:0], rng_feedback };
	 cnt_nxt = cnt + 1;
      end
   end

   always @(posedge clk) begin
      rng <= rng_nxt;
      cnt <= cnt_nxt;
   end

endmodule // rng
