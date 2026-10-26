//-----------------------------------------------------------------------------
// dma_stream_test.svh
//   AXI-Stream: stream out only, stream in only, in & out through the engine model,
//   1D / 2D, early TLAST with continue / fill.
//-----------------------------------------------------------------------------
class dma_stream_test extends dma_feat_base;
  `uvm_component_utils(dma_stream_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function dma_cmd stream_cmd(int ch, bit [1:0] st);
    dma_cmd c;
    int kind = $urandom_range(0, 3);
    c = gen_cmd(ch, (kind == 3) ? 2 : 0);
    c.use_stream = 1;
    c.streamtype = st;
    c.srctsize = 0; c.destsize = 0;
    if (!TB_EXT_MASK[ch]) begin c.xtype = T_CONTINUE; c.ytype = T_DISABLE; void'(place(c)); return c; end
    if (c.is2d()) begin
      c.xtype = T_CONTINUE;
      c.ytype = $urandom_range(0, 1) ? T_CONTINUE : T_FILL;
      if (c.ytype == T_FILL && c.desxsize * c.desysize < c.srcxsize * c.srcysize) c.ytype = T_CONTINUE;
    end else if (st != SM_OUT && $urandom_range(2) == 0) begin
      c.xtype = T_FILL;
      if (c.desxsize < c.srcxsize) c.desxsize = c.srcxsize;
    end
    // in & out: the engine returns as many bytes as it received; more data
    // than destination space would be a (correct) STRINOVERRUN error
    if (st == SM_INOUT) begin
      if (c.is2d()) while (c.desxsize * c.desysize < c.srcxsize * c.srcysize) c.desysize++;
      else if (c.desxsize < c.srcxsize) c.desxsize = c.srcxsize;
    end
    void'(place(c));
    return c;
  endfunction

  task body();
    int chs[$];
    for (int c = 0; c < TB_NCH; c++) if (TB_STREAM_MASK[c]) chs.push_back(c);
    if (chs.size() == 0) begin `uvm_info("TEST", "no stream channel: skipped", UVM_NONE) return; end
    for (int k = 0; k < 24; k++) begin
      int ch = chs[k % chs.size()];
      bit [1:0] st = (k % 3 == 0) ? SM_OUT : (k % 3 == 1) ? SM_IN : SM_INOUT;
      dma_cmd c = stream_cmd(ch, st);
      byte unsigned si[$];
      dma_exp e0;
      int esz = c.esize();
      env.so_cfg[ch].ready_mode = AXIS_RDY_RANDOM;
      init_src(c);
      if (st == SM_IN) begin
        // packet of random length (multiple of the element size)
        int cap = c.desxsize * (c.is2d() ? c.desysize : 1);
        int n = $urandom_range(1, cap);
        if ($urandom_range(3) == 0) n = cap;
        for (int i = 0; i < n * esz; i++) si.push_back($urandom);
      end else if (st == SM_INOUT) begin
        e0 = dma_ref_model::predict(c, env.mem, si);
        env.eng[ch].enable = 1;
        env.eng[ch].esz = esz;
        env.eng[ch].shrink_elems = ($urandom_range(2) == 0) ? $urandom_range(0, e0.so_bytes.size() / esz - 1) : 0;
        dma_stream_engine::xform(e0.so_bytes, env.eng[ch].xor_key, env.eng[ch].shrink_elems * esz, si);
      end
      `uvm_info("STREAM", $sformatf("type=%0d si_bytes=%0d : %s", st, si.size(), c.convert2string()), UVM_LOW)
      start_cmd(c, si);
      if (st == SM_IN) begin
        dma_axis_send_seq s = new("si_pkt");
        s.payload = si;
        s.start(env.si[ch].sqr);
      end
      finish_cmd(c);
      env.eng[ch].enable = 0;
    end
  endtask
endclass
