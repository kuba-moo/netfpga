// Description: 64bit counter

module  counter64
(
 // -- counter value
 output reg [63:0] count64,

 // -- misc
 input 	       clk
 );

   reg [63:0]  value64;

   always @(posedge clk) begin
      value64 <= value64 + 1;

      count64 <= value64;
   end

endmodule // output
