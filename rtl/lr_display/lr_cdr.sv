// LR card character display RAM (Address Bus sheet): U5 and U6
// 2016-type 2Kx8 SRAMs behind the U16/U17/U26 74LS157 address muxes, plus
// the CPU-side half of the U13 PAL (_WAIT, _W1/_W2, _SELMBUF lane swap).
//
// U5 (written by _W1) holds VD7:0 = the character, U6 (_W2) holds
// VD15:8 = the attribute; one cell = one 16-bit word, address A11:A1 on
// the CPU side (A1 -> SRAM A0 via U16 1A), MA10:0 on the 6845 side.
// _OE is common to both chips, so a CPU read drives the whole word and
// the CPU takes its byte by A0 (even -> AD15:8).
//
// Each SRAM is one dual-clock block RAM: port A in clk (the Z-Bus side,
// read/write), port B in clk_vid (the CRTC fetch, read only).  The CPU
// access happens a few clk cycles after the cpu_slot event (end of dot 3,
// synchronised), inside dots 4..7, and the CRTC fetch at the end of dot 8,
// so the ports never touch the array in the same instant.
//
// INFERRED (U13 is not dumped), from firmware evidence:
//   _WAIT: a CPU CDR cycle (the CDR select, which follows /MREQ and the
//     latched address; U13 has no /DS input) holds /WAIT Low until the
//     next CPU slot (once per character; for a write, the first with /DS
//     Low), then the access is made and /WAIT released; the read word is
//     driven while /DS is Low.  With /DS
//     in the term a write's /WAIT came after the Z8001 samples it in T2
//     and the write was lost.
//   _W1/_W2: a word write writes both SRAMs; a byte write writes only the
//     character SRAM U5, whatever A0 (BvidCHR byte-writes characters at
//     even addresses).  The byte comes from the lane A0 selects (U13 sees
//     A0: the _SELMBUF lane swap).
`default_nettype none
module lr_cdr (
  // Z-Bus side (clk)
  input  logic        clk,
  input  logic        rst_n,
  input  logic        cdr_sel,      // U18 F0 asserted
  input  logic        ds_n,
  input  logic        r_w,          // BR-W, High = read
  input  logic        b_w,          // BB-W, High = byte
  input  logic        a0,
  input  logic [10:0] wa,           // A11:A1
  input  logic [15:0] ad_in,
  input  logic        slot,         // CPU slot event (one clk cycle)
  output logic [15:0] ad_out,
  output logic        ad_oe,
  output logic        wait_n,
  output logic        wait_nx,      // NON-STOCK: /WAIT one clock ahead
  // CRTC side (clk_vid)
  input  logic        clk_vid,
  input  logic        fetch,
  input  logic [10:0] ma,
  output logic [7:0]  chr,
  output logic [7:0]  attr
);
  logic cyc, access, served_q, release_q, rdv_q;

  assign cyc    = cdr_sel;
  // A write takes a slot only once /DS is Low: /MREQ falls at T1's CLK
  // fall, the write data reaches AD at T2.
  assign access = cyc && slot && !served_q && (r_w || !ds_n);
  // /WAIT is released once the read word is on the registered bus (two
  // clocks after the array access: port A register, then the bus capture),
  // since the Z8001 takes its data at the same edge as it samples /WAIT.
  assign wait_n = !(cyc && !release_q);
  assign wait_nx = !(cyc && !served_q);

  // Justification: (reg-a) the slot of this cycle has been used; (reg-d)
  // the release one clock later.
  always_ff @(posedge clk) begin
    if (!rst_n || !cyc) begin
      served_q  <= 1'b0;
      release_q <= 1'b0;
    end else begin
      if (access) served_q <= 1'b1;
      release_q <= served_q;
    end
  end

  // Justification: (reg-a) read word in the port A register is this cycle's.
  always_ff @(posedge clk) begin
    if (!rst_n || !cyc) rdv_q <= 1'b0;
    else if (access)    rdv_q <= r_w;
  end

  logic       we_chr, we_atr;
  logic [7:0] d_chr, d_atr;
  assign we_chr = access && !r_w;
  assign we_atr = access && !r_w && !b_w;
  assign d_chr  = (b_w && !a0) ? ad_in[15:8] : ad_in[7:0];
  assign d_atr  = ad_in[15:8];

  // U5: character SRAM.
  (* ramstyle = "M10K, no_rw_check" *) logic [7:0] u5_mem [0:2047];
  logic [7:0] u5_qa, u5_qb;
  always_ff @(posedge clk) begin
    if (we_chr) u5_mem[wa] <= d_chr;
    u5_qa <= u5_mem[wa];
  end
  always_ff @(posedge clk_vid) if (fetch) u5_qb <= u5_mem[ma];

  // U6: attribute SRAM.
  (* ramstyle = "M10K, no_rw_check" *) logic [7:0] u6_mem [0:2047];
  logic [7:0] u6_qa, u6_qb;
  always_ff @(posedge clk) begin
    if (we_atr) u6_mem[wa] <= d_atr;
    u6_qa <= u6_mem[wa];
  end
  always_ff @(posedge clk_vid) if (fetch) u6_qb <= u6_mem[ma];

  assign ad_oe  = cyc && !ds_n && r_w && rdv_q;
  assign ad_out = {u6_qa, u5_qa};
  assign chr    = u5_qb;
  assign attr   = u6_qb;
endmodule
`default_nettype wire
