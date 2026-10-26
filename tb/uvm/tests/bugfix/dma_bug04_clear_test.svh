//-----------------------------------------------------------------------------
// dma_bug04_clear_test.svh
//   BUG-04: CLEARCMD / security change clear status, work registers and pending
//   pause / disable requests.
//-----------------------------------------------------------------------------
class dma_bug04_clear_test extends dma_dir_base;
  `uvm_component_utils(dma_bug04_clear_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task check_clean(int ch, string tag);
    bit [31:0] v;
    regs.chr(ch, CH_STATUS, v);
    chk(v == 0, $sformatf("%s: CH_STATUS %08h not cleared", tag, v));
    regs.chr(ch, CH_ERRINFO, v);
    chk(v == 0, $sformatf("%s: CH_ERRINFO %08h not cleared", tag, v));
    regs.chr(ch, CH_WRKREGPTR, v);
    chk(v == 0, $sformatf("%s: CH_WRKREGPTR %08h not cleared", tag, v));
    for (int p = 1; p <= 12; p++) begin
      regs.chw(ch, CH_WRKREGPTR, p);
      regs.chr(ch, CH_WRKREGVAL, v);
      chk(v == 0, $sformatf("%s: work register %0d = %08h still visible", tag, p, v));
    end
    regs.chw(ch, CH_WRKREGPTR, 0);
    chk(vif.ch_err[ch] === 1'b0 && vif.ch_stopped[ch] === 1'b0, $sformatf("%s: ch_err / ch_stopped outputs", tag));
    chk(vif.irq_channel[ch] === 1'b0, $sformatf("%s: channel interrupt still pending", tag));
  endtask

  task body();
    dma_cmd c;
    bit [31:0] v, st;
    // ---------------- Secure command, then the channel becomes Non-secure
    if (TB_SECEXT) begin
      c = mk(0, 2, 'h123, 'h456, 40);
      c.intren = 11'h003;
      init_src(c);
      drun(c, 160, "secure command");
      regs.chw(0, CH_WRKREGPTR, 1);
      regs.chr(0, CH_WRKREGVAL, v);
      chk(v != 0, "work register SRCADDR_INITIAL expected non-zero after a command");
      // errored command so that STAT_ERR / ERRINFO / ch_err are set
      c = mk(0, 0, 0, 0, 4); c.xtype = 3'b111; c.intren = 11'h002;
      set_attr_exp(c); regs.program_cmd(c); regs.enable(0); regs.wait_idle(0, st);
      chk(st[ST_ERR], "errored command did not set STAT_ERR");
      regs.set_ch_attr(0, 1, 0);                                      // -> Non-secure
      check_clean(0, "BUG-04 security change");
      regs.set_ch_attr(0, 0, 0);
    end
    // ---------------- CLEARCMD after an error
    c = mk(0, 0, 0, 0, 4); c.xtype = 3'b111; c.intren = 11'h002;
    set_attr_exp(c); regs.program_cmd(c); regs.enable(0); regs.wait_idle(0, st);
    regs.chw(0, CH_WRKREGPTR, 5);
    regs.chw(0, CH_CMD, 32'h2);                                       // CLEARCMD
    repeat (5) @(posedge vif.clk);
    check_clean(0, "BUG-04 CLEARCMD");
    // ---------------- STOP during a done-pause: the next command is not paused
    slow_mem(0);
    c = mk(0, 1, 'h800, 'h800, 32);
    c.restartcnt = 1; c.regreload = 3'b111; c.donetype = 3'b011; c.donepause = 1;
    init_src(c);
    void'(expect_cmd(c));
    env.sb.relax(0);
    regs.program_cmd(c);
    regs.enable(0);
    wait_status_bit(0, ST_RESUMEWAIT);
    regs.chw(0, CH_CMD, 1 << 3);                                      // STOPCMD while done-paused
    regs.wait_idle(0, st);
    chk(st[ST_STOPPED], $sformatf("stop during done-pause: status %08h", st));
    regs.clear_status(0);
    env.sb.unrelax(0);
    c = mk(0, 0, 'hA00, 'hA00, 64);
    init_src(c);
    void'(expect_cmd(c));
    regs.program_cmd(c);
    regs.enable(0);
    regs.wait_idle(0, st, 20000);
    chk((st & 32'h00FF_0000) == (1 << ST_DONE), $sformatf("BUG-04: command after a stopped done-pause: status %08h", st));
    void'(env.sb.check_done(0, tname));
    regs.clear_status(0);
    // ---------------- STOP while PAUSECMD and DISABLECMD are pending
    slow_mem(1);
    c = mk(0, $clog2(TB_DWB), 'hC00, 'hC00, 128);
    init_src(c);
    void'(expect_cmd(c));
    env.sb.relax(0);
    regs.program_cmd(c);
    regs.enable(0);
    repeat (100) @(posedge vif.clk);
    regs.chw(0, CH_CMD, (1 << 4) | (1 << 2));                         // PAUSECMD + DISABLECMD
    wait_status_bit(0, ST_PAUSED);
    regs.chw(0, CH_CMD, 1 << 3);                                      // STOPCMD
    regs.wait_idle(0, st);
    regs.chr(0, CH_CMD, v);
    chk(v[4:2] == 0, $sformatf("BUG-04: PAUSE / DISABLE / STOP bits left set after stop (CH_CMD %08h)", v));
    regs.clear_status(0);
    env.sb.unrelax(0);
    slow_mem(0);
    c = mk(0, 0, 'hE00, 'hE00, 64);
    init_src(c);
    void'(expect_cmd(c));
    regs.program_cmd(c);
    regs.enable(0);
    regs.wait_idle(0, st, 20000);
    chk((st & 32'h00FF_0000) == (1 << ST_DONE), $sformatf("BUG-04: command after stop with pending pause/disable: status %08h", st));
    void'(env.sb.check_done(0, tname));
    regs.clear_status(0);
    n_cmds += 4;
  endtask
endclass
