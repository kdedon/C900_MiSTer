// Writes boot0.rom, the boot ROM, into the platform RAM at physical
// 0x000000-0x00FFFF, where c900_dram reads it under _ROMCS.  Image bytes:
//   32 KB, a 23128 pair: 0x0000-0x3FFF U17 (D15:D8), 0x4000-0x7FFF U18
//          (D7:D0), written to both halves of the segment (the parts do
//          not see A15)
//   64 KB, a 27256 pair: 0x0000-0x7FFF U17, 0x8000-0xFFFF U18
// The first 32 KB always load as a 23128 pair.  A U18 byte of a 27256 pair
// then takes its word's high byte from the word's low byte, where the
// 23128 load left U17 byte 0x4000-0x7FFF (read-modify-write).
// Each byte is held (busy, the HPS's ioctl_wait) until the RAM has taken it.
`default_nettype none
module boot_rom_load (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        wr,          // one image byte
  input  logic [15:0] addr,
  input  logic [7:0]  data,
  output logic        busy,
  output logic [23:1] mem_addr,
  output logic        mem_rd,
  output logic        mem_wr,
  output logic [1:0]  mem_be,
  output logic [15:0] mem_wdata,
  input  logic [7:0]  mem_rdata,   // D7:D0 of the word read
  input  logic        mem_ack
);
  logic u18_64, rmw;
  assign u18_64 = addr[15];
  assign rmw    = addr[15] & addr[14];

  // Justification: (reg-a) the access in progress, the read before a
  // read-modify-write, and the mirror write to follow a 23128 byte.
  logic        pend_q, rd_q, again_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pend_q  <= 1'b0;
      rd_q    <= 1'b0;
      again_q <= 1'b0;
    end else if (pend_q) begin
      if (mem_ack) begin
        pend_q  <= rd_q | again_q;
        rd_q    <= 1'b0;
        again_q <= 1'b0;
      end
    end else if (wr) begin
      pend_q  <= 1'b1;
      rd_q    <= rmw;
      again_q <= ~u18_64;
    end
  end

  // Justification: (reg-a) the byte, its lane and word, the low byte read.
  logic        hi_q, both_q;
  logic [15:1] word_q;
  logic [7:0]  data_q, rlo_q;
  always_ff @(posedge clk) begin
    if (!pend_q && wr) begin
      hi_q   <= ~u18_64 & ~addr[14];
      both_q <= rmw;
      word_q <= u18_64 ? addr[14:0] : {1'b0, addr[13:0]};
      data_q <= data;
    end else if (pend_q && mem_ack) begin
      if (rd_q) rlo_q <= mem_rdata;
      else      word_q[15] <= 1'b1;
    end
  end

  assign busy      = pend_q;
  assign mem_addr  = {8'h00, word_q};
  assign mem_rd    = pend_q & rd_q;
  assign mem_wr    = pend_q & ~rd_q;
  assign mem_be    = both_q ? 2'b11 : {hi_q, ~hi_q};
  assign mem_wdata = both_q ? {rlo_q, data_q} : {data_q, data_q};
endmodule
`default_nettype wire
