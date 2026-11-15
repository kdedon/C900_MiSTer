// Western Digital WD2010-05 Winchester disk controller (WD1003-CMD
// U12), from the WD2010-05 datasheet (printed pages 67-97).
//
// Ports are the chip's 40 pins.  RE, WE and D are bidirectional: the
// `_in` ports are the host side, `_out`/`_oe` the chip's drivers (RE and
// WE are outputs only inside a BCS frame).  `clk` is the fabric clock;
// every pin is sampled by it and no pin is used as a clock.  WCLK
// (pin 25, 5 MHz) and RCLK (pin 39) arrive as one-`clk` edge pulses,
// `wclk_rise`/`wclk_fall` and `rclk_rise`/`rclk_fall`.  WCLK paces the
// controller: all timers count WCLK rises, the write channel uses both
// edges.  RCLK and `rd` (pin 37, a level taken at `clk`) feed the read
// channel, whose byte timing follows the disk.  The other inputs are
// `clk`-domain levels (the drive, separator and 8049 bus models of the
// core run on `clk`); pins from outside the fabric need a synchronizer
// at the core boundary.
//
// /MR is the only reset: a level, applied through the next-state logic,
// clearing all internal logic but the task file (pp.68, 77).  No source
// gives a power-up state; the initialisers are the former reset values,
// and the task file's (precomp 0xFF, the rest zero) is OPEN.
//
// Geometry comes from the task file only: cylinder (11 bits), head,
// sector number, sector count and the SDH sector size (128-1024 bytes)
// and CRC/ECC mode.
//
// Not implemented (OPEN): ECC
// auto-correction and the Compute Correction pattern search (an ECC
// data error is retried and reported like a CRC error; Compute
// Correction writes the four syndrome bytes and reports the error as
// uncorrectable); EARLY/LATE precompensation (held de-asserted).
`default_nettype none

module wd2010 (
  input  logic       clk,
  // host interface
  input  logic       cs_n,
  input  logic [2:0] a,
  input  logic       re_n_in,
  input  logic       we_n_in,
  input  logic [7:0] d_in,
  output logic [7:0] d_out,
  output logic       d_oe,
  output logic       re_n_out,
  output logic       re_oe,
  output logic       we_n_out,
  output logic       we_oe,
  input  logic       mr_n,
  output logic       intrq,
  output logic       sdhle_n,
  // sector buffer
  output logic       bcs_n,
  output logic       bcr_n,
  input  logic       brdy,
  output logic       bdrq,
  // drive and data separator
  input  logic       wclk_rise,
  input  logic       wclk_fall,
  input  logic       rclk_rise,
  input  logic       rclk_fall,
  input  logic       rd,
  input  logic       drun,
  output logic       rg,
  output logic       wg,
  output logic       wd,
  output logic       early_n,
  output logic       late_n,
  output logic       rwc,
  output logic       step,
  output logic       dirin,
  input  logic       drdy,
  input  logic       index,
  input  logic       wf,
  input  logic       tk000,
  input  logic       sc
);

  // ------------------------------------------------------------------
  // Constants

  localparam logic [7:0] ErrBB = 8'h80, ErrCRC = 8'h40, ErrID = 8'h10, ErrAC = 8'h04,
                         ErrTK = 8'h02, ErrDM = 8'h01;
  localparam logic [15:0] CrcPoly = 16'h1021;
  localparam logic [31:0] EccPoly = 32'h140A_0445;
  localparam logic [7:0]  ByteA1 = 8'hA1, ByteF8 = 8'hF8, Byte4E = 8'h4E, ByteFF = 8'hFF;
  localparam logic [15:0] BcrWidth    = 16'd8;   // tBCR 1.6 us
  localparam logic [15:0] MrToBcr     = 16'd16;  // tMRB 3.2 us
  localparam logic [15:0] StrobeWidth = 16'd2;   // tWRB / tREB 2 WCLK
  localparam logic [15:0] SpliceWclk  = 16'd24;  // WG on three bytes after the ID CRC (Fig 13 note 4)
  localparam logic [15:0] RgSuppress  = 16'd32;  // RG back on past the splice (Fig 13 note 5; length OPEN)
  localparam logic [10:0] RestoreMax  = 11'd2047;

  // ------------------------------------------------------------------
  // CRC-16 (x^16+x^12+x^5+1) and ECC-32 (0x140A0445), MSB first, both
  // preset to all ones and run from the A1; a field checks when the
  // register is zero after its check bytes.  The CRC-16 is kept in bits
  // 31:16, so the next check byte is always bits 31:24.

  function automatic logic [31:0] chk_init(input logic ecc);
    chk_init = ecc ? 32'hFFFF_FFFF : 32'hFFFF_0000;
  endfunction

  function automatic logic [31:0] chk_byte(input logic [31:0] c, input logic [7:0] b, input logic ecc);
    logic [31:0] r, p;
    p = ecc ? EccPoly : {CrcPoly, 16'h0000};
    r = c ^ {b, 24'h000000};
    for (int i = 0; i < 8; i++) r = r[31] ? ((r << 1) ^ p) : (r << 1);
    return r;
  endfunction

  // Sector size from the SDH size field: 00 256, 01 512, 10 1024, 11 128.
  function automatic logic [10:0] sec_len(input logic [1:0] s);
    case (s)
      2'b00:   sec_len = 11'd256;
      2'b01:   sec_len = 11'd512;
      2'b10:   sec_len = 11'd1024;
      default: sec_len = 11'd128;
    endcase
  endfunction

  // Step period in WCLK (p.80, 5 MHz WCLK).
  function automatic logic [15:0] step_period(input logic [3:0] r);
    case (r)
      4'h0:    step_period = 16'd175;
      4'hE:    step_period = 16'd16;
      4'hF:    step_period = 16'd80;
      default: step_period = 16'd2500 * {12'd0, r};
    endcase
  endfunction

  // IDENT byte: FE ^ {c10, 0, c9, c8} (p.90: FE FF FC FD F6 F7 F4 F5).
  function automatic logic [7:0] ident_of(input logic [2:0] ch);
    ident_of = 8'hFE ^ {4'h0, ch[2], 1'b0, ch[1:0]};
  endfunction

  // ------------------------------------------------------------------
  // Pin sampling and WCLK / edge enables

  // Justification: edge detection of sampled pins (reg-a).
  logic index_q, sc_q, brdy_q;
  logic tick, idx_rise, sc_rise, brdy_rise;
  assign tick      = wclk_rise;
  assign idx_rise  = index & ~index_q;
  assign sc_rise   = sc & ~sc_q;
  assign brdy_rise = brdy & ~brdy_q;

  initial begin
    index_q = 1'b0; sc_q = 1'b0; brdy_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    index_q <= index; sc_q <= sc; brdy_q <= brdy;
  end

  // ------------------------------------------------------------------
  // Task file (not cleared by MR, p.77)

  // Justification: task file registers (reg-a).
  logic [7:0] precomp_q, seccnt_q, secnum_q, cyllo_q, cylhi_q, sdh_q;
  // Justification: error register, status flags (reg-a).
  logic [7:0] err_q;
  logic       bsy_q, cip_q, errst_q, intrq_q, bdrq_q;
  // Justification: status latched by an aborted command (reg-a).
  logic       lat_q, lat_rdy_q, lat_wf_q, lat_sc_q;

  logic [7:0] status_c;
  assign status_c = {bsy_q, lat_q ? lat_rdy_q : drdy, lat_q ? lat_wf_q : wf, lat_q ? lat_sc_q : sc,
                     bdrq_q, 1'b0, cip_q, errst_q};

  // ------------------------------------------------------------------
  // Host bus: a read drives D from the CS+RE fall; a write commits at
  // the end of CS+WE with the last data sampled.  Host strobes are
  // ignored inside a BCS frame.

  // Justification: host strobe edge detection and the write data hold (reg-a).
  logic       hrd_q, hwr_q;
  logic [7:0] hwd_q;
  logic [2:0] hwa_q;
  logic       hrd, hwr, hrd_fall, hwr_end;
  logic       host_ok;
  assign hrd      = ~cs_n & ~re_n_in & host_ok;
  assign hwr      = ~cs_n & ~we_n_in & host_ok;
  assign hrd_fall = hrd & ~hrd_q;
  assign hwr_end  = ~hwr & hwr_q;

  logic [7:0] rdmux_c;
  always_comb begin
    if (cip_q && a != 3'd0) rdmux_c = status_c;
    else begin
      case (a)
        3'd1:    rdmux_c = err_q;
        3'd2:    rdmux_c = seccnt_q;
        3'd3:    rdmux_c = secnum_q;
        3'd4:    rdmux_c = cyllo_q;
        3'd5:    rdmux_c = cylhi_q;
        3'd6:    rdmux_c = sdh_q;
        3'd7:    rdmux_c = status_c;
        default: rdmux_c = 8'h00;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Controller state

  typedef enum logic [5:0] {
    StIdle, StDispatch,
    StEndOk, StEndAc, StEnd3, StEndBdrq, StEndBrdy,
    StRsChk, StRsPulse,
    StPreChg, StPreChgR, StPreSeek, StSkChk, StSkPulse, StSkDelay, StSkLastSc, StSkDone,
    StReady,
    StSrWait, StSrLock, StSrAm, StSrAmWin, StSrField,
    StRdSplice, StRdLock, StRdAm, StRdAmWin, StRdF8, StRdData, StRdDone,
    StRdNextBrdy,
    StWsBcr, StWsBrdy, StWrSplice, StWrRun, StWrDone, StWrNextBrdy,
    StFmBrdy, StFmIndex, StFmRun,
    StCcRun, StCcBrdy
  } st_e;

  // Where a search, seek or restore returns to.
  typedef enum logic [2:0] {RetNone, RetDrvChg, RetReseekScan, RetScanCmd, RetAfterSeek, RetRestoreChg} ret_e;

  // Justification: controller state, return point and command (reg-a).
  st_e        st_q;
  ret_e       ret_q;
  logic [7:0] cmd_q;
  // Justification: WCLK timer shared by the states (reg-a).
  logic [15:0] tmr_q;
  // Justification: WCLK rises with DRUN High while RG is off in an ID search (reg-a).
  logic [4:0]  dq_q;
  // Justification: drive position, last drive, step rate, ECC span (reg-a).
  logic [10:0] pcyl_q;
  logic [1:0]  ldrv_q;
  logic [3:0]  rate_q;
  // Justification: seek bookkeeping (reg-a).
  logic [10:0] nsteps_q;
  logic        dir_q, implied_q, sc_edge_q, need_edge_q, reseek_q, rsforce_q;
  // Justification: index pulses since a search started, data retries (reg-a).
  logic [3:0]  idx_q, retry_q;
  // Justification: search mode and the ID being read (reg-a).
  logic        any_q, found_q, idbad_q;
  logic [2:0]  fld_q;
  logic [2:0]  id_ch_q;
  logic [7:0]  id_cyl_q, id_sec_q;
  logic        id_bb_q;
  logic [4:0]  id_sh_q;   // {size, head}
  // Justification: CRC/ECC register and mode (reg-a).
  logic [31:0] crc_q;
  logic        ecc_q;
  // Justification: data field byte count and phase (reg-a).
  logic [10:0] cnt_q;
  logic        chkph_q;
  // Justification: read channel control (reg-a).
  logic        rg_q, am_en_q;
  // Justification: buffer pins and strobe timers (reg-a).
  logic        bcr_q, we_q, re_q;
  logic [15:0] bcr_t_q, mrb_t_q;
  logic [1:0]  we_t_q, re_t_q;
  logic [7:0]  bd_q;
  logic        bd_oe_q;
  // Justification: buffer fetch for writes: request, slot, fetched bytes (reg-a).
  logic        fetch_q, fbusy_q;
  logic        fslot_q;
  logic [7:0]  fb0_q, fb1_q;
  // Justification: write sequencer (reg-a).
  logic        wg_q, wrun_q;
  logic [4:0]  wph_q;
  logic [10:0] wcnt_q;
  logic [7:0]  nbyte_q;
  logic        nmc_q, crc_on_q;
  logic [7:0]  fmt_left_q;
  logic        bcs_r_q;
  logic        step_out_q, dirin_q;

  // Read channel.
  logic       am_c, bv_c;
  logic [7:0] rbyte_c;
  logic       rd_clr;
  assign rd_clr = ~rg_q;

  wd2010_rdchan u_rd (
    .clk(clk), .rclk_rise(rclk_rise), .rclk_fall(rclk_fall), .rd(rd), .clr(rd_clr), .am_en(am_en_q),
    .am(am_c), .byte_v(bv_c), .byte_q(rbyte_c)
  );

  // Write channel.
  logic take_c;
  wd2010_wrchan u_wr (
    .clk(clk), .wclk_rise(wclk_rise), .wclk_fall(wclk_fall), .run(wrun_q), .nbyte(nbyte_q), .mc(nmc_q),
    .take(take_c), .wd(wd)
  );

  // Command fields.
  logic [3:0]  op_c;
  logic        cmd_i, cmd_m, cmd_l, cmd_t;
  logic [10:0] tcyl_c;
  logic [10:0] slen_c, dlen_c;
  logic [3:0]  idx_lim_c;
  logic        is_read, is_write, is_fmt, is_seek;
  assign op_c      = cmd_q[7:4];
  assign cmd_i     = cmd_q[3];
  assign cmd_m     = cmd_q[2];
  assign cmd_l     = cmd_q[1];
  assign cmd_t     = cmd_q[0];
  assign tcyl_c    = {cylhi_q[2:0], cyllo_q};
  assign slen_c    = sec_len(sdh_q[6:5]);
  assign dlen_c    = slen_c + (cmd_l ? 11'd4 : 11'd0);
  assign idx_lim_c = (cmd_t && (op_c == 4'h2 || op_c == 4'h3 || op_c == 4'h4)) ? 4'd2 : 4'd10;
  assign is_read   = op_c == 4'h2;
  assign is_write  = op_c == 4'h3;
  assign is_fmt    = op_c == 4'h5;
  assign is_seek   = op_c == 4'h7;

  // Drive monitoring: WF or DRDY low aborts a drive command (p.83).
  logic mon_c;
  always_comb begin
    case (st_q)
      StRsChk, StRsPulse, StPreChg, StPreSeek, StSkChk, StSkPulse, StSkDelay, StSkLastSc,
      StReady, StSrWait, StSrLock, StSrAm, StSrAmWin, StSrField,
      StRdSplice, StRdLock, StRdAm, StRdAmWin, StRdF8, StRdData,
      StWrSplice, StWrRun, StFmIndex, StFmRun: mon_c = 1'b1;
      default: mon_c = 1'b0;
    endcase
  end

  // ID match for Read/Write: cylinder, head, size, sector (p.83).
  logic [7:0] exp_c;
  always_comb begin
    case (fld_q)
      3'd0:    exp_c = ident_of(tcyl_c[10:8]);
      3'd1:    exp_c = tcyl_c[7:0];
      3'd2:    exp_c = {1'b0, sdh_q[6:5], 2'b00, sdh_q[2:0]};
      default: exp_c = secnum_q;
    endcase
  end

  logic ident_ok_c;
  assign ident_ok_c = rbyte_c[7:4] == 4'hF && rbyte_c[2] == 1'b1;   // FE FF FC FD F4-F7

  logic [31:0] crc_take_c;
  assign crc_take_c = chk_byte(crc_q, nbyte_q, ecc_q);

  logic [10:0] idcyl_c;
  assign idcyl_c = {id_ch_q, id_cyl_q};

  // ------------------------------------------------------------------
  // Host strobe capture

  // Justification: next-state values of the write data hold (reg-a).
  logic [7:0] hwd_d;
  logic [2:0] hwa_d;
  always_comb begin
    hwd_d = hwd_q;
    hwa_d = hwa_q;
    if (hwr) begin
      hwd_d = d_in;
      hwa_d = a;
    end
  end

  initial begin
    hrd_q = 1'b0; hwr_q = 1'b0; hwd_q = 8'h00; hwa_q = 3'd0;
  end
  always_ff @(posedge clk) begin
    hrd_q <= hrd; hwr_q <= hwr; hwd_q <= hwd_d; hwa_q <= hwa_d;
  end

  // ------------------------------------------------------------------
  // Next-state logic of the controller registers

  // Justification: next-state values of the task file registers, error register and status flags (reg-a).
  logic [7:0] precomp_d;
  logic [7:0] seccnt_d;
  logic [7:0] secnum_d;
  logic [7:0] cyllo_d;
  logic [7:0] cylhi_d;
  logic [7:0] sdh_d;
  logic [7:0] err_d;
  logic bsy_d;
  logic cip_d;
  logic errst_d;
  logic intrq_d;
  logic bdrq_d;
  logic lat_d;
  logic lat_rdy_d;
  logic lat_wf_d;
  logic lat_sc_d;
  // Justification: next-state values of the buffer handshake strobes, timers and fetch slots (reg-a).
  logic bcr_d;
  logic we_d;
  logic re_d;
  logic [15:0] bcr_t_d;
  logic [15:0] mrb_t_d;
  logic [1:0] we_t_d;
  logic [1:0] re_t_d;
  logic [7:0] bd_d;
  logic bd_oe_d;
  logic fetch_d;
  logic fbusy_d;
  logic fslot_d;
  logic [7:0] fb0_d;
  logic [7:0] fb1_d;
  logic bcs_r_d;
  // Justification: next-state values of the read/write channel control, CRC/ECC and write sequencer (reg-a).
  logic rg_d;
  logic am_en_d;
  logic wg_d;
  logic wrun_d;
  logic [4:0] wph_d;
  logic [10:0] wcnt_d;
  logic [7:0] nbyte_d;
  logic nmc_d;
  logic crc_on_d;
  logic [7:0] fmt_left_d;
  logic [31:0] crc_d;
  logic ecc_d;
  logic [10:0] cnt_d;
  logic chkph_d;
  logic step_out_d;
  logic dirin_d;
  // Justification: next-state values of the command sequencer, seek bookkeeping and ID search (reg-a).
  st_e st_d;
  ret_e ret_d;
  logic [7:0] cmd_d;
  logic [15:0] tmr_d;
  logic [4:0] dq_d;
  logic [10:0] pcyl_d;
  logic [1:0] ldrv_d;
  logic [3:0] rate_d;
  logic [10:0] nsteps_d;
  logic dir_d;
  logic implied_d;
  logic sc_edge_d;
  logic need_edge_d;
  logic reseek_d;
  logic rsforce_d;
  logic [3:0] idx_d;
  logic [3:0] retry_d;
  logic any_d;
  logic found_d;
  logic idbad_d;
  logic [2:0] fld_d;
  logic [2:0] id_ch_d;
  logic [7:0] id_cyl_d;
  logic id_bb_d;
  logic [4:0] id_sh_d;
  logic [7:0] id_sec_d;

  always_comb begin
    precomp_d = precomp_q;
    seccnt_d = seccnt_q;
    secnum_d = secnum_q;
    cyllo_d = cyllo_q;
    cylhi_d = cylhi_q;
    sdh_d = sdh_q;
    err_d = err_q;
    bsy_d = bsy_q;
    cip_d = cip_q;
    errst_d = errst_q;
    intrq_d = intrq_q;
    bdrq_d = bdrq_q;
    lat_d = lat_q;
    lat_rdy_d = lat_rdy_q;
    lat_wf_d = lat_wf_q;
    lat_sc_d = lat_sc_q;
    bcr_d = bcr_q;
    we_d = we_q;
    re_d = re_q;
    bcr_t_d = bcr_t_q;
    mrb_t_d = mrb_t_q;
    we_t_d = we_t_q;
    re_t_d = re_t_q;
    bd_d = bd_q;
    bd_oe_d = bd_oe_q;
    fetch_d = fetch_q;
    fbusy_d = fbusy_q;
    fslot_d = fslot_q;
    fb0_d = fb0_q;
    fb1_d = fb1_q;
    bcs_r_d = bcs_r_q;
    rg_d = rg_q;
    am_en_d = am_en_q;
    wg_d = wg_q;
    wrun_d = wrun_q;
    wph_d = wph_q;
    wcnt_d = wcnt_q;
    nbyte_d = nbyte_q;
    nmc_d = nmc_q;
    crc_on_d = crc_on_q;
    fmt_left_d = fmt_left_q;
    crc_d = crc_q;
    ecc_d = ecc_q;
    cnt_d = cnt_q;
    chkph_d = chkph_q;
    step_out_d = step_out_q;
    dirin_d = dirin_q;
    st_d = st_q;
    ret_d = ret_q;
    cmd_d = cmd_q;
    tmr_d = tmr_q;
    dq_d = dq_q;
    pcyl_d = pcyl_q;
    ldrv_d = ldrv_q;
    rate_d = rate_q;
    nsteps_d = nsteps_q;
    dir_d = dir_q;
    implied_d = implied_q;
    sc_edge_d = sc_edge_q;
    need_edge_d = need_edge_q;
    reseek_d = reseek_q;
    rsforce_d = rsforce_q;
    idx_d = idx_q;
    retry_d = retry_q;
    any_d = any_q;
    found_d = found_q;
    idbad_d = idbad_q;
    fld_d = fld_q;
    id_ch_d = id_ch_q;
    id_cyl_d = id_cyl_q;
    id_bb_d = id_bb_q;
    id_sh_d = id_sh_q;
    id_sec_d = id_sec_q;


    // Status read clears INTRQ (p.80).
    if (hrd_fall && a == 3'd7) intrq_d = 1'b0;

    // BCR pulse timer.
    if (bcr_t_q != 16'd0 && tick) begin
      bcr_t_d = bcr_t_q - 16'd1;
      if (bcr_t_q == 16'd1) bcr_d = 1'b0;
    end
    // MR release: BCR 3.2 us later.
    if (mrb_t_q != 16'd0 && tick) begin
      mrb_t_d = mrb_t_q - 16'd1;
      if (mrb_t_q == 16'd1) begin
        bcr_d   = 1'b1;
        bcr_t_d = BcrWidth;
      end
    end
    // Buffer write strobe (Read Sector): 2 WCLK Low per byte.
    if (we_t_q != 2'd0 && tick) begin
      we_t_d = we_t_q - 2'd1;
      if (we_t_q == 2'd1) we_d = 1'b0;
    end
    // Buffer read strobe (Write Sector, Format): data taken at the rise.
    // Write Sector reads straight into the data register, one byte ahead
    // of the shifter (p.71); Format reads the two ID bytes.
    if (fetch_q && !fbusy_q && tick) begin
      fbusy_d = 1'b1;
      re_d    = 1'b1;
      re_t_d  = StrobeWidth[1:0];
    end else if (fbusy_q && tick) begin
      re_t_d = re_t_q - 2'd1;
      if (re_t_q == 2'd1) begin
        re_d    = 1'b0;
        fbusy_d = 1'b0;
        fetch_d = 1'b0;
        if (st_q == StWrRun) nbyte_d = d_in;
        else if (fslot_q)    fb1_d   = d_in;
        else                 fb0_d   = d_in;
      end
    end

    if (idx_rise && idx_q != 4'hF) idx_d = idx_q + 4'd1;

    // DRUN High for two byte times before RG (Fig 5).
    if (st_q != StSrWait || !drun) dq_d = 5'd0;
    else if (tick && dq_q != 5'd16) dq_d = dq_q + 5'd1;
    if (sc_rise) sc_edge_d = 1'b1;

    // Host write commits.
    if (hwr_end && !cip_q) begin
      case (hwa_q)
        3'd1: precomp_d = hwd_q;
        3'd2: seccnt_d  = hwd_q;
        3'd3: secnum_d  = hwd_q;
        3'd4: cyllo_d   = hwd_q;
        3'd5: cylhi_d   = hwd_q;
        3'd6: sdh_d     = hwd_q;
        3'd7: begin
          cmd_d   = hwd_q;
          intrq_d = 1'b0;
          err_d   = 8'h00;
          errst_d = 1'b0;
          lat_d   = 1'b0;
          bsy_d   = 1'b1;
          cip_d   = 1'b1;
          st_d    = StDispatch;
        end
        default: ;
      endcase
    end

    // Drive abort.
    if (mon_c && (!drdy || wf)) begin
      err_d     = err_q | ErrAC;
      lat_d     = 1'b1;
      lat_rdy_d = drdy;
      lat_wf_d  = wf;
      lat_sc_d  = sc;
      errst_d   = 1'b1;
      wg_d      = 1'b0;
      wrun_d    = 1'b0;
      rg_d      = 1'b0;
      am_en_d   = 1'b0;
      step_out_d = 1'b0;
      bcs_r_d   = 1'b0;
      bd_oe_d   = 1'b0;
      fetch_d   = 1'b0;
      st_d      = is_read ? StEnd3 : StEndOk;
    end else begin
      case (st_q)
        StIdle: ;

        StDispatch: begin
          idx_d    = 4'd0;
          retry_d  = 4'd0;
          reseek_d = 1'b0;
          casez (cmd_q)
            8'b0001_????: begin                 // Restore (Fig 7)
              rate_d      = cmd_q[3:0];
              dirin_d     = 1'b0;
              rsforce_d   = 1'b1;
              nsteps_d    = 11'd0;
              need_edge_d = 1'b0;
              ret_d       = RetNone;
              st_d        = StRsChk;
            end
            8'b0111_????: begin                 // Seek (Fig 8)
              rate_d    = cmd_q[3:0];
              implied_d = 1'b0;
              st_d      = StPreChg;
            end
            8'b0010_????: begin                 // Read Sector (Fig 9)
              implied_d = 1'b1;
              st_d      = StPreChg;
            end
            8'b0011_0???: begin                 // Write Sector (Fig 10)
              implied_d = 1'b1;
              bcr_d     = 1'b1;
              bcr_t_d   = BcrWidth;
              st_d      = StWsBcr;
            end
            8'b0100_000?: begin                 // Scan ID (Fig 11)
              any_d = 1'b1;
              ret_d = RetScanCmd;
              st_d  = drdy ? StSrWait : StEndAc;
            end
            8'b0101_0000: begin                 // Format (Fig 14)
              implied_d = 1'b1;
              bdrq_d    = 1'b1;
              st_d      = StFmBrdy;
            end
            8'b0000_1000: begin                 // Compute Correction (Fig 15)
              bcs_r_d = 1'b1;
              bcr_d   = 1'b1;
              bcr_t_d = BcrWidth;
              cnt_d   = 11'd0;
              tmr_d   = BcrWidth;
              st_d    = StCcRun;
            end
            8'b0000_000?: st_d = StEndOk;      // Set Parameter (span: correction only)
            default: st_d = StEndAc;
          endcase
        end

        // ---------------------------------------------------------- ends
        StEndAc: begin
          err_d     = err_q | ErrAC;
          lat_d     = 1'b1;
          lat_rdy_d = drdy;
          lat_wf_d  = wf;
          lat_sc_d  = sc;
          errst_d   = 1'b1;
          st_d      = StEndOk;
        end
        StEndOk: begin
          bcr_d     = 1'b1;
          bcr_t_d   = BcrWidth;
          intrq_d   = 1'b1;
          bsy_d     = 1'b0;
          cip_d     = 1'b0;
          bdrq_d    = 1'b0;
          wg_d      = 1'b0;
          wrun_d    = 1'b0;
          rg_d      = 1'b0;
          am_en_d   = 1'b0;
          bcs_r_d   = 1'b0;
          bd_oe_d   = 1'b0;
          rsforce_d = 1'b0;
          st_d      = StIdle;
        end
        // Read error end (3): ERR, then the normal BDRQ handshake.
        StEnd3: begin
          errst_d = 1'b1;
          rg_d    = 1'b0;
          am_en_d = 1'b0;
          bcs_r_d = 1'b0;
          bd_oe_d = 1'b0;
          st_d    = StEndBdrq;
        end
        // Read end (4): BDRQ up, BSY down, INTRQ now unless I.
        StEndBdrq: begin
          bdrq_d = 1'b1;
          bsy_d  = 1'b0;
          if (!cmd_i) intrq_d = 1'b1;
          st_d   = StEndBrdy;
        end
        StEndBrdy: if (brdy_rise) begin
          bdrq_d  = 1'b0;
          if (cmd_i) intrq_d = 1'b1;
          bcr_d   = 1'b1;
          bcr_t_d = BcrWidth;
          cip_d   = 1'b0;
          st_d    = StIdle;
        end

        // ---------------------------------------------------------- restore
        // Step, then wait for the SC leading edge (after ten index
        // pulses without it, the SC level) before the next step.
        StRsChk: begin
          if (need_edge_q ? (sc_edge_q || (idx_q >= 4'd10 && sc)) : sc) begin
            if (tk000) begin
              pcyl_d    = 11'd0;
              rsforce_d = 1'b0;
              if (ret_q == RetRestoreChg) begin
                // Seek / Format after a failed auto scan: Restore, then
                // aborted command (Fig 8, 14).
                err_d   = err_q | ErrAC;
                errst_d = 1'b1;
                st_d    = StEndOk;
              end else begin
                // Restore command, or Read/Write after a failed auto scan.
                if (is_read || is_write) errst_d = 1'b1;
                st_d = is_read ? StEnd3 : StEndOk;
              end
            end else if (nsteps_q == RestoreMax) begin
              err_d     = err_q | ErrTK;
              errst_d   = 1'b1;
              rsforce_d = 1'b0;
              st_d      = is_read ? StEnd3 : StEndOk;
            end else if (tick) begin
              step_out_d = 1'b1;
              tmr_d      = (rate_q == 4'hE) ? 16'd8 : 16'd40;
              st_d       = StRsPulse;
            end
          end
        end
        StRsPulse: if (tick) begin
          if (tmr_q == 16'd1) begin
            step_out_d  = 1'b0;
            nsteps_d    = nsteps_q + 11'd1;
            sc_edge_d   = 1'b0;
            idx_d       = 4'd0;
            need_edge_d = 1'b1;
            st_d        = StRsChk;
          end
          tmr_d = tmr_q - 16'd1;
        end

        // ---------------------------------------------------------- prologue
        // A drive change since the last command runs an auto Scan ID.
        StPreChg: begin
          if (sdh_q[4:3] != ldrv_q) begin
            any_d = 1'b1;
            ret_d = RetDrvChg;
            idx_d = 4'd0;
            st_d  = StSrWait;
          end else begin
            st_d = StPreSeek;
          end
        end
        StPreChgR: begin
          ldrv_d = sdh_q[4:3];
          if (found_q) begin
            pcyl_d = idcyl_c;
            st_d   = StPreSeek;
          end else begin
            // Not found: Restore (Fig 8, 14); Read/Write also report
            // ID not found (Fig 9, 10).
            if (is_read || is_write) err_d = err_q | ErrID;
            dirin_d     = 1'b0;
            rsforce_d   = 1'b1;
            nsteps_d    = 11'd0;
            need_edge_d = 1'b0;
            ret_d       = (is_read || is_write) ? RetNone : RetRestoreChg;
            st_d        = StRsChk;
          end
        end
        StPreSeek: begin
          if (tcyl_c > pcyl_q) begin
            dir_d    = 1'b1;
            nsteps_d = tcyl_c - pcyl_q;
            st_d     = StSkChk;
          end else if (tcyl_c < pcyl_q) begin
            dir_d    = 1'b0;
            nsteps_d = pcyl_q - tcyl_c;
            st_d     = StSkChk;
          end else begin
            nsteps_d = 11'd0;
            st_d     = StSkDone;
          end
        end
        StSkChk: begin
          dirin_d = dir_q;
          if (nsteps_q == 11'd0) begin
            st_d = StSkDone;
          end else if (tick) begin
            step_out_d = 1'b1;
            tmr_d      = (rate_q == 4'hE) ? 16'd8 : 16'd40;
            st_d       = StSkPulse;
          end
        end
        StSkPulse: if (tick) begin
          if (tmr_q == 16'd1) begin
            step_out_d = 1'b0;
            nsteps_d   = nsteps_q - 11'd1;
            pcyl_d     = dir_q ? pcyl_q + 11'd1 : pcyl_q - 11'd1;
            if (nsteps_q == 11'd1 && implied_q) begin
              sc_edge_d = 1'b0;
              idx_d     = 4'd0;
              st_d      = StSkLastSc;
            end else begin
              tmr_d = step_period(rate_q) - ((rate_q == 4'hE) ? 16'd8 : 16'd40);
              st_d  = StSkDelay;
            end
          end else begin
            tmr_d = tmr_q - 16'd1;
          end
        end
        StSkDelay: if (tick) begin
          if (tmr_q <= 16'd1 && nsteps_q == 11'd0) begin
            st_d = StSkDone;               // the delay follows the last step too (Fig 8)
          end else if (tmr_q <= 16'd1) begin
            step_out_d = 1'b1;
            tmr_d      = (rate_q == 4'hE) ? 16'd8 : 16'd40;
            st_d       = StSkPulse;
          end else begin
            tmr_d = tmr_q - 16'd1;
          end
        end
        StSkLastSc: if (sc_edge_q || (idx_q >= 4'd10 && sc)) st_d = StSkDone;
        StSkDone: begin
          idx_d = 4'd0;
          if (is_seek) st_d = drdy ? StEndOk : StEndAc;
          else         st_d = StReady;
        end

        // Drive ready and seek complete before the ID search.
        StReady: begin
          if (sc) begin
            any_d = 1'b0;
            ret_d = RetAfterSeek;
            if (is_fmt) st_d = StFmIndex;
            else        st_d = StSrWait;
          end
        end

        // ---------------------------------------------------------- ID search (Fig 5)
        StSrWait: begin
          rg_d    = 1'b0;
          am_en_d = 1'b0;
          if (idx_q >= idx_lim_c) begin
            found_d = 1'b0;
            case (ret_q)
              RetDrvChg:     st_d = StPreChgR;
              RetScanCmd:    begin err_d = err_q | ErrID; errst_d = 1'b1; st_d = StEndOk; end
              RetReseekScan: st_d = StPreSeek;
              default: begin                     // Read/Write: ID not found
                err_d = err_q | ErrID;
                if (!cmd_t && !reseek_q) begin
                  reseek_d = 1'b1;
                  any_d    = 1'b1;
                  ret_d    = RetReseekScan;
                  idx_d    = 4'd0;
                end else begin
                  errst_d = 1'b1;
                  st_d    = is_read ? StEnd3 : StEndOk;
                end
              end
            endcase
          end else if (dq_q == 5'd16) begin
            rg_d  = 1'b1;
            tmr_d = 16'd0;
            st_d  = StSrLock;
          end
        end
        StSrLock: begin
          if (!drun) begin
            rg_d = 1'b0;
            st_d = StSrWait;
          end else if (tick) begin
            if (tmr_q == 16'd39) begin
              am_en_d = 1'b1;
              st_d    = StSrAm;
            end else begin
              tmr_d = tmr_q + 16'd1;
            end
          end
        end
        StSrAm: begin
          if (am_c) begin
            crc_d = chk_byte(chk_init(1'b0), ByteA1, 1'b0);
            fld_d = 3'd0;
            st_d  = StSrField;
          end else if (!drun) begin
            tmr_d = 16'd0;
            st_d  = StSrAmWin;
          end
        end
        StSrAmWin: begin
          if (am_c) begin
            crc_d = chk_byte(chk_init(1'b0), ByteA1, 1'b0);
            fld_d = 3'd0;
            st_d  = StSrField;
          end else if (tick) begin
            if (tmr_q == 16'd11) begin
              rg_d    = 1'b0;
              am_en_d = 1'b0;
              st_d    = StSrWait;
            end else begin
              tmr_d = tmr_q + 16'd1;
            end
          end
        end
        StSrField: if (bv_c) begin
          crc_d = chk_byte(crc_q, rbyte_c, 1'b0);
          fld_d = fld_q + 3'd1;
          case (fld_q)
            3'd0: id_ch_d    = {~rbyte_c[3], ~rbyte_c[1], rbyte_c[0]};
            3'd1: id_cyl_d   = rbyte_c;
            3'd2: begin id_bb_d = rbyte_c[7]; id_sh_d = {rbyte_c[6:5], rbyte_c[2:0]}; end
            3'd3: id_sec_d   = rbyte_c;
            default: ;
          endcase
          if (fld_q == 3'd0 && !ident_ok_c) begin
            rg_d    = 1'b0;                  // not an ID field
            am_en_d = 1'b0;
            tmr_d   = 16'd0;
            st_d    = StSrWait;
          end else if (!any_q && fld_q <= 3'd3 &&
                       (fld_q == 3'd2 ? (rbyte_c & 8'h67) != exp_c : rbyte_c != exp_c)) begin
            rg_d    = 1'b0;                  // ID does not match (Fig 13 note 3)
            am_en_d = 1'b0;
            tmr_d   = 16'd0;
            st_d    = StSrWait;
          end else if (fld_q == 3'd5) begin
            rg_d    = 1'b0;
            am_en_d = 1'b0;
            tmr_d   = 16'd0;
            idbad_d = chk_byte(crc_q, rbyte_c, 1'b0) != 32'd0;
            if (ret_q == RetScanCmd) begin
              // Scan ID loads the task file from every ID read (Fig 11).
              sdh_d    = {sdh_q[7], id_sh_q[4:3], sdh_q[4:3], id_sh_q[2:0]};
              cyllo_d  = id_cyl_q;
              cylhi_d  = {5'b00000, id_ch_q};
              secnum_d = id_sec_q;
              pcyl_d   = idcyl_c;
            end
            if (chk_byte(crc_q, rbyte_c, 1'b0) != 32'd0) begin
              st_d = StSrWait;               // CRC error: keep searching
            end else begin
              found_d = 1'b1;
              case (ret_q)
                RetDrvChg: st_d = StPreChgR;
                RetReseekScan: begin
                  pcyl_d = idcyl_c;
                  idx_d  = 4'd0;
                  st_d   = StPreSeek;
                end
                RetScanCmd: begin
                  if (id_bb_q) begin
                    err_d   = err_q | ErrBB;
                    errst_d = 1'b1;
                  end
                  st_d = StEndOk;
                end
                default: begin
                  if (id_bb_q) begin
                    err_d   = err_q | ErrBB;
                    errst_d = 1'b1;
                    st_d    = is_read ? StEnd3 : StEndOk;
                  end else if (is_read) begin
                    bcs_r_d = 1'b1;
                    bcr_d   = 1'b1;
                    bcr_t_d = BcrWidth;
                    found_d = 1'b0;
                    st_d    = StRdSplice;
                  end else begin
                    st_d    = StWrSplice;
                  end
                end
              endcase
            end
          end
        end

        // ---------------------------------------------------------- read data (Fig 5A, 9)
        StRdSplice: if (tick) begin
          if (tmr_q == RgSuppress - 16'd1) begin
            rg_d  = 1'b1;
            tmr_d = 16'd0;
            st_d  = StRdLock;
          end else begin
            tmr_d = tmr_q + 16'd1;
          end
        end
        StRdLock: begin
          if (!drun) begin
            err_d = err_q | ErrDM;
            st_d  = StRdDone;
          end else if (tick) begin
            if (tmr_q == 16'd39) begin
              am_en_d = 1'b1;
              st_d    = StRdAm;
            end else begin
              tmr_d = tmr_q + 16'd1;
            end
          end
        end
        StRdAm: begin
          if (am_c) begin
            crc_d = chk_byte(chk_init(sdh_q[7]), ByteA1, sdh_q[7]);
            st_d  = StRdF8;
          end else if (!drun) begin
            tmr_d = 16'd0;
            st_d  = StRdAmWin;
          end
        end
        StRdAmWin: begin
          if (am_c) begin
            crc_d = chk_byte(chk_init(sdh_q[7]), ByteA1, sdh_q[7]);
            st_d  = StRdF8;
          end else if (tick) begin
            if (tmr_q == 16'd11) begin
              err_d = err_q | ErrDM;
              st_d  = StRdDone;
            end else begin
              tmr_d = tmr_q + 16'd1;
            end
          end
        end
        StRdF8: if (bv_c) begin
          if (rbyte_c == ByteF8) begin
            crc_d   = chk_byte(crc_q, rbyte_c, sdh_q[7]);
            cnt_d   = 11'd0;
            chkph_d = 1'b0;
            st_d    = StRdData;
          end else begin
            err_d = err_q | ErrDM;
            st_d  = StRdDone;
          end
        end
        StRdData: if (bv_c) begin
          crc_d = chk_byte(crc_q, rbyte_c, sdh_q[7]);
          cnt_d = cnt_q + 11'd1;
          if (!chkph_q) begin
            bd_d    = rbyte_c;
            bd_oe_d = 1'b1;
            we_d    = 1'b1;
            we_t_d  = StrobeWidth[1:0];
            if (cnt_q == dlen_c - 11'd1) begin
              cnt_d   = 11'd0;
              chkph_d = 1'b1;
              if (cmd_l) begin
                found_d = 1'b1;
                st_d    = StRdDone;
              end
            end
          end else if (cnt_q == (sdh_q[7] ? 11'd3 : 11'd1)) begin
            idbad_d = chk_byte(crc_q, rbyte_c, sdh_q[7]) != 32'd0;
            found_d = 1'b1;
            st_d    = StRdDone;
          end
        end
        // Sector done (found_q = data field read): drop BCS, pulse BCR.
        StRdDone: begin
          if (!we_q && we_t_q == 2'd0 && tick) begin
            rg_d    = 1'b0;
            am_en_d = 1'b0;
            bcs_r_d = 1'b0;
            bd_oe_d = 1'b0;
            bcr_d   = 1'b1;
            bcr_t_d = BcrWidth;
            if (!found_q) begin
              // DAM not found: retry until the index limit (Fig 9).
              found_d = 1'b0;
              tmr_d   = 16'd0;
              st_d    = (cmd_t || idx_q >= idx_lim_c) ? StEnd3 : StReady;
            end else if (!cmd_l && idbad_q) begin
              err_d = err_q | ErrCRC;
              if (!cmd_t && retry_q != 4'd10) begin
                retry_d = retry_q + 4'd1;
                idx_d   = 4'd0;
                st_d    = StReady;
              end else begin
                st_d = StEnd3;
              end
            end else if (cmd_m) begin
              secnum_d = secnum_q + 8'd1;
              seccnt_d = seccnt_q - 8'd1;
              if (seccnt_q == 8'd1) begin
                st_d = StEndBdrq;
              end else begin
                bdrq_d = 1'b1;
                bsy_d  = 1'b0;
                st_d   = StRdNextBrdy;
              end
            end else begin
              st_d = StEndBdrq;
            end
            found_d = 1'b0;
          end
        end
        StRdNextBrdy: if (brdy_rise) begin
          bdrq_d   = 1'b0;
          bsy_d    = 1'b1;
          idx_d    = 4'd0;
          retry_d  = 4'd0;
          reseek_d = 1'b0;
          st_d    = StReady;
        end

        // ---------------------------------------------------------- write sector (Fig 10)
        // BCR zeroes the counter, then BDRQ asks for the data (p.72).
        StWsBcr: if (!bcr_q) begin
          bdrq_d = 1'b1;
          st_d   = StWsBrdy;
        end
        StWsBrdy: if (brdy_rise) begin
          bdrq_d = 1'b0;
          st_d   = StPreChg;
        end
        StWrSplice: begin
          if (tick) begin
            if (tmr_q == SpliceWclk - 16'd1) begin
              // WG on: 12 x 00, A1*, F8, data, CRC/ECC, 2 x 00.
              wg_d     = 1'b1;
              wrun_d   = 1'b1;
              bcs_r_d  = 1'b1;
              wph_d    = 5'd0;
              wcnt_d   = 11'd1;
              nbyte_d  = 8'h00;
              nmc_d    = 1'b0;
              st_d     = StWrRun;
            end else begin
              tmr_d = tmr_q + 16'd1;
            end
          end
        end
        StWrRun, StFmRun: if (take_c) begin
          // nbyte_q has just been taken: account for it, then present the next byte.
          if (crc_on_q) crc_d = crc_take_c;
          case (wph_q)
            // ---- write sector
            5'd0: if (wcnt_q == 11'd12) begin wph_d = 5'd1; nbyte_d = ByteA1; nmc_d = 1'b1; end
                  else begin wcnt_d = wcnt_q + 11'd1; nbyte_d = 8'h00; end
            5'd1: begin
              wph_d = 5'd2; nbyte_d = ByteF8; nmc_d = 1'b0;
              crc_d = chk_byte(chk_init(sdh_q[7]), ByteA1, sdh_q[7]); ecc_d = sdh_q[7]; crc_on_d = 1'b1;
            end
            5'd2: begin
              // F8 is in the shifter: fetch data byte 0.
              wph_d = 5'd3; wcnt_d = 11'd1;
              fetch_d = 1'b1;
            end
            5'd3: if (wcnt_q == dlen_c) begin
                    crc_on_d = 1'b0;
                    wcnt_d   = 11'd1;
                    if (cmd_l) begin wph_d = 5'd5; nbyte_d = 8'h00; end
                    else begin
                      wph_d   = 5'd4;
                      nbyte_d = crc_take_c[31:24];
                    end
                  end else begin
                    wcnt_d  = wcnt_q + 11'd1;
                    fetch_d = 1'b1;
                  end
            5'd4: if (wcnt_q == (ecc_q ? 11'd4 : 11'd2)) begin
                    wph_d = 5'd5; wcnt_d = 11'd1; nbyte_d = 8'h00;
                  end else begin
                    wcnt_d  = wcnt_q + 11'd1;
                    crc_d   = crc_q << 8;
                    nbyte_d = crc_q[23:16];
                  end
            5'd5: if (wcnt_q == 11'd2) begin wph_d = 5'd6; end
                  else begin wcnt_d = wcnt_q + 11'd1; nbyte_d = 8'h00; end
            5'd6: begin
              // The last byte has left the shifter: WG and BCS off, BCR (Fig 10).
              wg_d    = 1'b0;
              wrun_d  = 1'b0;
              bcs_r_d = 1'b0;
              bcr_d   = 1'b1;
              bcr_t_d = BcrWidth;
              st_d    = StWrDone;
            end

            // ---- format: GAP1/GAP3 4E x (Sector Number + 3), extended while SC is Low
            5'd8: begin
              if (wcnt_q == 11'd2) begin fslot_d = 1'b0; fetch_d = 1'b1; end
              if (wcnt_q == 11'd4) begin fslot_d = 1'b1; fetch_d = 1'b1; end
              if (wcnt_q >= {3'b000, secnum_q} + 11'd3 && sc && !fetch_q && !fbusy_q) begin
                fmt_left_d = fmt_left_q - 8'd1;
                if (fmt_left_q == 8'd1) bcs_r_d = 1'b0;
                wph_d   = 5'd9; wcnt_d = 11'd1; nbyte_d = 8'h00;
              end else begin
                wcnt_d  = wcnt_q + 11'd1; nbyte_d = Byte4E;
              end
            end
            5'd9: if (wcnt_q == 11'd14) begin wph_d = 5'd10; nbyte_d = ByteA1; nmc_d = 1'b1; end
                  else begin wcnt_d = wcnt_q + 11'd1; nbyte_d = 8'h00; end
            5'd10: begin
              wph_d = 5'd11; nmc_d = 1'b0; nbyte_d = ident_of(tcyl_c[10:8]);
              crc_d = chk_byte(chk_init(1'b0), ByteA1, 1'b0); ecc_d = 1'b0; crc_on_d = 1'b1;
            end
            5'd11: begin wph_d = 5'd12; nbyte_d = tcyl_c[7:0]; end
            5'd12: begin wph_d = 5'd13; nbyte_d = {fb0_q[7], sdh_q[6:5], 2'b00, sdh_q[2:0]}; end
            5'd13: begin wph_d = 5'd14; nbyte_d = fb1_q; end
            5'd14: begin
              wph_d = 5'd15; crc_on_d = 1'b0;
              nbyte_d = crc_take_c[31:24];
              crc_d   = crc_take_c;
            end
            5'd15: begin wph_d = 5'd16; wcnt_d = 11'd1; nbyte_d = crc_q[23:16]; end
            5'd16: if (wcnt_q == 11'd16) begin wph_d = 5'd17; nbyte_d = ByteA1; nmc_d = 1'b1; end
                   else begin wcnt_d = wcnt_q + 11'd1; nbyte_d = 8'h00; end
            5'd17: begin
              wph_d = 5'd18; nmc_d = 1'b0; nbyte_d = ByteF8;
              ecc_d = sdh_q[7]; crc_d = chk_byte(chk_init(sdh_q[7]), ByteA1, sdh_q[7]); crc_on_d = 1'b1;
            end
            5'd18: begin wph_d = 5'd19; wcnt_d = 11'd1; nbyte_d = ByteFF; end
            5'd19: if (wcnt_q == slen_c) begin
                     crc_on_d = 1'b0; wph_d = 5'd20; wcnt_d = 11'd1;
                     nbyte_d  = crc_take_c[31:24];
                   end else begin
                     wcnt_d = wcnt_q + 11'd1; nbyte_d = ByteFF;
                   end
            5'd20: if (wcnt_q == (ecc_q ? 11'd4 : 11'd2)) begin
                     wph_d = 5'd21; wcnt_d = 11'd1; nbyte_d = 8'h00;
                   end else begin
                     wcnt_d  = wcnt_q + 11'd1;
                     crc_d   = crc_q << 8;
                     nbyte_d = crc_q[23:16];
                   end
            5'd21: if (wcnt_q == 11'd2) begin
                     wcnt_d = 11'd1; nbyte_d = Byte4E;
                     wph_d  = (fmt_left_q == 8'd0) ? 5'd22 : 5'd8;
                   end else begin
                     wcnt_d = wcnt_q + 11'd1; nbyte_d = 8'h00;
                   end
            5'd22: nbyte_d = Byte4E;         // GAP4 until INDEX
            default: ;
          endcase
        end
        StWrDone: begin
          if (cmd_m && seccnt_q != 8'd1) begin
            secnum_d = secnum_q + 8'd1;
            seccnt_d = seccnt_q - 8'd1;
            idx_d    = 4'd0;
            reseek_d = 1'b0;
            // BRDY counts only as a rising edge after BCR (p.72); BCR is
            // being pulsed now, so the next buffer always takes BDRQ.
            bdrq_d   = 1'b1;
            st_d     = StWrNextBrdy;
          end else begin
            if (cmd_m) begin
              secnum_d = secnum_q + 8'd1;
              seccnt_d = seccnt_q - 8'd1;
            end
            st_d = StEndOk;
          end
        end
        StWrNextBrdy: if (brdy_rise) begin
          bdrq_d = 1'b0;
          st_d   = StReady;
        end

        // ---------------------------------------------------------- format (Fig 14)
        StFmBrdy: if (brdy_rise) begin
          bdrq_d = 1'b0;
          st_d   = StPreChg;
        end
        StFmIndex: if (idx_rise) begin
          wg_d       = 1'b1;
          wrun_d     = 1'b1;
          bcr_d      = 1'b1;
          bcr_t_d    = BcrWidth;
          bcs_r_d    = 1'b1;
          fmt_left_d = seccnt_q;
          wph_d      = 5'd8;
          wcnt_d     = 11'd1;
          nbyte_d    = Byte4E;
          nmc_d      = 1'b0;
          crc_on_d   = 1'b0;
          st_d       = StFmRun;
        end

        // ---------------------------------------------------------- compute correction (Fig 15)
        StCcRun: if (tick) begin
          if (tmr_q != 16'd0) tmr_d = tmr_q - 16'd1;
          else if (!we_q) begin
            if (cnt_q == 11'd9) begin
              err_d   = err_q | ErrCRC;
              errst_d = 1'b1;
              bcs_r_d = 1'b0;
              bd_oe_d = 1'b0;
              bdrq_d  = 1'b1;
              bcr_d   = 1'b1;
              bcr_t_d = BcrWidth;
              st_d    = StCcBrdy;
            end else begin
              // Four syndrome bytes, the pattern search (one count per
              // clock, given up past the sector size), then two offset
              // and three pattern bytes, zero: no pattern is computed.
              bd_d    = cnt_q < 11'd4 ? crc_q[31:24] : 8'h00;
              crc_d   = crc_q << 8;
              bd_oe_d = 1'b1;
              we_d    = 1'b1;
              we_t_d  = StrobeWidth[1:0];
              cnt_d   = cnt_q + 11'd1;
              tmr_d   = cnt_q == 11'd3 ? 16'(slen_c) + 16'd6 : 16'd5;
            end
          end
        end
        StCcBrdy: if (brdy_rise) begin
          bcr_d   = 1'b1;
          bcr_t_d = BcrWidth;
          intrq_d = 1'b1;
          bdrq_d  = 1'b0;
          bsy_d   = 1'b0;
          cip_d   = 1'b0;
          st_d    = StIdle;
        end

        default: st_d = StIdle;
      endcase

      // Format ends at the INDEX after the last sector (GAP4).
      if (st_q == StFmRun && wph_q == 5'd22 && idx_rise) begin
        wg_d    = 1'b0;
        wrun_d  = 1'b0;
        bcs_r_d = 1'b0;
        st_d    = StEndOk;
      end
    end

    // Master reset: all internal logic except the task file (p.68).
    if (!mr_n) begin
      st_d = StIdle; cmd_d = 8'h00; bsy_d = 1'b0; cip_d = 1'b0; intrq_d = 1'b0; bdrq_d = 1'b0;
      err_d = 8'h00; errst_d = 1'b0; lat_d = 1'b0;
      pcyl_d = 11'd0; ldrv_d = 2'd0; rate_d = 4'd0;
      rg_d = 1'b0; am_en_d = 1'b0; wg_d = 1'b0; wrun_d = 1'b0; bcs_r_d = 1'b0; bd_oe_d = 1'b0;
      step_out_d = 1'b0; dirin_d = 1'b0; rsforce_d = 1'b0;
      bcr_d = 1'b0; bcr_t_d = 16'd0; we_d = 1'b0; we_t_d = 2'd0; re_d = 1'b0;
      fetch_d = 1'b0; fbusy_d = 1'b0;
      mrb_t_d = MrToBcr;
    end
  end

  initial begin
    precomp_q = 8'hFF;
    seccnt_q = 8'h00;
    secnum_q = 8'h00;
    cyllo_q = 8'h00;
    cylhi_q = 8'h00;
    sdh_q = 8'h00;
    err_q = 8'h00;
    bsy_q = 1'b0;
    cip_q = 1'b0;
    errst_q = 1'b0;
    intrq_q = 1'b0;
    bdrq_q = 1'b0;
    lat_q = 1'b0;
    lat_rdy_q = 1'b0;
    lat_wf_q = 1'b0;
    lat_sc_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    precomp_q <= precomp_d;
    seccnt_q <= seccnt_d;
    secnum_q <= secnum_d;
    cyllo_q <= cyllo_d;
    cylhi_q <= cylhi_d;
    sdh_q <= sdh_d;
    err_q <= err_d;
    bsy_q <= bsy_d;
    cip_q <= cip_d;
    errst_q <= errst_d;
    intrq_q <= intrq_d;
    bdrq_q <= bdrq_d;
    lat_q <= lat_d;
    lat_rdy_q <= lat_rdy_d;
    lat_wf_q <= lat_wf_d;
    lat_sc_q <= lat_sc_d;
  end

  initial begin
    bcr_q = 1'b0;
    we_q = 1'b0;
    re_q = 1'b0;
    bcr_t_q = 16'd0;
    mrb_t_q = 16'd0;
    we_t_q = 2'd0;
    re_t_q = 2'd0;
    bd_q = 8'h00;
    bd_oe_q = 1'b0;
    fetch_q = 1'b0;
    fbusy_q = 1'b0;
    fslot_q = 1'b0;
    fb0_q = 8'h00;
    fb1_q = 8'h00;
    bcs_r_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    bcr_q <= bcr_d;
    we_q <= we_d;
    re_q <= re_d;
    bcr_t_q <= bcr_t_d;
    mrb_t_q <= mrb_t_d;
    we_t_q <= we_t_d;
    re_t_q <= re_t_d;
    bd_q <= bd_d;
    bd_oe_q <= bd_oe_d;
    fetch_q <= fetch_d;
    fbusy_q <= fbusy_d;
    fslot_q <= fslot_d;
    fb0_q <= fb0_d;
    fb1_q <= fb1_d;
    bcs_r_q <= bcs_r_d;
  end

  initial begin
    rg_q = 1'b0;
    am_en_q = 1'b0;
    wg_q = 1'b0;
    wrun_q = 1'b0;
    wph_q = 5'd0;
    wcnt_q = 11'd0;
    nbyte_q = 8'h00;
    nmc_q = 1'b0;
    crc_on_q = 1'b0;
    fmt_left_q = 8'h00;
    crc_q = 32'hFFFF_FFFF;
    ecc_q = 1'b0;
    cnt_q = 11'd0;
    chkph_q = 1'b0;
    step_out_q = 1'b0;
    dirin_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    rg_q <= rg_d;
    am_en_q <= am_en_d;
    wg_q <= wg_d;
    wrun_q <= wrun_d;
    wph_q <= wph_d;
    wcnt_q <= wcnt_d;
    nbyte_q <= nbyte_d;
    nmc_q <= nmc_d;
    crc_on_q <= crc_on_d;
    fmt_left_q <= fmt_left_d;
    crc_q <= crc_d;
    ecc_q <= ecc_d;
    cnt_q <= cnt_d;
    chkph_q <= chkph_d;
    step_out_q <= step_out_d;
    dirin_q <= dirin_d;
  end

  initial begin
    st_q = StIdle;
    ret_q = RetNone;
    cmd_q = 8'h00;
    tmr_q = 16'd0;
    dq_q = 5'd0;
    pcyl_q = 11'd0;
    ldrv_q = 2'd0;
    rate_q = 4'd0;
    nsteps_q = 11'd0;
    dir_q = 1'b0;
    implied_q = 1'b0;
    sc_edge_q = 1'b0;
    need_edge_q = 1'b0;
    reseek_q = 1'b0;
    rsforce_q = 1'b0;
    idx_q = 4'd0;
    retry_q = 4'd0;
    any_q = 1'b0;
    found_q = 1'b0;
    idbad_q = 1'b0;
    fld_q = 3'd0;
    id_ch_q = 3'd0;
    id_cyl_q = 8'h00;
    id_bb_q = 1'b0;
    id_sh_q = 5'd0;
    id_sec_q = 8'h00;
  end
  always_ff @(posedge clk) begin
    st_q <= st_d;
    ret_q <= ret_d;
    cmd_q <= cmd_d;
    tmr_q <= tmr_d;
    dq_q <= dq_d;
    pcyl_q <= pcyl_d;
    ldrv_q <= ldrv_d;
    rate_q <= rate_d;
    nsteps_q <= nsteps_d;
    dir_q <= dir_d;
    implied_q <= implied_d;
    sc_edge_q <= sc_edge_d;
    need_edge_q <= need_edge_d;
    reseek_q <= reseek_d;
    rsforce_q <= rsforce_d;
    idx_q <= idx_d;
    retry_q <= retry_d;
    any_q <= any_d;
    found_q <= found_d;
    idbad_q <= idbad_d;
    fld_q <= fld_d;
    id_ch_q <= id_ch_d;
    id_cyl_q <= id_cyl_d;
    id_bb_q <= id_bb_d;
    id_sh_q <= id_sh_d;
    id_sec_q <= id_sec_d;
  end

  // ------------------------------------------------------------------
  // Pins

  assign host_ok  = ~bcs_r_q;
  assign bcs_n    = ~bcs_r_q;
  assign bcr_n    = ~bcr_q;
  assign bdrq     = bdrq_q;
  assign intrq    = intrq_q;
  assign rg       = rg_q;
  assign wg       = wg_q;
  assign step     = step_out_q;
  assign dirin    = dirin_q;
  assign early_n  = 1'b1;
  assign late_n   = 1'b1;
  assign rwc      = ~rsforce_q && precomp_q != 8'hFF && pcyl_q >= {1'b0, precomp_q, 2'b00};
  assign we_oe    = bcs_r_q;
  assign we_n_out = ~we_q;
  assign re_oe    = bcs_r_q;
  assign re_n_out = ~re_q;

  // D: the host read mux while CS+RE are Low, else the buffer byte.
  assign d_oe  = (hrd && a != 3'd0) || bd_oe_q;
  assign d_out = (hrd && a != 3'd0) ? rdmux_c : bd_q;

  // SDHLE (Figure 3B): CS, WE, A = 110, no command in progress.
  assign sdhle_n = ~(~cs_n & ~we_n_in & a == 3'd6 & ~cip_q);

endmodule

`default_nettype wire
