// -----------------------------------------------------------------------------
// axi5_slave_driver - AXI5 subordinate with a sparse memory
//
//   * independent channel engines (AW / W / B / AR / R), each with random READY / VALID timing (agent cfg)
//   * write data may arrive before the address; a write is committed when its AW and its last W beat were accepted
//   * out-of-order B / R between different IDs (cfg.ooo), R beat interleaving (cfg.interleave); responses of one ID stay in order
//   * exclusive access monitor (EXOKAY) per ID; any other write to a reserved range clears the reservation
//   * SLVERR (error window, random) and DECERR (outside the mapped window)
//   * AXI5: atomics (AWATOP) executed on the memory at commit time, original value returned on R with the AWID
//     (cfg.atomics_en = 0: SLVERR with the right number of read data beats); poison stored per CHUNK_B bytes
//     (WPOISON sets, a complete non-poisoned write of the chunk clears, RPOISON returns it); BIDUNQ / BTRACE / BLOOP and
//     RIDUNQ / RTRACE / RLOOP echo the request; RDATACHK odd byte parity
//   Override `decide()` (factory) to model something else than a memory.
// -----------------------------------------------------------------------------
class axi5_wburst;
  bit [AXI5_DATA_W-1:0]   d[$];
  bit [AXI5_STRB_W-1:0]   s[$];
  bit [AXI5_POISON_W-1:0] p[$];
endclass

class axi5_sreq;
  bit [AXI5_ID_W-1:0]   id;
  bit [AXI5_ADDR_W-1:0] addr;
  int unsigned          beats;
  bit [2:0]             size;
  axi5_burst_e          burst;
  bit                   lock;
  axi5_resp_e           resp;            // decided at acceptance
  int unsigned          next_beat;       // reads: next beat to present
  longint unsigned      ready_cyc;       // reads: earliest cycle of the next beat
  bit                   excl_ok;         // exclusive access succeeded
  bit [5:0]             atop;
  bit                   unq, trace;
  bit [AXI5_LOOP_W-1:0] loop;
  bit                   atomic_r;        // read data of an atomic: rdata_q / rpois_q hold the beats
  bit [AXI5_DATA_W-1:0]   rdata_q[$];
  bit [AXI5_POISON_W-1:0] rpois_q[$];
endclass

class axi5_bresp_t;
  bit [AXI5_ID_W-1:0]   id;
  axi5_resp_e           resp;
  longint unsigned      due;
  bit                   unq, trace;
  bit [AXI5_LOOP_W-1:0] loop;
endclass

class axi5_slave_driver extends uvm_component;
  `uvm_component_utils(axi5_slave_driver)

  typedef struct { bit [AXI5_ADDR_W-1:0] lo; bit [AXI5_ADDR_W-1:0] hi; } range_t;

  axi5_agent_cfg cfg;
  axi5_vif_t     vif;

  protected axi5_sreq     aw_pend[$];
  protected axi5_wburst   w_cur;
  protected axi5_wburst   w_done[$];
  protected axi5_bresp_t  b_q[$];
  protected axi5_sreq     rd_pend[$];
  protected range_t       reserv [bit [AXI5_ID_W-1:0]];
  protected longint unsigned cyc;
  bit       poisoned [longint unsigned];   // chunk address (multiple of CHUNK_B) -> poisoned
  int unsigned n_atomic, n_poison_wr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    set_defaults();
    forever begin
      wait (vif.aresetn === 1'b1);
      fork
        clock_counter();
        aw_engine(); w_engine(); commit_engine(); b_engine();
        ar_engine(); r_engine();
        @(negedge vif.aresetn);
      join_any
      disable fork;
      #2ns;
      aw_pend.delete(); w_cur = null; w_done.delete(); b_q.delete(); rd_pend.delete(); reserv.delete();   // memory and poison survive
      set_defaults();
    end
  endtask

  protected task set_defaults();
    vif.awready <= 1'b0; vif.wready <= 1'b0; vif.arready <= 1'b0;
    vif.bvalid <= 1'b0; vif.bid <= '0; vif.bresp <= '0; vif.buser <= '0;
    vif.rvalid <= 1'b0; vif.rid <= '0; vif.rdata <= '0; vif.rresp <= '0; vif.rlast <= 1'b0; vif.ruser <= '0;
    vif.bidunq <= 1'b0; vif.btrace <= 1'b0; vif.bloop <= '0;
    vif.rpoison <= '0; vif.rdatachk <= cfg.datachk_en ? axi5_datachk('0) : '0; vif.ridunq <= 1'b0; vif.rtrace <= 1'b0; vif.rloop <= '0;
  endtask

  // ---------------------------------------------------------------- poison
  protected function void poison_update(bit [AXI5_ADDR_W-1:0] ba, bit [AXI5_STRB_W-1:0] st, bit [AXI5_POISON_W-1:0] pz);
    if (!cfg.poison_en) return;
    for (int c = 0; c < AXI5_POISON_W; c++) begin
      bit any = 0, all = 1;
      longint unsigned ca = longint'(ba) + c * AXI5_CHUNK_B;
      for (int l = c * AXI5_CHUNK_B; l < (c + 1) * AXI5_CHUNK_B && l < AXI5_STRB_W; l++) begin any |= st[l]; all &= st[l]; end
      if (!any) continue;
      if (pz[c]) begin poisoned[ca] = 1'b1; n_poison_wr++; `vip_info("AXI5_SLV", $sformatf("chunk 0x%0h poisoned", ca), UVM_HIGH) end
      else if (all) poisoned.delete(ca);
    end
  endfunction

  protected function bit [AXI5_POISON_W-1:0] poison_of(bit [AXI5_ADDR_W-1:0] ba);
    bit [AXI5_POISON_W-1:0] r = '0;
    if (!cfg.poison_en) return r;
    for (int c = 0; c < AXI5_POISON_W; c++) r[c] = poisoned.exists(longint'(ba) + c * AXI5_CHUNK_B);
    return r;
  endfunction

  // ---------------------------------------------------------------- atomics
  // executes the atomic of request r with write data w; returns the B response, fills r.rdata_q / rpois_q
  protected function axi5_resp_e do_atomic(axi5_sreq r, axi5_wburst w);
    axi5_atop_kind_e k = axi5_atop_kind(r.atop);
    int unsigned total = r.beats << r.size;
    int unsigned n     = (k == AXI5_ATOP_COMPARE) ? total / 2 : total;
    bit [AXI5_ADDR_W-1:0] wbase = axi5_atop_base(r.addr, total);
    bit [AXI5_ADDR_W-1:0] sbase = (r.addr == wbase) ? wbase + n : wbase;      // AtomicCompare: swap value address
    byte unsigned wb [longint unsigned];
    byte unsigned orig[$], opnd[$], swp[$], res[$];
    bit any_poison = 0;
    axi5_resp_e rs = r.resp;
    bit [2:0] rsz = axi5_atop_rsize(r.atop, r.size, r.beats - 1);
    int unsigned rbeats = axi5_atop_rbeats(r.atop, r.size, r.beats - 1);
    n_atomic++;
    if (!cfg.atomics_en || k == AXI5_ATOP_RESERVED) rs = AXI5_SLVERR;
    for (int i = 0; i < r.beats && i < w.d.size(); i++) begin
      bit [AXI5_STRB_W-1:0] ln = axi5_atop_lanes(r.addr, r.size, r.burst, r.beats, i);
      bit [AXI5_ADDR_W-1:0] ba = ((r.beats == 1) ? wbase : axi5_burst_addr(r.addr, r.size, r.burst, r.beats, i)) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1);
      for (int l = 0; l < AXI5_STRB_W; l++) if (ln[l] && w.s[i][l]) wb[longint'(ba) + l] = w.d[i][8*l +: 8];
      if (w.p[i] != 0) any_poison = 1;
    end
    for (int i = 0; i < n; i++) begin
      orig.push_back(cfg.mem.read_byte(longint'(r.addr) + i));
      opnd.push_back(wb.exists(longint'(r.addr) + i) ? wb[longint'(r.addr) + i] : 8'h00);
      if (k == AXI5_ATOP_COMPARE) swp.push_back(wb.exists(longint'(sbase) + i) ? wb[longint'(sbase) + i] : 8'h00);
    end
    // read data: the original value, INCR from AWADDR
    if (axi5_atop_has_rdata(r.atop)) begin
      r.atomic_r = 1'b1;
      for (int j = 0; j < rbeats; j++) begin
        bit [AXI5_ADDR_W-1:0] ba = axi5_burst_addr(r.addr, rsz, AXI5_INCR, rbeats, j) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1);
        bit [AXI5_STRB_W-1:0] ln = axi5_valid_lanes(r.addr, rsz, AXI5_INCR, rbeats, j);
        bit [AXI5_DATA_W-1:0] d = '0;
        for (int l = 0; l < AXI5_STRB_W; l++)
          if (ln[l] && rs == AXI5_OKAY && longint'(ba) + l >= longint'(r.addr) && longint'(ba) + l < longint'(r.addr) + n)
            d[8*l +: 8] = orig[longint'(ba) + l - longint'(r.addr)];
        r.rdata_q.push_back(d);
        r.rpois_q.push_back(poison_of(ba));
      end
    end
    if (rs == AXI5_OKAY) begin
      axi5_atomic_result(r.atop, orig, opnd, swp, res);
      foreach (res[i]) cfg.mem.write_byte(longint'(r.addr) + i, res[i]);
      if (any_poison && cfg.poison_en)
        for (int i = 0; i < n; i += AXI5_CHUNK_B) poisoned[(longint'(r.addr) + i) & ~longint'(AXI5_CHUNK_B - 1)] = 1'b1;
      clear_reservations(r.addr, r.addr + n - 1);
    end
    r.resp = rs;
    return rs;
  endfunction

  protected function bit inject_now(axi5_inject_e kind);
    return (cfg.inject == kind) && ($urandom_range(99) < cfg.inject_pct);
  endfunction

  protected task clock_counter();
    forever begin @(vif.slv_cb); cyc++; end
  endtask

  protected function int unsigned rnd(int unsigned lo, int unsigned hi);
    return (hi <= lo) ? lo : $urandom_range(hi, lo);
  endfunction

  // ---------------------------------------------------------------- response code of a burst
  virtual function axi5_resp_e decide(axi5_sreq r);
    bit [AXI5_ADDR_W-1:0] last = axi5_burst_addr(r.addr, r.size, r.burst, r.beats, r.beats - 1);
    if (cfg.unmapped_decerr && (!cfg.is_mapped(r.addr) || !cfg.is_mapped(last))) return AXI5_DECERR;
    if (cfg.in_err_window(r.addr) || cfg.in_err_window(last) || ($urandom_range(99) < cfg.err_pct)) return AXI5_SLVERR;
    return AXI5_OKAY;
  endfunction

  protected function void clear_reservations(bit [AXI5_ADDR_W-1:0] lo, bit [AXI5_ADDR_W-1:0] hi);
    bit [AXI5_ID_W-1:0] del[$];
    foreach (reserv[i]) if (!(reserv[i].hi < lo || reserv[i].lo > hi)) del.push_back(i);
    foreach (del[i]) reserv.delete(del[i]);
  endfunction

  // ---------------------------------------------------------------- AW
  protected task aw_engine();
    bit rdy = 1'b0;
    @(vif.slv_cb);
    forever begin
      if (rdy && vif.slv_cb.awvalid === 1'b1) begin
        axi5_sreq r = new();
        r.id = vif.slv_cb.awid; r.addr = vif.slv_cb.awaddr; r.beats = vif.slv_cb.awlen + 1; r.size = vif.slv_cb.awsize;
        r.burst = axi5_burst_e'(vif.slv_cb.awburst); r.lock = vif.slv_cb.awlock;
        r.atop = vif.slv_cb.awatop; r.unq = vif.slv_cb.awidunq; r.trace = vif.slv_cb.awtrace; r.loop = vif.slv_cb.awloop;
        r.resp = decide(r);
        aw_pend.push_back(r);
      end
      rdy = ($urandom_range(99) < cfg.awready_pct);
      vif.slv_cb.awready <= rdy;
      @(vif.slv_cb);
    end
  endtask

  // ---------------------------------------------------------------- W
  protected task w_engine();
    bit rdy = 1'b0;
    @(vif.slv_cb);
    forever begin
      if (rdy && vif.slv_cb.wvalid === 1'b1) begin
        if (w_cur == null) w_cur = new();
        w_cur.d.push_back(vif.slv_cb.wdata);
        w_cur.s.push_back(vif.slv_cb.wstrb);
        w_cur.p.push_back(vif.slv_cb.wpoison);
        if (vif.slv_cb.wlast === 1'b1) begin w_done.push_back(w_cur); w_cur = null; end
      end
      rdy = ($urandom_range(99) < cfg.wready_pct);
      vif.slv_cb.wready <= rdy;
      @(vif.slv_cb);
    end
  endtask

  // a write is complete when its AW and its last W beat were accepted
  protected task commit_engine();
    forever begin
      @(vif.slv_cb);
      while (aw_pend.size() != 0 && w_done.size() != 0) begin
        axi5_sreq r = aw_pend.pop_front();
        axi5_wburst w = w_done.pop_front();
        axi5_bresp_t b = new();
        bit [AXI5_ADDR_W-1:0] a_lo = r.addr, a_hi = r.addr + (r.beats << r.size) - 1;
        bit do_write = (r.resp == AXI5_OKAY) && r.atop == 6'b0;
        b.id = r.id; b.resp = r.resp; b.unq = r.unq; b.trace = r.trace; b.loop = r.loop;
        if (r.atop != 6'b0) begin                         // atomic: executed here, read data queued on R
          b.resp = do_atomic(r, w);
          if (r.atomic_r) begin
            r.ready_cyc = cyc + rnd(cfg.r_delay_min, cfg.r_delay_max);
            r.beats = r.rdata_q.size();
            rd_pend.push_back(r);
          end
        end
        if (do_write && r.lock) begin                    // exclusive write
          bit hit = cfg.exclusive_en && reserv.exists(r.id) && reserv[r.id].lo == a_lo && reserv[r.id].hi == a_hi;
          do_write = hit;
          b.resp = hit ? AXI5_EXOKAY : AXI5_OKAY;
        end
        if (do_write) begin
          for (int i = 0; i < r.beats && i < w.d.size(); i++) begin
            bit [AXI5_ADDR_W-1:0] ba = axi5_burst_addr(r.addr, r.size, r.burst, r.beats, i) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1);
            for (int l = 0; l < AXI5_STRB_W; l++)
              if (w.s[i][l]) cfg.mem.write_byte(longint'(ba) + l, w.d[i][8*l +: 8]);
            poison_update(ba, w.s[i], w.p[i]);
          end
          clear_reservations(a_lo, a_hi);                // every successful write clears overlapping reservations
        end
        if (inject_now(AXI5_INJ_EXOKAY_NORMAL) && !r.lock) b.resp = AXI5_EXOKAY;
        b.due = cyc + rnd(cfg.b_delay_min, cfg.b_delay_max);
        b_q.push_back(b);
      end
    end
  endtask

  // ---------------------------------------------------------------- B
  protected function int pick_b();
    int cand[$];
    bit [AXI5_ID_W-1:0] seen[$];
    foreach (b_q[i]) begin
      bit dup = 0;
      foreach (seen[k]) if (seen[k] == b_q[i].id) dup = 1;
      if (dup) continue;                                // only the oldest response of an ID may leave
      seen.push_back(b_q[i].id);
      if (b_q[i].due <= cyc) cand.push_back(i);
      if (!cfg.ooo) break;                              // in order: only the head of the queue
    end
    if (cand.size() == 0) return -1;
    return cfg.ooo ? cand[$urandom_range(cand.size() - 1)] : cand[0];
  endfunction

  protected task b_engine();
    bit driving = 1'b0;
    @(vif.slv_cb);
    forever begin
      if (driving && vif.slv_cb.bready === 1'b1) begin driving = 1'b0; end      // handshake at this edge
      if (!driving) begin
        int k = pick_b();
        if (k >= 0) begin
          axi5_bresp_t b = b_q[k];
          b_q.delete(k);
          vif.slv_cb.bvalid <= 1'b1; vif.slv_cb.bid <= b.id; vif.slv_cb.bresp <= b.resp; vif.slv_cb.buser <= '0;
          vif.slv_cb.bidunq <= b.unq ^ inject_now(AXI5_INJ_RIDUNQ); vif.slv_cb.btrace <= b.trace ^ inject_now(AXI5_INJ_TRACE);
          vif.slv_cb.bloop <= b.loop ^ (inject_now(AXI5_INJ_LOOP) ? 1 : 0);
          driving = 1'b1;
        end else vif.slv_cb.bvalid <= 1'b0;
      end
      @(vif.slv_cb);
    end
  endtask

  // ---------------------------------------------------------------- AR
  protected task ar_engine();
    bit rdy = 1'b0;
    @(vif.slv_cb);
    forever begin
      if (rdy && vif.slv_cb.arvalid === 1'b1) begin
        axi5_sreq r = new();
        bit [AXI5_ADDR_W-1:0] a_lo, a_hi;
        r.id = vif.slv_cb.arid; r.addr = vif.slv_cb.araddr; r.beats = vif.slv_cb.arlen + 1; r.size = vif.slv_cb.arsize;
        r.burst = axi5_burst_e'(vif.slv_cb.arburst); r.lock = vif.slv_cb.arlock;
        r.unq = vif.slv_cb.aridunq; r.trace = vif.slv_cb.artrace; r.loop = vif.slv_cb.arloop;
        r.resp = decide(r);
        a_lo = r.addr; a_hi = r.addr + (r.beats << r.size) - 1;
        if (r.lock && r.resp == AXI5_OKAY && cfg.exclusive_en) begin
          reserv[r.id] = '{lo: a_lo, hi: a_hi};
          r.resp = AXI5_EXOKAY;
        end
        r.ready_cyc = cyc + rnd(cfg.r_delay_min, cfg.r_delay_max);
        rd_pend.push_back(r);
      end
      rdy = ($urandom_range(99) < cfg.arready_pct);
      vif.slv_cb.arready <= rdy;
      @(vif.slv_cb);
    end
  endtask

  // ---------------------------------------------------------------- R
  protected function int pick_r(int last);
    int cand[$];
    bit [AXI5_ID_W-1:0] seen[$];
    foreach (rd_pend[i]) begin
      bit dup = 0;
      foreach (seen[k]) if (seen[k] == rd_pend[i].id) dup = 1;
      if (dup) continue;                                // same-ID reads complete in order
      seen.push_back(rd_pend[i].id);
      if (rd_pend[i].ready_cyc <= cyc) cand.push_back(i);
      if (!cfg.ooo && !cfg.interleave) break;           // strictly in order
    end
    if (cand.size() == 0) return -1;
    if (last >= 0 && !cfg.interleave) begin             // finish the burst that is running
      foreach (cand[i]) if (cand[i] == last) return last;
    end
    return (cfg.ooo || cfg.interleave) ? cand[$urandom_range(cand.size() - 1)] : cand[0];
  endfunction

  protected task r_engine();
    bit driving = 1'b0;
    axi5_sreq cur = null;
    @(vif.slv_cb);
    forever begin
      if (driving && vif.slv_cb.rready === 1'b1) begin                 // beat accepted at this edge
        driving = 1'b0;
        cur.next_beat++;
        cur.ready_cyc = cyc + (cfg.r_gap_sep ? rnd(cfg.r_gap_min, cfg.r_gap_max) : rnd(cfg.r_delay_min, cfg.r_delay_max));
        if (cur.next_beat >= cur.beats) begin
          foreach (rd_pend[i]) if (rd_pend[i] == cur) begin rd_pend.delete(i); break; end
          cur = null;
        end
      end
      if (!driving) begin
        int idx = pick_r(-1);
        if (cur != null && !cfg.interleave) begin                       // continue the burst in progress
          idx = -1;
          foreach (rd_pend[i]) if (rd_pend[i] == cur) idx = i;
          if (idx >= 0 && rd_pend[idx].ready_cyc > cyc) idx = -2;       // inter-beat gap
        end
        if (idx >= 0) begin
          axi5_sreq r = rd_pend[idx];
          bit [AXI5_ADDR_W-1:0] ba = axi5_burst_addr(r.addr, r.size, r.burst, r.beats, r.next_beat) & ~AXI5_ADDR_W'(AXI5_STRB_W - 1);
          bit [AXI5_DATA_W-1:0] d;
          bit last = (r.next_beat == r.beats - 1);
          axi5_resp_e rs = r.resp;
          bit [AXI5_POISON_W-1:0] pz;
          if (r.atomic_r) begin d = r.rdata_q[r.next_beat]; pz = r.rpois_q[r.next_beat]; end
          else begin
            for (int l = 0; l < AXI5_STRB_W; l++) d[8*l +: 8] = (r.resp[1]) ? $urandom : cfg.mem.read_byte(longint'(ba) + l);
            pz = r.resp[1] ? '0 : poison_of(ba);
          end
          if (inject_now(AXI5_INJ_RLAST_EARLY) && r.next_beat == 0 && r.beats > 1) last = 1'b1;
          if (r.atomic_r && inject_now(AXI5_INJ_ATOP_RBEATS) && r.next_beat == r.beats - 2) last = 1'b1;
          vif.slv_cb.rvalid <= 1'b1; vif.slv_cb.rid <= r.id; vif.slv_cb.rdata <= d; vif.slv_cb.rresp <= rs;
          vif.slv_cb.rlast <= last; vif.slv_cb.ruser <= '0;
          vif.slv_cb.rpoison <= pz;
          vif.slv_cb.rdatachk <= !cfg.datachk_en ? '0 : (axi5_datachk(d) ^ (inject_now(AXI5_INJ_RDATACHK) ? 1 : 0));
          vif.slv_cb.ridunq <= r.unq ^ inject_now(AXI5_INJ_RIDUNQ); vif.slv_cb.rtrace <= r.trace ^ inject_now(AXI5_INJ_TRACE);
          vif.slv_cb.rloop <= r.loop ^ (inject_now(AXI5_INJ_LOOP) ? 1 : 0);
          cur = r; driving = 1'b1;
        end else vif.slv_cb.rvalid <= 1'b0;
      end
      @(vif.slv_cb);
    end
  endtask
endclass : axi5_slave_driver
