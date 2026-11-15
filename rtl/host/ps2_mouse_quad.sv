// Host adapter: an Amiga mouse on the HR card's J2.  Each MiSTer ps2_mouse
// report adds its deltas to a pending count per axis; the count drains as
// Gray-code quadrature on H/HQ and V/VQ, one phase step per STEP_CLKS
// clocks (10 kHz at 48 MHz, a fast hand on a 200 dpi mouse).  One step is
// one count on the card.  PS/2 Y is up-positive, J2 V is down-positive.
// Buttons: B1 left, B2 middle, B3 right, Low = pressed.  Reports are
// dropped while the OSD is open.
`default_nettype none
module ps2_mouse_quad #(
  parameter int STEP_CLKS = 4800
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [24:0] ps2_mouse,   // [24] toggle, [23:16] Y, [15:8] X, [7:0] flags
  input  logic        osd,
  output logic        m_h,
  output logic        m_hq,
  output logic        m_v,
  output logic        m_vq,
  output logic [2:0]  m_b_n
);
  localparam int PW = 12;                       // pending detents, saturating
  localparam logic signed [PW:0] PMAX = 13'sd2047, PMIN = -13'sd2047;
  localparam int TW = $clog2(STEP_CLKS);
  localparam int LAST = STEP_CLKS - 1;
  localparam logic [TW-1:0] TLAST = LAST[TW-1:0];

  // Justification: event edge (reg-a), pending counts and Gray phases
  // (reg-a), step timer (reg-a), buttons (reg-a).
  logic                 tog_q;
  logic signed [PW-1:0] px_q, py_q;
  logic [1:0]           phx_q, phy_q;
  logic [TW-1:0]        tmr_q;
  logic [2:0]           btn_q;

  logic ev;
  assign ev = (ps2_mouse[24] != tog_q) && !osd;

  // 9-bit two's complement deltas, Y negated for J2.
  logic signed [PW-1:0] dx, dy;
  assign dx = {{(PW-8){ps2_mouse[4]}}, ps2_mouse[15:8]};
  assign dy = -{{(PW-8){ps2_mouse[5]}}, ps2_mouse[23:16]};

  logic step;
  assign step = (tmr_q == TLAST);

  function automatic logic signed [PW-1:0] sat_add(input logic signed [PW-1:0] p,
                                                    input logic signed [PW-1:0] d);
    logic signed [PW:0] s;
    s = {p[PW-1], p} + {d[PW-1], d};
    if (s > PMAX) return PMAX[PW-1:0];
    if (s < PMIN) return PMIN[PW-1:0];
    return s[PW-1:0];
  endfunction

  // One axis: next pending count after an optional report and step.
  function automatic logic signed [PW-1:0] drain(input logic signed [PW-1:0] p, input logic st);
    if (!st || p == '0) return p;
    return p[PW-1] ? p + 12'sd1 : p - 12'sd1;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) tmr_q <= '0;
    else        tmr_q <= step ? '0 : tmr_q + 1'd1;
  end

  always_ff @(posedge clk) tog_q <= ps2_mouse[24];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      px_q <= '0;
      py_q <= '0;
    end else begin
      px_q <= ev ? sat_add(drain(px_q, step), dx) : drain(px_q, step);
      py_q <= ev ? sat_add(drain(py_q, step), dy) : drain(py_q, step);
    end
  end

  // Forward = 00 01 11 10 on (H, HQ): the phase index counts up.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      phx_q <= 2'd0;
      phy_q <= 2'd0;
    end else if (step) begin
      if (px_q != '0) phx_q <= px_q[PW-1] ? phx_q - 2'd1 : phx_q + 2'd1;
      if (py_q != '0) phy_q <= py_q[PW-1] ? phy_q - 2'd1 : phy_q + 2'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n)  btn_q <= 3'b111;
    else if (ev) btn_q <= ~{ps2_mouse[1], ps2_mouse[2], ps2_mouse[0]};
  end

  // Gray phase -> (A, B): 0 00, 1 01, 2 11, 3 10.
  assign m_h   = phx_q[1];
  assign m_hq  = phx_q[1] ^ phx_q[0];
  assign m_v   = phy_q[1];
  assign m_vq  = phy_q[1] ^ phy_q[0];
  assign m_b_n = btn_q;

  logic unused_ok;
  assign unused_ok = &{1'b0, ps2_mouse[7:6], ps2_mouse[3]};
endmodule
`default_nettype wire
