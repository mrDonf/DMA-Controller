//-----------------------------------------------------------------------------
// dma_bug01_link_1kb_test.svh
//   BUG-01: command link descriptor crossing a 1KB boundary must not stall.
//-----------------------------------------------------------------------------
class dma_bug01_link_1kb_test extends dma_dir_base;
  `uvm_component_utils(dma_bug01_link_1kb_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    // descriptor start offsets before a 1KB boundary (the TRM full descriptor
    // is 25..28 words, so the body fetch must cross the boundary)
    int offs[$] = '{'h3F8, 'h3FC, 'h3F4, 'h3F0, 'h3E8, 'h3C4, 'h388};
    foreach (offs[i]) begin
      dma_cmd e0, c1;
      bit [31:0] w[$], st;
      longint unsigned D = dsc_base(0) + 'h400 + offs[i];          // boundary at dsc_base + 0x800
      e0 = mk(0, 0, 0, 0, 0);
      e0.xtype = T_DISABLE; e0.linkaddren = 1; e0.linkaddr = D;
      c1 = mk(0, $urandom_range(0, $clog2(TB_DWB)), 'h100 + 16 * i, 'h200 + 16 * i, 9);
      c1.descriptor(dma_cmd::full_header(TB_AW > 32), w);
      put_desc(D, w);
      init_src(c1);
      void'(expect_cmd(c1));
      `uvm_info("BUG01", $sformatf("descriptor of %0d words at 0x%0h", w.size(), D), UVM_LOW)
      regs.program_cmd(e0);
      regs.enable(0);
      regs.wait_idle(0, st, 20000);
      chk(st[ST_DONE] && !st[ST_ERR], $sformatf("BUG-01: descriptor at 1KB-0x%0h: status %08h", 'h400 - offs[i], st));
      void'(env.sb.check_done(0, tname));
      regs.clear_status(0);
      n_cmds++;
    end
  endtask
endclass
