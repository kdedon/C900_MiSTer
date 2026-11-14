// NON-STOCK DRAM expansion card on CN10/CN12.  A PAL on A23:A16 selects
// 64 KB segments from 0x18 upward, skipping 0x37, 0x3E, 0x3F and 0xFF,
// until the card's size is filled:
//
//   2M   31 segments   0x18-0x36
//   4M   64            0x18-0x36, 0x38-0x3D, 0x40-0x5A
//   8M   128           0x18-0x36, 0x38-0x3D, 0x40-0x9A
//   15M  228           0x18-0x36, 0x38-0x3D, 0x40-0xFE (the space ends)
//
// 0x37 is the LR CDR and 0x3E-0x3F the HR bitmap; the BIOS probes both to
// find its console, so the holes stay open whichever card is fitted.  2M
// stops at 0x36 so the stock BIOS memory probe ends before the CDR.  0xFF
// is kept free for a bank window.  The base is fixed: with a 512K board
// 0x10-0x17 stays empty.  Row and column strobes use the same bus timing
// terms as the motherboard banks (INFERRED: the card's strobe timing is
// undocumented).
`default_nettype none
module c900_ramcard (
  input  logic [2:0] size,        // 0 none, 1 2M, 2 4M, 3 8M, 4 15M
  input  logic [7:0] a23_16,
  input  logic       a0,
  input  logic       ras_timing,  // refresh cycle, active Low
  input  logic       ras_enable,  // /MREQ
  input  logic       cas_timing,  // B/W
  input  logic       cas13,       // column strobe timing, /SUP included
  input  logic       ras14,       // /NOMMU
  output logic       ras_n,
  output logic       casl_n,
  output logic       cash_n
);
  logic       fitted;
  logic [7:0] last;
  always_comb begin
    fitted = 1'b1;
    unique case (size)
      3'd1:    last = 8'h36;
      3'd2:    last = 8'h5A;
      3'd3:    last = 8'h9A;
      3'd4:    last = 8'hFE;
      default: begin last = 8'h00; fitted = 1'b0; end
    endcase
  end

  logic sel;
  assign sel = fitted && (a23_16 >= 8'h18) && (a23_16 <= last) && (a23_16 != 8'h37)
               && (a23_16 != 8'h3E) && (a23_16 != 8'h3F);

  assign ras_n  = ~fitted | ras_enable | (ras_timing & ras14 & ~sel);
  assign casl_n = ~sel | cas13 | (~a0 & cas_timing);
  assign cash_n = ~sel | cas13 | ( a0 & cas_timing);
endmodule
`default_nettype wire
