// Debug readout of the disk-image path and the CPU board: counters in
// clk_sys, drawn as 20 rows of 32 bit cells (two words per row) over the bottom of the
// picture.  Lit = 1.  Words cross to clk_vid unsynchronised: a word may
// show torn while it changes.
`default_nettype none
module disk_dbg (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        reset_in,
  input  logic        pll_locked,
  input  logic        ioctl_download,
  // hps_io side
  input  logic [2:0]  img_mounted,
  input  logic [63:0] img_size,
  input  logic [2:0]  h_rd,
  input  logic [2:0]  h_wr,
  input  logic [2:0]  h_ack,
  input  logic        h_buff_wr,
  input  logic [7:0]  h_buff_dout,
  // drive side
  input  logic [2:0]  d_mounted,
  input  logic [63:0] d_size,
  input  logic [2:0][31:0] d_lba,
  input  logic [2:0]  d_rd,
  input  logic [2:0]  d_wr,
  input  logic [2:0]  d_scr,
  input  logic [2:0]  d_ack,
  input  logic        d_buff_wr,
  input  logic [7:0]  d_buff_dout,
  input  logic [2:0]  resident,
  input  logic        loading,
  input  logic        wb_busy,
  input  logic [1:0]  late,
  input  logic [15:0] st,
  // CPU board: {dma_wa, vi_n, nvi_n, r_w, ds, dmaen_n, st, as, ad, sn}
  input  logic [55:0] cpu,
  input  logic [1:0]  txd,
  // streaming server: hard disk selects, format table full, unit load
  // times (clk / 1024) {min, max} for floppy and hard disk
  input  logic [1:0]  hd_sel,
  input  logic        fmt_full,
  input  logic [1:0][15:0] ld_min,
  input  logic [1:0][15:0] ld_max,
  // video
  input  logic        clk_vid,
  input  logic        ce_pix,
  input  logic        de,
  input  logic        vs,
  input  logic [7:0]  r_in, g_in, b_in,
  output logic [7:0]  r, g, b
);
  logic [31:0] w [40];

  logic [2:0]  img_q, h_rd_q, h_ack_q, d_rd_q, d_wr_q, d_ack_q, d_mnt_q;
  logic        rst_q, reset_q;
  logic [25:0] tick;
  logic [31:0] lat_cnt, lat_ack;
  logic        lat_run, lat_acked;
  logic [15:0] blk_sum;
  logic [1:0]  ack_slot;
  logic [15:0] ms_idle;
  logic [15:0] ms_tick, ms_run, last_lba;
  logic [2:0]  njump;

  logic [6:0]  c_sn;
  logic [15:0] c_ad, c_off, c_lastoff, c_min, c_max, c_vec;
  logic [3:0]  c_st, c_cst;
  logic        c_as, c_as_q, c_ds, c_ds_q, c_rw, c_dmaen_n, c_nvi_n, c_vi_n, c_first;
  logic [22:0] c_wa;
  logic [6:0]  c_ssn;
  logic [1:0]  txd_q;
  assign {c_wa, c_vi_n, c_nvi_n, c_rw, c_ds, c_dmaen_n, c_st, c_as, c_ad, c_sn} = cpu;

  always_ff @(posedge clk) begin
    img_q <= img_mounted; h_rd_q <= h_rd; h_ack_q <= h_ack;
    d_rd_q <= d_rd; d_wr_q <= d_wr; d_ack_q <= d_ack; d_mnt_q <= d_mounted;
    rst_q <= rst_n; reset_q <= reset_in;

    if (tick == 26'd47_999_999) begin tick <= 26'd0; w[0] <= w[0] + 32'd1; end
    else tick <= tick + 26'd1;

    w[1] <= {ioctl_download, late, hd_sel, fmt_full, d_ack, d_wr, d_rd, h_ack, h_wr, h_rd,
             wb_busy, loading, resident, pll_locked, reset_in, rst_n};

    for (int s = 0; s < 3; s++)
      if (img_mounted[s] && !img_q[s]) w[2][8 * s + 8 +: 8] <= w[2][8 * s + 8 +: 8] + 8'd1;
    if (|(img_mounted & ~img_q)) begin
      if (img_size != 64'd0) w[2][7:0] <= w[2][7:0] + 8'd1;
    end

    if (|(h_rd & ~h_rd_q)) w[4] <= w[4] + 32'd1;
    if (|(h_ack & ~h_ack_q)) w[5] <= w[5] + 32'd1;
    if (h_buff_wr && |h_ack) begin
      w[6] <= w[6] + 32'd1;
      w[7] <= w[7] + {24'd0, h_buff_dout};
    end

    w[8] <= {ld_min[0], ld_max[0]};
    w[9] <= {ld_min[1], ld_max[1]};

    for (int s = 0; s < 3; s++)
      if (d_mounted[s] && !d_mnt_q[s]) w[12][8 * s + 8 +: 8] <= w[12][8 * s + 8 +: 8] + 8'd1;
    if (|(d_mounted & ~d_mnt_q)) begin
      if (d_size != 64'd0) w[12][7:0] <= w[12][7:0] + 8'd1;
    end

    if (|(d_rd & ~d_rd_q)) w[14] <= w[14] + 32'd1;
    if (|(d_wr & ~d_wr_q)) w[15] <= w[15] + 32'd1;
    for (int s = 0; s < 3; s++)
      if (d_ack[s] && !d_ack_q[s]) begin
        w[16] <= w[16] + 32'd1;
        w[18] <= {2'(s), d_scr[s], d_wr[s], d_lba[s][27:0]};
        ack_slot <= 2'(s);
        blk_sum <= 16'd0;
      end
    if (d_buff_wr) blk_sum <= blk_sum + {8'd0, d_buff_dout};
    if (|(d_ack_q & ~d_ack) && !w[18][29] && !w[18][28]) w[19] <= {w[18][15:0], blk_sum};

    // latency: a drive request rising to its ack, and to the end of the block
    if (|(d_rd & ~d_rd_q) && !lat_run) begin lat_run <= 1'b1; lat_acked <= 1'b0; lat_cnt <= 32'd0; end
    else if (lat_run) begin
      lat_cnt <= lat_cnt + 32'd1;
      if (|(d_ack & ~d_ack_q) && !lat_acked) begin
        lat_acked <= 1'b1;
      end
      if (|(d_ack_q & ~d_ack)) begin
        lat_run <= 1'b0;
        if (lat_cnt > w[20]) w[20] <= lat_cnt;
      end
    end

    if (rst_n && !rst_q) w[22][31:24] <= w[22][31:24] + 8'd1;
    if (reset_in && !reset_q) w[22][23:16] <= w[22][23:16] + 8'd1;
    if (ms_tick == 16'd47_999) begin
      ms_tick <= 16'd0;
      if (w[22][15:0] != 16'hFFFF) w[22][15:0] <= w[22][15:0] + 16'd1;
    end else ms_tick <= ms_tick + 16'd1;
    if (|(d_rd & ~d_rd_q) || |(d_wr & ~d_wr_q)) w[22][15:0] <= 16'd0;

    w[23] <= {st, 16'd0};

    // CPU: the offset and status while /AS is Low, taken at its rise
    c_as_q <= c_as;
    c_ds_q <= c_ds;
    txd_q  <= txd;
    if (!c_as) begin c_off <= c_ad; c_ssn <= c_sn; c_cst <= c_st; end
    if (c_as && !c_as_q) begin
      if (c_cst == 4'b1101) begin
        w[24] <= {9'd0, c_ssn, c_off};
        w[25] <= w[25] + 32'd1;
        if (c_off < c_min) c_min <= c_off;
        if (c_off > c_max) c_max <= c_off;
        if (c_off != c_lastoff + 16'd2 && c_off != c_lastoff + 16'd4 && c_off != c_lastoff + 16'd6 &&
            c_off != c_lastoff + 16'd8) w[35] <= {c_lastoff, c_off};
        c_lastoff <= c_off;
        if (c_ssn != w[27][6:0]) w[27] <= {w[27][23:0], 1'b0, c_ssn};
        if (c_ssn != 7'd0 && !c_first) begin c_first <= 1'b1; w[36] <= {16'd0, ms_run}; end
      end
      if (c_cst == 4'b0111) begin w[31] <= w[31] + 32'd1; w[37] <= {16'd0, ms_run}; end
      if (c_cst == 4'b0110) w[32] <= w[32] + 32'd1;
      if (c_cst == 4'b0100 || c_cst == 4'b0101) w[38] <= w[38] + 32'd1;
      if ((c_cst == 4'b1000 || c_cst == 4'b1001) && !c_rw) w[39] <= {9'd0, c_ssn, c_off};
    end
    if (!c_ds) c_vec <= c_ad;
    if (c_ds && !c_ds_q) begin
      if (c_cst == 4'b0111) w[34][31:16] <= c_vec;
      if (c_cst == 4'b0110) w[34][15:0]  <= c_vec;
    end
    if (tick == 26'd47_999_999) begin
      w[26] <= {c_min, c_max};
      c_min <= 16'hFFFF;
      c_max <= 16'h0000;
    end
    // DMA: memory cycles while the 8716 has the bus
    if (!c_dmaen_n && !c_ds && c_ds_q) begin
      if (!c_rw) begin w[28] <= {8'd0, c_wa, 1'b0}; w[29] <= w[29] + 32'd1; end
      else w[30] <= w[30] + 32'd1;
    end
    if (txd_q[0] && !txd[0]) w[33][31:16] <= w[33][31:16] + 16'd1;
    if (txd_q[1] && !txd[1]) w[33][15:0]  <= w[33][15:0] + 16'd1;
    if (rst_n && !rst_q) begin w[25] <= 32'd0; w[31] <= 32'd0; c_first <= 1'b0; end

    // mount and first request times (ms since the machine left reset)
    if (rst_n && !rst_q) begin ms_run <= 16'd0; w[21] <= 32'd0; end
    else if (ms_tick == 16'd47_999 && ms_run != 16'hFFFF) ms_run <= ms_run + 16'd1;
    if (|(d_mounted & ~d_mnt_q) && d_size != 64'd0) w[21][31:16] <= ms_run;
    if (|(d_rd & ~d_rd_q) && w[21][15:0] == 16'd0) w[21][15:0] <= ms_run | 16'd1;

    // the first four image-read jumps of more than 40 blocks: {from, to}
    for (int s = 0; s < 3; s++)
      if (d_ack[s] && !d_ack_q[s] && !d_scr[s] && !d_wr[s]) begin
        last_lba <= d_lba[s][15:0];
        if (((d_lba[s][15:0] > last_lba) ? d_lba[s][15:0] - last_lba : last_lba - d_lba[s][15:0]) > 16'd40 &&
            njump < 3'd4) begin
          njump <= njump + 3'd1;
          case (njump)
            3'd0: w[3]  <= {last_lba, d_lba[s][15:0]};
            3'd1: w[13] <= {last_lba, d_lba[s][15:0]};
            3'd2: w[11] <= {last_lba, d_lba[s][15:0]};
            default: w[17] <= {last_lba, d_lba[s][15:0]};
          endcase
        end
      end
  end

  // ---- overlay ---------------------------------------------------------------
  localparam int X0 = 4, Y0 = 238, CW = 356;
  logic [9:0] x, y;
  logic       de_q, vs_q;
  always_ff @(posedge clk_vid) begin
    if (ce_pix) begin
      de_q <= de;
      vs_q <= vs;
      if (de) x <= x + 10'd1;
      else x <= 10'd0;
      if (de_q && !de) y <= y + 10'd1;
      if (vs && !vs_q) y <= 10'd0;
    end
  end

  // five register stages from x, y to a lit cell: the picture shifts by
  // up to five pixels against the cells
  logic [9:0] xr, xc, yr, yp, yp3, yp4;
  logic [5:0] r44;
  logic [4:0] q44;
  logic       c, c3, c4, inr, inr2, inr3, inr4, okx, on;
  logic [3:0] nib, nib3;
  logic [2:0] bn;
  logic [4:0] row, row3, row4;
  logic       val;
  always_ff @(posedge clk_vid) begin
    xr  <= x - 10'(X0);
    yr  <= y - 10'(Y0);
    inr <= x >= 10'(X0) && x < 10'(X0 + 2 * CW) && y >= 10'(Y0) && y < 10'(Y0 + 20 * 9);

    c    <= xr >= 10'(CW);
    xc   <= (xr >= 10'(CW)) ? xr - 10'(CW) : xr;
    row  <= 5'(yr / 10'd9);
    yp   <= yr % 10'd9;
    inr2 <= inr;

    q44  <= 5'(xc / 10'd44);
    r44  <= 6'(xc % 10'd44);
    row3 <= row;
    c3   <= c;
    inr3 <= inr2;
    yp3  <= yp;

    nib  <= 4'(q44);
    bn   <= 3'(r44 / 6'd10);
    okx  <= q44 < 5'd8 && r44 < 6'd40 && (r44 % 6'd10) >= 6'd1 && (r44 % 6'd10) <= 6'd8;
    row4 <= row3;
    c4   <= c3;
    inr4 <= inr3;
    yp4  <= yp3;

    val  <= w[{row4, c4}][~{nib[2:0], bn[1:0]}];
    on   <= inr4 && okx && yp4 >= 10'd1 && yp4 <= 10'd7;
    nib3 <= nib;
  end

  always_comb begin
    r = r_in; g = g_in; b = b_in;
    if (on) begin
      r = val ? 8'h00 : 8'h50;
      g = val ? 8'hFF : 8'h50;
      b = val ? 8'h00 : (nib3[0] ? 8'hA0 : 8'h50);
    end
  end
endmodule
`default_nettype wire
