# Source lists shared by the top Makefile and the benches.  Paths are
# relative to $(ROOT) (the repo top).  Keep in step with files.qip.

ROOT ?= .
LR_DIR ?= $(ROOT)/rtl/lr_display

K8000 := $(ROOT)/rtl/vendor/k8000

# T48 and T65 netlists made from the vendored VHDL
include $(ROOT)/mk/ghdl.mk
include $(ROOT)/mk/sdram_sim.mk
include $(ROOT)/mk/vdc_sim.mk

# HR display card; hr_u262 includes hr_syn_prog.svh.
HR_DIR  := $(ROOT)/rtl/hr_display
HR_SRCS := $(addprefix $(HR_DIR)/,hr_u262.sv hr_syn.sv hr_zsel.sv hr_zarb.sv hr_zmemc.sv \
  hr_zcas.sv hr_fn3_xp.sv hr_fn4_dram.sv hr_fn5.sv hr_fn6.sv hr_u755.sv hr_pal20x8.sv \
  hr_fn7.sv hr_u312.sv hr_card.sv)
HR_INC  := +incdir+$(HR_DIR)

# Third-party RTL: the k8000 chips, the T65, T48 and 6845 netlists.
VENDOR_SRCS := \
  $(K8000)/k800x_cpu/gen/z8000_ctrl_pkg.sv \
  $(K8000)/k800x_cpu/gen/z8000_zbus_pkg.sv \
  $(K8000)/k800x_cpu/gen/z8000_mc_pkg.sv \
  $(K8000)/k800x_cpu/gen/z8000_decode_rom_gen.sv \
  $(K8000)/k800x_cpu/gen/z8000_mc_rom_gen.sv \
  $(wildcard $(K8000)/k800x_cpu/z8000_*.sv) \
  $(K8000)/k8010_mmu/z8010_mmu.sv \
  $(K8000)/k8030_scc/z8030_scc_channel.sv \
  $(K8000)/k8030_scc/z8030_scc.sv \
  $(K8000)/k8036_cio/z8036_cio.sv \
  $(K8000)/k8070_fpu/gen/z8070_enc_pkg.sv \
  $(K8000)/k8070_fpu/gen/z8070_dp_rom_pkg.sv \
  $(K8000)/k8070_fpu/gen/z8070_dp_rom.sv \
  $(K8000)/k8070_fpu/z8070_dec.sv \
  $(K8000)/k8070_fpu/z8070_ip.sv \
  $(K8000)/k8070_fpu/z8070_dp.sv \
  $(K8000)/k8070_fpu/z8070_fpu.sv \
  $(T65_NET) \
  $(T48_NET) \
  $(ROOT)/rtl/lr_display/mc6845/mc6845_synth.v

# Native chip models compiled before the rest, packages first.
CHIP_SRCS := \
  $(wildcard $(ROOT)/rtl/motherboard/pdmac/*.sv) \
  $(ROOT)/rtl/fdc/gcr_engine.sv \
  $(ROOT)/rtl/fdc/fd_pkg.sv \
  $(ROOT)/rtl/fdc/fd_layout.sv \
  $(ROOT)/rtl/fdc/fd_media.sv \
  $(ROOT)/rtl/fdc/fd_raw.sv \
  $(ROOT)/rtl/fdc/fd_scan.sv \
  $(ROOT)/rtl/fdc/fd_head.sv \
  $(ROOT)/rtl/fdc/fd_drive.sv \
  $(ROOT)/rtl/fdc/fdc8723.sv \
  $(ROOT)/rtl/hdc/wd2010_rdchan.sv \
  $(ROOT)/rtl/hdc/wd2010_wrchan.sv \
  $(ROOT)/rtl/hdc/wd2010.sv \
  $(ROOT)/rtl/hdc/wd10c20.sv \
  $(ROOT)/rtl/hdc/st506_pkg.sv \
  $(ROOT)/rtl/hdc/st506_media.sv \
  $(ROOT)/rtl/hdc/st506_walker.sv \
  $(ROOT)/rtl/hdc/st506_wrdec.sv \
  $(ROOT)/rtl/hdc/st506_drive.sv \
  $(ROOT)/rtl/lr_display/mc6845_lrdisp.sv \
  $(HR_SRCS) \
  $(ROOT)/rtl/motherboard/msm58321.sv \
  $(ROOT)/rtl/motherboard/c900_syslatch.sv \
  $(ROOT)/rtl/fdc/cpu6508.sv \
  $(ROOT)/rtl/hdc/t48_wdc.sv

# The rest of the native RTL, in any order.
CORE_SRCS := $(filter-out $(VENDOR_SRCS) $(CHIP_SRCS), \
  $(wildcard $(ROOT)/rtl/common/*.sv) \
  $(wildcard $(ROOT)/rtl/clock/*.sv) \
  $(wildcard $(ROOT)/rtl/motherboard/*.sv) \
  $(wildcard $(ROOT)/rtl/fdc/*.sv) \
  $(wildcard $(ROOT)/rtl/hdc/*.sv) \
  $(wildcard $(ROOT)/rtl/keyboard/*.sv) \
  $(wildcard $(LR_DIR)/*.sv) \
  $(wildcard $(ROOT)/rtl/lc_display/*.sv) \
  $(wildcard $(ROOT)/rtl/expansion/*.sv) \
  $(ROOT)/rtl/c900_core.sv)

