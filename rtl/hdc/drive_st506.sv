// ST-506 drive on the WD1003-CMD cable (3600 RPM, MFM from sectors
// streamed a slot ahead, write decode back), stepped once per 50 ns by the
// 20 MHz enable that toggles the card's Y101 crystal.  The drive is mounted
// when hd_image has taken the geometry from the image (`mount`, one clk),
// with the image's data size.  With no image every status line reads
// inactive (Low).
`default_nettype none
module drive_st506 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        step_en,     // 20 MHz: one clk per 50 ns
  input  logic        sel,
  input  logic        step,
  input  logic        dirin,
  input  logic [2:0]  head,
  input  logic        wg,
  input  logic        rwc,
  input  logic        wmfm,
  output logic        rmfm,
  output logic        drdy,
  output logic        sc,
  output logic        tk000,
  output logic        wf,
  output logic        index,
  // image geometry (hd_image), applied at `mount`
  input  logic        mount,
  input  logic        present,
  input  logic        readonly,
  input  logic [11:0] cyls,
  input  logic [3:0]  heads,
  input  logic [7:0]  spt,
  input  logic [31:0] sectors,
  // image (hps_io sd_* shape)
  output logic [31:0] sd_lba,
  output logic        sd_rd,
  output logic        sd_wr,
  output logic        sd_fmt,      // block is in the drive's format region
  input  logic        sd_ack,
  input  logic [8:0]  sd_buff_addr,
  input  logic [7:0]  sd_buff_dout,
  output logic [7:0]  sd_buff_din,
  input  logic        sd_buff_wr,
  output logic        late         // a fetch, commit or format write missed its time
);
  logic [63:0] size;
  assign size = present ? {23'd0, sectors, 9'd0} : 64'd0;

  // Justification: (reg-a) a drive is on the cable (an image is mounted).
  logic fitted_q;
  always_ff @(posedge clk) begin
    if (!rst_n)     fitted_q <= 1'b0;
    else if (mount) fitted_q <= present;
  end

  logic d_drdy, d_sc, d_tk000, d_wf, d_index, d_rmfm;
  st506_drive u_drive (
    .clk(clk), .rst_n(rst_n), .step_en(step_en),
    .ds(sel), .step(step), .dirin(dirin), .hs(head), .wg(wg), .rwc(rwc), .wmfm(wmfm),
    .drdy(d_drdy), .sc(d_sc), .tk000(d_tk000), .wf(d_wf), .index(d_index), .rmfm(d_rmfm),
    .img_mounted(mount), .img_readonly(readonly), .img_size(size),
    .geo_cyls(cyls), .geo_heads(heads), .geo_spt(spt), .geo_ssz(2'b01),
    .late(late), .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_fmt(sd_fmt), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
    .sd_buff_wr(sd_buff_wr)
  );

  assign drdy  = fitted_q & d_drdy;
  assign sc    = fitted_q & d_sc;
  assign tk000 = fitted_q & d_tk000;
  assign wf    = fitted_q & d_wf;
  assign index = fitted_q & d_index;
  assign rmfm  = fitted_q & d_rmfm;
endmodule
`default_nettype wire
