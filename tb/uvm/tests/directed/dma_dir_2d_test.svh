//-----------------------------------------------------------------------------
// dma_dir_2d_test.svh
//   Directed 2D: TRM figures 5-5 / 5-6 / 5-7 (mirror, rotations), table 5-3 corner
//   cases, the 5.3.2.2 reshaping cases.
//-----------------------------------------------------------------------------
class dma_dir_2d_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_2d_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task body();
    dma_cmd c;
    int ch = 0;
    if (!TB_EXT_MASK[ch]) begin `uvm_info("TEST", "no 2D support: skipped", UVM_NONE) return; end
    // ---- Figure 5-5: 9 x 8 block, strides 0x18
    c = mk(ch, 0, 'h3, 'h5, 9);
    c.ytype = T_CONTINUE; c.srcysize = 8; c.desysize = 8; c.srcystride = 'h18; c.desystride = 'h18;
    init_src(c);
    drun(c, 72, "fig5-5");
    for (int y = 0; y < 8; y++) for (int x = 0; x < 9; x++)
      chk(m(c.desaddr + y * 'h18 + x) == m(c.srcaddr + y * 'h18 + x), $sformatf("fig5-5 (%0d,%0d)", x, y));
    // ---- Figure 5-6: source increment 2, destination FIFO (inc 0), stride -48
    c = mk(ch, 0, 'h10, 'h400, 5);
    c.ytype = T_CONTINUE; c.srcysize = 3; c.desysize = 3;
    c.srcxinc = 2; c.desxinc = 0; c.srcystride = 24; c.desystride = 16'hFFD0;
    init_src(c);
    drun(c, 15, "fig5-6");
    for (int y = 0; y < 3; y++)
      chk(m(c.desaddr - 48 * y) == m(c.srcaddr + 24 * y + 8), $sformatf("fig5-6 line %0d last element", y));
    // ---- Figure 5-7: mirroring and rotations of an 8 x 8 byte block
    begin
      int dxi [4] = '{-1, 8, -1, -8};
      int dys [4] = '{ 8, -1, -8,  1};
      int dof [4] = '{ 7,  7, 63, 56};
      string nm [4] = '{"mirror", "rot90", "rot180", "rot270"};
      for (int t = 0; t < 4; t++) begin
        c = mk(ch, 0, 'h40, 'h400 + dof[t], 8);
        c.ytype = T_CONTINUE; c.srcysize = 8; c.desysize = 8; c.srcystride = 8;
        c.desxinc = 16'(dxi[t]); c.desystride = 16'(dys[t]);
        init_src(c);
        drun(c, 64, nm[t]);
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++)
          chk(m(longint'(c.desaddr) + x * dxi[t] + y * dys[t]) == m(c.srcaddr + y * 8 + x),
              $sformatf("%s (%0d,%0d)", nm[t], x, y));
      end
    end
    // ---- Table 5-3: zero / non-zero size corner cases
    begin
      int v [3] = '{0, 1, 3};
      for (int a = 0; a < 3; a++) for (int b = 0; b < 3; b++) for (int cc = 0; cc < 3; cc++) for (int dd = 0; dd < 3; dd++)
      for (int yt = T_CONTINUE; yt <= T_FILL; yt += 2) begin
        int sx = v[a] * 2, sy = v[b], dx = v[cc] * 2, dy = v[dd];
        bit sempty = (sx == 0 || sy == 0), dempty = (dx == 0 || dy == 0);
        int exp;
        if ((a == 0 || b == 0 || cc == 0 || dd == 0) == 0) continue;     // only the corner cases here
        c = mk(ch, 0, 'h100, 'h300, 0);
        c.ytype = yt; c.srcxsize = sx; c.srcysize = sy; c.desxsize = dx; c.desysize = dy;
        c.srcystride = 'h10; c.desystride = 'h10;
        if (yt == T_FILL && !sempty && dx * dy < sx * sy) continue;
        init_src(c);
        // table 5-3: no transfer, or write only (fill) when the source is empty
        exp = dempty ? 0 : (sempty ? ((yt == T_FILL) ? dx * dy : 0) : -1);
        drun(c, exp, $sformatf("tbl5-3 sx=%0d sy=%0d dx=%0d dy=%0d y=%0d", sx, sy, dx, dy, yt));
      end
    end
    // ---- 5.3.2.2: every X/Y type over source / destination shape relations
    begin
      int shp [9][2] = '{'{9, 8}, '{9, 6}, '{9, 10}, '{6, 8}, '{6, 12}, '{8, 9}, '{12, 8}, '{12, 6}, '{12, 10}};
      foreach (shp[k]) for (int xt = T_CONTINUE; xt <= T_FILL; xt++) for (int yt = T_CONTINUE; yt <= T_FILL; yt++) begin
        int dx = shp[k][0], dy = shp[k][1];
        // UNPREDICTABLE configurations of the TRM are not run
        if (xt != T_CONTINUE && dx < 9) continue;
        if (yt != T_CONTINUE && xt != T_CONTINUE && dy < 8) continue;
        if (yt != T_CONTINUE && xt == T_CONTINUE && dx * dy < 72) continue;
        c = mk(ch, (k % 2), 'h100, 'h200, 9);
        c.xtype = xt; c.ytype = yt; c.srcysize = 8; c.desxsize = dx; c.desysize = dy;
        c.srcystride = 9; c.desystride = 16'(dx + 3);
        init_src(c);
        drun(c, -1, $sformatf("5.3.2.2 9x8 -> %0dx%0d x=%0d y=%0d", dx, dy, xt, yt));
      end
    end
  endtask
endclass
