// U8 PAL16R6A-2CN-8444 on the WD1003-CMD (68-000057 sheet 2): the host
// strobe sequencer.  No fuse dump exists; equations are inferred from the
// CCCP spec and the firmware.  Inputs are named by the signals the
// equations use; which schematic pin carries CVE-, CRE-, WRE- or VRE- is
// untraced.
//   PCSD: a WD2010 buffer strobe inside the WDMA window (_EST High and BCS
//         Low at the strobe, or the window was open at the last CPUCLK
//         rise and the strobe is still Low); a CCCP read with WCS- High;
//         a CCCP write with WCS- High that is the second of a PCSS/PCSD
//         pair or made while SMR- is Low.
//   PCSS: a CCCP write with WCS- High otherwise.
// Registers load at CPUCLK rises: the pair advances at the first rise
// after a write ends; SMR- Low or a read resets it.  QALE, DALE2, LVE2 and
// NCR are held Low.  U8 has no reset pin.
`default_nettype none
module pal_hdc_u8 (
  input  logic clk,        // master clock
  input  logic cpuclk,     // pin 1 CPUCLK (host 6 MHz _CLK) rises now
  input  logic est_n,      // _EST from CN9 (High = block in flight)
  input  logic bcs_n,      // WD2010 BCS-
  input  logic bufwe_n,    // WD2010 WE- while it drives it (buffer write)
  input  logic bufre_n,    // WD2010 RE- while it drives it (buffer read)
  input  logic wcs_n,      // CCCP P1.3
  input  logic smr_n,      // CCCP P1.7
  input  logic wr_n,       // CCCP WR-
  input  logic rd_n,       // CCCP RD-
  output logic pcss,       // High = asserted
  output logic pcsd
);
  logic wr_q, win_q, seq_q;
  logic strobe, window, wr;

  assign strobe = ~bufwe_n | ~bufre_n;
  assign window = est_n & ~bcs_n;
  assign wr     = wcs_n & ~wr_n & rd_n;

  always_comb begin
    pcss = 1'b0;
    pcsd = strobe & (window | win_q);
    if (wcs_n) begin
      if (!rd_n)                      pcsd = 1'b1;
      else if (!wr_n && (seq_q || !smr_n)) pcsd = 1'b1;
      else if (!wr_n)                 pcss = 1'b1;
    end
  end

  always_ff @(posedge clk) if (cpuclk) begin
    if (!smr_n || (wcs_n && !rd_n)) seq_q <= 1'b0;
    else if (wr_q && !wr)           seq_q <= ~seq_q;
    wr_q  <= wr;
    win_q <= window | (strobe & win_q);
  end
endmodule
`default_nettype wire
