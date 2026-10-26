//-----------------------------------------------------------------------------
// dma_dir_done_test.svh
//   DONETYPE / DONEPAUSEEN (CH_CTRL):
//     1. DONETYPE = 0       : command ends without STAT_DONE and without interrupt
//     2. DONETYPE = 1       : with auto-restart, STAT_DONE only after the last cycle
//     3. DONETYPE = 3       : STAT_DONE already set while the restart cycles still run
//     4. DONETYPE = 1 + DONEPAUSEEN in a link chain: the channel stops in RESUMEWAIT
//        after the first command, the next command only starts after RESUMECMD;
//        DONEPAUSEEN has no effect on the last command of the chain.
//-----------------------------------------------------------------------------
class dma_dir_done_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_done_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // STAT_DONE seen while the channel is still enabled (between restart cycles)
  task run_restart(dma_cmd c, int cycles, output bit done_early);
    bit [31:0] st;
    done_early = 0;
    repeat (cycles) void'(expect_cmd(c));
    env.cov.sample_cmd(c);
    regs.program_cmd(c);
    regs.enable(c.ch);
    while (vif.ch_enabled[c.ch] !== 1'b1) @(posedge vif.clk);
    while (vif.ch_enabled[c.ch] === 1'b1) begin
      regs.chr(c.ch, CH_STATUS, st);
      if (st[ST_DONE] && vif.ch_enabled[c.ch] === 1'b1) done_early = 1;
    end
  endtask

  task body();
    dma_cmd c, c0, c1;
    bit [31:0] st, w[$];
    bit early;
    int irqs = 0, nb0;
    longint unsigned D = dsc_base(0);

    // ---------------- 1. DONETYPE = 0: no done status, no interrupt
    c = mk(0, $clog2(TB_DWB), 0, 0, 8);
    c.donetype = 3'b000; c.intren = 11'h001;
    init_src(c);
    fork
      forever begin @(posedge vif.irq_channel[0]); irqs++; end
    join_none
    start_cmd(c);
    finish_cmd(c, 32'h0);
    repeat (20) @(posedge vif.clk);
    disable fork;
    chk(irqs == 0, $sformatf("DONETYPE=0: %0d channel interrupts", irqs));

    // ---------------- 2. / 3. auto-restart with DONETYPE 1 and 3
    slow_mem(1);
    c = mk(0, $clog2(TB_DWB), 'h400, 'h400, 16);
    c.restartcnt = 2; c.regreload = 3'b111; c.donetype = 3'b001;
    init_src(c);
    run_restart(c, 3, early);
    chk(!early, "DONETYPE=1: STAT_DONE set before the last restart cycle");
    finish_cmd(c);
    c = mk(0, $clog2(TB_DWB), 'h800, 'h800, 16);
    c.restartcnt = 2; c.regreload = 3'b111; c.donetype = 3'b011;
    init_src(c);
    run_restart(c, 3, early);
    chk(early, "DONETYPE=3: STAT_DONE not set at the end of a restart cycle");
    finish_cmd(c);
    slow_mem(0);

    // ---------------- 4. DONEPAUSEEN in a link chain
    c0 = mk(0, $clog2(TB_DWB), 'hC00, 'hC00, 16);
    c0.donetype = 3'b001; c0.donepause = 1;
    c0.linkaddren = 1; c0.linkaddr = D;
    c1 = mk(0, $clog2(TB_DWB), 'hE00, 'hE00, 12);
    c1.donetype = 3'b001; c1.donepause = 1;
    c1.descriptor(link_header(c0, c1, 0), w);
    put_desc(D, w);
    init_src(c0); init_src(c1);
    void'(expect_cmd(c0));
    void'(expect_cmd(c1));
    nb0 = env.sb.n_wr_bytes;
    regs.program_cmd(c0);
    regs.enable(0);
    wait_status_bit(0, ST_RESUMEWAIT);
    regs.chr(0, CH_STATUS, st);
    chk(st[ST_DONE], $sformatf("DONEPAUSEEN: RESUMEWAIT without STAT_DONE (%08h)", st));
    begin
      int w0 = env.sb.n_wr_bytes;
      repeat (300) @(posedge vif.clk);
      chk(env.sb.n_wr_bytes == w0, "DONEPAUSEEN: next command started before RESUMECMD");
      chk(w0 - nb0 == c0.desxsize * c0.esize(),
          $sformatf("DONEPAUSEEN: first command wrote %0d bytes before the pause", w0 - nb0));
    end
    regs.chw(0, CH_STATUS, 1 << ST_DONE);
    regs.chw(0, CH_CMD, 32'h20);                       // RESUMECMD
    regs.wait_idle(0, st);
    chk(!st[ST_RESUMEWAIT] && st[ST_DONE], $sformatf("last command of the chain: status %08h", st));
    void'(env.sb.check_done(0, tname));
    env.sb.clear_reads(0);
    regs.clear_status(0);
    n_cmds += 2;
  endtask
endclass
