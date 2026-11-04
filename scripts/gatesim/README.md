# Netlist simulation of one module

Synthesise a module alone with Quartus 17.0.2 (the core's version), write
its functional Verilog netlist, and run an existing Verilator bench on it.

    mkdir w && cd w
    cp <rtl files> . && cp ../ds.qsf ds.qsf          # edit TOP_LEVEL_ENTITY, files, parameters
    ../q.sh $PWD                                     # map.log, eda.log, simulation/modelsim/ds.vo
    python3 ../wrapgen.py simulation/modelsim/ds.vo <rtl.sv> <module>   # gl.vo, wrap.sv
    verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH --x-initial unique \
      --top-module <tb> -Mdir obj -o tb <packages> wrap.sv gl.vo ../glprim.v atoms_sel.v <tb.sv>

- `q.sh`: runs quartus_map and quartus_eda in the pinned Docker image on project `ds`.
- `wrapgen.py`: renames the netlist module to `<module>_gl` and writes
  `wrap.sv`, a `<module>` with the RTL port list that maps the netlist's
  flattened ports (`name_i_j`) back to the packed arrays.
- `glprim.v`: models of dffeas, the I/O buffers and cyclonev_ram_block.
- `atoms_sel.v` is not here: copy `cyclonev_lcell_comb` out of
  `$QUARTUS/eda/sim_lib/cyclonev_atoms.v`.
- `tb_ds_small.sv`: a short disk_stream case (top `tb_disk_stream`).
- `qprobe/`: a one-module project for checking how Quartus sizes an
  expression (read map.rpt "No output dependent on input pin").

Status: the disk_stream netlist never served the hard disk probe under
`tb_ds_small.sv` although the same logic works on hardware, so this flow
is not trusted yet (wrapper or atom models; an older RAM model with a
fixed 8K depth was in use then).
