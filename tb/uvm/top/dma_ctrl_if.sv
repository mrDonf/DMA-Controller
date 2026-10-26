//-----------------------------------------------------------------------------
// dma_ctrl_if.sv - side-band signals of the DMA that are not covered by the
// AMBA VIP interfaces: triggers, LPI, control / status, interrupts, GPO,
// autoboot, APB PDEBUG/PWAKEUP and the AXI user / ACE-Lite extensions.
//-----------------------------------------------------------------------------
interface dma_ctrl_if #(
  parameter int NCH = 4,
  parameter int NTI = 4,
  parameter int NTO = 4,
  parameter int GW  = 8,
  parameter int CHW = 4,
  parameter int AW  = 32
) (
  input logic clk,
  input logic resetn
);
  // clock enables (driven by the top)
  logic              aclken_m0, aclken_m1, pclken;
  // LPI
  logic              clk_qreqn, clk_qacceptn, clk_qdeny, clk_qactive;
  logic              preq, paccept, pdeny;
  logic [3:0]        pstate;
  logic [9:0]        pactive;
  // APB side band
  logic              pdebug, pwakeup;
  // triggers
  logic [NTI-1:0]    trig_in_req, trig_in_ack;
  logic [NTI-1:0][1:0] trig_in_req_type, trig_in_ack_type;
  logic [NTO-1:0]    trig_out_req, trig_out_ack;
  // interrupts
  logic [NCH-1:0]    irq_channel;
  logic              irq_comb_nonsec, irq_comb_sec, irq_sec_viol_err;
  // stream side band
  logic [NCH-1:0]    str_in_flush;
  // GPO
  logic [NCH-1:0][GW-1:0] gpo_ch;
  // control / status
  logic              allch_stop_req_nonsec, allch_stop_ack_nonsec;
  logic              allch_pause_req_nonsec, allch_pause_ack_nonsec;
  logic              allch_stop_req_sec, allch_stop_ack_sec;
  logic              allch_pause_req_sec, allch_pause_ack_sec;
  logic              halt_req, restart_req, halted;
  logic [NCH-1:0]    ch_enabled, ch_err, ch_stopped, ch_paused, ch_priv, ch_nonsec;
  // autoboot
  logic              boot_en;
  logic [AW-1:2]     boot_addr;
  logic [7:0]        boot_memattr;
  logic [1:0]        boot_shareattr;
  // AXI extensions (per port [0]=M0 [1]=M1)
  logic [1:0][1:0]   awdomain, ardomain;
  logic [1:0][3:0]   awinner, arinner;
  logic [1:0][CHW-1:0] awchid, archid;
  logic [1:0]        awchidvalid, archidvalid, arcmdlink;

  // asynchronous peripheral clock used by the trigger agents in CDC tests
  logic              per_clk;

  clocking cb @(posedge clk);
    default input #1step output #1;
  endclocking

endinterface : dma_ctrl_if
