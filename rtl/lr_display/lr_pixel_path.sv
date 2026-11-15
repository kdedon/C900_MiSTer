// LR card video pipeline (Video sheet), clk_vid
// domain, one step per dot (dot_ce):
//
//   end of dot 8, char k   VRAM fetch of MA(k) (lr_cdr port B); the 6845
//                          sideband of char k (RA, DE, CURSOR, HS, VS)
//                          is captured with it (stage A); the 6845 runs
//                          on the bus clock and its pins have been
//                          stable since about dot 5, so this is where
//                          they cross into clk_vid
//   end of dot 0, k+1      U3 (character) / U4 (attribute) latch (stage B);
//                          U2 character ROM addressed by {U3, RA3:0}
//   end of dot 8, k+1      S-L: U1 74LS166 loads the ROM byte; U21 takes
//                          the attribute (CLKDLY); sideband to stage C
//                          (HSDLY: syncs travel with the pixels)
//   dots 0..8, k+2         U1 shifts out bit 7..0, then its serial input
//                          (the 9th dot); U22 + glue form the video bit
//
// Video bit:
//   vid = F5 | ((glyph & ~F6) ^ ~F0)        gated by DE
// F0 = cell polarity (reverse, underline row), F6 = blink glyph suppress,
// F5 = cursor.  U22 is the generated dump logic; its inputs are fed as:
//   attribute b0..b7 -> I4, I10, I13, I7, I12, I9, I5, I14 (solved map)
//   I0 = 6845 CURSOR, I1 = 0, I2 = 1, I3 = 1 (cursor group nets untraced;
//     this makes F5 = CURSOR)
//   I8 = (RA == 12) underline row (RA tap untraced; the ROM's underscore row)
//   I15 = ENBL_INK = bit 4 of a VSYNC count, Low half on (U20 LS393 tap
//     untraced; 16 frames on, 16 off)
//   I6 = 1, I11 = 0 (raster selectors, untraced)
// 9th dot: the U1 serial input is bit 0 of the ROM byte for codes
// 0xC0-0xDF, else 0 (gate untraced).
// intens: attribute b3 (INTENSE), delayed with the pixel (the sheet's INT
// net through U25 is untraced to CN2).
`default_nettype none
module lr_pixel_path (
  input  logic        clk_vid,
  input  logic        rst_n,
  input  logic        dot_ce,
  input  logic        fetch,
  input  logic        latch,
  input  logic        load,
  // VRAM word of the fetch
  input  logic [7:0]  chr,
  input  logic [7:0]  attr,
  // 6845 pins (bus clock domain; stable at fetch)
  input  logic [4:0]  ra,
  input  logic        de,
  input  logic        cursor,
  input  logic        hs,
  input  logic        vs,
  // U2 character ROM
  output logic [11:0] rom_addr,
  input  logic [7:0]  rom_q,
  // video out (registered, valid with ce_pix)
  output logic        ce_pix,
  output logic        vid,
  output logic        intens,
  output logic        hsync,
  output logic        vsync,
  output logic        de_out,
  output logic        hblank,
  output logic        vblank
);
  // sideband bundle: {ra[3:0], de, cursor, hs, vs}
  localparam int SBW = 8;
  logic [SBW-1:0] sb_a, sb_b, sb_c;

  // Justification: (reg-d) pipeline stages A/B/C, one per latch.
  always_ff @(posedge clk_vid) begin
    if (!rst_n) begin
      sb_a <= '0;
      sb_b <= '0;
      sb_c <= '0;
    end else begin
      if (fetch) sb_a <= {ra[3:0], de, cursor, hs, vs};
      if (latch) sb_b <= sb_a;
      if (load)  sb_c <= sb_b;
    end
  end

  // U3 character latch, U4 attribute latch, U21 attribute (CLKDLY).
  logic [7:0] u3_q, u4_q, u21_q;
  always_ff @(posedge clk_vid) begin
    if (!rst_n) begin
      u3_q  <= 8'h00;
      u4_q  <= 8'h00;
      u21_q <= 8'h00;
    end else begin
      if (latch) begin
        u3_q <= chr;
        u4_q <= attr;
      end
      if (load) u21_q <= u4_q;
    end
  end

  assign rom_addr = {u3_q, sb_b[7:4]};

  // U1 74LS166: load at S-L, shift MSB first, serial input = 9th dot.
  logic [7:0] u1_q;
  logic       ser, ser_c;
  assign ser = (u3_q[7:5] == 3'b110) && rom_q[0];
  always_ff @(posedge clk_vid) begin
    if (!rst_n)          u1_q <= 8'h00;
    else if (load)       u1_q <= rom_q;
    else if (dot_ce)     u1_q <= {u1_q[6:0], ser_c};
  end
  // Justification: (reg-a) U1 SER level for the character in the shifter.
  always_ff @(posedge clk_vid) begin
    if (!rst_n)    ser_c <= 1'b0;
    else if (load) ser_c <= ser;
  end

  // ENBL_INK: VSYNC count (U20 region).
  logic [4:0] fld_q;
  logic       vs_c_q;
  always_ff @(posedge clk_vid) begin
    if (!rst_n) begin
      fld_q  <= 5'd0;
      vs_c_q <= 1'b0;
    end else begin
      vs_c_q <= sb_c[0];
      if (sb_c[0] && !vs_c_q) fld_q <= fld_q + 5'd1;
    end
  end

  // U22 attribute decoder.
  logic [15:0] u22_i;
  logic [7:0]  u22_f;
  always_comb begin
    u22_i     = 16'h0000;
    u22_i[4]  = u21_q[0];
    u22_i[10] = u21_q[1];
    u22_i[13] = u21_q[2];
    u22_i[7]  = u21_q[3];
    u22_i[12] = u21_q[4];
    u22_i[9]  = u21_q[5];
    u22_i[5]  = u21_q[6];
    u22_i[14] = u21_q[7];
    u22_i[0]  = sb_c[2];                    // CURBL_INK <- CURSOR
    u22_i[1]  = 1'b0;
    u22_i[2]  = 1'b1;
    u22_i[3]  = 1'b1;
    u22_i[8]  = (sb_c[7:4] == 4'd12);       // underline row
    u22_i[15] = ~fld_q[4];                  // ENBL_INK
    u22_i[6]  = 1'b1;
    u22_i[11] = 1'b0;
  end

  lr_u22_attr u22 (.i(u22_i), .f(u22_f));

  logic glyph, pix;
  assign glyph = u1_q[7];
  assign pix   = u22_f[5] | ((glyph & ~u22_f[6]) ^ ~u22_f[0]);

  // Blanking for the platform's video path, from the 6845's pins: a line
  // is horizontal blank wherever DISPTMG is Low; vertical blank runs from
  // the HSYNC that ends a line without DISPTMG to the next DISPTMG.
  // Justification: (reg-a) HSYNC at the last dot, DISPTMG seen this line.
  logic hs_o_q, line_de_q;
  always_ff @(posedge clk_vid) begin
    if (!rst_n) begin
      hs_o_q    <= 1'b0;
      line_de_q <= 1'b0;
    end else if (dot_ce) begin
      hs_o_q <= sb_c[1];
      if (sb_c[1] && !hs_o_q) line_de_q <= 1'b0;
      else if (sb_c[3])      line_de_q <= 1'b1;
    end
  end

  // Output register: the dot just ending; ce_pix marks the new value.
  always_ff @(posedge clk_vid) begin
    if (!rst_n) begin
      ce_pix <= 1'b0;
      vid    <= 1'b0;
      intens <= 1'b0;
      hsync  <= 1'b0;
      vsync  <= 1'b0;
      de_out <= 1'b0;
      hblank <= 1'b1;
      vblank <= 1'b1;
    end else begin
      ce_pix <= dot_ce;
      if (dot_ce) begin
        vid    <= sb_c[3] & pix;
        intens <= sb_c[3] & pix & u21_q[3];
        hsync  <= sb_c[1];
        vsync  <= sb_c[0];
        de_out <= sb_c[3];
        hblank <= ~sb_c[3];
        if (sb_c[3])                          vblank <= 1'b0;
        else if (sb_c[1] && !hs_o_q && !line_de_q) vblank <= 1'b1;
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, ra[4], u22_f[7], u22_f[4:1]};
endmodule
`default_nettype wire
