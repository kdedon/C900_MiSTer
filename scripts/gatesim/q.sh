#!/bin/bash
# map + functional netlist of project ds in directory $1 (Quartus 17.0.2 image)
docker run --rm --user "$(id -u):$(id -g)" --volume "$1:/work" --workdir /work theypsilon/quartus-lite-c5@sha256:f638634df509786bc7507dbcb45673acd6adf32e5278c7b4e64ce67ae8ac2c70 bash -c "/opt/intelFPGA_lite/quartus/bin/quartus_map ds > map.log 2>&1 && /opt/intelFPGA_lite/quartus/bin/quartus_eda ds --simulation --functional --tool=modelsim_oem --format=verilog > eda.log 2>&1"
