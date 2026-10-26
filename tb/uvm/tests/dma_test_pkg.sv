//-----------------------------------------------------------------------------
// dma_test_pkg.sv - test cases of the AXI DMA UVM test bench
//   one test case per file, grouped in sub directories:
//     base/     base classes (generator, execution helpers, shared directed helpers)
//     data/     data movement: 1D / 2D / wrap / fill / template / multi channel (random, coverage closure)
//     feature/  command link, autoboot, auto restart, triggers, AXI-Stream
//     ctrl/     errors, channel control, security, register map, LPI, GPO / interrupts
//     directed/ TRM examples and case lists with explicit result checks
//     bugfix/   directed regression tests of RTL bugs found in review
//   New test: add <group>/<name>.svh with one class and include it below
//   (after its parent class).
//-----------------------------------------------------------------------------
`include "dma_tb_defines.svh"
`include "uvm_macros.svh"

package dma_test_pkg;
  import uvm_pkg::*;
  import vip_common_pkg::*;
  import apb_pkg::*;
  import axi5_pkg::*;
  import axis_pkg::*;
  import dma_tb_pkg::*;

  // ---- base classes (inheritance order)
  `include "base/dma_base_test.svh"
  `include "base/dma_feat_base.svh"
  `include "base/dma_ctrl_base.svh"
  `include "base/dma_dir_base.svh"
  `include "base/dma_perf_base.svh"
  // ---- data
  `include "data/dma_smoke_test.svh"
  `include "data/dma_rand_test.svh"
  `include "data/dma_1d_test.svh"
  `include "data/dma_wrapfill_test.svh"
  `include "data/dma_2d_test.svh"
  `include "data/dma_tmplt_test.svh"
  `include "data/dma_multi_ch_test.svh"
  // ---- feature
  `include "feature/dma_link_test.svh"
  `include "feature/dma_link_err_test.svh"
  `include "feature/dma_autoboot_test.svh"
  `include "feature/dma_restart_test.svh"
  `include "feature/dma_trig_cmd_test.svh"
  `include "feature/dma_trig_fc_test.svh"
  `include "feature/dma_stream_test.svh"
  `include "feature/dma_stream_err_test.svh"
  // ---- ctrl
  `include "ctrl/dma_err_test.svh"
  `include "ctrl/dma_ctrl_test.svh"
  `include "ctrl/dma_sec_test.svh"
  `include "ctrl/dma_reg_test.svh"
  `include "ctrl/dma_lpi_test.svh"
  `include "ctrl/dma_gpo_irq_test.svh"
  `include "ctrl/dma_trig_mtx_test.svh"
  `include "ctrl/dma_unit_status_test.svh"
  // ---- directed
  `include "directed/dma_dir_1d_test.svh"
  `include "directed/dma_dir_wrap1d_test.svh"
  `include "directed/dma_dir_2d_test.svh"
  `include "directed/dma_dir_tmplt_test.svh"
  `include "directed/dma_dir_burst_test.svh"
  `include "directed/dma_dir_regend_test.svh"
  `include "directed/dma_dir_link_test.svh"
  `include "directed/dma_dir_done_test.svh"
  `include "directed/dma_dir_trig_sw_test.svh"
  `include "directed/dma_dir_trig_test.svh"
  `include "directed/dma_dir_stream_test.svh"
  // ---- bugfix
  `include "bugfix/dma_bug01_link_1kb_test.svh"
  `include "bugfix/dma_bug02_w1c_test.svh"
  `include "bugfix/dma_bug03_pause_trigout_test.svh"
  `include "bugfix/dma_bug04_clear_test.svh"
  `include "bugfix/dma_bug08_link_abort_test.svh"
  // ---- performance (tests/perf)
  `include "perf/dma_perf_size_test.svh"
  `include "perf/dma_perf_tsize_test.svh"
  `include "perf/dma_perf_align_test.svh"
  `include "perf/dma_perf_burst_test.svh"
  `include "perf/dma_perf_latency_test.svh"
  `include "perf/dma_perf_multich_test.svh"
  `include "perf/dma_perf_arb_test.svh"
  `include "perf/dma_perf_cmd_test.svh"
endpackage : dma_test_pkg
