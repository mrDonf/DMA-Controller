//-----------------------------------------------------------------------------
// dma_dir_tmplt_test.svh
//   Directed templates: TRM figure 5-14, destination templates, template + wrap / fill.
//-----------------------------------------------------------------------------
class dma_dir_tmplt_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_tmplt_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_cmd c;
    int off [12] = '{0, 2, 3, 6, 8, 10, 11, 14, 16, 18, 19, 22};
    if (!TB_EXT_MASK[0]) begin `uvm_info("TEST", "no template support: skipped", UVM_NONE) return; end
    // ---- Figure 5-14
    c = mk(0, 0, 'h011, 'h014, 12);
    c.srctmplt = 32'h4D; c.srctsize = 7;
    c.destmplt = 32'h0F; c.destsize = 3;
    init_src(c);
    drun(c, 12, "fig5-14");
    for (int k = 0; k < 12; k++) chk(m(c.desaddr + k) == m(c.srcaddr + off[k]), $sformatf("fig5-14 element %0d", k));
    // ---- destination template, wider elements
    for (int ts = 1; ts <= $clog2(TB_DWB); ts++) begin
      c = mk(0, ts, 'h100, 'h300, 9);
      c.destmplt = 32'h8000_0011; c.destsize = 31;
      init_src(c);
      drun(c, 9 * (1 << ts), $sformatf("destination template ts=%0d", ts));
      chk(m(c.desaddr + 4 * (1 << ts)) == m(c.srcaddr + (1 << ts)), "template element 1 at position 4");
    end
    // ---- template with 1D wrap / fill
    c = mk(0, 1, 'h500, 'h600, 5);
    c.xtype = T_WRAP; c.desxsize = 12; c.srctmplt = 32'h5; c.srctsize = 3;
    init_src(c);
    drun(c, 24, "template + wrap");
    c = mk(0, 2, 'h700, 'h800, 4);
    c.xtype = T_FILL; c.desxsize = 7; c.destmplt = 32'h3; c.destsize = 2;
    init_src(c);
    drun(c, 28, "template + fill");
  endtask
endclass
