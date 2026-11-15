// Host adapter: a Mouse Systems serial mouse on SCC U74 channel A's RxD.
// 1200 baud 8N1, idle mark.  A packet is five bytes, sent back to back:
//   0  1 0 0 0 0 L M R   (button bits 0 = pressed)
//   1  dX1   2  dY1   3  dX2   4  dY2   (signed, X right, Y up)
// Protocol as decoded by the Linux sermouse driver (MSC mode: sync byte
// & 0xF8 == 0x80, x = d1 + d3, y = d2 + d4 up-positive).
// MiSTer ps2_mouse reports add to a pending count per axis.  dX1/dY1 take
// half the count, dX2/dY2 what is left when they go out, each clamped to
// +-127; the rest waits for the next packet.  A packet starts whenever
// motion is pending or the buttons changed.  Reports are dropped while
// the OSD is open.  Off (on = 0, or the HR card fitted) the line idles.
`default_nettype none
module ps2_mouse_msys #(
  parameter int BIT_CLKS = 40000                // 1200 baud at 48 MHz
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [24:0] ps2_mouse,   // [24] toggle, [23:16] Y, [15:8] X, [7:0] flags
  input  logic        osd,
  input  logic        on,
  input  logic        hr,
  output logic        active,
  output logic        rxd
);
  localparam int PW = 12;
  localparam logic signed [PW:0] PMAX = 13'sd2047, PMIN = -13'sd2047;
  localparam int TW = $clog2(BIT_CLKS);
  localparam int LAST = BIT_CLKS - 1;
  localparam logic [TW-1:0] TLAST = LAST[TW-1:0];

  // Justification: enable (reg-a), event edge (reg-a), pending counts
  // (reg-a), buttons now and as last sent (reg-a), frame shifter, bit and
  // byte counters, bit timer (reg-a).
  logic                 act_q, tog_q, busy_q;
  logic signed [PW-1:0] px_q, py_q;
  logic [2:0]           btn_q, sent_q;
  logic [9:0]           fr_q;
  logic [3:0]           bit_q;
  logic [2:0]           idx_q;
  logic [TW-1:0]        tmr_q;

  logic run_n;
  assign run_n = rst_n && act_q;

  always_ff @(posedge clk) begin
    if (!rst_n) act_q <= 1'b0;
    else        act_q <= on && !hr;
  end

  always_ff @(posedge clk) tog_q <= ps2_mouse[24];

  logic ev;
  assign ev = (ps2_mouse[24] != tog_q) && !osd;

  logic signed [PW-1:0] dx, dy;
  assign dx = {{(PW-8){ps2_mouse[4]}}, ps2_mouse[15:8]};
  assign dy = {{(PW-8){ps2_mouse[5]}}, ps2_mouse[23:16]};

  function automatic logic signed [PW-1:0] clamp127(input logic signed [PW-1:0] p);
    if (p > 12'sd127)  return 12'sd127;
    if (p < -12'sd127) return -12'sd127;
    return p;
  endfunction

  // The larger half of p, toward zero for the remainder.
  function automatic logic signed [PW-1:0] half(input logic signed [PW-1:0] p);
    logic signed [PW-1:0] rest;
    rest = (p >>> 1) + signed'({{(PW-1){1'b0}}, p[PW-1] & p[0]});
    return clamp127(p - rest);
  endfunction

  function automatic logic signed [PW-1:0] sat_add(input logic signed [PW-1:0] p,
                                                    input logic signed [PW-1:0] d);
    logic signed [PW:0] s;
    s = {p[PW-1], p} + {d[PW-1], d};
    if (s > PMAX) return PMAX[PW-1:0];
    if (s < PMIN) return PMIN[PW-1:0];
    return s[PW-1:0];
  endfunction

  logic tick, byte_end, pend, load;
  assign tick     = (tmr_q == TLAST);
  assign byte_end = busy_q && tick && (bit_q == 4'd9);
  assign pend     = (px_q != '0) || (py_q != '0) || (btn_q != sent_q);

  // Next byte: the packet's next one, or byte 0 of a new packet.
  logic [2:0] nidx;
  always_comb begin
    nidx = 3'd0;
    load = 1'b0;
    if (!busy_q || byte_end) begin
      if (busy_q && idx_q != 3'd4) begin nidx = idx_q + 3'd1; load = 1'b1; end
      else if (pend)               begin nidx = 3'd0;         load = 1'b1; end
    end
  end

  logic signed [PW-1:0] tx, ty;
  logic [7:0]           nbyte;
  always_comb begin
    tx = '0;
    ty = '0;
    unique case (nidx)
      3'd1:    tx = half(px_q);
      3'd2:    ty = half(py_q);
      3'd3:    tx = clamp127(px_q);
      3'd4:    ty = clamp127(py_q);
      default: ;
    endcase
    nbyte = (nidx == 3'd0) ? {5'b10000, ~btn_q} : (tx[7:0] | ty[7:0]);
  end

  always_ff @(posedge clk) begin
    if (!run_n) begin
      px_q <= '0;
      py_q <= '0;
    end else begin
      px_q <= ev ? sat_add(px_q - (load ? tx : '0), dx) : px_q - (load ? tx : '0);
      py_q <= ev ? sat_add(py_q - (load ? ty : '0), dy) : py_q - (load ? ty : '0);
    end
  end

  // {L, M, R}, High = pressed.
  always_ff @(posedge clk) begin
    if (!run_n)  btn_q <= 3'b000;
    else if (ev) btn_q <= {ps2_mouse[0], ps2_mouse[2], ps2_mouse[1]};
  end

  always_ff @(posedge clk) begin
    if (!run_n)                    sent_q <= 3'b000;
    else if (load && nidx == 3'd0) sent_q <= btn_q;
  end

  always_ff @(posedge clk) begin
    if (!run_n)    tmr_q <= '0;
    else if (load) tmr_q <= '0;
    else if (busy_q) tmr_q <= tick ? '0 : tmr_q + 1'd1;
  end

  // Frame {stop, data, start} goes out LSB first; ones shift in behind.
  always_ff @(posedge clk) begin
    if (!run_n) begin
      busy_q <= 1'b0;
      fr_q   <= '1;
      bit_q  <= 4'd0;
      idx_q  <= 3'd0;
    end else if (load) begin
      busy_q <= 1'b1;
      fr_q   <= {1'b1, nbyte, 1'b0};
      bit_q  <= 4'd0;
      idx_q  <= nidx;
    end else if (byte_end) begin
      busy_q <= 1'b0;
      fr_q   <= '1;
    end else if (busy_q && tick) begin
      fr_q   <= {1'b1, fr_q[9:1]};
      bit_q  <= bit_q + 4'd1;
    end
  end

  assign active = act_q;
  assign rxd    = fr_q[0] | !act_q;

  logic unused_ok;
  assign unused_ok = &{1'b0, ps2_mouse[7:6], ps2_mouse[3], tx[PW-1:8], ty[PW-1:8]};
endmodule
`default_nettype wire
