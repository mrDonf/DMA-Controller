//-----------------------------------------------------------------------------
// dma_trig_cmd_test.svh
//   Command triggers: HW / SW source and destination, trigger output HW / SW,
//   internal channel-to-channel trigger.
//-----------------------------------------------------------------------------
class dma_trig_cmd_test extends dma_feat_base;
  `uvm_component_utils(dma_trig_cmd_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task check_no_traffic(int cycles);
    int r0 = env.sb.n_rd_bursts, w0 = env.sb.n_wr_bursts;
    repeat (cycles) @(posedge vif.clk);
    if (env.sb.n_rd_bursts != r0 || env.sb.n_wr_bursts != w0)
      `uvm_error("TEST", "AXI traffic while waiting for a command trigger")
  endtask

  task body();
    bit [1:0] at;
    bit [31:0] st;
    if (TB_NTI == 0) begin `uvm_info("TEST", "no trigger inputs: skipped", UVM_NONE) return; end
    env.trig.async_mode = $test$plusargs("TRIG_ASYNC");
    for (int q = 0; q < TB_NTO; q++) env.trig.out_auto_ack[q] = 1;

    // 1. HW source command trigger
    for (int k = 0; k < 4; k++) begin
      int ch = k % TB_NCH;
      int p  = $urandom_range(0, TB_NTI - 1);
      dma_cmd c = simple(ch, $urandom_range(32, 512));
      c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_mode = TM_CMD; c.srctrig_sel = p;
      init_src(c);
      start_cmd(c);
      wait_status_bit(ch, ST_SRCTRIGWAIT);
      check_no_traffic(200);
      env.trig.in_req(p, $urandom_range(0, 3), at);
      if (at != AK_OKAY) `uvm_error("TEST", $sformatf("command trigger ack type %0b", at))
      finish_cmd(c);
    end
    // 2. SW source + destination command triggers
    for (int k = 0; k < 2; k++) begin
      int ch = (k + 1) % TB_NCH;
      dma_cmd c = simple(ch, 200);
      c.use_srctrig = 1; c.srctrig_type = TT_SW;
      c.use_destrig = 1; c.destrig_type = TT_SW;
      init_src(c);
      start_cmd(c);
      wait_status_bit(ch, ST_DESTRIGWAIT);
      regs.chw(ch, CH_CMD, (1 << 20) | (2'b10 << 21));        // destination SW request (block)
      check_no_traffic(100);
      regs.chw(ch, CH_CMD, (1 << 16));                        // source SW request
      finish_cmd(c);
    end
    // 3. HW source + destination command triggers, destination first
    if (TB_NTI >= 2) begin
      dma_cmd c = simple(0, 300);
      c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 0;
      c.use_destrig = 1; c.destrig_type = TT_HW; c.destrig_sel = 1;
      init_src(c);
      start_cmd(c);
      fork
        env.trig.in_req(1, RQ_BLOCK, at);
        begin repeat (300) @(posedge vif.clk); env.trig.in_req(0, RQ_SINGLE, at); end
      join
      finish_cmd(c);
    end
    // 4. trigger out: HW (auto acknowledged) and SW
    if (TB_NTO > 0) begin
      int q = $urandom_range(0, TB_NTO - 1);
      int n0 = env.trig.n_out_hs.exists(q) ? env.trig.n_out_hs[q] : 0;
      dma_cmd c = simple(2 % TB_NCH, 128);
      c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = q;
      init_src(c);
      run_cmd(c);
      if (env.trig.n_out_hs[q] != n0 + 1) `uvm_error("TEST", "trigger output handshake not seen")
    end
    begin
      dma_cmd c = simple(3 % TB_NCH, 64);
      c.use_trigout = 1; c.trigout_type = TT_SW;
      init_src(c);
      start_cmd(c);
      wait_status_bit(c.ch, ST_TRIGOUTWAIT);
      if (vif.ch_enabled[c.ch] !== 1'b1) `uvm_error("TEST", "channel finished before the SW trigger ack")
      regs.chw(c.ch, CH_CMD, 1 << 24);                        // SWTRIGOUTACK
      finish_cmd(c);
    end
    // 5. internal trigger: ch A trigger out -> ch B source command trigger
    if (TB_NCH > 1) begin
      dma_cmd a = simple(0, 256);
      dma_cmd b = simple(1, 256);
      a.use_trigout = 1; a.trigout_type = TT_INT;
      b.use_srctrig = 1; b.srctrig_type = TT_INT; b.srctrig_sel = 0;
      init_src(a); init_src(b);
      start_cmd(b);
      wait_status_bit(1, ST_SRCTRIGWAIT);
      check_no_traffic(100);
      start_cmd(a);
      finish_cmd(a);
      finish_cmd(b);
    end
  endtask
endclass
