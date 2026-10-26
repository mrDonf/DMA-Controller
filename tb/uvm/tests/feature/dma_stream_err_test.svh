//-----------------------------------------------------------------------------
// dma_stream_err_test.svh
//   Stream errors: invalid TSTRB, overrun (flush), early stream-in termination.
//-----------------------------------------------------------------------------
class dma_stream_err_test extends dma_feat_base;
  `uvm_component_utils(dma_stream_err_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task check_err(int ch, bit [31:0] bits);
    bit [31:0] st, ei;
    regs.wait_idle(ch, st);
    regs.chr(ch, CH_ERRINFO, ei);
    if (!st[ST_ERR] || (ei & bits) != bits)
      `uvm_error("TEST", $sformatf("ch%0d stream error expected %08h: status %08h errinfo %08h", ch, bits, st, ei))
    env.sb.relax(ch);
    regs.clear_status(ch);
    env.sb.unrelax(ch);
    env.sb.clear_reads(ch);
    n_cmds++;
  endtask

  task body();
    int ch = -1;
    for (int c = 0; c < TB_NCH; c++) if (TB_STREAM_MASK[c] && ch < 0) ch = c;
    if (ch < 0) begin `uvm_info("TEST", "no stream channel: skipped", UVM_NONE) return; end
    // 1. invalid TSTRB in the middle of the packet
    `uvm_info("STRERR", "1: invalid TSTRB", UVM_LOW)
    begin
      dma_cmd c = simple(ch, 256, 0);
      dma_axis_send_seq s = new("bad");
      c.use_stream = 1; c.streamtype = SM_IN;
      for (int i = 0; i < 64; i++) s.payload.push_back(i);
      void'(expect_cmd(c, s.payload));
      env.sb.relax(ch);
      regs.program_cmd(c);
      regs.enable(ch);
      s.bad_beat = 2;
      s.start(env.si[ch].sqr);
      check_err(ch, 32'h0008_0080);
    end
    // 2. overrun: more stream data than destination space (flush expected)
    `uvm_info("STRERR", "2: overrun", UVM_LOW)
    begin
      dma_cmd c = simple(ch, 64, 0);
      dma_axis_send_seq s = new("long");
      bit flush_seen = 0;
      c.use_stream = 1; c.streamtype = SM_IN;
      for (int i = 0; i < 400; i++) s.payload.push_back(i);
      void'(expect_cmd(c, s.payload));
      env.sb.relax(ch);
      regs.program_cmd(c);
      regs.enable(ch);
      fork
        s.start(env.si[ch].sqr);
        begin
          repeat (5000) begin @(posedge vif.clk); if (vif.str_in_flush[ch]) flush_seen = 1; end
        end
      join
      if (!flush_seen) `uvm_error("TEST", "str_in_flush not asserted on overrun")
      check_err(ch, 32'h0010_0080);
    end
    // 3. early termination of stream in (in & out mode)
    `uvm_info("STRERR", "3: early termination", UVM_LOW)
    begin
      dma_cmd c = simple(ch, 512, 0);
      dma_axis_send_seq s = new("early");
      c.use_stream = 1; c.streamtype = SM_INOUT;
      for (int i = 0; i < 16; i++) s.payload.push_back(i);
      init_src(c);
      env.so_cfg[ch].ready_mode = AXIS_RDY_NEVER;
      void'(expect_cmd(c, s.payload));
      env.sb.relax(ch);
      regs.program_cmd(c);
      regs.enable(ch);
      repeat (100) @(posedge vif.clk);
      s.start(env.si[ch].sqr);
      repeat (300) @(posedge vif.clk);
      env.so_cfg[ch].ready_mode = AXIS_RDY_ALWAYS;
      check_err(ch, 32'h0020_0080);
    end
  endtask
endclass
