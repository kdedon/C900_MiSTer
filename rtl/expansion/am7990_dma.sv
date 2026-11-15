// Am7990 bus master cycle: /HOLD-/HLDA handshake and the six T-states
// of a word transfer, at half-TCLK resolution.
//
//   T1 rise  address on A23:16 and DAL, READ, byte select, AS on, /DALO low
//   T2 fall  AS off
//   T3 rise  read: DAL released, /DALO high; write: data on DAL
//   T3 fall  /DAS low          T4 rise  read: /DALI low
//   T5 rise  /READY high adds a 100 ns wait state, sampled again next rise
//   T6 rise  /DAS high, read data taken      T6 fall  done
// The next word starts at the following T1 if req is still high, else
// /HOLD is released there.  BCON=1 makes pin 17 /BUSRQ: it is asserted
// only while the line is high.
`default_nettype none
module am7990_dma (
  input  logic        clk,
  input  logic        clr,         // STOP or RESET: abandon the cycle
  input  logic        tclk_rise,
  input  logic        tclk_fall,
  input  logic        acon,
  input  logic        bcon,
  // sequencer: hold req and the word until done; change them only after done
  input  logic        req,
  input  logic [23:0] addr,
  input  logic        wr,
  input  logic        byte_cyc,
  input  logic        hi_lane,     // byte cycle on DAL15:8
  input  logic [15:0] wdata,
  output logic        done,
  output logic [15:0] rdata,
  output logic        held,        // /HOLD asserted
  // pins
  output logic        hold_pd,
  input  logic        hold_i,      // pin 17 line level
  input  logic        hlda_n,
  input  logic        ready_n,
  input  logic [15:0] dal_i,
  output logic        drive,       // master: DAL/A/READ/DAS/ALE/BM/DALI/DALO enabled
  output logic [15:0] dal_o,
  output logic        dal_oe,
  output logic [7:0]  a_o,
  output logic        read_o,
  output logic        das_n_o,
  output logic        ale_o,
  output logic        pin15_o,     // BM0 or BYTE
  output logic        pin16_o,     // BM1 or /BUSAKO
  output logic        pin16_oe,
  output logic        dali_n_o,
  output logic        dalo_n_o
);
  typedef enum logic [1:0] {D_IDLE, D_REQ, D_CYC} dst_e;

  // Justification: (reg-a) cycle state, half-T count, latched read data.
  dst_e       st_q;
  logic [3:0] h_q;
  logic       done_q;

  always_ff @(posedge clk) begin
    done_q <= 1'b0;
    if (clr) begin
      st_q    <= D_IDLE;
      h_q     <= 4'd0;
      hold_pd <= 1'b0;
    end else begin
      unique case (st_q)
        D_IDLE: if (tclk_rise && req && (!bcon || hold_i)) begin
          hold_pd <= 1'b1;
          st_q    <= D_REQ;
        end
        D_REQ: if (tclk_rise && !hlda_n) begin
          st_q <= D_CYC;
          h_q  <= 4'd0;
        end
        D_CYC: begin
          if (tclk_rise) begin
            if (h_q == 4'd11) begin
              if (req) h_q <= 4'd0;
              else begin
                st_q    <= D_IDLE;
                hold_pd <= 1'b0;
              end
            end else if (h_q != 4'd7 || !ready_n) begin
              h_q <= h_q + 4'd1;
            end
            if (h_q == 4'd9) rdata <= dal_i;
          end
          if (tclk_fall && h_q != 4'd7) begin
            h_q <= h_q + 4'd1;
            if (h_q == 4'd10) done_q <= 1'b1;
          end
        end
        default: st_q <= D_IDLE;
      endcase
    end
  end

  assign done  = done_q;
  assign held  = hold_pd;
  assign drive = st_q == D_CYC;

  logic as_on;
  assign as_on    = h_q <= 4'd2;
  assign dal_o    = (h_q < 4'd4) ? addr[15:0] : wdata;
  assign dal_oe   = drive && (h_q < 4'd4 || wr);
  assign a_o      = addr[23:16];
  assign read_o   = !wr;
  assign das_n_o  = !(h_q >= 4'd5 && h_q <= 4'd9);
  assign ale_o    = acon ? !as_on : as_on;
  assign dali_n_o = wr || !(h_q >= 4'd6 && h_q <= 4'd9);
  assign dalo_n_o = !(wr || h_q < 4'd4);
  // BM1 BM0: LL word, LH upper byte, HL lower byte
  assign pin15_o  = bcon ? byte_cyc : (byte_cyc && hi_lane);
  assign pin16_o  = bcon ? (hlda_n || hold_pd) : (byte_cyc && !hi_lane);
  assign pin16_oe = bcon || drive;
endmodule
`default_nettype wire
