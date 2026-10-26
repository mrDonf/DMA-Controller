// -----------------------------------------------------------------------------
// vip_apb_if - AMBA APB (APB4, IHI0024) interface of the APB VIP
//
//   * one `psel` (one completer per interface instance; an address decoder lives outside)
//   * clocking blocks: mst_cb (requester drives), slv_cb (completer drives), mon_cb (all sampled)
//   * protocol assertions (checks_en), each one has a stable name used by the negative tests:
//       APB_A_SETUP     PENABLE is low in the first cycle of a transfer
//       APB_A_ACCESS    SETUP is always followed by ACCESS in the next cycle
//       APB_A_PEN_PSEL  PENABLE only together with PSEL
//       APB_A_STABLE    address / control / write data stable from SETUP to the end of ACCESS (also across wait states)
//       APB_A_PEN_END   PENABLE drops after the cycle in which PREADY was high
//       APB_A_RD_STRB   PSTRB low for read transfers
//       APB_A_NO_X      no X/Z on control signals and on the response (when relevant)
//   * `viol_cnt`/`viol_id` count violations; `expect_violations` demotes the $error (negative tests)
// -----------------------------------------------------------------------------
`ifndef VIP_APB_IF_SV
`define VIP_APB_IF_SV

interface vip_apb_if #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 32
)(
  input logic pclk,
  input logic presetn
);
  localparam int STRB_W = DATA_W / 8;

  logic [ADDR_W-1:0]  paddr;
  logic [2:0]         pprot;
  logic               psel;
  logic               penable;
  logic               pwrite;
  logic [DATA_W-1:0]  pwdata;
  logic [STRB_W-1:0]  pstrb;
  logic               pready;
  logic [DATA_W-1:0]  prdata;
  logic               pslverr;

  // ---------------------------------------------------------------- clocking blocks
  clocking mst_cb @(posedge pclk);
    default input #1step output #1;
    output paddr, pprot, psel, penable, pwrite, pwdata, pstrb;
    input  pready, prdata, pslverr;
  endclocking

  clocking slv_cb @(posedge pclk);
    default input #1step output #1;
    input  paddr, pprot, psel, penable, pwrite, pwdata, pstrb;
    output pready, prdata, pslverr;
  endclocking

  clocking mon_cb @(posedge pclk);
    default input #1step;
    input paddr, pprot, psel, penable, pwrite, pwdata, pstrb, pready, prdata, pslverr;
  endclocking

  // ---------------------------------------------------------------- checker control / bookkeeping
  bit          checks_en         = 1'b1;
  bit          expect_violations = 1'b0;
  int unsigned viol_cnt          = 0;
  string       viol_last         = "";
  int unsigned viol_by_id [string];

  function automatic void violation(string id, string msg);
    viol_cnt++;
    viol_last = id;
    viol_by_id[id] = viol_by_id.exists(id) ? viol_by_id[id] + 1 : 1;
    if (!expect_violations) $error("[%s] %s (psel=%b penable=%b pready=%b)", id, msg, psel, penable, pready);
  endfunction

  // ---------------------------------------------------------------- assertions
  wire ok = checks_en && presetn;

  property p_setup;
    @(posedge pclk) disable iff (!ok) $rose(psel) |-> !penable;
  endproperty
  A_SETUP: assert property (p_setup) else violation("APB_A_SETUP", "PENABLE high in the first cycle of a transfer");

  property p_access;
    @(posedge pclk) disable iff (!ok) (psel && !penable) |=> (psel && penable);
  endproperty
  A_ACCESS: assert property (p_access) else violation("APB_A_ACCESS", "SETUP phase not followed by an ACCESS phase");

  property p_pen_psel;
    @(posedge pclk) disable iff (!ok) penable |-> psel;
  endproperty
  A_PEN_PSEL: assert property (p_pen_psel) else violation("APB_A_PEN_PSEL", "PENABLE without PSEL");

  property p_stable;
    @(posedge pclk) disable iff (!ok)
      (psel && penable && !pready) |=> ($stable(paddr) && $stable(pwrite) && $stable(pprot) && (!pwrite || ($stable(pwdata) && $stable(pstrb))));
  endproperty
  A_STABLE: assert property (p_stable) else violation("APB_A_STABLE", "address/control/data changed during wait states");

  property p_stable_sa;       // SETUP -> first ACCESS cycle: nothing may change either
    @(posedge pclk) disable iff (!ok)
      (psel && !penable) |=> ($stable(paddr) && $stable(pwrite) && $stable(pprot) && (!pwrite || ($stable(pwdata) && $stable(pstrb))));
  endproperty
  A_STABLE_SA: assert property (p_stable_sa) else violation("APB_A_STABLE", "address/control/data changed between SETUP and ACCESS");

  property p_pen_end;
    @(posedge pclk) disable iff (!ok) (penable && pready) |=> !penable;
  endproperty
  A_PEN_END: assert property (p_pen_end) else violation("APB_A_PEN_END", "PENABLE still high after the completing cycle");

  property p_rd_strb;
    @(posedge pclk) disable iff (!ok) (psel && !pwrite) |-> (pstrb == '0);
  endproperty
  A_RD_STRB: assert property (p_rd_strb) else violation("APB_A_RD_STRB", "PSTRB active in a read transfer");

  property p_no_x_ctrl;
    @(posedge pclk) disable iff (!ok) !$isunknown({psel, penable});
  endproperty
  A_NO_X_CTRL: assert property (p_no_x_ctrl) else violation("APB_A_NO_X", "PSEL/PENABLE unknown");

  property p_no_x_xfer;
    @(posedge pclk) disable iff (!ok) psel |-> !$isunknown({paddr, pwrite});
  endproperty
  A_NO_X_XFER: assert property (p_no_x_xfer) else violation("APB_A_NO_X", "PADDR/PWRITE unknown during a transfer");

  property p_no_x_resp;
    @(posedge pclk) disable iff (!ok) (psel && penable) |-> !$isunknown(pready);
  endproperty
  A_NO_X_READY: assert property (p_no_x_resp) else violation("APB_A_NO_X", "PREADY unknown in the access phase");

  property p_no_x_rdata;
    @(posedge pclk) disable iff (!ok) (psel && penable && pready && !pwrite) |-> !$isunknown({prdata, pslverr});
  endproperty
  A_NO_X_RDATA: assert property (p_no_x_rdata) else violation("APB_A_NO_X", "PRDATA/PSLVERR unknown at the end of a read");

  property p_no_x_wdata;
    @(posedge pclk) disable iff (!ok) (psel && pwrite) |-> !$isunknown({pwdata, pstrb});
  endproperty
  A_NO_X_WDATA: assert property (p_no_x_wdata) else violation("APB_A_NO_X", "PWDATA/PSTRB unknown in a write");

  // coverage of the assertions themselves (every property was exercised at least once)
  C_XFER: cover property (@(posedge pclk) psel && penable && pready);
  C_WAIT: cover property (@(posedge pclk) psel && penable && !pready);
  C_ERR:  cover property (@(posedge pclk) psel && penable && pready && pslverr);

endinterface : vip_apb_if

`endif
