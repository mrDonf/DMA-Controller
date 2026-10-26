//-----------------------------------------------------------------------------
// dma_perf_mon.svh
//   Passive performance monitor on both AXI manager ports (VIP monitor items).
//   Per channel (AXI ID = channel number): payload bytes (write strobes), bus
//   bytes, number of bursts, first address / last response times, burst
//   latencies and the outstanding transactions seen at issue. Per port: data
//   beats. Counters cover a window opened by clear() and are read by the perf
//   tests (tests/perf).
//-----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_pm0)
`uvm_analysis_imp_decl(_pm1)

class dma_perf_stat extends uvm_object;
  `uvm_object_utils(dma_perf_stat)
  longint unsigned rd_bytes, wr_bytes, wr_payload, link_bytes;
  int unsigned     n_ar, n_aw, n_link, rd_beats, wr_beats;
  time             t_first_ar, t_first_aw, t_last_r, t_last_b;
  longint unsigned rd_lat_sum, wr_lat_sum;
  int unsigned     max_out_rd, max_out_wr;
  function new(string name = "dma_perf_stat");
    super.new(name);
    t_first_ar = '1; t_first_aw = '1; t_last_r = 0; t_last_b = 0;
  endfunction
endclass

class dma_perf_mon extends uvm_component;
  `uvm_component_utils(dma_perf_mon)
  uvm_analysis_imp_pm0 #(axi5_item, dma_perf_mon) imp0;
  uvm_analysis_imp_pm1 #(axi5_item, dma_perf_mon) imp1;

  dma_perf_stat    st[int];                 // per channel
  longint unsigned port_beats[2];           // R + W data beats per port
  longint unsigned port_rbeats[2], port_wbeats[2];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    imp0 = new("imp0", this);
    imp1 = new("imp1", this);
  endfunction

  function void clear();
    st.delete();
    port_beats[0] = 0; port_beats[1] = 0;
    port_rbeats = '{0, 0}; port_wbeats = '{0, 0};
  endfunction

  function dma_perf_stat get(int ch);
    if (!st.exists(ch)) st[ch] = dma_perf_stat::type_id::create($sformatf("pst%0d", ch));
    return st[ch];
  endfunction

  function void write_pm0(axi5_item t); add(0, t); endfunction
  function void write_pm1(axi5_item t); add(1, t); endfunction

  function void add(int p, axi5_item t);
    dma_perf_stat s;
    if (t.aborted) return;
    s = get(t.id);
    port_beats[p] += t.beats();
    if (t.write) port_wbeats[p] += t.beats(); else port_rbeats[p] += t.beats();
    if (t.write) begin
      s.n_aw++;
      s.wr_beats   += t.beats();
      s.wr_bytes   += t.total_bytes();
      foreach (t.strb[i]) s.wr_payload += $countones(t.strb[i]);
      s.wr_lat_sum += t.latency_cycles;
      if (t.start_time < s.t_first_aw) s.t_first_aw = t.start_time;
      if (t.end_time > s.t_last_b)     s.t_last_b   = t.end_time;
      if (t.outstanding + 1 > s.max_out_wr) s.max_out_wr = t.outstanding + 1;
    end else if (t.prot[2]) begin
      s.n_link++;
      s.link_bytes += t.total_bytes();
    end else begin
      s.n_ar++;
      s.rd_beats   += t.beats();
      s.rd_bytes   += t.total_bytes();
      s.rd_lat_sum += t.latency_cycles;
      if (t.start_time < s.t_first_ar) s.t_first_ar = t.start_time;
      if (t.end_time > s.t_last_r)     s.t_last_r   = t.end_time;
      if (t.outstanding + 1 > s.max_out_rd) s.max_out_rd = t.outstanding + 1;
    end
  endfunction
endclass : dma_perf_mon
