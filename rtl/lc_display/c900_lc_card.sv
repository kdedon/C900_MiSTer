// LC colour card: MOS 8568 VDC with its RAM behind the chip, in the display
// slot.  Byte I/O at odd ports 0x0181-0x01FF, D7:0 lane:
//   0x0181  W VDC address register   R VDC status         (RS = A1 = 0)
//   0x0183  R/W VDC data register                          (RS = 1)
//   0x01FF  R ID = 0xC1 (64 KB RAM)
// The port address is latched from BAD15:0 while /AS is low, as a Z-Bus
// peripheral does: CN12 A15:A10 come from the MMU and float during I/O.
// The 8568 INTR goes to CN11 pin 37 _NVI; no vector, IEI goes to IEO.
//
// Clocks, from one PLL VCO (edges coincide every 62.5 ns), so every
// crossing is a plain register path that timing analysis checks:
//   clk      48 MHz Z-Bus side: decode, ID, /WAIT.
//   clk_vdc  32 MHz, twice the 16 MHz dot clock; the VDC and its RAM.
// An access is a four-phase level handshake: req_q rises with rs, we and
// data held; clk_vdc gives the VDC one /CS + bus strobe clock and raises
// ack_vq with the read byte held in db_out; req_q falls at the /DS rise.
// The 64 KB RAM is outside the module (ram_*), on the VDC's RAM pins.
`default_nettype none
module c900_lc_card (
  input  logic        clk,
  input  logic        rst_n,           // card held in reset when absent
  input  logic        mreset_n,        // backplane _MRESET
  input  logic        clk_vdc,
  // backplane, clk domain
  input  logic [15:0] ad_bus,          // BAD15:0, one clock behind the pins
  input  logic        as_n,
  input  logic        ds_n,
  input  logic        r_w,
  input  logic        b_w,
  input  logic [3:0]  st,
  output logic [15:0] ad_out,
  output logic [15:0] ad_oe,
  output logic        wait_n,
  output logic        wait_nx,         // NON-STOCK: /WAIT one clock ahead, for a 48 MHz turbo CPU
  output logic        nvi_n,           // CN11 pin 37 _NVI: the 8568 INTR, clk_vdc register
  // VDC video pins and the display window, clk_vdc domain
  output logic [3:0]  rgbi,
  output logic        hsync,
  output logic        vsync,
  output logic        pixel_ce,
  output logic        active_h,
  output logic        active_v,
  // VDC RAM pins, clk_vdc domain
  output logic        ram_rd,
  output logic        ram_we,
  output logic [15:0] ram_addr,
  output logic [7:0]  ram_di,
  input  logic [7:0]  ram_do
);
  localparam logic [3:0] ST_IO     = 4'b0010;
  localparam logic [8:0] WIN_A15_7 = 9'b0_0000_0011;     // 0x0180-0x01FF
  localparam logic [5:0] P_ID      = 6'b111111;          // 0x01FF

  logic       ack_vq;                  // clk_vdc register read across

  // ---------------- clk domain ----------------
  // Justification: port address latch (reg-a).  The last /AS-low clock
  // takes the address: AD may carry write data from the /AS rise.
  logic [15:0] pa;
  always_ff @(posedge clk) begin
    if (!as_n) pa <= ad_bus;
  end

  logic sel, sel_vdc, sel_id;
  assign sel     = !ds_n && st == ST_IO && b_w && pa[15:7] == WIN_A15_7 && pa[0];
  assign sel_vdc = sel && pa[6:2] == 5'b00000;
  assign sel_id  = sel && pa[6:1] == P_ID;

  logic       ds_low_q;                // /DS was low last clock
  logic       started_q, done_q;       // VDC access of this /DS
  logic       rs_q, we_q;
  logic [7:0] wd_q;
  logic       req_q;
  logic [7:0] db_out;                  // clk_vdc register, stable at ack
  logic [7:0] rd_q;

  // Write data is taken on the second /DS-low clock: the AD capture is one
  // clock behind the pins.
  logic start;
  assign start = sel_vdc && ds_low_q && !started_q && !ack_vq;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ds_low_q   <= 1'b0;
      started_q  <= 1'b0;
      done_q     <= 1'b0;
      rs_q       <= 1'b0;
      we_q       <= 1'b0;
      wd_q       <= 8'h00;
      req_q      <= 1'b0;
      rd_q       <= 8'hFF;
    end else begin
      ds_low_q <= !ds_n;
      if (ds_n) begin
        started_q <= 1'b0;
        done_q    <= 1'b0;
        req_q     <= 1'b0;
      end else if (start) begin
        started_q <= 1'b1;
        rs_q      <= pa[1];
        we_q      <= !r_w;
        wd_q      <= ad_bus[7:0];
        req_q     <= 1'b1;
      end
      if (req_q && ack_vq && !done_q) begin
        done_q <= 1'b1;
        rd_q   <= db_out;
      end
    end
  end

  assign wait_n = !(rst_n && mreset_n && sel_vdc && !done_q);
  assign wait_nx = !(rst_n && mreset_n && sel_vdc && !done_q && !(req_q && ack_vq));

  // Read data, D7:0 only.
  logic       drive;
  logic [7:0] dout;
  always_comb begin
    drive = 1'b0;
    dout  = 8'hFF;
    if (r_w) begin
      if (sel_vdc && done_q) begin drive = 1'b1; dout = rd_q; end
      if (sel_id)            begin drive = 1'b1; dout = 8'hC1; end
    end
  end
  assign ad_out = {8'hFF, dout};
  assign ad_oe  = {8'h00, {8{drive && rst_n}}};

  // ---------------- clk_vdc domain ----------------
  logic rst_v;
  always_ff @(posedge clk_vdc) rst_v <= !(rst_n && mreset_n);

  // cs_vq: one clock per req_q rise.  ack_vq rises on the clock db_out takes
  // the read byte and falls once req_q is low.
  logic req_seen_vq, cs_vq;
  always_ff @(posedge clk_vdc) begin
    if (rst_v) begin
      req_seen_vq <= 1'b0;
      cs_vq       <= 1'b0;
      ack_vq      <= 1'b0;
    end else begin
      req_seen_vq <= req_q;
      cs_vq       <= req_q && !req_seen_vq;
      ack_vq      <= req_q && (ack_vq || cs_vq);
    end
  end

  // INIT on the card reset; RES tied inactive.
  mos8568 u_8568 (
    .clk      (clk_vdc),
    .init_n   (!rst_v),
    .res      (1'b0),
    .cs       (cs_vq),
    .rs       (rs_q),
    .we       (we_q),
    .d_in     (wd_q),
    .d_out    (db_out),
    .intr_n   (nvi_n),
    .lpen     (1'b1),
    .vsync    (vsync),
    .hsync    (hsync),
    .rgbi     (rgbi),
    .pixel_ce (pixel_ce),
    .active_h (active_h),
    .active_v (active_v),
    .ram_rd   (ram_rd),
    .ram_we   (ram_we),
    .ram_addr (ram_addr),
    .ram_di   (ram_di),
    .ram_do   (ram_do)
  );

endmodule
`default_nettype wire
