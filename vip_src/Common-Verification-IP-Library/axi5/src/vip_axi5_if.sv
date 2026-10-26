// -----------------------------------------------------------------------------
// vip_axi5_if - AMBA AXI5 (IHI0022 Issue H+) interface of the AXI5 VIP: the five AXI4 channels plus the AXI5 signals
//   AWATOP, WPOISON / RPOISON, WDATACHK / RDATACHK, AxIDUNQ / BIDUNQ / RIDUNQ, xTRACE, AxLOOP / BLOOP / RLOOP, AWAKEUP
//
//   clocking blocks: mst_cb (manager), slv_cb (subordinate), mon_cb (everything sampled)
//
//   Protocol checker (every check reports through violation(); `expect_violations` demotes the $error for negative tests):
//     AXI_A_RESET      VALID signals low during reset
//     AXI_A_HS_STABLE  VALID stays high and the payload stable until READY (5 channels, AXI5 signals included)
//     AXI_A_NO_X       no X/Z on VALID/READY and on the payload of a valid channel
//     AXI_A_BURST      reserved AxBURST, AxSIZE wider than the bus, illegal WRAP length / alignment, FIXED > 16 beats
//     AXI_A_4KB        INCR burst crossing a 4KB boundary
//     AXI_A_LOCK       exclusive access: more than 16 beats / total size not a power of two up to 128 bytes
//     AXI_A_WLAST      WLAST high exactly on the last beat of the write burst (AWLEN)
//     AXI_A_RLAST      RLAST high exactly on the last beat of the read burst (ARLEN, or the atomic read data length)
//     AXI_A_WSTRB      WSTRB enables only byte lanes of the beat; for atomics exactly the lanes of the operand window
//     AXI_A_B_ORDER    BVALID only after the write address and the last write data beat were accepted
//     AXI_A_R_ID       R/B ID matches an outstanding request; read data only for an accepted AR or an atomic with read data
//     AXI_A_EXOKAY     EXOKAY only as the response to an exclusive access
//     AXI_A_ATOP       reserved AWATOP, AWLOCK with an atomic, data size (1/2/4/8 bytes, Compare 2..32), alignment,
//                      AWBURST (INCR; Compare WRAP when AWADDR is the upper half), AWSIZE full width when AWLEN > 0
//     AXI_A_ATOP_ID    atomic with the ID of an outstanding write (any atomic) or read (atomics with read data)
//     AXI_A_IDUNQ      AxIDUNQ with another same-ID transaction outstanding (or the reverse); BIDUNQ / RIDUNQ == request
//     AXI_A_TRACE      BTRACE == AWTRACE, RTRACE == ARTRACE (AWTRACE for atomic read data)
//     AXI_A_LOOP       BLOOP == AWLOOP, RLOOP == ARLOOP (AWLOOP for atomic read data)
//     AXI_A_DATACHK    WDATACHK / RDATACHK odd parity per data byte (datachk_en)
//     AXI_A_WAKEUP     AWAKEUP high whenever AWVALID, ARVALID or WVALID is high (wakeup_check_en)
// -----------------------------------------------------------------------------
`ifndef VIP_AXI5_IF_SV
`define VIP_AXI5_IF_SV

interface vip_axi5_if #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 32,
  parameter int ID_W   = 4,
  parameter int USER_W = 1,
  parameter int LOOP_W = 4
)(
  input logic aclk,
  input logic aresetn
);
  localparam int STRB_W   = DATA_W / 8;
  localparam int SIZE_MAX = $clog2(STRB_W);
  localparam int POISON_W = (DATA_W + 63) / 64;

  // write address
  logic [ID_W-1:0]    awid;
  logic [ADDR_W-1:0]  awaddr;
  logic [7:0]         awlen;
  logic [2:0]         awsize;
  logic [1:0]         awburst;
  logic               awlock;
  logic [3:0]         awcache;
  logic [2:0]         awprot;
  logic [3:0]         awqos;
  logic [3:0]         awregion;
  logic [USER_W-1:0]  awuser;
  logic [5:0]         awatop;
  logic               awidunq;
  logic               awtrace;
  logic [LOOP_W-1:0]  awloop;
  logic               awvalid, awready;
  // write data
  logic [DATA_W-1:0]  wdata;
  logic [STRB_W-1:0]  wstrb;
  logic               wlast;
  logic [USER_W-1:0]  wuser;
  logic [POISON_W-1:0] wpoison;
  logic [STRB_W-1:0]  wdatachk;
  logic               wtrace;
  logic               wvalid, wready;
  // write response
  logic [ID_W-1:0]    bid;
  logic [1:0]         bresp;
  logic [USER_W-1:0]  buser;
  logic               bidunq;
  logic               btrace;
  logic [LOOP_W-1:0]  bloop;
  logic               bvalid, bready;
  // read address
  logic [ID_W-1:0]    arid;
  logic [ADDR_W-1:0]  araddr;
  logic [7:0]         arlen;
  logic [2:0]         arsize;
  logic [1:0]         arburst;
  logic               arlock;
  logic [3:0]         arcache;
  logic [2:0]         arprot;
  logic [3:0]         arqos;
  logic [3:0]         arregion;
  logic [USER_W-1:0]  aruser;
  logic               aridunq;
  logic               artrace;
  logic [LOOP_W-1:0]  arloop;
  logic               arvalid, arready;
  // read data
  logic [ID_W-1:0]    rid;
  logic [DATA_W-1:0]  rdata;
  logic [1:0]         rresp;
  logic               rlast;
  logic [USER_W-1:0]  ruser;
  logic [POISON_W-1:0] rpoison;
  logic [STRB_W-1:0]  rdatachk;
  logic               ridunq;
  logic               rtrace;
  logic [LOOP_W-1:0]  rloop;
  logic               rvalid, rready;
  // wakeup
  logic               awakeup;

  clocking mst_cb @(posedge aclk);
    default input #1step output #1;
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion, awuser, awatop, awidunq, awtrace, awloop, awvalid;
    output wdata, wstrb, wlast, wuser, wpoison, wdatachk, wtrace, wvalid;
    output bready;
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion, aruser, aridunq, artrace, arloop, arvalid;
    output rready, awakeup;
    input  awready, wready, bid, bresp, buser, bidunq, btrace, bloop, bvalid, arready;
    input  rid, rdata, rresp, rlast, ruser, rpoison, rdatachk, ridunq, rtrace, rloop, rvalid;
  endclocking

  clocking slv_cb @(posedge aclk);
    default input #1step output #1;
    output awready, wready, arready;
    output bid, bresp, buser, bidunq, btrace, bloop, bvalid;
    output rid, rdata, rresp, rlast, ruser, rpoison, rdatachk, ridunq, rtrace, rloop, rvalid;
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion, awuser, awatop, awidunq, awtrace, awloop, awvalid;
    input  wdata, wstrb, wlast, wuser, wpoison, wdatachk, wtrace, wvalid, bready;
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion, aruser, aridunq, artrace, arloop, arvalid, rready;
    input  awakeup;
  endclocking

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion, awuser, awatop, awidunq, awtrace, awloop, awvalid, awready;
    input wdata, wstrb, wlast, wuser, wpoison, wdatachk, wtrace, wvalid, wready;
    input bid, bresp, buser, bidunq, btrace, bloop, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion, aruser, aridunq, artrace, arloop, arvalid, arready;
    input rid, rdata, rresp, rlast, ruser, rpoison, rdatachk, ridunq, rtrace, rloop, rvalid, rready;
    input awakeup;
  endclocking

  // ---------------------------------------------------------------- bookkeeping
  bit          checks_en         = 1'b1;
  bit          expect_violations = 1'b0;
  bit          datachk_en        = 1'b0;     // the interface carries WDATACHK / RDATACHK
  bit          wakeup_check_en   = 1'b0;     // the interface carries AWAKEUP
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

  // ---------------------------------------------------------------- handshake / reset / X (SVA)
  `define AXI5_STABLE(NAME, VALID, READY, PAYLOAD) \
    property p_``NAME``_stable; @(posedge aclk) disable iff (!ok) (VALID && !READY) |=> (VALID && $stable(PAYLOAD)); endproperty \
    A_``NAME``_STABLE: assert property (p_``NAME``_stable) else violation("AXI_A_HS_STABLE", `"NAME channel: VALID dropped or payload changed before READY`");

  `AXI5_STABLE(AW, awvalid, awready, {awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awregion, awuser, awatop, awidunq, awtrace, awloop})
  `AXI5_STABLE(W,  wvalid,  wready,  {wdata, wstrb, wlast, wuser, wpoison, wdatachk, wtrace})
  `AXI5_STABLE(B,  bvalid,  bready,  {bid, bresp, buser, bidunq, btrace, bloop})
  `AXI5_STABLE(AR, arvalid, arready, {arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arregion, aruser, aridunq, artrace, arloop})
  `AXI5_STABLE(R,  rvalid,  rready,  {rid, rdata, rresp, rlast, ruser, rpoison, rdatachk, ridunq, rtrace, rloop})

  property p_reset_valids;
    @(posedge aclk) (!aresetn) |-> (awvalid !== 1'b1 && wvalid !== 1'b1 && arvalid !== 1'b1 && bvalid !== 1'b1 && rvalid !== 1'b1);
  endproperty
  A_RESET: assert property (disable iff (!checks_en) p_reset_valids) else violation("AXI_A_RESET", "VALID high during reset");

  property p_no_x_hs;
    @(posedge aclk) disable iff (!ok) !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready});
  endproperty
  A_NO_X_HS: assert property (p_no_x_hs) else violation("AXI_A_NO_X", "unknown VALID/READY");

  property p_no_x_aw; @(posedge aclk) disable iff (!ok) awvalid |-> !$isunknown({awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awatop, awidunq, awtrace, awloop}); endproperty
  A_NO_X_AW: assert property (p_no_x_aw) else violation("AXI_A_NO_X", "unknown AW payload");
  property p_no_x_w;  @(posedge aclk) disable iff (!ok) wvalid |-> !$isunknown({wdata, wstrb, wlast, wpoison, wtrace}); endproperty
  A_NO_X_W: assert property (p_no_x_w) else violation("AXI_A_NO_X", "unknown W payload");
  property p_no_x_b;  @(posedge aclk) disable iff (!ok) bvalid |-> !$isunknown({bid, bresp, bidunq, btrace, bloop}); endproperty
  A_NO_X_B: assert property (p_no_x_b) else violation("AXI_A_NO_X", "unknown B payload");
  property p_no_x_ar; @(posedge aclk) disable iff (!ok) arvalid |-> !$isunknown({arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, aridunq, artrace, arloop}); endproperty
  A_NO_X_AR: assert property (p_no_x_ar) else violation("AXI_A_NO_X", "unknown AR payload");
  property p_no_x_r;  @(posedge aclk) disable iff (!ok) rvalid |-> !$isunknown({rid, rdata, rresp, rlast, rpoison, ridunq, rtrace, rloop}); endproperty
  A_NO_X_R: assert property (p_no_x_r) else violation("AXI_A_NO_X", "unknown R payload");

  // data check: odd parity per byte
  function automatic bit par_ok(logic [DATA_W-1:0] d, logic [STRB_W-1:0] p);
    for (int i = 0; i < STRB_W; i++) if (^{d[8 * i +: 8], p[i]} !== 1'b1) return 0;
    return 1;
  endfunction
  A_WDATACHK: assert property (@(posedge aclk) disable iff (!ok || !datachk_en) wvalid |-> par_ok(wdata, wdatachk))
    else violation("AXI_A_DATACHK", "WDATACHK is not the odd parity of WDATA");
  A_RDATACHK: assert property (@(posedge aclk) disable iff (!ok || !datachk_en) rvalid |-> par_ok(rdata, rdatachk))
    else violation("AXI_A_DATACHK", "RDATACHK is not the odd parity of RDATA");
  A_WAKEUP: assert property (@(posedge aclk) disable iff (!ok || !wakeup_check_en) (awvalid || arvalid || wvalid) |-> awakeup)
    else violation("AXI_A_WAKEUP", "AWVALID / ARVALID / WVALID high while AWAKEUP is low");

  // ---------------------------------------------------------------- procedural protocol checks
  typedef struct {
    logic [ID_W-1:0] id; logic [ADDR_W-1:0] addr; int unsigned beats; logic [2:0] size; logic [1:0] burst; logic lock;
    logic [5:0] atop; logic unq; logic trace; logic [LOOP_W-1:0] loop;
  } req_t;

  req_t        aw_q[$];                 // accepted write addresses whose B response is still to come
  req_t        w_aw_q[$];               // accepted write addresses that no completed W burst has been matched to yet
  typedef struct { logic [STRB_W-1:0] strb; logic last; } wbeat_t;
  wbeat_t      w_cur[$];                // beats of the W burst in progress
  wbeat_t      w_done_q[$][$];          // complete W bursts that arrived before their address
  int unsigned w_done_cnt;
  req_t        ar_q[$];                 // outstanding reads (and atomics with read data, beats = read data beats)
  int unsigned r_beat_cnt [logic [ID_W-1:0]];
  int unsigned aw_total, wl_total, b_total;

  function automatic logic [ADDR_W-1:0] beat_addr(logic [ADDR_W-1:0] a, logic [2:0] sz, logic [1:0] bt, int unsigned beats, int unsigned i);
    logic [ADDR_W-1:0] inc   = ADDR_W'(1) << sz;
    logic [ADDR_W-1:0] algn  = a & ~(inc - 1);
    logic [ADDR_W-1:0] wsz   = ADDR_W'(beats) << sz;
    logic [ADDR_W-1:0] lower;
    if (i == 0) return a;
    case (bt)
      2'b00:   return a;
      2'b10: begin lower = a & ~(wsz - 1); return lower + (((algn - lower) + (ADDR_W'(i) << sz)) & (wsz - 1)); end
      default: return algn + (ADDR_W'(i) << sz);
    endcase
  endfunction

  function automatic int atop_kind(logic [5:0] t);           // 0 none, 1 store, 2 load, 3 swap, 4 compare, 5 reserved
    case (t[5:4])
      2'b00:   return (t == 6'b0) ? 0 : 5;
      2'b01:   return 1;
      2'b10:   return 2;
      default: return (t == 6'b110000) ? 3 : (t == 6'b110001) ? 4 : 5;
    endcase
  endfunction

  function automatic int unsigned atop_rbeats(req_t r);
    int unsigned t  = r.beats << r.size;
    int unsigned rb = (atop_kind(r.atop) == 4) ? t / 2 : t;
    return (rb + (1 << r.size) - 1) >> r.size;
  endfunction

  // legality of an address request, checked when it is accepted
  task automatic check_request(string chn, req_t r);
    int unsigned bytes = r.beats * (1 << r.size);
    int          k = atop_kind(r.atop);
    if (r.burst == 2'b11) violation("AXI_A_BURST", {chn, ": reserved AxBURST 2'b11"});
    if (r.size > SIZE_MAX) violation("AXI_A_BURST", $sformatf("%s: AxSIZE %0d wider than the %0d-bit bus", chn, r.size, DATA_W));
    if (r.burst == 2'b10 && !(k == 4 && r.beats == 1)) begin       // AtomicCompare may be a single-transfer WRAP
      if (!(r.beats inside {2, 4, 8, 16})) violation("AXI_A_BURST", $sformatf("%s: WRAP burst with %0d beats", chn, r.beats));
      if ((r.addr & ((ADDR_W'(1) << r.size) - 1)) != 0 && k == 0) violation("AXI_A_BURST", {chn, ": WRAP burst start address not aligned to AxSIZE"});
    end
    if (r.burst == 2'b00 && r.beats > 16) violation("AXI_A_BURST", $sformatf("%s: FIXED burst with %0d beats", chn, r.beats));
    if (r.burst == 2'b01 && (int'(r.addr[11:0]) & ~((1 << r.size) - 1)) + bytes > 4096)
      violation("AXI_A_4KB", $sformatf("%s: INCR burst from 0x%0h with %0d bytes crosses a 4KB boundary", chn, r.addr, bytes));
    if (r.lock) begin
      if (r.beats > 16) violation("AXI_A_LOCK", $sformatf("%s: exclusive burst with %0d beats", chn, r.beats));
      if (!(bytes inside {1, 2, 4, 8, 16, 32, 64, 128})) violation("AXI_A_LOCK", $sformatf("%s: exclusive access of %0d bytes", chn, bytes));
    end
    if (k != 0) begin
      int unsigned opb = (k == 4) ? bytes / 2 : bytes;
      if (k == 5) violation("AXI_A_ATOP", $sformatf("reserved AWATOP 6'b%06b", r.atop));
      if (r.lock) violation("AXI_A_ATOP", "atomic transaction with AWLOCK set");
      if (k inside {1, 2, 3} && !(bytes inside {1, 2, 4, 8})) violation("AXI_A_ATOP", $sformatf("atomic data size %0d bytes (1, 2, 4 or 8)", bytes));
      if (k == 4 && !(bytes inside {2, 4, 8, 16, 32})) violation("AXI_A_ATOP", $sformatf("AtomicCompare data size %0d bytes (2..32)", bytes));
      if (opb != 0 && (r.addr % opb) != 0) violation("AXI_A_ATOP", $sformatf("atomic address 0x%0h not aligned to %0d bytes", r.addr, opb));
      if (r.beats > 1 && r.size != SIZE_MAX) violation("AXI_A_ATOP", "atomic with AWLEN > 0 and AWSIZE narrower than the bus");
      if (k inside {1, 2, 3} && r.burst != 2'b01) violation("AXI_A_ATOP", "AtomicStore / Load / Swap must be INCR");
      if (k == 4 && bytes != 0) begin
        bit upper = (r.addr % bytes) != 0;
        if (r.beats > 1 && r.burst != (upper ? 2'b10 : 2'b01))
          violation("AXI_A_ATOP", $sformatf("AtomicCompare to the %s half must be %s", upper ? "upper" : "lower", upper ? "WRAP" : "INCR"));
        if (r.beats == 1 && !(r.burst inside {2'b01, 2'b10})) violation("AXI_A_ATOP", "AtomicCompare must be INCR or WRAP");
      end
    end
  endtask

  // check one W beat (index idx of its burst) against the write address it belongs to
  task automatic chk_beat(req_t aw, int unsigned idx, logic [STRB_W-1:0] strb, logic last);
    logic [ADDR_W-1:0] a  = beat_addr(aw.addr, aw.size, aw.burst, aw.beats, idx);
    int unsigned lo = int'(a % STRB_W);
    int unsigned n  = 1 << aw.size;
    int unsigned hi = ((lo / n) + 1) * n;
    if (atop_kind(aw.atop) != 0 && aw.beats == 1) begin                 // atomic single transfer: the whole window
      lo = int'((aw.addr & ~ADDR_W'(n - 1)) % STRB_W); hi = lo + n;
    end
    for (int l = 0; l < STRB_W; l++) begin
      if (strb[l] && (l < lo || l >= hi))
        violation("AXI_A_WSTRB", $sformatf("beat %0d (addr 0x%0h size %0d): WSTRB lane %0d outside the transfer", idx, a, aw.size, l));
      if (atop_kind(aw.atop) != 0 && !strb[l] && l >= lo && l < hi)
        violation("AXI_A_WSTRB", $sformatf("atomic beat %0d: WSTRB lane %0d of the operand is low", idx, l));
    end
    if ((idx + 1 == aw.beats) != (last === 1'b1))
      violation("AXI_A_WLAST", $sformatf("WLAST=%b on beat %0d of %0d", last, idx, aw.beats));
  endtask

  // ID rules of a new request against everything outstanding
  task automatic check_ids(string chn, req_t r, bit is_write);
    int k = atop_kind(r.atop);
    req_t dir_q[$];
    if (k != 0) begin
      bit clash = 0;
      foreach (aw_q[i]) if (aw_q[i].id === r.id) clash = 1;
      if (k inside {2, 3, 4}) foreach (ar_q[i]) if (ar_q[i].id === r.id) clash = 1;
      if (clash) violation("AXI_A_ATOP_ID", $sformatf("atomic with ID 0x%0h while a transaction with that ID is outstanding", r.id));
    end
    if (is_write) dir_q = aw_q; else dir_q = ar_q;
    foreach (dir_q[i]) if (dir_q[i].id === r.id && (r.unq || dir_q[i].unq))
      violation("AXI_A_IDUNQ", $sformatf("%s ID 0x%0h issued with IDUNQ=%0b while a same-ID transaction with IDUNQ=%0b is outstanding", chn, r.id, r.unq, dir_q[i].unq));
  endtask

  always @(posedge aclk) begin
    if (!aresetn) begin
      w_cur.delete(); w_done_q.delete();
      aw_q.delete(); w_aw_q.delete(); ar_q.delete(); r_beat_cnt.delete();
      w_done_cnt = 0; aw_total = 0; wl_total = 0; b_total = 0;
    end else if (checks_en) begin
      // ---- AW accepted
      if (awvalid === 1'b1 && awready === 1'b1) begin
        automatic req_t r;
        r.id = awid; r.addr = awaddr; r.beats = awlen + 1; r.size = awsize; r.burst = awburst; r.lock = awlock;
        r.atop = awatop; r.unq = awidunq; r.trace = awtrace; r.loop = awloop;
        check_request("AW", r);
        check_ids("AW", r, 1);
        aw_q.push_back(r); w_aw_q.push_back(r); aw_total++;
        if (atop_kind(r.atop) inside {2, 3, 4}) begin                 // atomic read data follows on R with AWID
          automatic req_t rr = r;
          rr.beats = atop_rbeats(r);
          ar_q.push_back(rr);
        end
        if (w_done_q.size() != 0) begin                       // its data arrived first: validate the whole burst now
          automatic wbeat_t bq[$] = w_done_q[0];
          w_done_q.delete(0);
          void'(w_aw_q.pop_back());
          foreach (bq[i]) if (i < r.beats || bq[i].last) chk_beat(r, i, bq[i].strb, bq[i].last);
          if (bq.size() != r.beats) violation("AXI_A_WLAST", $sformatf("write data burst of %0d beats for AWLEN+1 = %0d", bq.size(), r.beats));
        end else if (w_cur.size() != 0 && w_aw_q.size() == 1) begin   // partial burst before its address: check what is there
          foreach (w_cur[i]) chk_beat(r, i, w_cur[i].strb, w_cur[i].last);
        end
      end
      // ---- W accepted
      if (wvalid === 1'b1 && wready === 1'b1) begin
        automatic wbeat_t wb;
        wb.strb = wstrb; wb.last = wlast;
        if (wlast === 1'b1) wl_total++;
        if (w_aw_q.size() != 0 && w_done_q.size() == 0) begin
          chk_beat(w_aw_q[0], w_cur.size(), wstrb, wlast);
          w_cur.push_back(wb);
          if (wlast === 1'b1 || w_cur.size() >= w_aw_q[0].beats) begin
            void'(w_aw_q.pop_front()); w_cur.delete(); w_done_cnt++;
          end
        end else begin
          w_cur.push_back(wb);
          if (wlast === 1'b1) begin w_done_q.push_back(w_cur); w_cur.delete(); end
        end
      end
      // ---- B
      if (bvalid === 1'b1) begin
        automatic int idx = -1;
        foreach (aw_q[i]) if (aw_q[i].id === bid) begin idx = i; break; end
        if (idx < 0) violation("AXI_A_R_ID", $sformatf("BID 0x%0h without an outstanding write", bid));
        else begin
          if (b_total >= aw_total || b_total >= wl_total)
            violation("AXI_A_B_ORDER", "BVALID before the write address and the last write data beat were accepted");
          if (bresp === 2'b01 && !aw_q[idx].lock) violation("AXI_A_EXOKAY", "EXOKAY response to a non-exclusive write");
          if (bidunq !== aw_q[idx].unq) violation("AXI_A_IDUNQ", $sformatf("BIDUNQ=%b for a write with AWIDUNQ=%b", bidunq, aw_q[idx].unq));
          if (btrace !== aw_q[idx].trace) violation("AXI_A_TRACE", $sformatf("BTRACE=%b for a write with AWTRACE=%b", btrace, aw_q[idx].trace));
          if (bloop !== aw_q[idx].loop) violation("AXI_A_LOOP", $sformatf("BLOOP=0x%0h for a write with AWLOOP=0x%0h", bloop, aw_q[idx].loop));
        end
        if (bready === 1'b1 && idx >= 0) begin           // a response with an unknown ID is reported once and not counted
          aw_q.delete(idx);
          b_total++;
        end
      end
      // ---- AR accepted
      if (arvalid === 1'b1 && arready === 1'b1) begin
        automatic req_t r;
        r.id = arid; r.addr = araddr; r.beats = arlen + 1; r.size = arsize; r.burst = arburst; r.lock = arlock;
        r.atop = 6'b0; r.unq = aridunq; r.trace = artrace; r.loop = arloop;
        check_request("AR", r);
        check_ids("AR", r, 0);
        ar_q.push_back(r);
      end
      // ---- R
      if (rvalid === 1'b1) begin
        automatic int idx = -1;
        foreach (ar_q[i]) if (ar_q[i].id === rid) begin idx = i; break; end
        if (idx < 0) violation("AXI_A_R_ID", $sformatf("RID 0x%0h without an outstanding read", rid));
        else begin
          automatic int unsigned cnt = r_beat_cnt.exists(rid) ? r_beat_cnt[rid] : 0;
          if (rresp === 2'b01 && !ar_q[idx].lock) violation("AXI_A_EXOKAY", "EXOKAY response to a non-exclusive read");
          if (ridunq !== ar_q[idx].unq) violation("AXI_A_IDUNQ", $sformatf("RIDUNQ=%b for a request with IDUNQ=%b", ridunq, ar_q[idx].unq));
          if (rtrace !== ar_q[idx].trace) violation("AXI_A_TRACE", $sformatf("RTRACE=%b for a request with TRACE=%b", rtrace, ar_q[idx].trace));
          if (rloop !== ar_q[idx].loop) violation("AXI_A_LOOP", $sformatf("RLOOP=0x%0h for a request with LOOP=0x%0h", rloop, ar_q[idx].loop));
          if (rready === 1'b1) begin
            if ((cnt + 1 == ar_q[idx].beats) != (rlast === 1'b1))
              violation("AXI_A_RLAST", $sformatf("RLAST=%b on beat %0d of %0d (ID 0x%0h)", rlast, cnt, ar_q[idx].beats, rid));
            if (rlast === 1'b1 || cnt + 1 >= ar_q[idx].beats) begin ar_q.delete(idx); r_beat_cnt[rid] = 0; end
            else r_beat_cnt[rid] = cnt + 1;
          end
        end
      end
    end
  end

  C_AW:     cover property (@(posedge aclk) awvalid && awready);
  C_W:      cover property (@(posedge aclk) wvalid && wready && wlast);
  C_B:      cover property (@(posedge aclk) bvalid && bready);
  C_AR:     cover property (@(posedge aclk) arvalid && arready);
  C_R:      cover property (@(posedge aclk) rvalid && rready && rlast);
  C_WBEFORE: cover property (@(posedge aclk) wvalid && wready && !awvalid && !awready);
  C_RERR:   cover property (@(posedge aclk) rvalid && rready && rresp[1]);
  C_BERR:   cover property (@(posedge aclk) bvalid && bready && bresp[1]);
  C_ATOMIC: cover property (@(posedge aclk) awvalid && awready && awatop != 0);
  C_POISON: cover property (@(posedge aclk) rvalid && rready && |rpoison);
  C_WAKE:   cover property (@(posedge aclk) $rose(awakeup));

endinterface : vip_axi5_if

`endif
