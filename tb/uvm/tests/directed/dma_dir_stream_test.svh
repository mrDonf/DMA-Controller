//-----------------------------------------------------------------------------
// dma_dir_stream_test.svh
//   Directed AXI-Stream cases of TRM 5.5.
//-----------------------------------------------------------------------------
class dma_dir_stream_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_stream_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task send(int ch, byte unsigned q[$]);
    dma_axis_send_seq s = new("pkt");
    s.payload = q;
    s.start(env.si[ch].sqr);
  endtask

  task body();
    dma_cmd c;
    byte unsigned si[$];
    int ch = -1;
    for (int k = 0; k < TB_NCH; k++) if (TB_STREAM_MASK[k] && ch < 0) ch = k;
    if (ch < 0) begin `uvm_info("TEST", "no stream channel: skipped", UVM_NONE) return; end
    // ---- stream out only: source -> str_out, no writes
    c = mk(ch, 0, 'h3, 0, 100);
    c.use_stream = 1; c.streamtype = SM_OUT;
    init_src(c);
    drun(c, 0, "stream out only");
    // ---- stream in only, exact length
    si.delete(); for (int i = 0; i < 64; i++) si.push_back(i * 3);
    c = mk(ch, 0, 0, 'h105, 64);
    c.use_stream = 1; c.streamtype = SM_IN;
    void'(expect_cmd(c, si)); regs.program_cmd(c); regs.enable(ch); send(ch, si); finish_cmd(c);
    for (int i = 0; i < 64; i++) chk(m(c.desaddr + i) == si[i], $sformatf("stream in byte %0d", i));
    // ---- BUG-06: the packet (one beat with TLAST) is pending before ENABLECMD,
    //      so it is accepted in the very first cycle of the transfer state
    for (int k = 0; k < 3; k++) begin
      si.delete(); for (int i = 0; i < 4 * (k + 1); i++) si.push_back(8'h40 + i);
      c = mk(ch, 2, 0, 'h1000 + 'h40 * k, 7);
      c.use_stream = 1; c.streamtype = SM_IN;
      void'(expect_cmd(c, si));
      regs.program_cmd(c);
      fork send(ch, si); join_none
      repeat (30) @(posedge vif.clk);
      regs.enable(ch);
      finish_cmd(c);
    end
    // ---- stream in shorter than the destination: continue stops, fill pads
    for (int xt = T_CONTINUE; xt <= T_FILL; xt += 2) begin
      int w0 = env.sb.n_wr_bytes;
      si.delete(); for (int i = 0; i < 40; i++) si.push_back(8'h80 + i);
      c = mk(ch, 1, 0, 'h300, 0);
      c.desxsize = 32; c.xtype = xt;
      c.use_stream = 1; c.streamtype = SM_IN;
      void'(expect_cmd(c, si)); regs.program_cmd(c); regs.enable(ch); send(ch, si); finish_cmd(c);
      chk(env.sb.n_wr_bytes - w0 == ((xt == T_FILL) ? 64 : 40),
          $sformatf("early TLAST x=%0d: %0d bytes written", xt, env.sb.n_wr_bytes - w0));
      if (xt == T_FILL) chk(m(c.desaddr + 62) == c.fillval[7:0] && m(c.desaddr + 63) == c.fillval[15:8], "fill after TLAST");
    end
    // ---- in & out through the external engine (identity), 2D continue / fill
    begin
      dma_exp e0;
      c = mk(ch, 0, 'h500, 'h600, 7);
      c.ytype = T_FILL; c.srcysize = 5; c.desxsize = 8; c.desysize = 6;
      c.srcystride = 16; c.desystride = 16;
      c.use_stream = 1; c.streamtype = SM_INOUT;
      init_src(c);
      e0 = dma_ref_model::predict(c, env.mem, si);
      env.eng[ch].enable = 1; env.eng[ch].esz = 1; env.eng[ch].shrink_elems = 0; env.eng[ch].xor_key = 0;
      si = e0.so_bytes;
      drun(c, 48, "stream in & out 2D", si);
      env.eng[ch].enable = 0;
      env.eng[ch].xor_key = 8'h5A;
    end
  endtask
endclass
