//-----------------------------------------------------------------------------
// dma_scoreboard.svh
//   * every byte written on M0 / M1 must match the next expected value of that
//     address (per-address ordered queues -> overlapping / FIFO style
//     destinations and concurrent channels are handled)
//   * a write to an address without expectation is an error
//   * every byte read by a data burst must belong to the source of an active
//     command of that channel; command link reads (ARPROT[2]) must stay inside
//     the registered descriptor areas
//   * AXI rules of the DMA: FIXED / INCR only, <= 16 beats, no 1KB crossing,
//     transfers routed to the right manager port, AxPROT / AxQOS as programmed
//   * stream-out packets compared with the expected bytes
//-----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_m0)
`uvm_analysis_imp_decl(_m1)
`uvm_analysis_imp_decl(_so)

// MAIR style memory attribute -> AxCACHE (AXI IHI0022 table A4-5)
function automatic bit [3:0] tb_cache(bit [7:0] attr, bit is_wr);
  bit [3:0] o = attr[7:4], i = attr[3:0];
  bit ra, wa;
  if (o == 4'b0000) return (i[3:2] == 2'b00) ? 4'b0000 : 4'b0001;   // Device nGnRnE / other device
  if (o == 4'b0100) return 4'b0011;                                // Normal non-cacheable bufferable
  ra = o[1]; wa = o[0];
  if (!o[2]) return is_wr ? {wa, 3'b110} : {1'b1, ra, 2'b10};      // write-through
  return is_wr ? {wa, 3'b111} : {1'b1, ra, 2'b11};                 // write-back
endfunction

class dma_scoreboard extends uvm_component;
  `uvm_component_utils(dma_scoreboard)

  uvm_analysis_imp_m0 #(axi5_item, dma_scoreboard) imp_m0;
  uvm_analysis_imp_m1 #(axi5_item, dma_scoreboard) imp_m1;

  typedef struct { byte unsigned v; int ch; } eb_t;
  protected eb_t    exp_q   [longint unsigned][$];
  protected int     pend    [int];
  protected bit     rd_ok   [int][longint unsigned];
  protected bit     lk_ok   [longint unsigned];
  protected bit     relaxed [int];
  protected bit     relax_ok[int][longint unsigned];
  protected byte unsigned so_exp [int][$];       // concatenated expected stream-out bytes per channel
  protected int     so_pkt_exp [int];
  // expected attributes per channel
  bit [3:0]         exp_qos  [int];
  bit               chk_attr [int];
  bit [2:0]         exp_rprot [int], exp_wprot [int], exp_lprot [int];
  bit [3:0]         exp_rcache [int], exp_wcache [int], exp_lcache [int];

  int unsigned n_wr_bytes, n_rd_bursts, n_wr_bursts, n_errors, n_so_pkts;
  // transaction recording for directed burst-shape checks
  bit          rec_en;
  axi5_item    rec_q[$];
  int          rec_port[$];
  bit          check_reads = 1'b1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    imp_m0 = new("imp_m0", this);
    imp_m1 = new("imp_m1", this);
  endfunction

  function void err(string m);
    n_errors++;
    `uvm_error("DMA_SB", m)
  endfunction

  // ---------------------------------------------------------------- expectations
  function void add_expect(dma_exp e);
    if (!pend.exists(e.ch)) pend[e.ch] = 0;
    foreach (e.wr_addr[i]) begin
      eb_t b;
      b.v = e.wr_data[i];
      b.ch = e.ch;
      exp_q[e.wr_addr[i]].push_back(b);
      pend[e.ch]++;
    end
    foreach (e.rd_ok[a]) rd_ok[e.ch][a] = 1'b1;
    if (e.so_bytes.size() != 0) begin
      foreach (e.so_bytes[i]) so_exp[e.ch].push_back(e.so_bytes[i]);
      if (!so_pkt_exp.exists(e.ch)) so_pkt_exp[e.ch] = 0;
      so_pkt_exp[e.ch]++;
    end
  endfunction

  // descriptor fetches use bus-width beats: the whole bus words holding the
  // descriptor may be read
  function void allow_link_read(longint unsigned a, int nbytes);
    longint unsigned lo = a & ~longint'(TB_DWB - 1);
    longint unsigned hi = (a + nbytes + TB_DWB - 1) & ~longint'(TB_DWB - 1);
    for (longint unsigned x = lo; x < hi; x++) lk_ok[x] = 1'b1;
  endfunction

  function void allow_read(int ch, longint unsigned a, int nbytes);
    for (int i = 0; i < nbytes; i++) rd_ok[ch][a + i] = 1'b1;
  endfunction

  // channel stopped / errored: drop the remaining expectations; later writes
  // to these addresses are tolerated if they carry an expected value
  function void relax(int ch);
    longint unsigned dl[$];
    relaxed[ch] = 1'b1;
    foreach (exp_q[a]) begin
      eb_t keep[$];
      for (int i = 0; i < exp_q[a].size(); i++) begin
        if (exp_q[a][i].ch == ch) relax_ok[ch][a] = 1'b1;
        else keep.push_back(exp_q[a][i]);
      end
      exp_q[a] = keep;
      if (keep.size() == 0) dl.push_back(a);
    end
    foreach (dl[i]) exp_q.delete(dl[i]);
    pend[ch] = 0;
    so_exp.delete(ch);
    so_pkt_exp.delete(ch);
  endfunction

  function void unrelax(int ch);
    relaxed.delete(ch);
    relax_ok.delete(ch);
  endfunction

  function int pending(int ch);
    return pend.exists(ch) ? pend[ch] : 0;
  endfunction

  // all expected writes of the channel happened
  function bit check_done(int ch, string tag = "");
    if (pending(ch) != 0) begin
      int shown = 0;
      string s = "";
      foreach (exp_q[a]) for (int i = 0; i < exp_q[a].size(); i++)
        if (exp_q[a][i].ch == ch && shown < 8) begin
          s = {s, $sformatf(" %0h=%02h", a, exp_q[a][i].v)};
          shown++;
        end
      err($sformatf("%s ch%0d: %0d expected byte writes missing:%s", tag, ch, pending(ch), s));
      return 0;
    end
    if (so_exp.exists(ch) && so_exp[ch].size() != 0) begin
      err($sformatf("%s ch%0d: %0d expected stream-out bytes not received", tag, ch, so_exp[ch].size()));
      return 0;
    end
    return 1;
  endfunction

  function void clear_reads(int ch);
    rd_ok.delete(ch);
  endfunction

  // ---------------------------------------------------------------- AXI checks
  function void check_burst_rules(axi5_item t, int port);
    longint unsigned first, last;
    int nb = 1 << t.size;
    if (t.burst == AXI5_WRAP) err($sformatf("M%0d WRAP burst issued: %s", port, t.convert2string()));
    if (t.len > 15) err($sformatf("M%0d burst longer than 16 beats: %s", port, t.convert2string()));
    if (t.size > $clog2(TB_DWB)) err($sformatf("M%0d AxSIZE wider than the bus: %s", port, t.convert2string()));
    first = t.addr;
    last  = (t.burst == AXI5_FIXED) ? t.addr + nb - 1 : ((t.addr / nb) * nb + (t.len + 1) * nb - 1);
    if (t.burst == AXI5_INCR && (first >> 10) != (last >> 10))
      err($sformatf("M%0d burst crosses a 1KB boundary: %s", port, t.convert2string()));
    if (tb_port_of(t.addr) != port)
      err($sformatf("transfer routed to M%0d but address maps to M%0d: %s", port, tb_port_of(t.addr), t.convert2string()));
    if (t.id >= TB_NCH) err($sformatf("M%0d unexpected ID %0d", port, t.id));
    if (chk_attr.exists(t.id) && chk_attr[t.id]) begin
      bit [2:0] ep;
      bit [3:0] ec;
      if (t.qos != exp_qos[t.id])
        err($sformatf("M%0d ch%0d AxQOS %0d expected %0d", port, t.id, t.qos, exp_qos[t.id]));
      if (t.write)        begin ep = exp_wprot[t.id]; ec = exp_wcache[t.id]; end
      else if (t.prot[2]) begin ep = exp_lprot[t.id]; ec = exp_lcache[t.id]; end
      else                begin ep = exp_rprot[t.id]; ec = exp_rcache[t.id]; end
      if (t.prot != ep)  err($sformatf("M%0d ch%0d AxPROT %03b expected %03b (%s)", port, t.id, t.prot, ep, t.convert2string()));
      if (t.cache != ec) err($sformatf("M%0d ch%0d AxCACHE %04b expected %04b (%s)", port, t.id, t.cache, ec, t.convert2string()));
    end
  endfunction

  function void on_item(axi5_item t, int port);
    int ch = t.id;
    if (t.aborted) return;
    if (rec_en) begin rec_q.push_back(t); rec_port.push_back(port); end
    check_burst_rules(t, port);
    if (t.write) begin
      n_wr_bursts++;
      for (int i = 0; i <= t.len; i++) begin
        longint unsigned ba = longint'(t.beat_addr(i)) & ~longint'(TB_DWB - 1);
        bit [TB_DWB-1:0] lanes = t.valid_lanes(i);
        for (int l = 0; l < TB_DWB; l++) begin
          if (!t.strb[i][l]) continue;
          if (!lanes[l]) err($sformatf("M%0d WSTRB outside the beat lanes beat %0d: %s", port, i, t.convert2string()));
          begin
            longint unsigned a = ba + l;
            byte unsigned    v = t.data[i][8*l +: 8];
            n_wr_bytes++;
            if (exp_q.exists(a) && exp_q[a].size() != 0) begin
              eb_t e = exp_q[a].pop_front();
              if (exp_q[a].size() == 0) exp_q.delete(a);
              if (e.ch != ch) err($sformatf("byte 0x%0h written by ch%0d, expected from ch%0d", a, ch, e.ch));
              if (e.v != v)   err($sformatf("ch%0d byte 0x%0h = %02h expected %02h (%s)", ch, a, v, e.v, t.convert2string()));
              if (pend.exists(e.ch)) pend[e.ch]--;
            end else if (relaxed.exists(ch) && relax_ok.exists(ch) && relax_ok[ch].exists(a)) begin
              // tolerated write of a stopped / errored command
            end else begin
              err($sformatf("ch%0d unexpected write of byte 0x%0h = %02h (%s)", ch, a, v, t.convert2string()));
            end
          end
        end
      end
    end else begin
      n_rd_bursts++;
      if (!check_reads) return;
      for (int i = 0; i <= t.len; i++) begin
        longint unsigned ba = t.beat_addr(i);
        int nb = 1 << t.size;
        longint unsigned hi = (ba / nb) * nb + nb;
        for (longint unsigned a = ba; a < hi; a++) begin
          if (t.prot[2]) begin
            if (!lk_ok.exists(a)) begin
              err($sformatf("ch%0d command link read outside descriptors: 0x%0h (%s)", ch, a, t.convert2string()));
              break;
            end
          end else if (!(rd_ok.exists(ch) && rd_ok[ch].exists(a))) begin
            if (!relaxed.exists(ch)) begin
              err($sformatf("ch%0d read outside the source: 0x%0h (%s)", ch, a, t.convert2string()));
              break;
            end
          end
        end
      end
    end
  endfunction

  function void write_m0(axi5_item t); on_item(t, 0); endfunction
  function void write_m1(axi5_item t); on_item(t, 1); endfunction

  // ---------------------------------------------------------------- stream out
  function void stream_out(int ch, axis_item p);
    byte unsigned q[$];
    p.bytes(q);
    n_so_pkts++;
    if (!so_exp.exists(ch)) begin
      if (!relaxed.exists(ch)) err($sformatf("ch%0d unexpected stream-out packet (%0d bytes)", ch, q.size()));
      return;
    end
    foreach (q[i]) begin
      if (so_exp[ch].size() == 0) begin
        err($sformatf("ch%0d stream-out longer than expected", ch));
        break;
      end
      begin
        byte unsigned e = so_exp[ch].pop_front();
        if (e != q[i]) begin
          err($sformatf("ch%0d stream-out byte %0d = %02h expected %02h", ch, i, q[i], e));
          break;
        end
      end
    end
  endfunction

  // recorded bursts of one channel / direction (data or link reads)
  function void get_rec(int ch, bit write, ref axi5_item q[$], input bit link = 0);
    q.delete();
    foreach (rec_q[i])
      if (rec_q[i].id == ch && rec_q[i].write == write && (write || rec_q[i].prot[2] == link)) q.push_back(rec_q[i]);
  endfunction

  function void report_phase(uvm_phase phase);
    int left = 0;
    foreach (exp_q[a]) left += exp_q[a].size();
    `uvm_info("DMA_SB", $sformatf("bytes written %0d, write bursts %0d, read bursts %0d, stream packets %0d, errors %0d, pending %0d",
                                  n_wr_bytes, n_wr_bursts, n_rd_bursts, n_so_pkts, n_errors, left), UVM_LOW)
    if (left != 0) `uvm_error("DMA_SB", $sformatf("%0d expected byte writes never happened", left))
  endfunction

endclass : dma_scoreboard
