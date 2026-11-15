// ST-506 drive emulator: write decoder.  Turns the cells written under
// WG back into fields: it hunts for the A1 sync (0x4489), then reads 16
// cells per byte.  The byte after the A1 decides the field: F8 = a data
// field (its data bytes go to the staging buffer and its ECC is
// computed; complete after size + 4 more bytes), an IDENT byte = an ID
// field (complete after 7 bytes), anything else drops the sync.
//
// `cell_bit` is the decision for one cell (a WMFM pulse arrived in it),
// `cell_idx` the cell's position in the revolution.  Events are pulses
// in the clk after the deciding cell; `fq` is the field's byte position
// (A1 first cell + 8 cells, divided by 16 toward zero).
`default_nettype none

module st506_wrdec (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,        // WG rose: drop the sync
  input  logic        cell_v,       // a cell is decided this clk
  input  logic        cell_bit,
  input  logic [17:0] cell_idx,
  input  logic [3:0]  size_l2,
  // staging buffer
  output logic        st_we,
  output logic [9:0]  st_addr,
  output logic [7:0]  st_d,
  // events
  output logic        ev_dhdr,      // a data field's F8 was read
  output logic        ev_data,      // a data field is complete
  output logic [31:0] data_ecc,
  output logic        ev_id,        // an ID field is complete
  output logic [10:0] id_cyl,
  output logic [7:0]  id_hb,
  output logic [7:0]  id_sec,
  output logic [13:0] fq            // byte position of the current field
);
  import st506_pkg::*;

  // Justification: last 16 cells, sync, cell count, field length (reg-a).
  logic [15:0] sr_q;
  logic        sync_q;
  logic [3:0]  nc_q;
  logic [10:0] len_q;
  // Justification: field kind and its bytes (reg-a).
  logic        isdata_q;
  logic [10:0] cyl_q;
  logic [7:0]  hb_q, sec_q;
  logic [31:0] ecc_q;
  logic [13:0] fq_q;
  // Justification: event pulses and staging write (reg-a).
  logic        dh_q, dv_q, iv_q, we_q;
  logic [9:0]  wa_q;
  logic [7:0]  wd_q;

  logic [15:0] sr_n;
  logic [7:0]  byte_c;
  logic [17:0] fc_c;      // A1 first cell + 8, toward zero
  logic [10:0] size_c;

  assign sr_n   = {sr_q[14:0], cell_bit};
  assign byte_c = {sr_n[14], sr_n[12], sr_n[10], sr_n[8], sr_n[6], sr_n[4], sr_n[2], sr_n[0]};
  assign size_c = 11'd1 << size_l2;
  // the A1 ends at cell_idx; its first cell is cell_idx - 15
  assign fc_c   = (cell_idx < 18'd7) ? 18'd0 : cell_idx - 18'd7;

  logic unused_ok;
  assign unused_ok = &{1'b0, sr_q[15], fc_c[3:0]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sr_q <= 16'h0000;  sync_q <= 1'b0;  nc_q <= 4'd0;  len_q <= 11'd0;
      isdata_q <= 1'b0;  cyl_q <= 11'd0;  hb_q <= 8'd0;  sec_q <= 8'd0;  ecc_q <= 32'h0;  fq_q <= 14'd0;
      dh_q <= 1'b0;  dv_q <= 1'b0;  iv_q <= 1'b0;  we_q <= 1'b0;  wa_q <= 10'd0;  wd_q <= 8'd0;
    end else begin
      dh_q <= 1'b0;  dv_q <= 1'b0;  iv_q <= 1'b0;  we_q <= 1'b0;
      if (start) begin
        sr_q <= 16'h0000;  sync_q <= 1'b0;
      end else if (cell_v) begin
        sr_q <= sr_n;
        if (!sync_q) begin
          if (sr_n == A1Cells) begin
            sync_q <= 1'b1;  nc_q <= 4'd0;  len_q <= 11'd1;  fq_q <= fc_c[17:4];
          end
        end else begin
          nc_q <= nc_q + 4'd1;
          if (nc_q == 4'd15) begin
            len_q <= len_q + 11'd1;
            if (len_q == 11'd1) begin
              isdata_q <= byte_c == 8'hF8;
              ecc_q    <= EccAfterMark;
              if (byte_c == 8'hF8)                  dh_q <= 1'b1;
              else if ((byte_c & 8'hF4) == 8'hF4)   cyl_q[10:8] <= {~byte_c[3], ~byte_c[1], byte_c[0]};
              else                                  sync_q <= 1'b0;
            end else if (isdata_q) begin
              if (len_q < size_c + 11'd2) begin
                we_q  <= 1'b1;  wa_q <= 10'(len_q - 11'd2);  wd_q <= byte_c;
                ecc_q <= ecc32_byte(ecc_q, byte_c);
              end
              if (len_q == size_c + 11'd5) begin
                dv_q <= 1'b1;  sync_q <= 1'b0;
              end
            end else begin
              case (len_q)
                11'd2:   cyl_q[7:0] <= byte_c;
                11'd3:   hb_q <= byte_c;
                11'd4:   sec_q <= byte_c;
                11'd6:   begin iv_q <= 1'b1; sync_q <= 1'b0; end
                default: ;
              endcase
            end
          end
        end
      end
    end
  end

  assign st_we    = we_q;
  assign st_addr  = wa_q;
  assign st_d     = wd_q;
  assign ev_dhdr  = dh_q;
  assign ev_data  = dv_q;
  assign data_ecc = ecc_q;
  assign ev_id    = iv_q;
  assign id_cyl   = cyl_q;
  assign id_hb    = hb_q;
  assign id_sec   = sec_q;
  assign fq       = fq_q;

endmodule

`default_nettype wire
