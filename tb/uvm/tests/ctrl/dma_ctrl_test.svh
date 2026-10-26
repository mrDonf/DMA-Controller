//-----------------------------------------------------------------------------
// dma_ctrl_test.svh
//   Channel control: PAUSE / RESUME, STOP, DISABLE in a chain, all-channel pause / stop
//   (SW bits and HW handshakes), CTI halt / restart, CLEARCMD.
//-----------------------------------------------------------------------------
class dma_ctrl_test extends dma_ctrl_base;
  `uvm_component_utils(dma_ctrl_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task body();
    bit [31:0] st, v;
    dma_cmd c;
    int r0, w0;
    slow_mem(1);
    // ---------------- PAUSECMD / RESUMECMD
    c = simple(0, 4096, 3);
    init_src(c);
    start_cmd(c);
    repeat (300) @(posedge vif.clk);
    regs.chw(0, CH_CMD, 1 << 4);
    wait_status_bit(0, ST_PAUSED);
    regs.chr(0, CH_STATUS, st);
    if (!st[ST_RESUMEWAIT]) `uvm_error("TEST", "STAT_RESUMEWAIT not set after PAUSECMD")
    if (vif.ch_paused[0] !== 1'b1 || vif.ch_enabled[0] !== 1'b1) `uvm_error("TEST", "ch_paused / ch_enabled outputs")
    r0 = env.sb.n_rd_bursts; w0 = env.sb.n_wr_bursts;
    repeat (500) @(posedge vif.clk);
    if (env.sb.n_rd_bursts != r0 || env.sb.n_wr_bursts != w0) `uvm_error("TEST", "AXI traffic while paused")
    regs.chw(0, CH_CMD, 1 << 5);
    finish_cmd(c);
    // ---------------- STOPCMD
    c = simple(1 % TB_NCH, 4096, 3);
    init_src(c);
    void'(expect_cmd(c));
    env.sb.relax(c.ch);
    regs.program_cmd(c);
    regs.enable(c.ch);
    repeat (300) @(posedge vif.clk);
    regs.chw(c.ch, CH_CMD, 1 << 3);
    regs.wait_idle(c.ch, st);
    if (!st[ST_STOPPED] || st[ST_DONE] || vif.ch_stopped[c.ch] !== 1'b1)
      `uvm_error("TEST", $sformatf("STOPCMD: status %08h", st))
    regs.chr(c.ch, CH_CMD, v);
    if (v[3]) `uvm_error("TEST", "STOPCMD bit not cleared")
    regs.clear_status(c.ch);
    env.sb.unrelax(c.ch);
    n_cmds++;
    // ---------------- DISABLECMD in a command chain: the next command is not fetched
    begin
      dma_cmd c1;
      bit [31:0] w[$];
      c  = simple(2 % TB_NCH, 4096, 3);
      c1 = simple(2 % TB_NCH, 64, 0);
      c1.desaddr = c.desaddr + 'h10000;
      c.linkaddren = 1;
      c.linkaddr = dsc_base(c.ch);
      c1.descriptor(dma_cmd::full_header(TB_AW > 32), w);
      put_desc(c.linkaddr, w);
      init_src(c);
      start_cmd(c);
      repeat (300) @(posedge vif.clk);
      regs.chw(c.ch, CH_CMD, 1 << 2);
      finish_cmd(c, (1 << ST_DONE) | (1 << ST_DISABLED));
    end
    // ---------------- all channel pause (SW)
    c = simple(0, 4096, 3);
    init_src(c);
    start_cmd(c);
    repeat (200) @(posedge vif.clk);
    regs.wr(ufrm() + U_CTRL, 32'h0000_0200, uprot());
    begin
      int t = 0;
      do begin regs.rd(ufrm() + U_STATUS, v, uprot()); t++; repeat (20) @(posedge vif.clk); end
      while (!v[19] && t < 2000);
      if (!v[19]) `uvm_error("TEST", "STAT_ALLCHPAUSED not set")
    end
    if (vif.ch_paused[0] !== 1'b1) `uvm_error("TEST", "channel not paused by ALLCHPAUSE")
    regs.wr(ufrm() + U_STATUS, 32'h0008_0000, uprot());             // W1C -> resume
    finish_cmd(c);
    // ---------------- all channel pause (HW 4-phase)
    c = simple(0, 4096, 3);
    init_src(c);
    start_cmd(c);
    repeat (200) @(posedge vif.clk);
    if (TB_SECEXT) vif.allch_pause_req_sec <= 1'b1; else vif.allch_pause_req_nonsec <= 1'b1;
    begin
      int t = 0;
      while (!(TB_SECEXT ? vif.allch_pause_ack_sec : vif.allch_pause_ack_nonsec) && t < 20000) begin @(posedge vif.clk); t++; end
      if (t >= 20000) `uvm_error("TEST", "allch_pause_ack not asserted")
    end
    repeat (100) @(posedge vif.clk);
    if (TB_SECEXT) vif.allch_pause_req_sec <= 1'b0; else vif.allch_pause_req_nonsec <= 1'b0;
    repeat (10) @(posedge vif.clk);
    if ((TB_SECEXT ? vif.allch_pause_ack_sec : vif.allch_pause_ack_nonsec) !== 1'b0) `uvm_error("TEST", "pause ack not released")
    finish_cmd(c);
    // ---------------- all channel stop (SW and HW)
    for (int hw = 0; hw < 2; hw++) begin
      c = simple(1 % TB_NCH, 4096, 3);
      init_src(c);
      void'(expect_cmd(c));
      env.sb.relax(c.ch);
      regs.program_cmd(c);
      regs.enable(c.ch);
      repeat (200) @(posedge vif.clk);
      if (!hw) regs.wr(ufrm() + U_CTRL, 32'h0000_0100, uprot());
      else if (TB_SECEXT) vif.allch_stop_req_sec <= 1'b1;
      else vif.allch_stop_req_nonsec <= 1'b1;
      regs.wait_idle(c.ch, st);
      if (!st[ST_STOPPED]) `uvm_error("TEST", $sformatf("all channel stop (%0d): status %08h", hw, st))
      if (!hw) begin
        regs.rd(ufrm() + U_STATUS, v, uprot());
        if (!v[18]) `uvm_error("TEST", "STAT_ALLCHSTOPPED not set")
        regs.wr(ufrm() + U_STATUS, 32'h0004_0000, uprot());
      end else begin
        repeat (10) @(posedge vif.clk);
        if ((TB_SECEXT ? vif.allch_stop_ack_sec : vif.allch_stop_ack_nonsec) !== 1'b1) `uvm_error("TEST", "allch_stop_ack")
        if (TB_SECEXT) vif.allch_stop_req_sec <= 1'b0; else vif.allch_stop_req_nonsec <= 1'b0;
        repeat (10) @(posedge vif.clk);
      end
      regs.clear_status(c.ch);
      env.sb.unrelax(c.ch);
      n_cmds++;
    end
    // ---------------- CTI halt / restart
    begin
      bit halted_seen = 0;
      regs.rd(ufrm() + U_CTRL, v, uprot());
      regs.wr(ufrm() + U_CTRL, v | (1 << 28), uprot());              // DBGHALTEN
      c = simple(0, 4096, 3);
      init_src(c);
      start_cmd(c);
      repeat (200) @(posedge vif.clk);
      vif.halt_req <= 1'b1;
      fork
        begin repeat (20000) begin @(posedge vif.clk); if (vif.halted) halted_seen = 1; if (halted_seen) break; end end
      join
      if (!halted_seen) `uvm_error("TEST", "CTI halted pulse not seen")
      if (vif.ch_paused[0] !== 1'b1) `uvm_error("TEST", "channel not paused by the CTI halt")
      vif.halt_req <= 1'b0;
      repeat (50) @(posedge vif.clk);
      vif.restart_req <= 1'b1;
      repeat (4) @(posedge vif.clk);
      vif.restart_req <= 1'b0;
      finish_cmd(c);
    end
    // ---------------- CLEARCMD
    c = simple(0, 64);
    init_src(c);
    run_cmd(c);
    regs.chw(0, CH_CMD, 1 << 1);
    repeat (5) @(posedge vif.clk);
    regs.chr(0, CH_CTRL, v);
    if (v != 32'h0020_0200) `uvm_error("TEST", $sformatf("CLEARCMD: CH_CTRL = %08h", v))
    regs.chr(0, CH_SRCADDR, v);
    if (v != 0) `uvm_error("TEST", "CLEARCMD: CH_SRCADDR not cleared")
    slow_mem(0);
  endtask
endclass
