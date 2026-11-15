/********************************************************************************
 * Commodore 128 VDC
 *
 * for the C128 MiSTer FPGA core, by Erik Scheffers
 *
 * - timing based on the excellent analysis by @remark on the C128 forum
 *   https://c-128.freeforums.net/post/5516/thread
 ********************************************************************************/

module vdc_ramiface #(
	parameter RAM_ADDR_BITS,

	parameter C_LATCH_WIDTH,
	parameter S_LATCH_WIDTH,

	parameter C_LATCH_BITS = $clog2(C_LATCH_WIDTH),
	parameter S_LATCH_BITS = $clog2(S_LATCH_WIDTH)
)(
	input          ram64k,   // 0 = 16kB, 1 = 64kB -- visible RAM
	input          initRam,  // 1 = initialize RAM on reset
	input          debug,

	input          clk,
	input          reset,
	input          enable,

	input    [5:0] regA,      // selected register
	input    [7:0] db_in,     // cpu data in
	input          enableBus,
	input          cs,
	input          rs,
	input          we,        // write registers

	input    [7:0] reg_ht,    // horizontal total
	input    [7:0] reg_hd,    // horizontal display
	input    [7:0] reg_ai,	  // address increment
	input          reg_copy,  // copy mode
	input          reg_ram,   // configured ram, 0=16kB, 1=64kB
	input          reg_atr,   // attribute enable
	input          reg_text,  // text/bitmap mode
	input    [4:0] reg_ctv,   // character Total Vertical (minus 1)
	input   [15:0] reg_ds,    // display start address
	input   [15:0] reg_aa,    // attribute start address
	input    [2:0] reg_cb,    // character start address
	input    [3:0] reg_drr,   // dynamic refresh count

	output  [15:0] reg_ua,    // update address
	output   [7:0] reg_wc,    // word count
	output   [7:0] reg_da,    // data
	output  [15:0] reg_ba,    // block start address

	input          fetchFrame,
	input          fetchLine,
	input          fetchRow,
	input          lastRow,
	input          newCol,
	input          endCol,
	input    [7:0] col,
	input    [4:0] line,

	output    wire busy,
	output         rowbuf,                     // buffer containing current screen info
	output reg [15:0] attrv,                   // attributes at column col-8, rows 1 and 0
	output   [7:0] charbuf[C_LATCH_WIDTH],     // character data for current col
	output  [15:0] dispaddr,

	// RAM pins, set at the start of a column and held to the next
	output                     mem_rd,
	output                     mem_we,
	output [RAM_ADDR_BITS-1:0] mem_addr,
	output               [7:0] mem_di,
	input                [7:0] mem_do     // the byte read at the last mem_rd
);

// Row latches in block RAM, a byte lane per row buffer. They are written
// only on enabled clocks and read only on enabled clocks, which never follow
// each other; col and rowbuf change only on enabled clocks. So the read
// registered on the clock before gives what the latch shows that cycle.
// lc lanes: screen codes rows 0, 1, attributes rows 0, 1 (b7 for the
// character fetch); lv lanes: attributes rows 0, 1 for the video.
(* ramstyle = "M10K" *) reg [3:0][7:0] lc[S_LATCH_WIDTH];
(* ramstyle = "M10K" *) reg [1:0][7:0] lv[S_LATCH_WIDTH];
reg [31:0] lc_q;
wire [7:0] scrn_q0 = lc_q[7:0];
wire [7:0] scrn_q1 = lc_q[15:8];
wire       atb_q0  = lc_q[23];
wire       atb_q1  = lc_q[31];
wire [7:0] vcol = col - 8'd8;

always @(posedge clk) begin
	lc_q  <= lc[col[S_LATCH_BITS-1:0]];
	attrv <= lv[vcol[S_LATCH_BITS-1:0]];
end

typedef enum bit[2:0] {CA_IDLE, CA_READ, CA_WRITE, CA_FILL, CA_COPY[2]} cAction_t;
typedef enum bit[2:0] {RA_IDLE, RA_CHAR, RA_SCRN, RA_ATTR, RA_CPU, RA_RFSH} rAction_t;

cAction_t  cpuAction;
rAction_t  ramAction;

reg        start_erase;
reg        erasing;

// si, ai and rowbuf as they stand before the clock edge.
reg [S_LATCH_BITS-1:0] si_q, ai_q;
reg                    rowbuf_q;

// The latch write of an enabled end-of-column clock: the byte just read,
// to the next row's lane.
wire                    rl_we = !reset && !start_erase && !erasing && enable && endCol;
wire                    rl_ws = rl_we && ramAction == RA_SCRN;
wire                    rl_wa = rl_we && ramAction == RA_ATTR;
wire [S_LATCH_BITS-1:0] rl_a  = rl_ws ? si_q : ai_q;

always @(posedge clk) begin
	if (rl_ws || rl_wa) begin
		if (rl_ws &&  rowbuf_q) lc[rl_a][0] <= mem_do;
		if (rl_ws && !rowbuf_q) lc[rl_a][1] <= mem_do;
		if (rl_wa &&  rowbuf_q) lc[rl_a][2] <= mem_do;
		if (rl_wa && !rowbuf_q) lc[rl_a][3] <= mem_do;
	end
	if (rl_wa) begin
		if ( rowbuf_q) lv[rl_a][0] <= mem_do;
		if (!rowbuf_q) lv[rl_a][1] <= mem_do;
	end
end

reg        ram_rd;
reg        ram_we;
reg [15:0] ram_addr;
reg  [7:0] ram_di;
wire [7:0] ram_do = mem_do;

function [RAM_ADDR_BITS-1:0] shuffleAddr;
	input [15:0] addr;
	input        has64k;
	input        ena64k;
begin
	if (RAM_ADDR_BITS > 14)
		shuffleAddr = RAM_ADDR_BITS'(
			ena64k ? {has64k & addr[15], addr[14:9], has64k & addr[8], addr[7:0]}
			       : {has64k & addr[15], addr[13:8], has64k & addr[8], addr[7:0]}
		);
	else
		shuffleAddr = RAM_ADDR_BITS'(ena64k ? {addr[14:9], addr[7:0]} : addr[13:0]);
end
endfunction

assign mem_rd   = ram_rd;
assign mem_we   = ram_we;
assign mem_addr = shuffleAddr(ram_addr, ram64k, reg_ram /*|| (ramAction==RA_IDLE || ramAction==RA_RFSH)*/);
assign mem_di   = ram_di;

wire en_rfsh = col >= reg_hd && col < reg_hd+reg_drr;
wire en_int = col < 2 || col >= reg_ht-8'd2;

wire [7:0] attrlen = lastRow ? 8'd2 : reg_hd;
wire [7:0] scrnlen = reg_hd;

always @(posedge clk) begin
	reg [15:0] scrnaddr;    // screen data row address
	reg [15:0] attraddr;    // attributes row address
	reg  [7:0] rfshaddr;    // refresh address
	reg  [7:0] wda, cda;    // write/copy data
	reg  [7:0] wc;          // block word count
	reg        en_char;     // enable char fetch
	reg        firstLine, firstAttr;

	reg [C_LATCH_BITS-1:0] ci; // character index
	reg [S_LATCH_BITS-1:0] si; // screen index
	reg [S_LATCH_BITS-1:0] ai; // attribute index

	integer    i;

	busy = erasing || start_erase || reset || cpuAction != CA_IDLE;

	ram_rd <= 0;
	ram_we <= 0;

	if (reset) begin
		ci     = 0;
		si     = 0;
		ai     = 0;

		wc     <= 0;
		wda    <= 0;
		cda	 <= 0;
		reg_ua <= 0;
		reg_wc <= 0;
		reg_da <= 0;
		reg_ba <= 0;

		cpuAction <= CA_IDLE;
		ramAction <= RA_IDLE;
		start_erase <= initRam;
		ram_addr <= 16'hFFFF;
		ram_di <= 0;
		ram_rd <= 1;
		ram_we <= 0;

		dispaddr <= 16'hFFFF;
	end
	else begin
		if (enableBus && cs && rs) begin
			if (!we) begin
				// Reading DA loads next value into DA
				if (regA == 31) begin
					reg_ua    <= reg_ua + 16'd1;
					cpuAction <= CA_READ;
				end
			end
			else begin
				case (regA)
					// Updating UA loads value at new address into DA
					18: begin
						reg_ua[15:8] <= db_in;
						cpuAction    <= CA_READ;
					end
					19: begin
						reg_ua[7:0] <= db_in;
						cpuAction   <= CA_READ;
					end

					// Updating WC starts a COPY (from BA to UA) or FILL (to UA) for WC items
					// Does *not* change WC or DA
					30: begin
						reg_wc    <= db_in;
						wc        <= db_in;
						cpuAction <= reg_copy ? CA_COPY0 : CA_FILL;
					end

					// Updating DA writes databus to UA and loads next value into DA
					31: begin
						wda       <= db_in;
						cpuAction <= CA_WRITE;
					end

					// Updating BA does not change state
					32: reg_ba[15:8] <= db_in;
					33: reg_ba[7:0]  <= db_in;
				endcase
			end
		end

		if (start_erase) begin
			start_erase <= 0;
			erasing     <= 1;
			ram_di      <= 8'hFF;
			ram_addr    <= 0;
			ram_we      <= 1;
		end
		else if (erasing) begin
			if (ram_addr == 16'hFFFF) begin
				erasing  <= 0;
				ram_we   <= 0;
			end
			else begin
				ram_di   <= ram_addr[0] ? 8'h00 : 8'hFF;
				ram_addr <= ram_addr + 16'd1;
				ram_we   <= 1;
			end
		end
		else if (enable && endCol) begin
			charbuf[ci] <= ramAction == RA_IDLE && debug ? 8'h00 : ram_do;
			ci = C_LATCH_BITS'((ci + 1) % C_LATCH_WIDTH);

			case (ramAction)
				RA_SCRN: begin
					si = S_LATCH_BITS'(si + 1);
				end

				RA_ATTR:  begin
					ai = S_LATCH_BITS'(ai + 1);
				end

				RA_CPU:
					case (cpuAction)
						CA_READ: begin
							reg_da    <= ram_do;
							cpuAction <= CA_IDLE;
						end
						CA_WRITE: begin
							reg_ua    <= reg_ua + 16'd1;
							cpuAction <= CA_READ;
						end
						CA_FILL: begin
							reg_ua    <= reg_ua + 16'd1;
							wc        <= wc - 8'd1;
							cpuAction <= wc==1 ? CA_IDLE : CA_FILL;
						end
						CA_COPY0: begin
							cda       <= ram_do;
							reg_ba    <= reg_ba + 16'd1;
							cpuAction <= CA_COPY1;
						end
						CA_COPY1:  begin
							reg_ua    <= reg_ua + 16'd1;
							wc        <= wc - 8'd1;
							cpuAction <= wc==1 ? CA_IDLE : CA_COPY0;
						end
					endcase
			endcase
		end
		else if (enable && newCol) begin
			if (col == 0) begin
				if (fetchLine) begin
					ci = 0;
					en_char = 1;
				end

				if (fetchFrame) begin
					scrnaddr = reg_ds;
					firstLine <= |reg_ctv;
					firstAttr <= 1;
				end

				if (fetchRow || fetchFrame) begin
					rowbuf = ~rowbuf;

					if (!reg_text) begin
						si = 0;
						dispaddr <= scrnaddr;
					end
					else
						dispaddr <= 16'hffff;

					if (reg_atr) begin
						ai = 0;
						attraddr = fetchFrame ? reg_aa + ((reg_text && reg_ai) ? 16'd1 : 16'd0)
						                      : attraddr + reg_hd + reg_ai + ((firstAttr && reg_text && reg_ai) ? reg_ai-16'd2 : 16'd0);
						if (!fetchFrame)
							firstAttr <= 0;
					end
				end

				if (fetchRow || (reg_text && fetchLine)) begin
					scrnaddr = (fetchFrame || (reg_text && firstLine)) ? reg_ds : scrnaddr + reg_hd + reg_ai;
					firstLine <= 0;
				end
			end

			if (col == reg_hd) begin
				en_char = 0;
			end

			ram_di <= 8'hXX;

			if (en_char) begin
				// fetch character data
				ramAction <= RA_CHAR;

				if (reg_text)
					ram_addr <= 16'(scrnaddr + col);
				else if (col < S_LATCH_WIDTH) begin
					if (reg_ctv[4])
						ram_addr <= {reg_cb[2:1], reg_atr & (rowbuf ? atb_q1 : atb_q0), (rowbuf ? scrn_q1 : scrn_q0), line[4:0]};
					else
						ram_addr <= {reg_cb,      reg_atr & (rowbuf ? atb_q1 : atb_q0), (rowbuf ? scrn_q1 : scrn_q0), line[3:0]};
				end

				ram_rd <= 1;
			end
			else if (!en_int && en_rfsh) begin
				// ram refresh causes glitches in the last column when scrolling horizontally
				ramAction     <= RA_RFSH;
				ram_addr[7:0] <= rfshaddr;
				rfshaddr      <= rfshaddr + 1'd1;
				ram_rd        <= 1;
			end
			else if (!en_int && si < scrnlen) begin
				// fetch screen data
				ramAction <= RA_SCRN;
				ram_addr  <= scrnaddr + si;
				ram_rd    <= 1;
			end
			else if (!en_int && ai < attrlen) begin
				// fetch attribute data
				ramAction <= RA_ATTR;
				ram_addr  <= attraddr + ai;
				ram_rd    <= 1;
			end
			else if (cpuAction != CA_IDLE) begin
				// perform CPU action -- are these allowed during `en_int`?
				ramAction <= RA_CPU;

				case (cpuAction)
					CA_READ: begin
						ram_addr  <= reg_ua;
						ram_rd    <= 1;
					end
					CA_WRITE: begin
						ram_di    <= wda;
						ram_addr  <= reg_ua;
						ram_we    <= 1;
					end
					CA_FILL: begin
						ram_di    <= wda;
						ram_addr  <= reg_ua;
						ram_we    <= 1;
					end
					CA_COPY0: begin
						ram_addr  <= reg_ba;
						ram_rd    <= 1;
					end
					CA_COPY1: begin
						ram_di    <= cda;
						ram_addr  <= reg_ua;
						ram_we    <= 1;
					end
				endcase
			end
			else begin
				ram_addr  <= 16'hffff;
				ram_rd    <= 1;
				ramAction <= RA_IDLE;
			end
		end
	end

	si_q     <= si;
	ai_q     <= ai;
	rowbuf_q <= rowbuf;
end

endmodule
