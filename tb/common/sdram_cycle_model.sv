// Cycle-level 16-bit SDR SDRAM module for whole-core benches: one chip
// selected by nCS Low and, with DUAL, a second chip selected by nCS High
// (the 128 MB MiSTer module).  No delays: commands are decoded at the rising
// edge of clk; the word for chip edge E(n) is driven from the falling edge
// after E(n-1) to the falling edge after E(n), the middle of the real
// tAC..tOH window, so a register sampling at either edge of the controller
// clock between those two points sees it.  A register sampling at the end
// of the window (the falling edge itself) gets the word only through
// nonblocking-assignment order: this model proves protocol and latency, not
// pin timing.
//
// Modelled: mode register (CL 2/3, BL 1/2/4/8, single-write bit), bank
// open/close, READ/WRITE with auto-precharge, DQM write masks, refresh
// interval per chip.  Errors are counted and printed; chip 1 holds no data.
`default_nettype none
module sdram_cycle_model #(
  parameter bit DUAL      = 1'b1,
  parameter int REFI_CLKS = 750      // refresh interval limit in clk cycles
) (
  input  wire        clk,
  input  wire        cke,
  input  wire [12:0] a,
  input  wire [1:0]  ba,
  inout  wire [15:0] dq,
  input  wire        dqml,
  input  wire        dqmh,
  input  wire        ncs,
  input  wire        nras,
  input  wire        ncas,
  input  wire        nwe
);
  int errors = 0;
  int n_ref [2];
  int n_rd = 0, n_wr = 0;
  int max_ref_gap [2];

  logic [15:0] mem [0:(1 << 24) - 1];   // chip 0: {ba, row, col[8:0]}

  int  cl = 2, bl = 1;
  bit  wr_single = 1'b0;
  bit  init_done [2];
  bit  act [2][4];
  int  row [2][4];
  longint ap_at [2][4];
  longint last_ref [2];
  longint edge_n = 0;

  // output slots, indexed by rising-edge number mod 16
  bit          slot_v [16];
  logic [15:0] slot_d [16];
  logic [15:0] dq_q = 16'h0000;
  bit          dq_oe = 1'b0;
  assign dq = dq_oe ? dq_q : 16'hzzzz;

  initial begin
    for (int c = 0; c < 2; c++) begin
      n_ref[c] = 0; max_ref_gap[c] = 0; init_done[c] = 0; last_ref[c] = 0;
      for (int b = 0; b < 4; b++) begin act[c][b] = 0; row[c][b] = 0; ap_at[c][b] = -1; end
    end
    for (int i = 0; i < 16; i++) slot_v[i] = 0;
  end

  task automatic err(input string msg);
    errors++;
    if (errors <= 20) $display("SDRAM ERROR edge %0d: %s", edge_n, msg);
  endtask

  always @(posedge clk) begin
    int c, b, col;
    logic [23:0] k;
    logic [15:0] d;
    edge_n++;
    for (int ci = 0; ci < 2; ci++)
      for (int bi = 0; bi < 4; bi++)
        if (ap_at[ci][bi] >= 0 && edge_n >= ap_at[ci][bi]) begin
          act[ci][bi]   = 0;
          ap_at[ci][bi] = -1;
        end
    for (int ci = 0; ci < 2; ci++)
      if (init_done[ci] && edge_n - last_ref[ci] > longint'(REFI_CLKS) &&
          edge_n - last_ref[ci] == longint'(REFI_CLKS) + 1)
        err($sformatf("chip %0d refresh interval over %0d clocks", ci, REFI_CLKS));
    c = DUAL ? int'(ncs) : 0;
    if (cke && (DUAL || !ncs) && {nras, ncas, nwe} != 3'b111) begin
      b = int'(ba);
      unique case ({nras, ncas, nwe})
        3'b011: begin  // ACTIVE
          if (!init_done[c]) err($sformatf("chip %0d ACTIVE before init", c));
          if (act[c][b]) err($sformatf("chip %0d ACTIVE to open bank %0d", c, b));
          if (c == 1) err("chip 1 accessed");
          act[c][b] = 1;
          row[c][b] = int'(a);
        end
        3'b101, 3'b100: begin  // READ / WRITE
          if (!act[c][b] || ap_at[c][b] >= 0) err($sformatf("chip %0d column command to closed bank %0d", c, b));
          if (a[9]) err("column bit A9 set");
          col = int'(a[8:0]);
          if (!nwe) begin
            k = {ba, row[c][b][12:0], 9'(col)};
            d = mem[k];
            if (!dqml) d[7:0]  = dq[7:0];
            if (!dqmh) d[15:8] = dq[15:8];
            if (c == 0) mem[k] = d;
            n_wr++;
            if (a[10]) ap_at[c][b] = edge_n + 2;
          end else begin
            for (int i = 0; i < bl; i++) begin
              int cc, s;
              cc = (col & ~(bl - 1)) | ((col + i) & (bl - 1));
              s  = int'((edge_n + longint'(cl - 1 + i)) % 16);
              slot_v[s] = 1;
              slot_d[s] = mem[{ba, row[c][b][12:0], 9'(cc)}];
            end
            n_rd++;
            if (a[10]) ap_at[c][b] = edge_n + longint'(bl);
          end
        end
        3'b010: begin  // PRECHARGE
          for (int i = 0; i < 4; i++)
            if (a[10] || i == b) begin
              if (ap_at[c][i] >= 0) err($sformatf("chip %0d PRECHARGE during auto-precharge", c));
              act[c][i] = 0;
            end
        end
        3'b001: begin  // AUTO REFRESH
          for (int i = 0; i < 4; i++)
            if (act[c][i]) err($sformatf("chip %0d REFRESH with bank %0d open", c, i));
          if (init_done[c]) begin
            n_ref[c]++;
            if (int'(edge_n - last_ref[c]) > max_ref_gap[c]) max_ref_gap[c] = int'(edge_n - last_ref[c]);
          end
          last_ref[c] = edge_n;
        end
        3'b000: begin  // LOAD MODE
          cl = int'(a[6:4]);
          unique case (a[2:0])
            3'd0: bl = 1;
            3'd1: bl = 2;
            3'd2: bl = 4;
            3'd3: bl = 8;
            default: err("unsupported burst length");
          endcase
          wr_single = a[9];
          if (cl != 2 && cl != 3) err("unsupported CAS latency");
          if (bl > 1 && !wr_single) err("write bursts are not modelled");
          init_done[c] = 1;
          last_ref[c]  = edge_n;
        end
        default: err($sformatf("unsupported command %b", {nras, ncas, nwe}));
      endcase
    end
  end

  // Drive the word of the next chip edge from this falling edge.
  always @(negedge clk) begin
    int s;
    s = int'((edge_n) % 16);
    dq_oe <= slot_v[s];
    if (slot_v[s]) dq_q <= slot_d[s];
    slot_v[s] = 0;
  end
endmodule
`default_nettype wire
