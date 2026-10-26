//-----------------------------------------------------------------------------
// dma_dir_regend_test.svh
//   End-of-command address / size registers: TRM 5.6.4 examples.
//-----------------------------------------------------------------------------
class dma_dir_regend_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_regend_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task chk_end(dma_cmd c, longint exp_src, longint exp_des, string tag);
    bit [31:0] sa, da, xs, ys;
    regs.chr(c.ch, CH_SRCADDR, sa);
    regs.chr(c.ch, CH_DESADDR, da);
    regs.chr(c.ch, CH_XSIZE, xs);
    regs.chr(c.ch, CH_YSIZE, ys);
    chk(sa == 32'(sbase(c.ch) + exp_src), $sformatf("%s: SRCADDR %08h expected base+%0h", tag, sa, exp_src));
    chk(da == 32'(dbase(c.ch) + exp_des), $sformatf("%s: DESADDR %08h expected base+%0h", tag, da, exp_des));
    chk(xs == 0 && ys == 0, $sformatf("%s: XSIZE %08h / YSIZE %08h not zero", tag, xs, ys));
  endtask

  task body();
    dma_cmd c;
    // 1D without wrap, X 5
    c = mk(0, 0, 0, 0, 5);
    init_src(c); drun(c, 5, "1D"); chk_end(c, 'h5, 'h5, "1D without wrap");
    if (!TB_EXT_MASK[0]) return;
    // 1D wrap, SX 5 DX 7: read address back at the line start
    c = mk(0, 0, 0, 0, 5);
    c.xtype = T_WRAP; c.desxsize = 7;
    init_src(c); drun(c, 7, "1D wrap"); chk_end(c, 'h0, 'h7, "1D wrap");
    // 2D continue, X 5 Y 3 stride 0x10
    c = mk(0, 0, 0, 0, 5);
    c.ytype = T_CONTINUE; c.srcysize = 3; c.desysize = 3; c.srcystride = 'h10; c.desystride = 'h10;
    init_src(c); drun(c, 15, "2D"); chk_end(c, 'h30, 'h30, "2D without wrap");
    // 2D Y wrap
    c.ytype = T_WRAP;
    init_src(c); drun(c, 15, "2D Y wrap"); chk_end(c, 'h0, 'h30, "2D Y wrap");
    // 2D X wrap + Y wrap, SX 5 DX 7
    c.xtype = T_WRAP; c.desxsize = 7;
    init_src(c); drun(c, 21, "2D XY wrap"); chk_end(c, 'h0, 'h30, "2D X wrap Y wrap");
  endtask
endclass
