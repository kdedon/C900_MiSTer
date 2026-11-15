// LC card 8563 pins to the MiSTer video path, one for one.
//
// Every 16 MHz dot period the pins go into a 16-entry dual-clock FIFO
// (clk_vdc -> clk_vid).  clk_vid runs at 64 MHz with the LC card fitted,
// from the same 50 MHz reference as clk_vdc, so the fill stays put: reading
// starts at half full, one entry per four clk_vid.  The fractional step of
// clk_vid's PLL drifts one entry in hours, as with the HR card.
//
//   clk_vdc : a slot every second clock, phased by pixel_ce; push
//             {field, pixel_ce, hs, vs, hblank, vblank, rgbi}
//   clk_vid : every 4th clock pop; CE_PIXEL with the entries that carry
//             pixel_ce (16 MHz, or 8 MHz in double-width mode)
//
// Blanking is the 8563's display window; colours are the CGA palette.
//
// field is read from the sync pins, as a monitor would: 1 for the lower
// field of an interlaced frame, whose VSYNC rose mid-line after one that
// rose near HSYNC (its lines start half a line later after VSYNC), else 0.
// It changes with the VSYNC rise and stays 0 unless the 8563 interlaces.
//
// The 8568 sets its sync polarity (R37).  As a multisync monitor does, a
// sync pin found high for more than half its period is taken as active
// low and inverted, so the scaler always gets positive pulses.
`default_nettype none

module lc_video (
  input  logic       clk_vdc,    // 32 MHz
  input  logic [3:0] rgbi,       // R, G, B, I
  input  logic       hsync,
  input  logic       vsync,
  input  logic       pixel_ce,
  input  logic       active_h,
  input  logic       active_v,
  input  logic       clk_vid,    // 64 MHz
  output logic       ce_pix = 1'b0,
  output logic [7:0] r = '0,
  output logic [7:0] g = '0,
  output logic [7:0] b = '0,
  output logic       hs = 1'b0,
  output logic       vs = 1'b0,
  output logic       hblank = 1'b1,
  output logic       vblank = 1'b1,
  output logic       field = 1'b0
);
  // ---- clk_vdc: one entry per dot period ----
  // Justification: dot-slot phase (reg-a).
  logic slot_q = 1'b0;
  logic push;
  assign push = pixel_ce || slot_q;
  always_ff @(posedge clk_vdc) slot_q <= !push;

  // Sync polarity: high slots in the last line, lines with VSYNC high in
  // the last field (a field is at most 2048 lines).
  // Justification: polarity, high-time counts (reg-a).
  logic        hneg_q = 1'b0, vneg_q = 1'b0;
  logic [11:0] hhi_q = '0;
  logic [10:0] vhi_q = '0, vln_q = '0;
  logic        hs_p, vs_p;
  assign hs_p = hsync ^ hneg_q;
  assign vs_p = vsync ^ vneg_q;

  // Slots since the HSYNC rise, and the last line's length (a line is at
  // most 256 characters of 16 dots).
  // Justification: sync edges, line position and length, VSYNC phase,
  // field (reg-a).
  logic        hs_q = 1'b0, vs_q = 1'b0, mid_q = 1'b0, fld_q = 1'b0;
  logic [11:0] pos_q = '0, len_q = '0;
  logic        hs_rise, vs_rise, mid;
  assign hs_rise = hs_p && !hs_q;
  assign vs_rise = vs_p && !vs_q;
  assign mid     = pos_q >= {2'b00, len_q[11:2]} && pos_q < len_q - {2'b00, len_q[11:2]};
  always_ff @(posedge clk_vdc) if (push) begin
    hs_q  <= hs_p;
    vs_q  <= vs_p;
    pos_q <= hs_rise ? 12'd0 : pos_q + 12'd1;
    if (hs_rise) len_q <= pos_q;
  end

  always_ff @(posedge clk_vdc) if (push) begin
    hhi_q <= hs_rise ? 12'd0 : hhi_q + {11'd0, hs_p};
    if (hs_rise && hhi_q > {1'b0, pos_q[11:1]}) hneg_q <= !hneg_q;
    if (vs_rise) begin
      vhi_q <= 11'd0;
      vln_q <= 11'd0;
      if (vhi_q > {1'b0, vln_q[10:1]}) vneg_q <= !vneg_q;
    end else if (hs_rise) begin
      vhi_q <= vhi_q + {10'd0, vs_p};
      vln_q <= vln_q + 11'd1;
    end
  end

  logic fld;
  assign fld = vs_rise ? mid && !mid_q : fld_q;
  always_ff @(posedge clk_vdc) if (push) begin
    if (vs_rise) mid_q <= mid;
    fld_q <= fld;
  end

  logic [9:0] word;
  assign word = {fld, pixel_ce, hs_p, vs_p, ~active_h, ~active_v, rgbi};

  logic [1:0] ph;
  logic [9:0] cur;
  logic       cur_ok;
  vid_fifo #(.W(10)) u_fifo (.clk_src(clk_vdc), .push(push), .word(word),
    .clk_vid(clk_vid), .ph(ph), .cur(cur), .cur_ok(cur_ok));

  logic [7:0] pr, pg, pb;
  rgbicolor u_pal (.palette(4'b0000), .rgbi(cur[3:0]), .r(pr), .g(pg), .b(pb));

  always_ff @(posedge clk_vid) begin
    ce_pix <= cur_ok && cur[8] && ph == 2'd0;
    hs     <= cur[7];
    vs     <= cur[6];
    hblank <= cur[5];
    vblank <= cur[4];
    field  <= cur[9];
    r <= pr;
    g <= pg;
    b <= pb;
  end
endmodule

`default_nettype wire
