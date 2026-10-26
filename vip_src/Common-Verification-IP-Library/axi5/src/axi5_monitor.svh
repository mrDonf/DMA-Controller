// -----------------------------------------------------------------------------
// axi5_monitor - passive: rebuilds write and read bursts from the five channels (independent of the drivers)
//   ap         one axi5_item per completed burst (published at the B handshake / at the last R beat)
//   ap_abort   bursts cut by a reset
//   Write data may precede the address: the k-th AW is paired with the k-th W burst (AXI5 has no write interleaving).
//   AXI5: AWATOP / IDUNQ / TRACE / LOOP of the request, WPOISON / RPOISON per beat; an atomic with read data is
//   published when its B and all its R beats (RID = AWID, adata / aresp / apoison) were seen.
// -----------------------------------------------------------------------------
class axi5_monitor extends uvm_monitor;
  `uvm_component_utils(axi5_monitor)

  axi5_agent_cfg cfg;
  axi5_vif_t     vif;
  uvm_analysis_port #(axi5_item) ap;
  uvm_analysis_port #(axi5_item) ap_abort;

  int unsigned n_wr, n_rd, n_err, n_ooo, n_wfirst, max_wr_out, max_rd_out, n_beats_w, n_beats_r;
  int unsigned n_atomic, n_poison_w, n_poison_r, n_unq, n_trace;

  protected axi5_item aw_unpaired[$];          // AW accepted, W burst not complete yet
  protected axi5_item wr_wait[$];              // AW + W complete (or at least AW), waiting for B (AW order)
  protected axi5_item rd_wait[$];              // AR accepted, in issue order
  protected axi5_item w_done_unpaired[$];      // W bursts complete before their AW (items carrying only data)
  protected axi5_item w_cur;
  protected axi5_item at_wait[$];              // atomics with read data: AW seen, B and / or R still to come
  protected bit       at_bdone [axi5_item];
  protected int unsigned w_cur_beats;
  protected longint unsigned cyc;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap       = new("ap", this);
    ap_abort = new("ap_abort", this);
  endfunction

  protected function axi5_item new_req(bit w, bit [AXI5_ID_W-1:0] id, bit [AXI5_ADDR_W-1:0] a, bit [7:0] len, bit [2:0] sz, bit [1:0] bt,
                                       bit lk, bit [3:0] ca, bit [2:0] pr, bit [3:0] qo, bit [3:0] rg, bit [AXI5_USER_W-1:0] us);
    axi5_item it = axi5_item::type_id::create("mon_item");
    it.write = w; it.id = id; it.addr = a; it.len = len; it.size = sz; it.burst = axi5_burst_e'(bt); it.lock = lk;
    it.cache = ca; it.prot = pr; it.qos = qo; it.region = rg; it.user = us;
    it.data = new[len + 1]; it.strb = new[len + 1]; it.rresp = new[len + 1]; it.w_delay = new[len + 1];
    it.start_time = $time;
    it.latency_cycles = cyc;                     // temporarily the issue cycle
    return it;
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      cyc++;
      if (vif.aresetn !== 1'b1) begin
        foreach (wr_wait[i])        begin wr_wait[i].aborted = 1; ap_abort.write(wr_wait[i]); end
        foreach (aw_unpaired[i])    begin aw_unpaired[i].aborted = 1; ap_abort.write(aw_unpaired[i]); end
        foreach (rd_wait[i])        begin rd_wait[i].aborted = 1; ap_abort.write(rd_wait[i]); end
        wr_wait.delete(); aw_unpaired.delete(); rd_wait.delete(); w_done_unpaired.delete(); w_cur = null; w_cur_beats = 0;
        at_wait.delete(); at_bdone.delete();
        continue;
      end
      // ---- AW
      if (vif.mon_cb.awvalid === 1'b1 && vif.mon_cb.awready === 1'b1) begin
        axi5_item it = new_req(1'b1, vif.mon_cb.awid, vif.mon_cb.awaddr, vif.mon_cb.awlen, vif.mon_cb.awsize, vif.mon_cb.awburst,
                               vif.mon_cb.awlock, vif.mon_cb.awcache, vif.mon_cb.awprot, vif.mon_cb.awqos, vif.mon_cb.awregion, vif.mon_cb.awuser);
        it.atop = vif.mon_cb.awatop; it.idunq = vif.mon_cb.awidunq; it.trace = vif.mon_cb.awtrace; it.loop = vif.mon_cb.awloop;
        it.poison = new[it.beats()];
        if (it.idunq) n_unq++;
        if (it.trace) n_trace++;
        if (axi5_atop_has_rdata(it.atop)) begin
          it.adata = new[0]; it.aresp = new[0]; it.apoison = new[0];
          at_wait.push_back(it); at_bdone[it] = 0;
        end
        it.outstanding = wr_wait.size() + aw_unpaired.size();
        if (it.outstanding + 1 > max_wr_out) max_wr_out = it.outstanding + 1;
        aw_unpaired.push_back(it);
      end
      // ---- W
      if (vif.mon_cb.wvalid === 1'b1 && vif.mon_cb.wready === 1'b1) begin
        if (w_cur == null) begin w_cur = axi5_item::type_id::create("mon_w"); w_cur.data = new[1]; w_cur.strb = new[1]; w_cur.poison = new[1]; w_cur_beats = 0; end
        w_cur.data = new[w_cur_beats + 1](w_cur.data); w_cur.strb = new[w_cur_beats + 1](w_cur.strb); w_cur.poison = new[w_cur_beats + 1](w_cur.poison);
        w_cur.data[w_cur_beats] = vif.mon_cb.wdata; w_cur.strb[w_cur_beats] = vif.mon_cb.wstrb; w_cur.poison[w_cur_beats] = vif.mon_cb.wpoison;
        if (vif.mon_cb.wpoison != 0) n_poison_w++;
        w_cur_beats++;
        n_beats_w++;
        if (vif.mon_cb.wlast === 1'b1) begin
          w_cur.w_first_seen = (aw_unpaired.size() == 0 && w_done_unpaired.size() == 0);   // no address accepted for it yet
          w_done_unpaired.push_back(w_cur); w_cur = null;
        end
      end
      // ---- pair AW with W burst (k-th with k-th)
      while (aw_unpaired.size() != 0 && w_done_unpaired.size() != 0) begin
        axi5_item a = aw_unpaired.pop_front();
        axi5_item w = w_done_unpaired.pop_front();
        for (int i = 0; i < a.beats() && i < w.data.size(); i++) begin a.data[i] = w.data[i]; a.strb[i] = w.strb[i]; a.poison[i] = w.poison[i]; end
        if (w.data.size() != a.beats())
          `vip_error("AXI5_MON", $sformatf("write burst ID 0x%0h: %0d data beats for AWLEN+1 = %0d", a.id, w.data.size(), a.beats()))
        a.w_first_seen = w.w_first_seen;
        if (a.w_first_seen) n_wfirst++;
        wr_wait.push_back(a);
      end
      // ---- B
      if (vif.mon_cb.bvalid === 1'b1 && vif.mon_cb.bready === 1'b1) begin
        int idx = -1;
        foreach (wr_wait[i]) if (wr_wait[i].id == vif.mon_cb.bid) begin idx = i; break; end
        if (idx >= 0) begin
          axi5_item it = wr_wait[idx];
          it.ooo = (idx != 0);
          wr_wait.delete(idx);
          it.bresp = axi5_resp_e'(vif.mon_cb.bresp);
          if (vif.mon_cb.bresp[1]) it.error = 1'b1;
          if (at_bdone.exists(it)) begin
            at_bdone[it] = 1'b1;
            if (it.adata.size() >= axi5_atop_rbeats(it.atop, it.size, it.len)) publish_atomic(it);
          end else publish_wr(it);
        end
      end
      // ---- AR
      if (vif.mon_cb.arvalid === 1'b1 && vif.mon_cb.arready === 1'b1) begin
        axi5_item it = new_req(1'b0, vif.mon_cb.arid, vif.mon_cb.araddr, vif.mon_cb.arlen, vif.mon_cb.arsize, vif.mon_cb.arburst,
                               vif.mon_cb.arlock, vif.mon_cb.arcache, vif.mon_cb.arprot, vif.mon_cb.arqos, vif.mon_cb.arregion, vif.mon_cb.aruser);
        it.outstanding = rd_wait.size();
        if (it.outstanding + 1 > max_rd_out) max_rd_out = it.outstanding + 1;
        it.rresp = new[0]; it.data = new[0]; it.rpoison = new[0];
        it.idunq = vif.mon_cb.aridunq; it.trace = vif.mon_cb.artrace; it.loop = vif.mon_cb.arloop;
        if (it.idunq) n_unq++;
        if (it.trace) n_trace++;
        rd_wait.push_back(it);
      end
      // ---- R
      if (vif.mon_cb.rvalid === 1'b1 && vif.mon_cb.rready === 1'b1) begin
        int idx = -1;
        foreach (rd_wait[i]) if (rd_wait[i].id == vif.mon_cb.rid) begin idx = i; break; end
        if (idx < 0) begin                                   // read data of an atomic
          int ai = -1;
          foreach (at_wait[i]) if (at_wait[i].id == vif.mon_cb.rid) begin ai = i; break; end
          if (ai >= 0) begin
            axi5_item it = at_wait[ai];
            int k = it.adata.size();
            it.adata = new[k + 1](it.adata); it.aresp = new[k + 1](it.aresp); it.apoison = new[k + 1](it.apoison);
            it.adata[k] = vif.mon_cb.rdata; it.aresp[k] = axi5_resp_e'(vif.mon_cb.rresp); it.apoison[k] = vif.mon_cb.rpoison;
            if (vif.mon_cb.rresp[1]) it.error = 1'b1;
            n_beats_r++;
            if (vif.mon_cb.rlast === 1'b1 && at_bdone[it]) publish_atomic(it);
          end
        end
        if (idx >= 0) begin
          axi5_item it = rd_wait[idx];
          int k = it.data.size();
          it.data = new[k + 1](it.data); it.rresp = new[k + 1](it.rresp);
          it.data[k] = vif.mon_cb.rdata; it.rresp[k] = axi5_resp_e'(vif.mon_cb.rresp);
          it.rpoison = new[k + 1](it.rpoison); it.rpoison[k] = vif.mon_cb.rpoison;
          if (vif.mon_cb.rpoison != 0) n_poison_r++;
          if (vif.mon_cb.rresp[1]) it.error = 1'b1;
          n_beats_r++;
          if (vif.mon_cb.rlast === 1'b1) begin
            it.ooo = (idx != 0);
            rd_wait.delete(idx);
            it.end_time = $time;
            it.latency_cycles = cyc - it.latency_cycles;
            n_rd++; if (it.error) n_err++; if (it.ooo) n_ooo++;
            `vip_info("AXI5_MON", it.convert2string(), UVM_HIGH)
            ap.write(it);
          end
        end
      end
      // stall accounting for coverage (backpressure seen on W / R)
      if (vif.mon_cb.wvalid === 1'b1 && vif.mon_cb.wready !== 1'b1 && aw_unpaired.size() + wr_wait.size() != 0) wr_wait_stall();
    end
  endtask

  protected function void publish_wr(axi5_item it);
    it.end_time = $time;
    it.latency_cycles = cyc - it.latency_cycles;
    n_wr++; if (it.error) n_err++; if (it.ooo) n_ooo++; if (it.atop != 0) n_atomic++;
    `vip_info("AXI5_MON", it.convert2string(), UVM_HIGH)
    ap.write(it);
  endfunction

  protected function void publish_atomic(axi5_item it);
    foreach (at_wait[i]) if (at_wait[i] == it) begin at_wait.delete(i); break; end
    at_bdone.delete(it);
    publish_wr(it);
  endfunction

  protected function void wr_wait_stall();
    if (wr_wait.size() != 0) wr_wait[$].w_stalls++;
    else if (aw_unpaired.size() != 0) aw_unpaired[$].w_stalls++;
  endfunction

  function void report_phase(uvm_phase phase);
    `vip_info("AXI5_MON", $sformatf("writes=%0d reads=%0d error bursts=%0d out-of-order=%0d data-before-address=%0d max outstanding wr/rd=%0d/%0d beats w/r=%0d/%0d violations=%0d",
              n_wr, n_rd, n_err, n_ooo, n_wfirst, max_wr_out, max_rd_out, n_beats_w, n_beats_r, vif.viol_cnt), UVM_LOW)
    `vip_info("AXI5_MON", $sformatf("atomics=%0d poisoned beats w/r=%0d/%0d IDUNQ requests=%0d traced requests=%0d",
              n_atomic, n_poison_w, n_poison_r, n_unq, n_trace), UVM_LOW)
  endfunction
endclass : axi5_monitor
