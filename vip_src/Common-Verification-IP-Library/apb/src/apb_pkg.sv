// -----------------------------------------------------------------------------
// apb_pkg - UVM VIP for AMBA APB (APB4: PPROT, PSTRB, PSLVERR; wait states)
//
//   Compile with +define+APB_ADDR_W=<n> / +define+APB_DATA_W=<n> to change the widths (default 32/32).
//   Roles:   VIP_MASTER  active requester  (apb_master_driver + sequencer)
//            VIP_SLAVE   active completer  (apb_slave_driver, memory model, wait states, error injection)
//            VIP_MONITOR passive           (monitor, coverage, checks only)
//   See VIP/docs/apb_vip.md.
// -----------------------------------------------------------------------------
`ifndef APB_PKG_SV
`define APB_PKG_SV

`include "uvm_macros.svh"
`include "vip_macros.svh"

`ifndef APB_ADDR_W
  `define APB_ADDR_W 32
`endif
`ifndef APB_DATA_W
  `define APB_DATA_W 32
`endif

package apb_pkg;
  import uvm_pkg::*;
  import vip_common_pkg::*;

  localparam int APB_ADDR_W = `APB_ADDR_W;
  localparam int APB_DATA_W = `APB_DATA_W;
  localparam int APB_STRB_W = APB_DATA_W / 8;

  typedef virtual vip_apb_if #(APB_ADDR_W, APB_DATA_W) apb_vif_t;

  // protocol violations a master can be told to generate (checker verification, negative tests)
  typedef enum { APB_INJ_NONE, APB_INJ_NO_ACCESS, APB_INJ_EARLY_PENABLE, APB_INJ_ADDR_CHANGE, APB_INJ_STRB_ON_READ } apb_inject_e;

  `include "apb_cfg.svh"
  `include "apb_item.svh"
  `include "apb_sequencer.svh"
  `include "apb_master_driver.svh"
  `include "apb_slave_driver.svh"
  `include "apb_monitor.svh"
  `include "apb_coverage.svh"
  `include "apb_scoreboard.svh"
  `include "apb_agent.svh"
  `include "apb_env.svh"
  `include "apb_reg_adapter.svh"
  `include "apb_seq_lib.svh"
endpackage : apb_pkg

`endif
