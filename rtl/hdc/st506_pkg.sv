// ST-506 MFM track primitives shared by the drive emulator blocks:
// track layout constants (as the C900 leaves a track after a format,
// measured on the real capture), the ID-field CRC and data-field ECC
// (WD2010-05 pp.70-71), the IDENT byte and the MFM cell rule.
`default_nettype none

package st506_pkg;

  // Disk bytes per revolution (166,688 cells on the capture).
  localparam int unsigned BytesPerRev = 10418;
  // Slot layout in bytes from the slot start: 14 x 00, ID A1 at 14,
  // 15 x 00 after the 7-byte ID, data A1 at 36, F8, data, ECC x 4,
  // 3 x 00, then GAP3 4E.
  localparam logic [10:0] OffId     = 11'd14;
  localparam logic [10:0] OffData   = 11'd36;
  localparam logic [10:0] SlotFixed0 = 11'd45;   // slot bytes without GAP3, plus the sector size
  localparam logic [15:0] Gap1Def   = 16'd49;    // 4E bytes from INDEX to the first slot
  localparam logic [15:0] Gap3Def   = 16'd43;    // Sector Number 0x28 + 3

  localparam logic [15:0] A1Cells   = 16'h4489;  // A1 with the missing clock
  localparam logic [31:0] EccPoly   = 32'h140A_0445;
  localparam logic [15:0] CrcPoly   = 16'h1021;

  // log2 of the sector size for an SDH size code (00 256, 01 512, 10 1024, 11 128).
  function automatic logic [3:0] size_log2(input logic [1:0] s);
    case (s)
      2'b00:   size_log2 = 4'd8;
      2'b01:   size_log2 = 4'd9;
      2'b10:   size_log2 = 4'd10;
      default: size_log2 = 4'd7;
    endcase
  endfunction

  function automatic logic [15:0] crc16_byte(input logic [15:0] c, input logic [7:0] b);
    logic [15:0] r;
    r = c ^ {b, 8'h00};
    for (int i = 0; i < 8; i++) r = r[15] ? ((r << 1) ^ CrcPoly) : (r << 1);
    return r;
  endfunction

  function automatic logic [31:0] ecc32_byte(input logic [31:0] c, input logic [7:0] b);
    logic [31:0] r;
    r = c ^ {b, 24'h000000};
    for (int i = 0; i < 8; i++) r = r[31] ? ((r << 1) ^ EccPoly) : (r << 1);
    return r;
  endfunction

  // ECC register after A1 F8 (start of a data field's data bytes).
  localparam logic [31:0] EccAfterMark = ecc32_byte(ecc32_byte(32'hFFFF_FFFF, 8'hA1), 8'hF8);

  // ECC of a data field of n zero bytes.
  function automatic logic [31:0] ecc_zero(input int n);
    logic [31:0] e;
    e = EccAfterMark;
    for (int i = 0; i < n; i++) e = ecc32_byte(e, 8'h00);
    return e;
  endfunction

  // head mod n for a head 0-7 (n >= 1): 3-bit logic, no divider.
  function automatic logic [7:0] head_mod(input logic [2:0] h, input logic [7:0] n);
    logic [2:0] r;
    if (n[7:3] != 5'd0) r = h;
    else begin
      case (n[2:0])
        3'd1:    r = 3'd0;
        3'd2:    r = {2'd0, h[0]};
        3'd3:    r = (h >= 3'd6) ? h - 3'd6 : (h >= 3'd3) ? h - 3'd3 : h;
        3'd4:    r = {1'b0, h[1:0]};
        3'd5:    r = (h >= 3'd5) ? h - 3'd5 : h;
        3'd6:    r = (h >= 3'd6) ? h - 3'd6 : h;
        3'd7:    r = (h == 3'd7) ? 3'd0 : h;
        default: r = h;
      endcase
    end
    return {5'd0, r};
  endfunction

  // IDENT byte for cylinder bits 10:8: FE FF FC FD F6 F7 F4 F5.
  function automatic logic [7:0] ident_of(input logic [2:0] ch);
    return {4'hF, ~ch[2], 1'b1, ~ch[1], ch[0]};
  endfunction

  // 16 MFM cells of a byte, first cell in bit 15; a clock cell is 1 only
  // between two 0 data bits.
  function automatic logic [15:0] mfm_cells(input logic [7:0] b, input logic prev);
    logic [15:0] w;
    logic        p;
    w = 16'h0000;
    p = prev;
    for (int i = 7; i >= 0; i--) begin
      w[2*i+1] = ~p & ~b[i];
      w[2*i]   = b[i];
      p        = b[i];
    end
    return w;
  endfunction

endpackage

`default_nettype wire
