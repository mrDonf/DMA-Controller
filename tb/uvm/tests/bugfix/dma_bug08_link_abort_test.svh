//-----------------------------------------------------------------------------
// dma_bug08_link_abort_test.svh
//   BUG-08: STOP while a command link read is still outstanding. The read data
//   of the aborted fetch arrives after the abort; it must not corrupt the link
//   engine state (buffer space reservation) used by the next linked command.
//   Part 1 stops the link fetch several times with slow read data, part 2 runs
//   long (REGCLEAR, full) descriptors that fill the command buffer and checks
//   the transferred data.
//-----------------------------------------------------------------------------
class dma_bug08_link_abort_test extends dma_dir_base;
  `uvm_component_utils(dma_bug08_link_abort_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task body();
    longint unsigned D = dsc_base(0) + 'h100;
    dma_cmd e0, c1;
    bit [31:0] w[$], st;
    // ---------------- 1. STOP during the link fetch (read data delayed)
    // the stop lands in the header fetch (8 cycles) or in the body fetch /
    // decode (header received after 40..60 cycles, body beats 40..60 apart)
    int stop_at[] = '{8, 8, 70, 130, 8, 100};
    foreach (stop_at[k]) begin
      e0 = mk(0, 0, 0, 0, 0);
      e0.xtype = T_DISABLE; e0.linkaddren = 1; e0.linkaddr = D;
      c1 = mk(0, $clog2(TB_DWB), 'h40, 'h40, 4);
      c1.descriptor(dma_cmd::full_header(TB_AW > 32), w);
      put_desc(D, w);
      init_src(c1);
      for (int p = 0; p < 2; p++) begin env.axi_cfg[p].r_delay_min = 40; env.axi_cfg[p].r_delay_max = 60; end
      void'(expect_cmd(c1));                         // a late stop may let some data through
      env.sb.relax(0);
      regs.program_cmd(e0);
      regs.enable(0);
      while (vif.ch_enabled[0] !== 1'b1) @(posedge vif.clk);
      repeat (stop_at[k]) @(posedge vif.clk);
      regs.chw(0, CH_CMD, 1 << 3);                     // STOPCMD while the link read is outstanding
      regs.wait_idle(0, st, 20000);
      chk(st[ST_STOPPED] || (st[ST_DONE] && stop_at[k] > 8),
          $sformatf("stop %0d (%0d cycles) during the link fetch: status %08h", k, stop_at[k], st));
      env.sb.clear_reads(0);
      regs.clear_status(0);
      env.sb.unrelax(0);
      for (int p = 0; p < 2; p++) begin env.axi_cfg[p].r_delay_min = 0; env.axi_cfg[p].r_delay_max = 0; end
    end
    // ---------------- 2. long descriptors afterwards (command buffer full)
    for (int k = 0; k < 4; k++) begin
      e0 = mk(0, 0, 0, 0, 0);
      e0.xtype = T_DISABLE; e0.linkaddren = 1; e0.linkaddr = D + 'h100 * k;
      c1 = mk(0, k % ($clog2(TB_DWB) + 1), 'h200 * k, 'h200 * k + 'h80, 13 + k);
      c1.srcxinc = 1; c1.desxinc = 1;
      c1.descriptor(dma_cmd::full_header(TB_AW > 32), w);
      put_desc(e0.linkaddr, w);
      init_src(c1);
      void'(expect_cmd(c1));
      regs.program_cmd(e0);
      regs.enable(0);
      regs.wait_idle(0, st, 20000);
      chk(st[ST_DONE] && !st[ST_ERR], $sformatf("linked command %0d after the aborted fetches: status %08h", k, st));
      void'(env.sb.check_done(0, tname));
      regs.clear_status(0);
      n_cmds++;
    end
  endtask
endclass
