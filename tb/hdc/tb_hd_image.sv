// hd_image: geometry from raw sizes (exact, rounded up, none) and from a
// fixed-VHD footer (geometries past the card's limits refused), through a behavioural hps_io block port.
`timescale 1ns/1ps
`default_nettype none
module tb_hd_image;
  logic clk = 1'b0, rst_n = 1'b0;
  always #10 clk = ~clk;

  logic        img_mounted = 1'b0, img_readonly = 1'b0;
  logic [63:0] img_size = 64'd0;
  logic [31:0] sd_lba;
  logic        sd_rd, sd_ack = 1'b0, sd_buff_wr = 1'b0;
  logic [8:0]  sd_buff_addr = 9'd0;
  logic [7:0]  sd_buff_dout = 8'h00;
  logic        busy, present, readonly;
  logic [11:0] cyls;
  logic [3:0]  heads;
  logic [7:0]  spt;
  logic [31:0] sectors;
  logic [7:0]  last_sector [512];
  int          errors = 0;

  hd_image dut (.*);

  // hps_io: answer a read of the last sector with last_sector[].
  initial forever begin
    @(posedge clk);
    if (sd_rd) begin
      repeat (5) @(posedge clk);
      sd_ack <= 1'b1;
      for (int i = 0; i < 512; i++) begin
        @(posedge clk);
        sd_buff_addr <= 9'(i); sd_buff_dout <= last_sector[i]; sd_buff_wr <= 1'b1;
        @(posedge clk);
        sd_buff_wr <= 1'b0;
      end
      @(posedge clk);
      sd_ack <= 1'b0;
    end
  end

  task automatic mount(input longint bytes, input bit vhd, input int c, input int h, input int s);
    for (int i = 0; i < 512; i++) last_sector[i] = 8'h00;
    if (vhd) begin
      string ck = "conectix";
      for (int i = 0; i < 8; i++) last_sector[i] = ck[i];
      last_sector[56] = 8'(c >> 8); last_sector[57] = 8'(c); last_sector[58] = 8'(h); last_sector[59] = 8'(s);
      last_sector[63] = 8'd2;
    end
    @(posedge clk);
    img_size <= 64'(bytes); img_mounted <= 1'b1;
    @(posedge clk);
    img_mounted <= 1'b0;
    repeat (3) @(posedge clk);
    wait (!busy);
    @(posedge clk);
  endtask

  task automatic expect_geom(input string what, input bit p, input int c, input int h, input int s);
    if (present !== p || (p && (cyls != 12'(c) || heads != 4'(h) || spt != 8'(s)))) begin
      $display("FAIL %s: present=%b %0dx%0dx%0d, want %b %0dx%0dx%0d", what, present, cyls, heads, spt, p, c, h, s);
      errors++;
    end else $display("ok   %s: present=%b %0dx%0dx%0d sectors=%0d", what, present, cyls, heads, spt, sectors);
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    mount(64'd306*4*17*512, 0, 0, 0, 0);       expect_geom("raw 306x4 (also 612x2)", 1, 306, 4, 17);
    mount(64'd612*4*17*512, 0, 0, 0, 0);       expect_geom("raw 612x4", 1, 612, 4, 17);
    mount(64'd704*7*17*512, 0, 0, 0, 0);       expect_geom("raw 704x7", 1, 704, 7, 17);
    mount(64'd652*4*17*512, 0, 0, 0, 0);       expect_geom("raw 652x4", 1, 652, 4, 17);
    mount(64'd698*7*17*512, 0, 0, 0, 0);       expect_geom("raw 698x7", 1, 698, 7, 17);
    mount(64'd10*4*17*512, 0, 0, 0, 0);        expect_geom("raw 10x4", 1, 10, 4, 17);
    mount(64'd612*4*17*512 - 64'd5*512, 0, 0, 0, 0); expect_geom("raw 612x4 short by 5 sectors", 1, 612, 4, 17);
    mount(64'd1000*512, 0, 0, 0, 0);           expect_geom("raw odd size", 0, 0, 0, 0);
    mount(64'd820*6*17*512 + 64'd512, 1, 820, 6, 17); expect_geom("VHD 820x6x17", 1, 820, 6, 17);
    if (sectors != 32'd820*6*17) begin $display("FAIL VHD sectors %0d", sectors); errors++; end
    mount(64'd300*8*17*512 + 64'd512, 1, 300, 8, 17); expect_geom("VHD 300x8x17", 1, 300, 8, 17);
    if (sectors != 32'd300*8*17) begin $display("FAIL VHD sectors %0d", sectors); errors++; end
    mount(64'd300*9*17*512 + 64'd512, 1, 300, 9, 17); expect_geom("VHD 300x9x17 refused", 0, 0, 0, 0);
    mount(64'd300*8*18*512 + 64'd512, 1, 300, 8, 18); expect_geom("VHD 300x8x18 refused", 0, 0, 0, 0);
    mount(64'd2048*8*17*512 + 64'd512, 1, 2048, 8, 17); expect_geom("VHD 2048x8x17 refused", 0, 0, 0, 0);
    mount(64'd2047*8*17*512 + 64'd512, 1, 2047, 8, 17); expect_geom("VHD 2047x8x17", 1, 2047, 8, 17);
    mount(64'd0, 0, 0, 0, 0);                  expect_geom("eject", 0, 0, 0, 0);
    if (errors != 0) $fatal(1, "tb_hd_image: %0d failures", errors);
    $display("tb_hd_image: PASS");
    $finish;
  end
endmodule
`default_nettype wire
