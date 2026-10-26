//-----------------------------------------------------------------------------
// dma_perf_cmd_test.svh
//   Command overhead:
//     * 16 small commands programmed through APB one after the other versus
//       the same 16 commands as a command link chain (descriptors in memory)
//     * 2D line overhead: 4KB as 1x4096, 16x256, 64x64 and 256x16 bytes
//   The APB case includes the register programming time (APB clock = ACLK).
//-----------------------------------------------------------------------------
class dma_perf_cmd_test extends dma_perf_base;
  `uvm_component_utils(dma_perf_cmd_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  localparam int NCMD = 16;

  task body();
    int sizes[] = '{8, 64, 512};
    int lines[] = '{1, 16, 64, 256};
    int ch = 0;
    suite = "cmd";
    mem_profile(0);
    foreach (sizes[k]) begin
      run_apb(ch, sizes[k]);
      run_link(ch, sizes[k]);
    end
    // 2D line overhead (only on channels with 2D support)
    if (TB_EXT_MASK[ch]) foreach (lines[k]) begin
      dma_cmd c = copy(ch, 4096);
      int lb = 4096 / lines[k];
      c.srcxsize = lb >> c.ts; c.desxsize = lb >> c.ts;
      if (lines[k] > 1) begin
        c.ytype = T_CONTINUE;
        c.srcysize = lines[k]; c.desysize = lines[k];
        c.srcystride = (lb + 64) >> c.ts; c.desystride = (lb + 32) >> c.ts;   // gaps between lines
      end
      measure($sformatf("2d_y%0d", lines[k]), '{c}, $sformatf("lines=%0d,linebytes=%0d", lines[k], lb));
    end
  endtask

  // NCMD commands, each programmed and started after the previous one ended
  task run_apb(int ch, int nb);
    longint unsigned c0, c1, pay = 0;
    dma_cmd cs[$];
    for (int i = 0; i < NCMD; i++) begin
      dma_cmd c = copy(ch, nb, (nb >= TB_DWB) ? -1 : 0, i * 1024, i * 1024);
      init_src(c);
      cs.push_back(c);
    end
    env.perf.clear();
    c0 = cyc_now();
    foreach (cs[i]) begin
      bit [31:0] st;
      void'(expect_cmd(cs[i]));
      regs.program_cmd(cs[i]);
      regs.enable(ch);
      regs.wait_idle(ch, st);
      void'(env.sb.check_done(ch, tname));
      env.sb.clear_reads(ch);
      regs.clear_status(ch);
      n_cmds++;
    end
    c1 = cyc_now();
    pay = env.perf.get(ch).wr_payload;
    `uvm_info("PERF", $sformatf("PERF,%s,apb_n%0d,ch=%0d,bytes=%0d,cyc=%0d,bpc=%0.3f,cpc=%0.1f,mode=apb,size=%0d",
              suite, nb, ch, pay, c1 - c0, real'(pay) / (c1 - c0), real'(c1 - c0) / NCMD, nb), UVM_NONE)
  endtask

  // the same NCMD commands as a link chain started with one ENABLE
  task run_link(int ch, int nb);
    longint unsigned c0, c1, pay;
    dma_cmd cs[$];
    longint unsigned D = dsc_base(ch);
    bit [31:0] st;
    for (int i = 0; i < NCMD; i++) begin
      dma_cmd c = copy(ch, nb, (nb >= TB_DWB) ? -1 : 0, 'h10000 + i * 1024, 'h10000 + i * 1024);
      init_src(c);
      cs.push_back(c);
    end
    for (int i = 0; i < NCMD; i++) begin
      if (i < NCMD - 1) begin cs[i].linkaddren = 1; cs[i].linkaddr = D + (i + 1) * 'h80; end
    end
    for (int i = 1; i < NCMD; i++) begin
      bit [31:0] w[$];
      cs[i].descriptor(link_header(cs[i - 1], cs[i], 0), w);
      put_desc(D + i * 'h80, w);
    end
    foreach (cs[i]) void'(expect_cmd(cs[i]));
    regs.program_cmd(cs[0]);
    env.perf.clear();
    c0 = cyc_now();
    regs.enable(ch);
    regs.wait_idle(ch, st);
    c1 = cyc_now();
    if (!st[ST_DONE] || st[ST_ERR]) `uvm_error("PERF", $sformatf("link chain status %08h", st))
    void'(env.sb.check_done(ch, tname));
    env.sb.clear_reads(ch);
    regs.clear_status(ch);
    n_cmds += NCMD;
    pay = env.perf.get(ch).wr_payload;
    `uvm_info("PERF", $sformatf("PERF,%s,link_n%0d,ch=%0d,bytes=%0d,cyc=%0d,bpc=%0.3f,cpc=%0.1f,link=%0d,mode=link,size=%0d",
              suite, nb, ch, pay, c1 - c0, real'(pay) / (c1 - c0), real'(c1 - c0) / NCMD,
              env.perf.get(ch).link_bytes, nb), UVM_NONE)
  endtask
endclass
