// C900 DMA address chips beside the 8716 on motherboard sheet 18:
//   U80 74LS374, clock LD2: Q7 = DIR (R/W), Q6:0 = word address 22:16
//   U81 74LS374, clock LD1: word address 15:8
//   U83 74LS193, /LOAD LD0, CNT_UP CLKADR: word address 3:0
//   U82 74LS193, /LOAD LD0, CNT_UP U83 TC_UP: word address 7:4
// The byte address is {wa, 1'b0}. 74LS374 has no clear and the 74LS193 CLR
// pins are grounded, so no board reset reaches these chips.  Silicon
// powers up with arbitrary contents; the initialisers give zero.
//
// One fabric clock. LD1 and LD2 are one-clock rise pulses (74LS374 clocks);
// CLKADR is a rise/fall pulse pair, from which the CNT_UP level is rebuilt
// for the U83 TC_UP output. U83 TC_UP rise is the U82 count enable. /LOAD is a level:
// while LD0 is Low both counters follow BD on every clk and ignore counts.
`default_nettype none

module dma_addr (
  input  logic        clk,
  input  logic [7:0]  bd_in,
  input  logic        ld0,
  input  logic        ld1,
  input  logic        ld2,
  input  logic        clkadr_rise,
  input  logic        clkadr_fall,
  output logic [22:0] wa,
  output logic        dir
);

  // Justification: CNT_UP level (reg-a), rebuilt from the pulses; idle Low.
  logic clkadr_q;
  logic clkadr;

  // Justification: chip state.
  logic [7:0] u80_q;
  logic [7:0] u81_q;
  logic [3:0] u82_q;
  logic [3:0] u83_q;

  logic [3:0] u82_d;
  logic [3:0] u83_d;
  logic       u83_tc_n, u83_tc_n_prev, u83_tc_rise;

  initial begin
    clkadr_q = 1'b0;
  end
  always_ff @(posedge clk) begin
    clkadr_q <= clkadr;
  end

  assign clkadr = (clkadr_q | clkadr_rise) & ~clkadr_fall;

  initial begin
    u80_q = 8'h00;
  end
  always_ff @(posedge clk) begin
    if (ld2) u80_q <= bd_in;
  end

  initial begin
    u81_q = 8'h00;
  end
  always_ff @(posedge clk) begin
    if (ld1) u81_q <= bd_in;
  end

  always_comb begin
    u83_d = u83_q;
    if (!ld0)             u83_d = bd_in[3:0];
    else if (clkadr_rise) u83_d = u83_q + 4'h1;
  end

  // U83 TC_UP (active low): Low while Q = 15 and CNT_UP is Low. Its level
  // on the previous sample follows from the registered Q and CLKADR.
  assign u83_tc_n      = ~((u83_d == 4'hF) & ~clkadr);
  assign u83_tc_n_prev = ~((u83_q == 4'hF) & ~clkadr_q);
  assign u83_tc_rise   = u83_tc_n & ~u83_tc_n_prev;

  always_comb begin
    u82_d = u82_q;
    if (!ld0)             u82_d = bd_in[7:4];
    else if (u83_tc_rise) u82_d = u82_q + 4'h1;
  end

  initial begin
    u82_q = 4'h0;
    u83_q = 4'h0;
  end
  always_ff @(posedge clk) begin
    u82_q <= u82_d;
    u83_q <= u83_d;
  end

  assign wa  = {u80_q[6:0], u81_q, u82_q, u83_q};
  assign dir = u80_q[7];

endmodule

`default_nettype wire
