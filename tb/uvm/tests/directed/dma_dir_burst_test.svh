//-----------------------------------------------------------------------------
// dma_dir_burst_test.svh
//   Exact AXI burst shapes: TRM 4.3.7 / 4.3.8, 1KB split, MAXBURSTLEN, FIFO/2,
//   FIXED / single transfers, table 6-1.
//-----------------------------------------------------------------------------
class dma_dir_burst_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_burst_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  typedef struct { longint off; int len; int size; int burst; } bs_t;

  task expect_bursts(int ch, bit wr, longint unsigned base, bs_t exp[$], string tag);
    axi5_item q[$];
    env.sb.get_rec(ch, wr, q);
    if (q.size() != exp.size()) begin
      string s = "";
      foreach (q[i]) s = {s, $sformatf(" [%0h len%0d sz%0d]", longint'(q[i].addr) - longint'(base), q[i].len, q[i].size)};
      `uvm_error("DIRECTED", $sformatf("%s: %0d %s bursts, expected %0d:%s", tag, q.size(), wr ? "write" : "read", exp.size(), s))
      return;
    end
    foreach (exp[i]) begin
      chk(longint'(q[i].addr) - longint'(base) == exp[i].off && q[i].len == exp[i].len &&
          q[i].size == exp[i].size && int'(q[i].burst) == exp[i].burst,
          $sformatf("%s burst %0d: off %0h len %0d size %0d burst %0d, expected off %0h len %0d size %0d burst %0d",
                    tag, i, longint'(q[i].addr) - longint'(base), q[i].len, q[i].size, q[i].burst,
                    exp[i].off, exp[i].len, exp[i].size, exp[i].burst));
    end
  endtask

  task rec_run(dma_cmd c, string tag);
    env.sb.rec_q.delete();
    env.sb.rec_port.delete();
    env.sb.rec_en = 1;
    init_src(c);
    drun(c, -1, tag);
    env.sb.rec_en = 0;
  endtask

  task body();
    dma_cmd c;
    bs_t e[$];
    int lb = $clog2(TB_DWB);
    int smallest = 0;
    for (int ch = 0; ch < TB_NCH; ch++) if (tb_fifo_depth(ch) < tb_fifo_depth(smallest)) smallest = ch;
    if (TB_DWB == 8) begin
      // ---- 4.3.7 unaligned start, 13 bytes at addr[2:0] = 3, unoptimized (device)
      c = mk(0, 0, 'h3, 'h3, 13, 0);
      rec_run(c, "4.3.7 unoptimized");
      e = '{'{'h3, 12, 0, 1}};
      expect_bursts(0, 0, sbase(0), e, "4.3.7 unoptimized read");
      expect_bursts(0, 1, dbase(0), e, "4.3.7 unoptimized write");
      // ---- 4.3.7 optimized: one wide burst from the unaligned address
      c = mk(0, 0, 'h3, 'h3, 13, 1);
      rec_run(c, "4.3.7 optimized");
      e = '{'{'h3, 1, 3, 1}};
      expect_bursts(0, 0, sbase(0), e, "4.3.7 optimized read");
      expect_bursts(0, 1, dbase(0), e, "4.3.7 optimized write");
      begin
        axi5_item q[$];
        env.sb.get_rec(0, 1, q);
        if (q.size() == 1) chk(q[0].strb[0] == 8'hF8 && q[0].strb[1] == 8'hFF, "4.3.7 optimized write strobes");
      end
      // ---- 4.3.8 unaligned end, 3 bytes aligned: read 16-bit then 8-bit, write one 64-bit beat
      c = mk(0, 0, 'h0, 'h0, 3, 1);
      rec_run(c, "4.3.8");
      e = '{'{'h0, 0, 1, 1}, '{'h2, 0, 0, 1}};
      expect_bursts(0, 0, sbase(0), e, "4.3.8 optimized read");
      e = '{'{'h0, 0, 3, 1}};
      expect_bursts(0, 1, dbase(0), e, "4.3.8 optimized write");
      begin
        axi5_item q[$];
        env.sb.get_rec(0, 1, q);
        if (q.size() == 1) chk(q[0].strb[0] == 8'h07, "4.3.8 write strobe");
      end
    end
    // ---- 1KB boundary: 64 bytes starting 32 bytes before a 1KB boundary
    c = mk(0, lb, 'h3E0, 'h3E0, 64 / TB_DWB, 1);
    rec_run(c, "1KB split");
    e = '{'{'h3E0, 32 / TB_DWB - 1, lb, 1}, '{'h400, 32 / TB_DWB - 1, lb, 1}};
    expect_bursts(0, 0, sbase(0), e, "1KB split read");
    expect_bursts(0, 1, dbase(0), e, "1KB split write");
    // ---- MAXBURSTLEN
    c = mk(0, lb, 'h0, 'h0, 10, 1);
    c.src_maxburst = 3; c.des_maxburst = 1;
    rec_run(c, "MAXBURSTLEN");
    e = '{'{0, 3, lb, 1}, '{4 * TB_DWB, 3, lb, 1}, '{8 * TB_DWB, 1, lb, 1}};
    expect_bursts(0, 0, sbase(0), e, "MAXBURSTLEN=3 read");
    e.delete();
    for (int i = 0; i < 5; i++) e.push_back('{2 * i * TB_DWB, 1, lb, 1});
    expect_bursts(0, 1, dbase(0), e, "MAXBURSTLEN=1 write");
    // ---- FIFO/2 limit on the channel with the smallest FIFO
    begin
      int half = ((tb_fifo_depth(smallest) / 2 < 1) ? 1 : tb_fifo_depth(smallest) / 2);
      c = mk(smallest, lb, 'h0, 'h0, 4 * half, 1);
      rec_run(c, "FIFO/2");
      e.delete();
      for (int i = 0; i < 4; i++) e.push_back('{i * half * TB_DWB, half - 1, lb, 1});
      expect_bursts(smallest, 0, sbase(smallest), e, "FIFO/2 read");
    end
    // ---- increment 0 -> FIXED burst, increment 2 -> single transfers
    c = mk(0, 2, 'h10, 'h20, 10, 0);
    c.srcxinc = 0;
    c.desxinc = 2;
    rec_run(c, "FIXED / single");
    begin
      // FIXED bursts: <= MAXBURSTLEN+1 beats and <= FIFO/2 bytes
      int fmax = ((tb_fifo_depth(0) / 2 < 1) ? 1 : tb_fifo_depth(0) / 2) * TB_DWB / 4;
      int left = 10;
      e.delete();
      while (left > 0) begin
        int n = (left < fmax) ? left : fmax;
        if (n > 16) n = 16;
        e.push_back('{'h10, n - 1, 2, 0});
        left -= n;
      end
    end
    expect_bursts(0, 0, sbase(0), e, "increment 0 read");
    e.delete();
    for (int i = 0; i < 10; i++) e.push_back('{'h20 + 8 * i, 0, 2, 1});
    expect_bursts(0, 1, dbase(0), e, "increment 2 write");
    // ---- Table 6-1: XSIZE 20, TRIGINBLKSIZE 7, MAXBURSTLEN 3 -> 3 3 1 | 3 3 1 | 3 3
    if (TB_NTI > 0) begin
      int h0;
      c = mk(0, 0, 'h0, 'h100, 20, 0);
      c.src_maxburst = 2;
      c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 0; c.srctrig_mode = TM_DMAFC; c.srctrig_blk = 6;
      env.sb.rec_q.delete();
      env.sb.rec_en = 1;
      init_src(c);
      void'(expect_cmd(c));
      regs.program_cmd(c);
      regs.enable(0);
      h0 = env.trig.n_in_hs.exists(0) ? env.trig.n_in_hs[0] : 0;
      env.trig.fc_peripheral(0, 0, 0, 10);
      finish_cmd(c);
      env.sb.rec_en = 0;
      chk(env.trig.n_in_hs[0] - h0 == 3, $sformatf("table 6-1: %0d trigger blocks, expected 3", env.trig.n_in_hs[0] - h0));
      chk(env.trig.last_acktype[0] == AK_LOKAY, "table 6-1: last block not acknowledged with LAST OKAY");
      e = '{'{0, 2, 0, 1}, '{3, 2, 0, 1}, '{6, 0, 0, 1}, '{7, 2, 0, 1}, '{10, 2, 0, 1}, '{13, 0, 0, 1},
            '{14, 2, 0, 1}, '{17, 2, 0, 1}};
      expect_bursts(0, 0, sbase(0), e, "table 6-1 read");
    end
  endtask
endclass
