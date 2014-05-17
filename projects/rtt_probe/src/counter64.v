// Description: 64bit counter

module  counter64
(
 // -- counter value
 output [63:0] count64,

 // -- misc
 input 	       clk,
 input 	       reset
 );

   reg [63:0]  value64;

   always @(posedge clk) begin
      if (reset)
	value64 <= 0;
      else
	value64 <= value64 + 1;
   end

endmodule // output
