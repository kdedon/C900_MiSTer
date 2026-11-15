// Hard disk image geometry, taken from the mounted image alone (the host
// sends it to the 8049 in the 0x0C block).  Rules:
//   1. a fixed VHD: the last 512-byte sector is a footer with the cookie
//      "conectix" and disk type 2; geometry from the footer's CHS field,
//      data = the image less the footer; more than 2047 cylinders (the
//      WD2010's cylinder register), 8 heads or 17 sectors (a cylinder
//      buffer holds 136 blocks) is no drive;
//   2. a raw image whose size is exactly a C900 drive type (the first in
//      the table wins: 306x4 before 612x2);
//   3. a raw image within one cylinder below a type rounds up to it;
//   4. anything else: no drive (not ready).
// On mount the last sector is read through the hps_io block port to look
// for the footer; while probing this module owns the port (busy High).
`default_nettype none
module hd_image (
  input  logic        clk,
  input  logic        rst_n,
  // hps_io mount + block port for this slot
  input  logic        img_mounted,
  input  logic        img_readonly,
  input  logic [63:0] img_size,
  output logic [31:0] sd_lba,
  output logic        sd_rd,
  input  logic        sd_ack,
  input  logic [8:0]  sd_buff_addr,
  input  logic [7:0]  sd_buff_dout,
  input  logic        sd_buff_wr,
  // result
  output logic        busy,         // probing: the port belongs to this module
  output logic        present,      // a drive is fitted
  output logic        readonly,
  output logic [11:0] cyls,
  output logic [3:0]  heads,
  output logic [7:0]  spt,
  output logic [31:0] sectors       // data sectors (512 B)
);
  // ---- C900 drive types (17 sectors of 512 B) --------------------------------------
  localparam int NTYPES = 8;
  localparam logic [11:0] T_CYL  [NTYPES] = '{12'd306, 12'd612, 12'd20, 12'd704,
                                             12'd652, 12'd612, 12'd698, 12'd10};
  localparam logic [3:0]  T_HEAD [NTYPES] = '{4'd4, 4'd4, 4'd4, 4'd7, 4'd4, 4'd2, 4'd7, 4'd4};

  function automatic logic [31:0] type_sectors(input logic [2:0] k);
    return 32'(T_CYL[k]) * 32'(T_HEAD[k]) * 32'd17;
  endfunction

  // ---- probe FSM -----------------------------------------------------------------
  typedef enum logic [2:0] { S_IDLE, S_REQ, S_XFER, S_DECIDE, S_DONE } state_e;
  state_e state_q;

  logic [31:0] nsec_q;          // image size in sectors
  logic [63:0] cookie_q;
  logic [31:0] dtype_q;
  logic [31:0] chs_q;
  logic [2:0]  ack_q;

  always_ff @(posedge clk) begin
    if (!rst_n) ack_q <= 3'b000;
    else        ack_q <= {ack_q[1:0], sd_ack};
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q  <= S_IDLE;
      nsec_q   <= 32'd0;
      readonly <= 1'b0;
      sd_rd    <= 1'b0;
      sd_lba   <= 32'd0;
    end else begin
      if (img_mounted) begin
        nsec_q   <= img_size[40:9];
        readonly <= img_readonly;
        sd_rd    <= 1'b0;
        state_q  <= (img_size[63:9] == 55'd0) ? S_DONE : S_REQ;
      end else begin
        unique case (state_q)
          S_REQ: begin
            sd_lba  <= nsec_q - 32'd1;
            sd_rd   <= 1'b1;
            state_q <= S_XFER;
          end
          S_XFER: begin
            if (ack_q[1] && !ack_q[2]) sd_rd <= 1'b0;          // request taken
            if (!ack_q[1] && ack_q[2]) state_q <= S_DECIDE;    // sector delivered
          end
          S_DECIDE: state_q <= S_DONE;
          default: ;
        endcase
      end
    end
  end

  // Footer fields from the delivered sector (big-endian).
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cookie_q <= 64'd0;
      dtype_q  <= 32'd0;
      chs_q    <= 32'd0;
    end else if (img_mounted) begin
      cookie_q <= 64'd0;
      dtype_q  <= 32'd0;
      chs_q    <= 32'd0;
    end else if (state_q == S_XFER && sd_ack && sd_buff_wr) begin
      if (sd_buff_addr < 9'd8)
        cookie_q <= {cookie_q[55:0], sd_buff_dout};
      if (sd_buff_addr >= 9'd56 && sd_buff_addr < 9'd60)
        chs_q <= {chs_q[23:0], sd_buff_dout};
      if (sd_buff_addr >= 9'd60 && sd_buff_addr < 9'd64)
        dtype_q <= {dtype_q[23:0], sd_buff_dout};
    end
  end

  // ---- decision ------------------------------------------------------------------
  logic        is_vhd, exact_hit, near_hit;
  logic [2:0]  exact_k, near_k;
  logic [31:0] raw_sec;

  logic        vhd_fits;

  assign is_vhd   = (cookie_q == 64'h636F6E6563746978) && (dtype_q == 32'd2);   // "conectix"
  assign vhd_fits = chs_q[31:16] <= 16'd2047 && chs_q[15:8] <= 8'd8 && chs_q[7:0] <= 8'd17;
  assign raw_sec = nsec_q;

  // Every type is under 2^17 sectors: compare 17 bits, the rest must be 0.
  logic        raw_small;
  logic [16:0] raw17;
  assign raw_small = raw_sec[31:17] == 15'd0;
  assign raw17     = raw_sec[16:0];

  always_comb begin
    exact_hit = 1'b0; exact_k = 3'd0;
    near_hit  = 1'b0; near_k  = 3'd0;
    for (int k = NTYPES - 1; k >= 0; k--) begin
      if (raw_small && raw17 == 17'(type_sectors(3'(k)))) begin
        exact_hit = 1'b1;
        exact_k   = 3'(k);
      end
      if (raw_small && raw17 < 17'(type_sectors(3'(k))) &&
          raw17 > 17'(type_sectors(3'(k)) - 32'(T_HEAD[k]) * 32'd17)) begin
        near_hit = 1'b1;
        near_k   = 3'(k);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || img_mounted) begin
      present <= 1'b0;
      cyls    <= 12'd0;
      heads   <= 4'd0;
      spt     <= 8'd0;
      sectors <= 32'd0;
    end else if (state_q == S_DECIDE) begin
      present <= 1'b1;
      if (is_vhd) begin
        present <= vhd_fits;
        cyls    <= chs_q[27:16];
        heads   <= chs_q[11:8];
        spt     <= chs_q[7:0];
        sectors <= nsec_q - 32'd1;
      end else if (exact_hit) begin
        spt     <= 8'd17;
        cyls    <= T_CYL[exact_k];
        heads   <= T_HEAD[exact_k];
        sectors <= raw_sec;
      end else if (near_hit) begin
        spt     <= 8'd17;
        cyls    <= T_CYL[near_k];
        heads   <= T_HEAD[near_k];
        sectors <= raw_sec;
      end else begin
        present <= 1'b0;
      end
    end
  end

  logic unused_ok;
  assign unused_ok = &{1'b0, img_size[8:0]};

  assign busy = (state_q == S_REQ) || (state_q == S_XFER) || (state_q == S_DECIDE);
endmodule
`default_nettype wire
