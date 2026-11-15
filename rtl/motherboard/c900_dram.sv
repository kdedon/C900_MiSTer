// The motherboard DRAM banks behind the U54 strobes, held in the platform
// RAM (SDRAM) at the C900 physical address.  Bank 0 (_RAS0, segments
// 0x08-0x0F) and bank 1 (_RAS1, 0x10-0x17) are the stock 1 MB; 512K fits
// bank 0 only, and an unfitted bank neither drives the bus nor stores.
// The NON-STOCK RAM card adds its own strobes (c900_ramcard).
// The boot ROM is held there too, at 0x000000-0x00FFFF: _ROMCS starts a
// read as a row strobe does, and the word drives AD under rom_oe.
//
// The strobes come from U54 on the bus wires.  A read is requested when
// the row strobe of a fitted bank falls
// with R/W High and /AS High: the request is the strobe itself in its first clock (the
// controller sees it at the next fabric edge, one after the ZCLK rise that
// dropped /MREQ) and then a register held until mem_ack.  The address is
// the MMU's physical address (or the U80-U83 word address while /NOMMU is
// Low), valid since the /AS fall.  The data is driven only under the
// column strobes, so a read that turns out not to be a DRAM cycle is never
// seen.  A write is requested when a column strobe falls with R/W Low and
// the row strobe Low; the asserted column strobes are the byte enables
// (_CASxH = D15:D8, _CASxL = D7:D0).  A column strobe with the row strobe
// High (U53 holds _CAS Low into the next T1, where the MMU already drives
// the next address) and a row strobe with no column strobe (refresh) leave
// the array alone.  Read data drives AD while a column strobe of a fitted
// bank is Low and R/W is High.
`default_nettype none
module c900_dram (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        ram_512k,   // bank 1 unfitted
  input  logic        card_fit,   // RAM card fitted (non-stock)
  input  logic [23:0] pa,         // physical byte address
  input  logic        ras0_n,
  input  logic        cas0l_n,
  input  logic        cas0h_n,
  input  logic        ras1_n,
  input  logic        cas1l_n,
  input  logic        cas1h_n,
  input  logic        ras2_n,     // RAM card strobes
  input  logic        cas2l_n,
  input  logic        cas2h_n,
  input  logic        romcs_n,
  input  logic        rom_oe,
  input  logic        as_n,       // /AS (a new cycle begins when it falls)
  input  logic        rfsh_n,     // refresh cycle (row strobe only)
  input  logic        we_n,       // R/W: High = read
  input  logic [15:0] d_in,
  output logic [15:0] d_out,
  output logic        d_oe,
  // memory port to the platform RAM controller
  output logic [23:1] mem_addr,
  output logic        mem_rd,
  output logic        mem_wr,
  output logic [1:0]  mem_be,
  output logic [15:0] mem_wdata,
  input  logic [15:0] mem_rdata,
  input  logic        mem_rvalid,
  input  logic        mem_ack
);
  logic bank1_fit, ext_fit;
  assign bank1_fit = ~ram_512k;
  assign ext_fit   = card_fit;

  logic row_n, casl_n, cash_n;
  assign row_n  = ras0_n & (ras1_n | ~bank1_fit) & (ras2_n | ~ext_fit);
  assign casl_n = cas0l_n & (cas1l_n | ~bank1_fit) & (cas2l_n | ~ext_fit);
  assign cash_n = cas0h_n & (cas1h_n | ~bank1_fit) & (cas2h_n | ~ext_fit);

  // A read opens with a row strobe or _ROMCS; _ROMCS aliases fold onto the
  // ROM's 64 KB.
  logic rd_n;
  logic [23:1] rd_addr;
  assign rd_n    = row_n & romcs_n;
  assign rd_addr = romcs_n ? pa[23:1] : {8'h00, pa[15:1]};

  logic row_q, col_q, as_q, issued_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      row_q    <= 1'b0;
      col_q    <= 1'b0;
      as_q     <= 1'b1;
    end else begin
      row_q    <= ~rd_n & rfsh_n;
      col_q    <= ~(casl_n & cash_n);
      as_q     <= as_n;
    end
  end

  logic rd_start, rd_now;
  assign rd_start = !issued_q && we_n && ~rd_n && rfsh_n && as_n;

  // Request: a level held until mem_ack.
  logic        req_rd_q, req_wr_q;
  logic [23:1] addr_q;
  logic [1:0]  be_q;
  logic [15:0] wdata_q, rdata_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      req_rd_q <= 1'b0;
      req_wr_q <= 1'b0;
      addr_q   <= 23'h0;
      be_q     <= 2'b00;
      wdata_q  <= 16'h0000;
    end else if (mem_ack) begin
      req_rd_q <= 1'b0;
      req_wr_q <= 1'b0;
    end else if (!req_rd_q && !req_wr_q) begin
      if (rd_start) begin
        req_rd_q <= 1'b1;
        addr_q   <= rd_addr;
        be_q     <= 2'b11;
      end else if (~(casl_n & cash_n) && !col_q && !we_n && !row_n) begin
        req_wr_q <= 1'b1;
        addr_q   <= pa[23:1];
        be_q     <= {~cash_n, ~casl_n};
        wdata_q  <= d_in;
      end
    end
  end

  // One read per row strobe: re-armed when /AS falls or the strobe rises.
  // A bus master that holds /MREQ (the row strobe) across its cycles gets
  // each read at its /AS rise, where the board's latches take the address:
  // the previous word can still be on AD while /AS is Low.
  always_ff @(posedge clk) begin
    if (!rst_n)                                   issued_q <= 1'b0;
    else if ((as_q && !as_n) || (rd_n && row_q))  issued_q <= 1'b0;
    else if (rd_now)                              issued_q <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n)                  rdata_q <= 16'hFFFF;
    else if (mem_ack && req_rd_q) rdata_q <= mem_rdata;
  end

  // A read's first clock is the strobe itself.
  assign rd_now    = rd_start && !req_rd_q && !req_wr_q;
  assign mem_addr  = rd_now ? rd_addr : addr_q;
  assign mem_rd    = req_rd_q | rd_now;
  assign mem_wr    = req_wr_q;
  assign mem_be    = rd_now ? 2'b11 : be_q;
  assign mem_wdata = wdata_q;

  // The returning word goes straight to the bus while mem_rvalid or mem_ack
  // is High.
  assign d_out = (req_rd_q && (mem_rvalid || mem_ack)) ? mem_rdata : rdata_q;
  assign d_oe  = we_n & ~(casl_n & cash_n) | rom_oe;

  logic unused_ok;
  assign unused_ok = &{1'b0, pa[0]};
endmodule
`default_nettype wire
