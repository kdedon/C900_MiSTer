// Am7990 silo: one 48-byte FIFO between the bus and the serial side
// (TM p.1-16).  The chip is half duplex: it holds transmit or receive
// bytes, both only in loopback, where the received frame fills in
// behind the transmitted one (TM p.1-24 LOOP).
//
// Entry: {rx, tag, last, byte}.  Transmit tag[0] = send the FCS after
// this last byte.  Receive tag on a last byte: 00 good, 01 FCS error,
// 10 overflow, 11 runt.
// Receive bytes count once the frame passes the address filter; a
// rejected frame is rewound.  An overflow rewrites the frame's newest
// byte as its last, tagged overflow.
`default_nettype none
module am7990_silo (
  input  logic        clk,
  input  logic        clr,
  // transmit: one or two bytes of a DMA word; last/fcs go with the final byte
  input  logic        tpush,
  input  logic [7:0]  tb0,
  input  logic [7:0]  tb1,
  input  logic        ttwo,
  input  logic        tlast,
  input  logic        tfcs,
  // receive: bytes from the deserializer
  input  logic        rwe,
  input  logic [7:0]  rbyte,
  input  logic        rlast,
  input  logic [1:0]  rtag,
  input  logic        rcommit,     // the frame is accepted
  input  logic        rrewind,
  input  logic        rmark,
  // show-ahead head entry
  output logic        hv,
  output logic [11:0] hd,
  input  logic        take,
  output logic [5:0]  free,        // bytes the silo can take
  output logic        full,
  output logic [5:0]  tbytes,      // transmit bytes held
  output logic        tframe,      // a whole transmit frame held
  output logic [5:0]  rbytes       // receive bytes committed, head included
);
  localparam logic [5:0] CAP  = 6'd48;
  localparam logic [1:0] OFLO = 2'b10;

  (* ramstyle = "MLAB, no_rw_check" *) logic [11:0] mem [0:63];
  // Justification: (reg-a) write, commit and read pointers; the second
  // byte of a push; transmit entry and frame counts; the newest receive
  // byte, for an overflow mark.
  logic [5:0]  wp_q, cp_q, rp_q;
  logic        p1_q;
  logic [11:0] p1d_q;
  logic [5:0]  tn_q;
  logic [4:0]  te_q;
  logic [7:0]  lb_q;

  logic [5:0]  used;
  assign used = wp_q - rp_q + 6'(hv);
  assign full = used >= CAP;

  logic        rw, tw, we;
  logic [5:0]  wa;
  logic [11:0] wd;
  always_comb begin
    rw = rwe && !full && !rmark;
    tw = 1'b0;
    we = 1'b1;
    wa = wp_q;
    wd = p1d_q;
    if (rmark) begin
      wa = wp_q - 6'd1;
      wd = {1'b1, OFLO, 1'b1, lb_q};
    end else if (rw) begin
      wd = {1'b1, rtag, rlast, rbyte};
    end else if (tpush) begin
      tw = 1'b1;
      wd = {1'b0, 1'b0, tfcs && !ttwo, tlast && !ttwo, tb0};
    end else if (p1_q) begin
      tw = 1'b1;
    end else begin
      we = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
  end

  logic rd, tt;
  assign rd = (!hv || take) && cp_q != rp_q;
  assign tt = take && !hd[11];

  always_ff @(posedge clk) begin
    if (rd) hd <= mem[rp_q];
  end

  always_ff @(posedge clk) begin
    if (clr) begin
      wp_q <= 6'd0;
      cp_q <= 6'd0;
      rp_q <= 6'd0;
      hv   <= 1'b0;
      p1_q <= 1'b0;
      tn_q <= 6'd0;
      te_q <= 5'd0;
    end else begin
      p1_q <= tpush && ttwo;
      if (tpush) p1d_q <= {1'b0, 1'b0, tfcs, tlast, tb1};
      if (rw) lb_q <= rbyte;
      if (rrewind)       wp_q <= cp_q;
      else if (rw || tw) wp_q <= wp_q + 6'd1;
      if (tw || (rw && rcommit)) cp_q <= wp_q + 6'd1;
      else if (rcommit && !rrewind) cp_q <= wp_q;
      if (rd) begin
        rp_q <= rp_q + 6'd1;
        hv   <= 1'b1;
      end else if (take) begin
        hv <= 1'b0;
      end
      tn_q <= tn_q + 6'(tw) - 6'(tt);
      te_q <= te_q + 5'(tw && wd[8]) - 5'(tt && hd[8]);
    end
  end

  assign free   = CAP - used - 6'(p1_q);
  assign tbytes = tn_q + 6'(p1_q);
  assign tframe = te_q != 5'd0;
  assign rbytes = cp_q - rp_q + 6'(hv) - tn_q;
endmodule
`default_nettype wire
