// -----------------------------------------------------------------------------
// vip_axis_if - AMBA AXI4-Stream interface of the AXI4-Stream VIP (IHI0051)
//
//   clocking blocks: mst_cb (transmitter drives), slv_cb (receiver drives TREADY), mon_cb (everything sampled)
//   Protocol checks (violation() ids):
//     AXIS_A_RESET     TVALID low during reset
//     AXIS_A_HS_STABLE TVALID stays high and the payload stable until TREADY
//     AXIS_A_NO_X      no X/Z on TVALID/TREADY, nor on the payload of a valid beat
//     AXIS_A_STRB      TSTRB high on a byte whose TKEEP is low (reserved combination)
//     AXIS_A_KEEP_MID  a null byte (TKEEP=0) before the last beat of a packet (checked when cfg `check_keep_mid` is set)
//     AXIS_A_ID_DEST   TID / TDEST change inside a packet
//     AXIS_A_MAXLEN    packet longer than the configured maximum number of beats (0 = unchecked)
// -----------------------------------------------------------------------------
`ifndef VIP_AXIS_IF_SV
`define VIP_AXIS_IF_SV

interface vip_axis_if #(
  parameter int DATA_W = 32,
  parameter int ID_W   = 4,
  parameter int DEST_W = 4,
  parameter int USER_W = 4
)(
  input logic aclk,
  input logic aresetn
);
  localparam int KEEP_W = DATA_W / 8;

  logic [DATA_W-1:0] tdata;
  logic [KEEP_W-1:0] tstrb;
  logic [KEEP_W-1:0] tkeep;
  logic              tlast;
  logic [ID_W-1:0]   tid;
  logic [DEST_W-1:0] tdest;
  logic [USER_W-1:0] tuser;
  logic              tvalid;
  logic              tready;

  clocking mst_cb @(posedge aclk);
    default input #1step output #1;
    output tdata, tstrb, tkeep, tlast, tid, tdest, tuser, tvalid;
    input  tready;
  endclocking

  clocking slv_cb @(posedge aclk);
    default input #1step output #1;
    output tready;
    input  tdata, tstrb, tkeep, tlast, tid, tdest, tuser, tvalid;
  endclocking

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input tdata, tstrb, tkeep, tlast, tid, tdest, tuser, tvalid, tready;
  endclocking

  bit          checks_en         = 1'b1;
  bit          expect_violations = 1'b0;
  bit          check_keep_mid    = 1'b0;
  int unsigned max_packet_beats  = 0;
  int unsigned viol_cnt          = 0;
  string       viol_last         = "";
  int unsigned viol_by_id [string];

  function automatic void violation(string id, string msg);
    viol_cnt++;
    viol_last = id;
    viol_by_id[id] = viol_by_id.exists(id) ? viol_by_id[id] + 1 : 1;
    if (!expect_violations) $error("[%s] %s", id, msg);
  endfunction

  wire ok = checks_en && aresetn;

  property p_stable;
    @(posedge aclk) disable iff (!ok) (tvalid && !tready) |=> (tvalid && $stable({tdata, tstrb, tkeep, tlast, tid, tdest, tuser}));
  endproperty
  A_STABLE: assert property (p_stable) else violation("AXIS_A_HS_STABLE", $sformatf("TVALID dropped or payload changed before TREADY (valid=%b data=%h last=%b keep=%b id=%h dest=%h user=%h; previous cycle: data=%h last=%b keep=%b id=%h)", tvalid, tdata, tlast, tkeep, tid, tdest, tuser, $past(tdata), $past(tlast), $past(tkeep), $past(tid)));

  property p_reset;
    @(posedge aclk) disable iff (!checks_en) (!aresetn) |-> (tvalid !== 1'b1);
  endproperty
  A_RESET: assert property (p_reset) else violation("AXIS_A_RESET", "TVALID high during reset");

  property p_no_x_hs;
    @(posedge aclk) disable iff (!ok) !$isunknown({tvalid, tready});
  endproperty
  A_NO_X_HS: assert property (p_no_x_hs) else violation("AXIS_A_NO_X", "unknown TVALID/TREADY");

  property p_no_x_pl;
    @(posedge aclk) disable iff (!ok) tvalid |-> !$isunknown({tdata, tstrb, tkeep, tlast, tid, tdest, tuser});
  endproperty
  A_NO_X_PL: assert property (p_no_x_pl) else violation("AXIS_A_NO_X", "unknown payload with TVALID high");

  property p_strb_keep;
    @(posedge aclk) disable iff (!ok) tvalid |-> ((tstrb & ~tkeep) == '0);
  endproperty
  A_STRB: assert property (p_strb_keep) else violation("AXIS_A_STRB", "TSTRB set for a byte whose TKEEP is low");

  // packet-level checks (accepted beats)
  logic [ID_W-1:0]   pk_id;
  logic [DEST_W-1:0] pk_dest;
  bit                in_packet;
  int unsigned       pk_beats;

  always @(posedge aclk) begin
    if (!aresetn) begin
      in_packet <= 1'b0; pk_beats <= 0;
    end else if (checks_en && tvalid === 1'b1 && tready === 1'b1) begin
      if (in_packet && (tid !== pk_id || tdest !== pk_dest))
        violation("AXIS_A_ID_DEST", $sformatf("TID/TDEST changed inside a packet (id %0h->%0h dest %0h->%0h)", pk_id, tid, pk_dest, tdest));
      if (check_keep_mid && tlast !== 1'b1 && tkeep !== {KEEP_W{1'b1}})
        violation("AXIS_A_KEEP_MID", $sformatf("null byte before the last beat (TKEEP=%b)", tkeep));
      pk_beats <= (tlast === 1'b1) ? 0 : pk_beats + 1;
      if (max_packet_beats != 0 && pk_beats + 1 > max_packet_beats)
        violation("AXIS_A_MAXLEN", $sformatf("packet longer than %0d beats", max_packet_beats));
      if (!in_packet) begin pk_id <= tid; pk_dest <= tdest; end        // first beat of a packet defines TID / TDEST
      in_packet <= (tlast !== 1'b1);
    end
  end

  C_BEAT:  cover property (@(posedge aclk) tvalid && tready);
  C_LAST:  cover property (@(posedge aclk) tvalid && tready && tlast);
  C_STALL: cover property (@(posedge aclk) tvalid && !tready);
  C_IDLE:  cover property (@(posedge aclk) !tvalid && tready);

endinterface : vip_axis_if

`endif
