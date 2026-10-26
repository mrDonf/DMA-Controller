//-----------------------------------------------------------------------------
// dma_dir_wrap1d_test.svh
//   Directed 1D WRAP: every case of TRM 5.2.2 incl. the FIFO destination example.
//-----------------------------------------------------------------------------
class dma_dir_wrap1d_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_wrap1d_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // number of destination elements written (TRM 5.2.2)
  function int writes(bit [2:0] xt, int sx, int dx);
    if (dx == 0) return 0;
    if (sx == 0) return (xt == T_FILL) ? dx : 0;
    if (xt == T_CONTINUE) return (sx < dx) ? sx : dx;
    return dx;
  endfunction

  task body();
    dma_cmd c;
    int ch = 0;
    int pairs[$][2];
    if (!TB_EXT_MASK[ch]) begin `uvm_info("TEST", "no extended features: skipped", UVM_NONE) return; end
    pairs = '{'{0, 0}, '{0, 9}, '{11, 0}, '{9, 9}, '{13, 6}, '{5, 17}, '{1, 8}, '{8, 1}};
    for (int xt = T_CONTINUE; xt <= T_FILL; xt++) foreach (pairs[k]) begin
      int sx = pairs[k][0], dx = pairs[k][1];
      for (int ts = 0; ts <= 1; ts++) begin
        c = mk(ch, ts, 'h21 + k * 'h100, 'h47 + k * 'h100, 0);
        c.xtype = xt; c.srcxsize = sx; c.desxsize = dx;
        init_src(c);
        drun(c, writes(xt, sx, dx) * (1 << ts), $sformatf("1Dwrap x=%0d sx=%0d dx=%0d", xt, sx, dx));
        // explicit content check
        for (int i = 0; i < writes(xt, sx, dx); i++) begin
          bit fill = (xt == T_FILL) && (i >= sx);
          int  si  = (xt == T_WRAP) ? (i % sx) : i;
          for (int b = 0; b < (1 << ts); b++)
            chk(m((c.desaddr & ~longint'((1 << ts) - 1)) + i * (1 << ts) + b) ==
                (fill ? c.fillval[8 * b +: 8] : m((c.srcaddr & ~longint'((1 << ts) - 1)) + si * (1 << ts) + b)),
                $sformatf("1Dwrap x=%0d sx=%0d dx=%0d element %0d", xt, sx, dx, i));
        end
      end
    end
    // ---- DESXADDRINC = 0 (FIFO destination), SRCXSIZE 3, DESXSIZE 8
    for (int xt = T_CONTINUE; xt <= T_FILL; xt++) begin
      c = mk(ch, 0, 'h800, 'h900, 0);
      c.xtype = xt; c.srcxsize = 3; c.desxsize = 8; c.desxinc = 0;
      init_src(c);
      drun(c, writes(xt, 3, 8), $sformatf("FIFO destination x=%0d", xt));
      case (xt)
        T_CONTINUE: chk(m(c.desaddr) == m(c.srcaddr + 2), "FIFO continue: last = src[2]");
        T_WRAP:     chk(m(c.desaddr) == m(c.srcaddr + 1), "FIFO wrap: last = src[1] (src 0 1 2 0 1 2 0 1)");
        T_FILL:     chk(m(c.desaddr) == c.fillval[7:0], "FIFO fill: last = fill value");
      endcase
    end
  endtask
endclass
