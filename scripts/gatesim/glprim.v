// Simple models of the Quartus atoms in a functional netlist.
module dffeas (input d, clk, clrn, prn, ena, asdata, aload, sclr, sload, devclrn, devpor, output reg q);
  parameter power_up = "low";
  parameter is_wysiwyg = "false";
  parameter dont_touch = "false";
  parameter x_on_violation = "on";
  parameter sclr_over_ena = "false";
  parameter lpm_type = "dffeas";
  initial q = (power_up == "high");
  always @(posedge clk or negedge clrn or negedge prn or posedge aload)
    if (!clrn) q <= 1'b0;
    else if (!prn) q <= 1'b1;
    else if (aload) q <= asdata;
    else if (ena || sclr_over_ena == "true") begin
      if (sclr) q <= 1'b0;
      else if (!ena) q <= q;
      else if (sload) q <= asdata;
      else q <= d;
    end
endmodule
module cyclonev_io_ibuf (input i, ibar, dynamicterminationcontrol, output o);
  parameter bus_hold = "false";
  parameter simulate_z_as = "z";
  parameter differential_mode = "false";
  parameter lpm_type = "cyclonev_io_ibuf";
  assign o = i;
endmodule
module cyclonev_io_obuf (input i, oe, dynamicterminationcontrol, input [15:0] seriesterminationcontrol, parallelterminationcontrol, input devoe, output o, obar);
  parameter bus_hold = "false";
  parameter open_drain_output = "false";
  parameter shift_series_termination_control = "false";
  parameter sim_dynamic_termination_control_is_connected = "false";
  parameter lpm_type = "cyclonev_io_obuf";
  assign o = i;
  assign obar = ~i;
endmodule
// M10K slice, N x 1 as Quartus splits these RAMs; registered address,
// unregistered output; own-port read during write returns new data,
// the other port reads old data.
module cyclonev_ram_block (portadatain, portaaddr, portawe, portare, portbdatain, portbaddr, portbwe, portbre,
  clk0, clk1, ena0, ena1, ena2, ena3, clr0, clr1, nerror, portabyteenamasks, portbbyteenamasks,
  portaaddrstall, portbaddrstall, devclrn, devpor, eccstatus, portadataout, portbdataout, dftout);
  parameter operation_mode = "dual_port";
  parameter port_b_address_clock = "clock0";
  parameter port_a_address_width = 13;
  parameter port_b_address_width = 13;
  parameter port_a_data_width = 1;
  parameter port_b_data_width = 1;
  parameter clk0_core_clock_enable = 0;
  parameter clk1_core_clock_enable = 0;
  parameter data_interleave_offset_in_bits = 0;
  parameter data_interleave_width_in_bits = 0;
  parameter logical_ram_name = 0;
  parameter mixed_port_feed_through_mode = 0;
  parameter port_a_address_clear = 0;
  parameter port_a_byte_enable_clock = 0;
  parameter port_a_byte_enable_mask_width = 0;
  parameter port_a_byte_size = 0;
  parameter port_a_data_out_clear = 0;
  parameter port_a_data_out_clock = 0;
  parameter port_a_first_address = 0;
  parameter port_a_first_bit_number = 0;
  parameter port_a_last_address = 0;
  parameter port_a_logical_ram_depth = 0;
  parameter port_a_logical_ram_width = 0;
  parameter port_a_read_during_write_mode = 0;
  parameter port_b_address_clear = 0;
  parameter port_b_data_in_clock = 0;
  parameter port_b_data_out_clear = 0;
  parameter port_b_data_out_clock = 0;
  parameter port_b_first_address = 0;
  parameter port_b_first_bit_number = 0;
  parameter port_b_last_address = 0;
  parameter port_b_logical_ram_depth = 0;
  parameter port_b_logical_ram_width = 0;
  parameter port_b_read_during_write_mode = 0;
  parameter port_b_read_enable_clock = 0;
  parameter port_b_write_enable_clock = 0;
  parameter ram_block_type = 0;

  input  [0:0] portadatain; input [port_a_address_width-1:0] portaaddr; input portawe, portare;
  input  [0:0] portbdatain; input [port_b_address_width-1:0] portbaddr; input portbwe, portbre;
  input  clk0, clk1, ena0, ena1, ena2, ena3, clr0, clr1, nerror;
  input  [0:0] portabyteenamasks, portbbyteenamasks;
  input  portaaddrstall, portbaddrstall, devclrn, devpor;
  output [1:0] eccstatus; output [0:0] portadataout, portbdataout; output [8:0] dftout;
  localparam N = 1 << port_a_address_width;
  reg mem [0:N-1];
  reg qa = 1'b0, qb = 1'b0;
  integer i;
  initial for (i = 0; i < N; i = i + 1) mem[i] = 1'b0;
  always @(posedge clk0) if (ena0) begin
    if (portawe && portabyteenamasks[0]) begin mem[portaaddr] <= portadatain[0]; qa <= portadatain[0]; end
    else if (portare) qa <= mem[portaaddr];
  end
  wire bclk = (port_b_address_clock == "clock1") ? clk1 : clk0;
  wire bena = (port_b_address_clock == "clock1") ? ena1 : ena0;
  always @(posedge bclk) if (bena) begin
    if (portbwe && portbbyteenamasks[0] && operation_mode == "bidir_dual_port") begin mem[portbaddr] <= portbdatain[0]; qb <= portbdatain[0]; end
    else if (portbre) qb <= mem[portbaddr];
  end
  assign portadataout = qa;
  assign portbdataout = qb;
  assign eccstatus = 2'b00;
  assign dftout = 9'd0;
endmodule
