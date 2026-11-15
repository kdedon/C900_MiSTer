// tb_crom: the LANCE card's boot ROM and configuration window.
// A scoreboard of the 12 KB image and the 8 configuration words checks
// every ROMD read: 0xFFFF with no image or no configuration, the image
// big-endian by word, the configuration at 3FE0-3FFF with byte 0 of each
// ring word in D15:8, 0xFFFF elsewhere, ROMA counting up after each read
// and wrapping at 3FFF, other ports leaving it alone, reset clearing it,
// and no answer from a card that is not fitted.  Bus cycles run at the
// bench's slow timing and at back-to-back INIR timing.
//   +seed=<n>
`timescale 1ns/1ps
`default_nettype none
module tb_crom;
  localparam logic [3:0] ST_IO = 4'b0010;
  localparam logic [15:0] ROMA = 16'h0718, ROMD = 16'h071A;

  logic clk = 1'b0;
  always #10.417 clk = ~clk;

  logic [15:0] cpu_ad = 16'hFFFF;
  logic        cpu_ad_oe = 1'b0;
  logic        as_n = 1'b1, ds_n = 1'b1, r_w = 1'b1;
  logic [3:0]  st = 4'b0000;
  logic        rst_n = 1'b0, enable = 1'b1;
  logic [15:0] c_ad_out, c_ad_oe, ad_wire, ad_q;
  assign ad_wire = (c_ad_oe & c_ad_out | ~c_ad_oe) & (cpu_ad_oe ? cpu_ad : 16'hFFFF);
  always_ff @(posedge clk) ad_q <= ad_wire;

  logic        rom_ok = 1'b0, rom_wr = 1'b0, cfg_ok = 1'b0, cfg_wr = 1'b0;
  logic [13:0] rom_addr = '0;
  logic [7:0]  rom_data = '0;
  logic [4:0]  cfg_addr = '0;
  logic [15:0] cfg_data = '0;

  am7990_lance_card dut (
    .clk(clk), .rst_n(rst_n && enable), .enable(enable),
    .ad_bus(ad_q), .as_n(as_n), .ds_n(ds_n), .r_w(r_w), .b_w(1'b0), .st(st),
    .intack_n(1'b1), .iei(1'b1), .bai_n(1'b1), .bao_n(),
    .busreq_n(), .ad_out(c_ad_out), .ad_oe(c_ad_oe), .bus_oe(),
    .vi_n(), .ieo(), .wait_n(1'b1), .busreq_in_n(1'b1),
    .wait_pd(), .mac_ok(1'b0), .mac(48'd0),
    .rom_ok(rom_ok), .rom_wr(rom_wr), .rom_addr(rom_addr), .rom_data(rom_data),
    .cfg_ok(cfg_ok), .cfg_wr(cfg_wr), .cfg_addr(cfg_addr), .cfg_data(cfg_data),
    .as_n_o(), .ds_n_o(), .r_w_o(), .b_w_o(), .mreq_n_o(), .st_o(), .a_hi_o(),
    .tclk_rise(), .tclk_fall(), .tx(), .tena(),
    .rclk_rise(1'b0), .rx(1'b0), .rena(1'b0), .clsn(1'b0)
  );

  // ---- scoreboard ----
  logic [7:0]  img [0:16383];
  logic [63:0] cw [0:7];
  int          wa = 0;        // the window address the card should hold
  int          nrd = 0;

  function automatic logic [15:0] expect_w(int a);
    if (a < 'h1800) return rom_ok ? {img[2*a], img[2*a+1]} : 16'hFFFF;
    if (a >= 'h3FE0) begin
      int j = a - 'h3FE0;
      return cfg_ok ? {cw[j/4][16*(j%4) +: 8], cw[j/4][16*(j%4) + 8 +: 8]} : 16'hFFFF;
    end
    return 16'hFFFF;
  endfunction

  // A word I/O cycle; fast = INIR timing (one clock of /AS, /DS for three).
  task automatic cyc(input logic [15:0] port, input logic rd, input logic [15:0] wd, input bit fast,
                     output logic [15:0] rdv, output logic [15:0] oe);
    st = ST_IO; r_w = rd; cpu_ad = port; cpu_ad_oe = 1'b1;
    @(posedge clk); #1 as_n = 1'b0;
    repeat (fast ? 1 : 3) @(posedge clk);
    #1 as_n = 1'b1;
    @(posedge clk); #1;
    if (rd) cpu_ad_oe = 1'b0; else cpu_ad = wd;
    if (!fast) @(posedge clk);
    #1 ds_n = 1'b0;
    repeat (fast ? 3 : 12) @(posedge clk);
    rdv = ad_wire;
    oe  = c_ad_oe;
    #1 ds_n = 1'b1;
    @(posedge clk); #1 cpu_ad_oe = 1'b0; st = 4'b0000;
    if (!fast) @(posedge clk);
  endtask

  task automatic set_a(int a);
    logic [15:0] r, o;
    cyc(ROMA, 1'b0, 16'(a), 1'b0, r, o);
    wa = a & 'h3FFF;
  endtask

  task automatic rd_w(bit fast);
    logic [15:0] r, o;
    cyc(ROMD, 1'b1, 16'h0000, fast, r, o);
    if (!enable) begin
      if (o != 16'h0000) $fatal(1, "a card not fitted drives AD (%h)", o);
    end else begin
      if (o != 16'hFFFF) $fatal(1, "ROMD at %h: AD enable %h", wa, o);
      if (r != expect_w(wa)) $fatal(1, "ROMD at %h: %h, want %h", wa, r, expect_w(wa));
      wa = (wa + 1) & 'h3FFF;
    end
    nrd++;
  endtask

  task automatic rd_n(int n, bit fast);
    repeat (n) rd_w(fast);
  endtask

  task automatic load_rom();
    for (int i = 0; i < 16384; i++) begin
      @(posedge clk); #1 rom_wr = 1'b1; rom_addr = 14'(i); rom_data = img[i];
      @(posedge clk); #1 rom_wr = 1'b0;
    end
    rom_ok = 1'b1;
  endtask

  task automatic load_cfg();
    for (int i = 0; i < 32; i++) begin
      @(posedge clk); #1 cfg_wr = 1'b1; cfg_addr = 5'(i); cfg_data = cw[i/4][16*(i%4) +: 16];
      @(posedge clk); #1 cfg_wr = 1'b0;
    end
    cfg_ok = 1'b1;
  endtask

  initial begin
    int seed;
    logic [15:0] r, o;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    foreach (img[i]) img[i] = 8'($urandom);
    foreach (cw[i]) cw[i] = {$urandom, $urandom};
    repeat (10) @(posedge clk);
    #1 rst_n = 1'b1;

    // no image, no configuration
    rd_n(3, 1'b0);
    set_a('h3FDE); rd_n(6, 1'b0);

    // the image goes in while the machine is held in reset
    #1 rst_n = 1'b0;
    load_rom();
    #1 rst_n = 1'b1;
    repeat (4) @(posedge clk);
    if (dut.wa_q != 14'd0) $fatal(1, "ROMA %h after reset", dut.wa_q);
    wa = 0;
    rd_n(8, 1'b0);
    set_a(0); rd_n(600, 1'b1);
    set_a('h17FC); rd_n(8, 1'b1);                 // the last words, then FFFF
    for (int k = 0; k < 20; k++) begin
      set_a(int'($urandom_range(0, 'h1FFF))); rd_n(int'($urandom_range(1, 40)), k % 2 == 1);
    end
    set_a('h3FE0); rd_n(4, 1'b0);                 // configuration not valid yet

    // the configuration, then a wrap past 3FFF
    load_cfg();
    set_a('h3FE0); rd_n(32, 1'b1);
    rd_n(4, 1'b1);
    set_a('h3FDF); rd_n(3, 1'b0);
    set_a('h7FE4); rd_n(2, 1'b0);                 // ROMA keeps 14 bits

    // other ports leave ROMA alone
    set_a('h0123);
    cyc(16'h0710, 1'b1, 16'h0000, 1'b0, r, o);
    cyc(16'h0702, 1'b0, 16'h0000, 1'b0, r, o);
    cyc(ROMA, 1'b1, 16'h0000, 1'b0, r, o);
    if (o != 16'h0000) $fatal(1, "ROMA answers a read");
    cyc(ROMD, 1'b0, 16'h5555, 1'b0, r, o);
    rd_n(2, 1'b0);

    // Main clears the configuration; a new one replaces it
    cfg_ok = 1'b0;
    set_a('h3FF0); rd_n(4, 1'b0);
    foreach (cw[i]) cw[i] = {$urandom, $urandom};
    load_cfg();
    set_a('h3FE0); rd_n(32, 1'b0);

    // no card fitted: nothing answers
    #1 enable = 1'b0;
    set_a(0); rd_n(2, 1'b0);
    #1 enable = 1'b1;
    repeat (4) @(posedge clk);
    wa = 0;
    rd_n(2, 1'b0);
    $display("PASS tb_crom seed %0d (%0d reads)", seed, nrd);
    $finish;
  end

  initial begin
    #100ms $fatal(1, "timeout");
  end
endmodule
`default_nettype wire
