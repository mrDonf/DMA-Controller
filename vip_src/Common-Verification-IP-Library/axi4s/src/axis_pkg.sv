// -----------------------------------------------------------------------------
// axis_pkg - UVM VIP for AMBA AXI4-Stream (TDATA, TSTRB, TKEEP, TLAST, TID, TDEST, TUSER)
//
//   Compile with +define+AXIS_DATA_W / AXIS_ID_W / AXIS_DEST_W / AXIS_USER_W (defaults 32 / 4 / 4 / 4).
//   Roles: VIP_MASTER (transmitter: drives packets), VIP_SLAVE (receiver: drives TREADY with configurable patterns),
//          VIP_MONITOR (passive). One item = one packet (beats up to and including TLAST).
//   See VIP/docs/axi4s_vip.md.
// -----------------------------------------------------------------------------
`ifndef AXIS_PKG_SV
`define AXIS_PKG_SV

`include "uvm_macros.svh"
`include "vip_macros.svh"

`ifndef AXIS_DATA_W
  `define AXIS_DATA_W 32
`endif
`ifndef AXIS_ID_W
  `define AXIS_ID_W 4
`endif
`ifndef AXIS_DEST_W
  `define AXIS_DEST_W 4
`endif
`ifndef AXIS_USER_W
  `define AXIS_USER_W 4
`endif

package axis_pkg;
  import uvm_pkg::*;
  import vip_common_pkg::*;

  localparam int AXIS_DATA_W = `AXIS_DATA_W;
  localparam int AXIS_ID_W   = `AXIS_ID_W;
  localparam int AXIS_DEST_W = `AXIS_DEST_W;
  localparam int AXIS_USER_W = `AXIS_USER_W;
  localparam int AXIS_KEEP_W = AXIS_DATA_W / 8;

  typedef virtual vip_axis_if #(AXIS_DATA_W, AXIS_ID_W, AXIS_DEST_W, AXIS_USER_W) axis_vif_t;

  // byte qualification of a packet
  typedef enum { AXIS_KEEP_FULL, AXIS_KEEP_TAIL, AXIS_KEEP_SPARSE } axis_keep_e;
  // TREADY behaviour of the receiver
  typedef enum { AXIS_RDY_ALWAYS, AXIS_RDY_RANDOM, AXIS_RDY_TOGGLE, AXIS_RDY_BURSTY, AXIS_RDY_AFTER_VALID, AXIS_RDY_NEVER } axis_ready_e;
  typedef enum { AXIS_INJ_NONE, AXIS_INJ_DROP_VALID, AXIS_INJ_CHANGE_DATA, AXIS_INJ_STRB_NO_KEEP, AXIS_INJ_ID_CHANGE } axis_inject_e;

  `include "axis_cfg.svh"
  `include "axis_item.svh"
  `include "axis_sequencer.svh"
  `include "axis_master_driver.svh"
  `include "axis_slave_driver.svh"
  `include "axis_monitor.svh"
  `include "axis_coverage.svh"
  `include "axis_scoreboard.svh"
  `include "axis_agent.svh"
  `include "axis_env.svh"
  `include "axis_seq_lib.svh"
endpackage : axis_pkg

`endif
