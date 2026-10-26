//-----------------------------------------------------------------------------
// dma_tb_pkg.sv - UVM test bench structure of the AXI DMA controller
// (configuration, command model, reference model, scoreboard, agents, env).
// Sequences: seq/ ; test cases: tests/dma_test_pkg.sv.
//-----------------------------------------------------------------------------
`include "dma_tb_defines.svh"
`include "uvm_macros.svh"

package dma_tb_pkg;
  import uvm_pkg::*;
  import vip_common_pkg::*;
  import apb_pkg::*;
  import axi5_pkg::*;
  import axis_pkg::*;

  `include "dma_tb_cfg.svh"
  `include "dma_cmd.svh"
  `include "dma_ref_model.svh"
  `include "dma_scoreboard.svh"
  `include "dma_coverage.svh"
  `include "dma_perf_mon.svh"
  `include "dma_seqs.svh"          // seq/
  `include "dma_agents.svh"
  `include "dma_env.svh"
endpackage : dma_tb_pkg
