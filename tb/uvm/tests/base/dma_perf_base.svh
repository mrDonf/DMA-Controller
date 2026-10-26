//-----------------------------------------------------------------------------
// dma_perf_base.svh
//   Base class of the performance tests (tests/perf).
//   * memory timing profiles of the AXI subordinates (first beat latency, beat
//     gap, READY probability, write response latency);
//   * measure(): runs a set of commands concurrently with full data checking
//     (reference model + scoreboard) and prints one PERF line per command plus
//     an aggregate line, parsed by scripts/perf_report.py:
//       PERF,<suite>,<case>,<key>=<value>,...
//     cyc   : cycles from ENABLE (channel enabled) to the channel going idle
//     bpc   : payload bytes per cycle (write strobes / cyc)
//     eff   : bpc / bus width (%), the peak of a copy is one bus word per cycle
//     bus   : payload bytes per cycle between the first AR and the last B
//     lat0  : cycles from ENABLE to the first AR handshake
//     tail  : cycles from the last B handshake to the channel going idle
//     rlat  : average read burst duration (AR to last R), cycles
//     ord / owr : most outstanding read / write bursts seen on the port
//-----------------------------------------------------------------------------
class dma_perf_base extends dma_dir_base;
  `uvm_component_utils(dma_perf_base)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  string suite = "perf";
  realtime tclk = 10ns;

  // ---------------------------------------------------------------- timing profiles
  task mem_profile(int lat = 0, int gap = 0, int rdy = 100, int blat = 0);
    for (int p = 0; p < 2; p++) begin
      env.axi_cfg[p].r_gap_sep   = 1'b1;
      env.axi_cfg[p].r_delay_min = lat;  env.axi_cfg[p].r_delay_max = lat;
      env.axi_cfg[p].r_gap_min   = gap;  env.axi_cfg[p].r_gap_max   = gap;
      env.axi_cfg[p].arready_pct = rdy;  env.axi_cfg[p].awready_pct = rdy;
      env.axi_cfg[p].wready_pct  = rdy;
      env.axi_cfg[p].b_delay_min = blat; env.axi_cfg[p].b_delay_max = blat;
    end
  endtask

  task pre_body();
    timeout_ns = 2_000_000_000;
    uvm_top.set_timeout(timeout_ns * 1ns, 1);
  endtask

  // aligned 1D copy of n bytes with bus width elements (or ts)
  function dma_cmd copy(int ch, int nbytes, int ts = -1, int s_off = 0, int d_off = 0, bit m1_s = 0, bit m1_d = 0);
    dma_cmd c;
    if (ts < 0) ts = $clog2(TB_DWB);
    c = mk(ch, ts, 0, 0, nbytes >> ts);
    c.srcaddr = win_base(ch, 0, m1_s) + 'h1000 + s_off;
    c.desaddr = win_base(ch, 1, m1_d) + 'h1000 + d_off;
    c.src_maxburst = 15; c.des_maxburst = 15;
    c.intren = 11'h0;
    return c;
  endfunction

  function real cycles(time t); return real'(t) / (tclk / 1ns); endfunction

  // ---------------------------------------------------------------- measurement
  task measure(string cname, dma_cmd cs[$], string extra = "", bit chk = 1);
    longint unsigned c_en[int], c_end[int];
    time t_en[int];
    longint unsigned cyc_lo = '1, cyc_hi = 0, tot = 0;
    int nwait = cs.size(), nen = 0;
    // contention window: all channels enabled .. first channel idle
    bit snap = 0;
    longint unsigned w_lo = 0, w_hi = 0, w_b[int], w_rb = 0, w_wb = 0;
    env.perf.clear();
    foreach (cs[i]) begin
      init_src(cs[i]);
      void'(expect_cmd(cs[i]));
      regs.program_cmd(cs[i]);
    end
    foreach (cs[i]) begin
      fork
        automatic int ch = cs[i].ch;
        begin
          while (vif.ch_enabled[ch] !== 1'b1) @(posedge vif.clk);
          c_en[ch] = cyc_now(); t_en[ch] = $time;
          nen++;
          if (nen == cs.size()) begin
            w_lo = cyc_now();
            foreach (env.perf.st[k]) w_b[k] = env.perf.st[k].wr_payload;
            w_rb = env.perf.port_rbeats[0] + env.perf.port_rbeats[1];
            w_wb = env.perf.port_wbeats[0] + env.perf.port_wbeats[1];
          end
          while (vif.ch_enabled[ch] === 1'b1) @(posedge vif.clk);
          c_end[ch] = cyc_now();
          if (!snap) begin
            snap = 1;
            w_hi = cyc_now();
            foreach (cs[j]) begin
              int k = cs[j].ch;
              w_b[k] = env.perf.get(k).wr_payload - (w_b.exists(k) ? w_b[k] : 0);
            end
            w_rb = env.perf.port_rbeats[0] + env.perf.port_rbeats[1] - w_rb;
            w_wb = env.perf.port_wbeats[0] + env.perf.port_wbeats[1] - w_wb;
          end
          nwait--;
        end
      join_none
    end
    foreach (cs[i]) regs.enable(cs[i].ch);
    wait (nwait == 0);
    foreach (cs[i]) finish_cmd(cs[i], (1 << ST_DONE), chk);
    foreach (cs[i]) begin
      int ch = cs[i].ch;
      dma_perf_stat s = env.perf.get(ch);
      longint unsigned n = c_end[ch] - c_en[ch];
      real bus = (s.t_last_b > s.t_first_ar) ? real'(s.wr_payload) / cycles(s.t_last_b - s.t_first_ar) : 0.0;
      if (c_en[ch] < cyc_lo)  cyc_lo = c_en[ch];
      if (c_end[ch] > cyc_hi) cyc_hi = c_end[ch];
      tot += s.wr_payload;
      `uvm_info("PERF", $sformatf("PERF,%s,%s,ch=%0d,bytes=%0d,cyc=%0d,bpc=%0.3f,eff=%0.1f,bus=%0.3f,lat0=%0.0f,tail=%0.0f,rlat=%0.1f,ar=%0d,aw=%0d,link=%0d,ord=%0d,owr=%0d%s",
                suite, cname, ch, s.wr_payload, n, real'(s.wr_payload) / n, 100.0 * real'(s.wr_payload) / n / TB_DWB, bus,
                (s.n_ar > 0) ? cycles(s.t_first_ar - t_en[ch]) : -1.0,
                cycles(t_en[ch]) + n - cycles(s.t_last_b),
                (s.n_ar > 0) ? real'(s.rd_lat_sum) / s.n_ar : 0.0, s.n_ar, s.n_aw, s.n_link, s.max_out_rd, s.max_out_wr,
                (extra != "") ? {",", extra} : ""), UVM_NONE)
    end
    if (cs.size() > 1 && w_hi > w_lo) begin
      string sh = "";
      longint unsigned wt = 0;
      foreach (cs[j]) wt += w_b[cs[j].ch];
      foreach (cs[j]) sh = {sh, $sformatf(",share%0d=%0.1f", cs[j].ch, (wt > 0) ? 100.0 * w_b[cs[j].ch] / wt : 0.0)};
      `uvm_info("PERF", $sformatf("PERF,%s,%s,ch=window,bytes=%0d,cyc=%0d,bpc=%0.3f,eff=%0.1f,rutil=%0.1f,wutil=%0.1f%s%s",
                suite, cname, wt, w_hi - w_lo, real'(wt) / (w_hi - w_lo), 100.0 * real'(wt) / (w_hi - w_lo) / TB_DWB,
                100.0 * w_rb / (w_hi - w_lo), 100.0 * w_wb / (w_hi - w_lo), sh,
                (extra != "") ? {",", extra} : ""), UVM_NONE)
    end
    if (cs.size() > 1)
      `uvm_info("PERF", $sformatf("PERF,%s,%s,ch=all,bytes=%0d,cyc=%0d,bpc=%0.3f,eff=%0.1f,m0r=%0.1f,m0w=%0.1f,m1r=%0.1f,m1w=%0.1f%s",
                suite, cname, tot, cyc_hi - cyc_lo, real'(tot) / (cyc_hi - cyc_lo),
                100.0 * real'(tot) / (cyc_hi - cyc_lo) / TB_DWB,
                100.0 * env.perf.port_rbeats[0] / (cyc_hi - cyc_lo), 100.0 * env.perf.port_wbeats[0] / (cyc_hi - cyc_lo),
                100.0 * env.perf.port_rbeats[1] / (cyc_hi - cyc_lo), 100.0 * env.perf.port_wbeats[1] / (cyc_hi - cyc_lo),
                (extra != "") ? {",", extra} : ""), UVM_NONE)
  endtask

  function longint unsigned cyc_now(); return longint'($time / (tclk / 1ns)); endfunction
endclass
