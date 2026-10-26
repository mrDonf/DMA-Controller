//-----------------------------------------------------------------------------
// dma_dir_1d_test.svh
//   Directed 1D: TRM figures 5-1 / 5-3 / 5-4, TRANSIZE x alignment x size sweep,
//   1KB crossing, 32-bit XSIZE.
//-----------------------------------------------------------------------------
class dma_dir_1d_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_1d_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_cmd c;
    longint unsigned s, d;
    // ---- Figure 5-1: SRCADDR 0x011, bytes, SRCXSIZE 23, DESADDR 0x014
    c = mk(0, 0, 'h011, 'h014, 23);
    init_src(c);
    drun(c, 23, "fig5-1");
    for (int i = 0; i < 23; i++) chk(m(c.desaddr + i) == m(c.srcaddr + i), $sformatf("fig5-1 byte %0d", i));
    // ---- Figure 5-3: increments 2 / 4
    c = mk(0, 0, 'h011, 'h014, 12);
    c.srcxinc = 2; c.desxinc = 4;
    init_src(c);
    drun(c, 12, "fig5-3");
    for (int k = 0; k < 12; k++) chk(m(c.desaddr + 4 * k) == m(c.srcaddr + 2 * k), $sformatf("fig5-3 element %0d", k));
    // ---- Figure 5-4: source increment 0, destination increment -3
    c = mk(0, 0, 'h011, 'h040, 4);
    c.srcxinc = 0; c.desxinc = 16'hFFFD;
    init_src(c);
    drun(c, 4, "fig5-4");
    chk(m(dbase(0) + 'h40) == m(sbase(0) + 'h11), "fig5-4 @0x40");
    chk(m(dbase(0) + 'h3D) == m(sbase(0) + 'h11), "fig5-4 @0x3D");
    chk(m(dbase(0) + 'h3A) == m(sbase(0) + 'h11), "fig5-4 @0x3A");
    chk(m(dbase(0) + 'h37) == m(sbase(0) + 'h11), "fig5-4 @0x37");
    // ---- sweep: every TRANSIZE x start / end alignment x size x memory type
    for (int ts = 0; ts <= $clog2(TB_DWB); ts++) begin
      int esz = 1 << ts;
      int nel = TB_DWB / esz;
      int offs[$], sizes[$];
      offs = '{0, esz, TB_DWB / 2, TB_DWB - esz};
      sizes = '{1, 2, nel - 1, nel, nel + 1, 3 * nel + 1, 37};
      foreach (offs[i]) foreach (sizes[j]) for (int dsel = 0; dsel < 2; dsel++) begin
        int n = sizes[j];
        if (n < 1) continue;
        if (i > 0 && offs[i] == offs[i - 1]) continue;
        c = mk(dsel % TB_NCH, ts, offs[i] + 'h100 * j, (dsel ? (TB_DWB - esz) : 0) + 'h100 * j, n, (i + j + dsel) % 3 != 0);
        c.src_maxburst = (j * 5 + i) % 16;
        c.des_maxburst = (j * 3 + i + dsel) % 16;
        init_src(c);
        drun(c, n * esz, $sformatf("sweep ts=%0d so=%0d n=%0d", ts, offs[i], n));
      end
    end
    // ---- 1KB boundary crossing source and destination
    c = mk(1 % TB_NCH, 0, 'h3F3, 'h7E1, 200);
    init_src(c);
    drun(c, 200, "1KB crossing");
    // ---- 32-bit XSIZE (XSIZEHI): 65552 bytes
    c = mk(2 % TB_NCH, 0, 'h3, 'h5, 32'h0001_0010);
    init_src(c);
    drun(c, 32'h0001_0010, "XSIZEHI");
  endtask
endclass
