// -----------------------------------------------------------------------------
// axi5_master_driver - AXI5 manager with independent channel engines
//
//   AXI5: AWATOP / AxIDUNQ / AxTRACE / AxLOOP from the item, WPOISON per beat, WDATACHK (odd byte parity, cfg.datachk_en),
//         WTRACE = item.trace; atomics with read data complete when both B and all R beats (AWID) arrived;
//         AWAKEUP high while anything is fetched / outstanding and cfg.wakeup_idle_cycles after that (cfg.wakeup_en)
//
//   fetch  : takes items from the sequencer (pipelined handshake: item_done at once, response item when the burst completes)
//            as long as the outstanding limits allow
//   AW/AR  : one engine per address channel, VALID is held until READY; items issue back to back when their delay is 0
//   W      : data beats of the write items in order; independent of AW (data may precede the address)
//   B/R    : ready generators (cfg.bready_pct / rready_pct per cycle); responses complete the oldest item with the same ID
//   reset  : all engines are killed, the channels driven idle, every item in flight returns with aborted = 1
// -----------------------------------------------------------------------------
class axi5_master_driver extends uvm_driver #(axi5_item);
  `uvm_component_utils(axi5_master_driver)

  axi5_agent_cfg cfg;
  axi5_vif_t     vif;

  protected axi5_item aw_q[$], w_q[$], ar_q[$];       // waiting for their channel
  protected axi5_item wr_wait[$];                      // address issued, waiting for B (in issue order)
  protected axi5_item rd_wait[$];                      // address issued, waiting for R beats
  protected int unsigned rd_beats [axi5_item];         // beats received so far
  protected axi5_item held;                            // fetched but blocked by an outstanding limit
  protected axi5_item all_inflight[$];
  protected axi5_item at_wait[$];                      // atomics waiting for R data (by AWID)
  protected int unsigned at_beats [axi5_item];         // atomic R beats received
  protected bit          at_bdone [axi5_item];         // atomic B received

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle();
    forever begin
      wait (vif.aresetn === 1'b1);
      fork
        fetch_engine();
        aw_engine();
        w_engine();
        ar_engine();
        b_engine();
        r_engine();
        wakeup_engine();
        @(negedge vif.aresetn);
      join_any
      disable fork;
      #2ns;                                   // clocking-block drives scheduled for this edge have landed: overwrite them before the next edge
      drive_idle();
      `vip_info("AXI5_MST", "reset: all channels flushed", UVM_MEDIUM)
      foreach (all_inflight[i]) begin
        all_inflight[i].aborted = 1'b1;
        seq_item_port.put_response(all_inflight[i]);
      end
      all_inflight.delete(); aw_q.delete(); w_q.delete(); ar_q.delete(); wr_wait.delete(); rd_wait.delete(); rd_beats.delete(); held = null;
      at_wait.delete(); at_beats.delete(); at_bdone.delete();
      do begin
        @(posedge vif.aclk);
        #2ns;
        drive_idle();
      end while (vif.aresetn !== 1'b1);
    end
  endtask

  protected task drive_idle();
    vif.awvalid <= 1'b0; vif.wvalid <= 1'b0; vif.arvalid <= 1'b0; vif.bready <= 1'b0; vif.rready <= 1'b0;
    vif.awid <= '0; vif.awaddr <= '0; vif.awlen <= '0; vif.awsize <= '0; vif.awburst <= '0; vif.awlock <= 1'b0;
    vif.awcache <= '0; vif.awprot <= '0; vif.awqos <= '0; vif.awregion <= '0; vif.awuser <= '0;
    vif.wdata <= '0; vif.wstrb <= '0; vif.wlast <= 1'b0; vif.wuser <= '0;
    vif.arid <= '0; vif.araddr <= '0; vif.arlen <= '0; vif.arsize <= '0; vif.arburst <= '0; vif.arlock <= 1'b0;
    vif.arcache <= '0; vif.arprot <= '0; vif.arqos <= '0; vif.arregion <= '0; vif.aruser <= '0;
    vif.awatop <= '0; vif.awidunq <= 1'b0; vif.awtrace <= 1'b0; vif.awloop <= '0;
    vif.wpoison <= '0; vif.wdatachk <= cfg.datachk_en ? axi5_datachk('0) : '0; vif.wtrace <= 1'b0;
    vif.aridunq <= 1'b0; vif.artrace <= 1'b0; vif.arloop <= '0;
    if (vif.aresetn !== 1'b1 || !cfg.wakeup_en) vif.awakeup <= 1'b0;
  endtask

  // AWAKEUP: high while the manager has work (fetched or outstanding transactions), low after wakeup_idle_cycles idle cycles
  protected task wakeup_engine();
    int unsigned idle = cfg.wakeup_idle_cycles + 1;
    @(vif.mst_cb);
    forever begin
      bit busy = all_inflight.size() != 0 || held != null;
      if (busy) idle = 0; else if (idle <= cfg.wakeup_idle_cycles) idle++;
      vif.mst_cb.awakeup <= cfg.wakeup_en && cfg.inject != AXI5_INJ_WAKEUP && (busy || idle <= cfg.wakeup_idle_cycles);
      @(vif.mst_cb);
    end
  endtask

  protected function bit inject_now(axi5_inject_e kind);
    return (cfg.inject == kind) && ($urandom_range(99) < cfg.inject_pct);
  endfunction

  protected function int unsigned n_wr_out(); return wr_wait.size() + aw_q.size() + ((held != null && held.write) ? 1 : 0); endfunction
  protected function int unsigned n_rd_out(); return rd_wait.size() + ar_q.size(); endfunction

  // ---------------------------------------------------------------- fetch
  protected task fetch_engine();
    @(vif.mst_cb);
    forever begin
      axi5_item req;
      if (held != null) begin
        if (held.write ? (wr_wait.size() + aw_q.size() < cfg.max_wr_outstanding) : (rd_wait.size() + ar_q.size() < cfg.max_rd_outstanding)) begin
          issue(held); held = null;
        end
      end else begin
        seq_item_port.try_next_item(req);
        if (req != null) begin
          axi5_item it;
          $cast(it, req.clone());
          it.set_id_info(req);
          it.rresp = new[it.beats()];
          if (!it.write) begin it.data = new[it.beats()]; it.rpoison = new[it.beats()]; end
          if (it.write && axi5_atop_has_rdata(it.atop)) begin
            int unsigned nb = axi5_atop_rbeats(it.atop, it.size, it.len);
            it.adata = new[nb]; it.aresp = new[nb]; it.apoison = new[nb];
          end
          if (it.poison.size() != it.beats()) it.poison = new[it.beats()](it.poison);
          if (cfg.wakeup_en && cfg.inject != AXI5_INJ_WAKEUP) vif.mst_cb.awakeup <= 1'b1;
          seq_item_port.item_done();
          all_inflight.push_back(it);
          if (it.write ? (wr_wait.size() + aw_q.size() < cfg.max_wr_outstanding) : (rd_wait.size() + ar_q.size() < cfg.max_rd_outstanding))
            issue(it);
          else held = it;
        end
      end
      @(vif.mst_cb);
    end
  endtask

  protected function void issue(axi5_item it);
    if (it.write) begin aw_q.push_back(it); w_q.push_back(it); end
    else          ar_q.push_back(it);
  endfunction

  // ---------------------------------------------------------------- address channels
  protected task aw_engine();
    @(vif.mst_cb);
    forever begin
      if (aw_q.size() == 0) begin
        vif.mst_cb.awvalid <= 1'b0;
        @(vif.mst_cb);
        continue;
      end
      begin
        axi5_item it = aw_q.pop_front();
        bit [AXI5_ADDR_W-1:0] a = it.addr;
        bit [7:0]             l = it.len;
        bit drop = inject_now(AXI5_INJ_AW_DROP_VALID);
        bit chg  = inject_now(AXI5_INJ_AW_CHANGE);
        bit lk = it.lock;
        bit unq = it.idunq;
        if (inject_now(AXI5_INJ_CROSS_4KB) && it.burst == AXI5_INCR) begin a = {a[AXI5_ADDR_W-1:12], 12'hFF0}; l = 8'd15; end
        if (it.atop != 0 && inject_now(AXI5_INJ_ATOP_LOCK))  lk = 1'b1;
        if (it.atop != 0 && inject_now(AXI5_INJ_ATOP_ALIGN)) a = a ^ AXI5_ADDR_W'(1);
        if (inject_now(AXI5_INJ_IDUNQ)) unq = 1'b1;
        repeat (it.aw_delay) begin vif.mst_cb.awvalid <= 1'b0; @(vif.mst_cb); end
        vif.mst_cb.awvalid <= 1'b1;
        vif.mst_cb.awid <= it.id; vif.mst_cb.awaddr <= a; vif.mst_cb.awlen <= l; vif.mst_cb.awsize <= it.size;
        vif.mst_cb.awburst <= it.burst; vif.mst_cb.awlock <= lk; vif.mst_cb.awcache <= it.cache; vif.mst_cb.awprot <= it.prot;
        vif.mst_cb.awqos <= it.qos; vif.mst_cb.awregion <= it.region; vif.mst_cb.awuser <= it.user;
        vif.mst_cb.awatop <= it.atop; vif.mst_cb.awidunq <= unq; vif.mst_cb.awtrace <= it.trace; vif.mst_cb.awloop <= it.loop;
        it.start_time = $time;
        if (drop) begin                                         // violation: VALID withdrawn before READY
          @(vif.mst_cb);
          vif.mst_cb.awvalid <= 1'b0;
          @(vif.mst_cb);
          vif.mst_cb.awvalid <= 1'b1;
        end else if (chg) begin                                // violation: payload changes while VALID waits for READY
          @(vif.mst_cb);
          if (vif.mst_cb.awready !== 1'b1) vif.mst_cb.awaddr <= a ^ 32'h10;
        end
        if (axi5_atop_has_rdata(it.atop)) begin at_wait.push_back(it); at_beats[it] = 0; at_bdone[it] = 0; end
        do @(vif.mst_cb); while (vif.mst_cb.awready !== 1'b1);
        wr_wait.push_back(it);
      end
    end
  endtask

  protected task ar_engine();
    @(vif.mst_cb);
    forever begin
      if (ar_q.size() == 0) begin
        vif.mst_cb.arvalid <= 1'b0;
        @(vif.mst_cb);
        continue;
      end
      begin
        axi5_item it = ar_q.pop_front();
        repeat (it.aw_delay) begin vif.mst_cb.arvalid <= 1'b0; @(vif.mst_cb); end
        vif.mst_cb.arvalid <= 1'b1;
        vif.mst_cb.arid <= it.id; vif.mst_cb.araddr <= it.addr; vif.mst_cb.arlen <= it.len; vif.mst_cb.arsize <= it.size;
        vif.mst_cb.arburst <= it.burst; vif.mst_cb.arlock <= it.lock; vif.mst_cb.arcache <= it.cache; vif.mst_cb.arprot <= it.prot;
        vif.mst_cb.arqos <= it.qos; vif.mst_cb.arregion <= it.region; vif.mst_cb.aruser <= it.user;
        vif.mst_cb.aridunq <= it.idunq; vif.mst_cb.artrace <= it.trace; vif.mst_cb.arloop <= it.loop;
        it.start_time = $time;
        rd_wait.push_back(it);                                  // R data can only follow the AR handshake, but registering early is harmless
        rd_beats[it] = 0;
        do @(vif.mst_cb); while (vif.mst_cb.arready !== 1'b1);
      end
    end
  endtask

  // ---------------------------------------------------------------- write data
  protected task w_engine();
    @(vif.mst_cb);
    forever begin
      if (w_q.size() == 0) begin
        vif.mst_cb.wvalid <= 1'b0;
        @(vif.mst_cb);
        continue;
      end
      begin
        axi5_item it = w_q.pop_front();
        int unsigned n = it.beats();
        for (int b = 0; b < n; b++) begin
          bit last = (b == n - 1);
          bit [AXI5_STRB_W-1:0] st = it.strb[b];
          repeat (it.w_delay[b]) begin vif.mst_cb.wvalid <= 1'b0; @(vif.mst_cb); end
          if (inject_now(AXI5_INJ_WLAST_EARLY) && b == 0 && n > 1) last = 1'b1;
          if (inject_now(AXI5_INJ_WLAST_LATE)  && last)            last = 1'b0;
          if (inject_now(AXI5_INJ_WSTRB_OUTSIDE) && it.size < AXI5_SIZE_MAX) st = ~it.valid_lanes(b) | st;
          vif.mst_cb.wvalid <= 1'b1;
          vif.mst_cb.wdata <= it.data[b]; vif.mst_cb.wstrb <= st; vif.mst_cb.wlast <= last; vif.mst_cb.wuser <= it.user;
          vif.mst_cb.wpoison <= it.poison[b]; vif.mst_cb.wtrace <= it.trace;
          vif.mst_cb.wdatachk <= !cfg.datachk_en ? '0 : (axi5_datachk(it.data[b]) ^ (inject_now(AXI5_INJ_WDATACHK) ? 1 : 0));
          do @(vif.mst_cb); while (vif.mst_cb.wready !== 1'b1);
        end
      end
    end
  endtask

  // ---------------------------------------------------------------- responses
  protected task b_engine();
    bit rdy = 1'b0;
    @(vif.mst_cb);
    forever begin
      // handshake of the previous cycle
      if (rdy && vif.mst_cb.bvalid === 1'b1) begin
        axi5_item it = null;
        foreach (wr_wait[i]) if (wr_wait[i].id == vif.mst_cb.bid) begin it = wr_wait[i]; wr_wait.delete(i); break; end
        if (it == null) `vip_error("AXI5_MST", $sformatf("B response with ID 0x%0h but no such write is outstanding", vif.mst_cb.bid))
        else begin
          it.bresp = axi5_resp_e'(vif.mst_cb.bresp);
          if (vif.mst_cb.bresp[1]) it.error = 1'b1;
          it.end_time = $time;
          if (at_bdone.exists(it)) begin                     // atomic with read data: also needs its R beats
            at_bdone[it] = 1'b1;
            if (at_beats[it] >= it.adata.size()) atomic_done(it);
          end else finish(it);
        end
      end
      rdy = ($urandom_range(99) < cfg.bready_pct);
      vif.mst_cb.bready <= rdy;
      @(vif.mst_cb);
    end
  endtask

  protected task r_engine();
    bit rdy = 1'b0;
    @(vif.mst_cb);
    forever begin
      if (rdy && vif.mst_cb.rvalid === 1'b1) begin
        axi5_item it = null;
        foreach (rd_wait[i]) if (rd_wait[i].id == vif.mst_cb.rid) begin it = rd_wait[i]; break; end
        if (it == null) foreach (at_wait[i]) if (at_wait[i].id == vif.mst_cb.rid) begin it = at_wait[i]; break; end
        if (it == null) `vip_error("AXI5_MST", $sformatf("R beat with ID 0x%0h but no such read is outstanding", vif.mst_cb.rid))
        else if (it.write) begin                              // atomic read data
          int unsigned k = at_beats[it];
          if (k < it.adata.size()) begin
            it.adata[k] = vif.mst_cb.rdata; it.aresp[k] = axi5_resp_e'(vif.mst_cb.rresp); it.apoison[k] = vif.mst_cb.rpoison;
            if (vif.mst_cb.rresp[1]) it.error = 1'b1;
          end
          at_beats[it] = k + 1;
          if (vif.mst_cb.rlast === 1'b1 || k + 1 >= it.adata.size()) begin
            at_beats[it] = it.adata.size();
            if (at_bdone[it]) atomic_done(it);
          end
        end
        else begin
          int unsigned k = rd_beats[it];
          if (k < it.beats()) begin
            it.data[k]  = vif.mst_cb.rdata;
            it.rresp[k] = axi5_resp_e'(vif.mst_cb.rresp);
            it.rpoison[k] = vif.mst_cb.rpoison;
            if (vif.mst_cb.rresp[1]) it.error = 1'b1;
          end
          rd_beats[it] = k + 1;
          if (vif.mst_cb.rlast === 1'b1 || k + 1 >= it.beats()) begin
            foreach (rd_wait[i]) if (rd_wait[i] == it) begin rd_wait.delete(i); break; end
            rd_beats.delete(it);
            it.end_time = $time;
            finish(it);
          end
        end
      end
      rdy = ($urandom_range(99) < cfg.rready_pct);
      vif.mst_cb.rready <= rdy;
      @(vif.mst_cb);
    end
  endtask

  protected function void atomic_done(axi5_item it);
    foreach (at_wait[i]) if (at_wait[i] == it) begin at_wait.delete(i); break; end
    at_beats.delete(it); at_bdone.delete(it);
    finish(it);
  endfunction

  protected function void finish(axi5_item it);
    foreach (all_inflight[i]) if (all_inflight[i] == it) begin all_inflight.delete(i); break; end
    seq_item_port.put_response(it);
  endfunction
endclass : axi5_master_driver
