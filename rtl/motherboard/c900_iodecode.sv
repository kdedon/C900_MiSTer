// Motherboard I/O decode, sheet 5: U56 74LS373 address latch, U58 status
// decode (I/O cycle), U57 74LS138 (/I-O0../I-O7 from latched A10:A8, enabled
// while A15:A11 are 0).  U56 is transparent while /AS is Low; here it is a
// register that follows AD while /AS is Low and holds once /AS rises, one
// fabric clock behind the transparent part.
//
// U57 drives CS0 of the Z-bus peripherals: CIOs U70 and U66 /I-O0, SCC
// U74 /I-O1; their CS1 pins take A7 from the A bus.
// U57 is enabled by _I-O (U58, status 0010) and the latched
// IOPAGE (A15:A11 = 0), so special I/O never selects it.  MMU /CS = U11
// AND of AD1 and _MRESET (pin 9 net INFERRED, not yet beeped): the MMU
// itself only answers special I/O, and _MRESET holds /CS Low through
// power-on and S1 resets, which brings the Z8010 up in pass-through
// (MSEN = 1) so the boot ROM is reachable before the MMU is programmed.
// The 8716
// _IO_6 select is /I-O5 (0x0500, what the BIOS and kernel write; SP wires
// pin 3 to Y6), qualified by /DS and write.
`default_nettype none
module c900_iodecode
  import z8000_zbus_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        mreset_n,     // _MRESET (power-on and S1)
  input  logic [15:0] ad,
  input  logic        as_n,
  input  logic        ds_n,
  input  logic        r_w,
  input  logic [3:0]  st,
  output logic [15:0] adr,          // U56 Q
  output logic [7:0]  io_n,         // U57 /Y7../Y0
  output logic        mmu_cs_n,     // Z8010 U2 /CS
  output logic        io6           // 8716 _IO_6 input (pin 3)
);
  logic [15:0] adr_q;
  logic        std_io, dec_en;

  always_ff @(posedge clk) begin
    if (!rst_n)     adr_q <= 16'h0000;
    else if (!as_n) adr_q <= ad;
  end
  assign adr = adr_q;

  assign std_io = (st == ST_IO);
  assign dec_en = std_io && (adr_q[15:11] == 5'b00000);

  always_comb begin
    io_n = 8'hFF;
    if (dec_en) io_n[adr_q[10:8]] = 1'b0;
  end

  // U11 takes the raw BAD1; the Z8010 samples /CS at the /AS rise, while
  // the address is still held on the bus.  On the registered bus the
  // address has already given way to the data phase at that sample, so the
  // latched A1 stands for it.
  assign mmu_cs_n   = adr_q[1] & mreset_n;
  assign io6        = !io_n[5] && !ds_n && !r_w;
endmodule
`default_nettype wire
