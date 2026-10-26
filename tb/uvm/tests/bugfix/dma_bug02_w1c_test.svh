//-----------------------------------------------------------------------------
// dma_bug02_w1c_test.svh
//   BUG-02: one W1C clears ALLCHPAUSED / ALLCHSTOPPED and their interrupt.
//-----------------------------------------------------------------------------
class dma_bug02_w1c_test extends dma_dir_base;
  `uvm_component_utils(dma_bug02_w1c_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function bit irq_comb(); return TB_SECEXT ? vif.irq_comb_sec : vif.irq_comb_nonsec; endfunction

  task body();
    bit [31:0] v, st;
    dma_cmd c;
    slow_mem(1);
    // ---------------- ALLCHPAUSED: one W1C clears the flag, the interrupt and resumes
    regs.wr(ufrm() + U_CTRL, 32'h0000_0008, uprot());                 // INTREN_ALLCHPAUSED
    c = mk(0, $clog2(TB_DWB), 0, 0, 256);
    init_src(c);
    start_cmd(c);
    repeat (200) @(posedge vif.clk);
    regs.wr(ufrm() + U_CTRL, 32'h0000_0208, uprot());                 // + ALLCHPAUSE
    do begin regs.rd(ufrm() + U_STATUS, v, uprot()); end while (!v[19]);
    repeat (3) @(posedge vif.clk);
    chk(irq_comb() === 1'b1, "BUG-02: INTR_ALLCHPAUSED not raised");
    regs.wr(ufrm() + U_STATUS, 32'h0008_0000, uprot());               // single W1C
    regs.rd(ufrm() + U_STATUS, v, uprot());
    chk(!v[19] && !v[3], $sformatf("BUG-02: STAT_ALLCHPAUSED still set after one W1C (%08h)", v));
    repeat (3) @(posedge vif.clk);
    chk(irq_comb() === 1'b0, "BUG-02: combined interrupt still pending after one W1C");
    finish_cmd(c);
    // ---------------- ALLCHSTOPPED
    regs.wr(ufrm() + U_CTRL, 32'h0000_0004, uprot());                 // INTREN_ALLCHSTOPPED
    c = mk(0, $clog2(TB_DWB), 'h1000, 'h1000, 256);
    init_src(c);
    void'(expect_cmd(c));
    env.sb.relax(0);
    regs.program_cmd(c);
    regs.enable(0);
    repeat (200) @(posedge vif.clk);
    regs.wr(ufrm() + U_CTRL, 32'h0000_0104, uprot());                 // + ALLCHSTOP
    regs.wait_idle(0, st);
    do begin regs.rd(ufrm() + U_STATUS, v, uprot()); end while (!v[18]);
    regs.wr(ufrm() + U_STATUS, 32'h0004_0000, uprot());
    regs.rd(ufrm() + U_STATUS, v, uprot());
    chk(!v[18] && !v[2], $sformatf("BUG-02: STAT_ALLCHSTOPPED still set after one W1C (%08h)", v));
    regs.rd(ufrm() + U_CTRL, v, uprot());
    chk(!v[8], "BUG-02: ALLCHSTOP request not withdrawn by the W1C");
    repeat (3) @(posedge vif.clk);
    chk(irq_comb() === 1'b0, "BUG-02: combined interrupt still pending after one W1C");
    regs.clear_status(0);
    env.sb.unrelax(0);
    regs.wr(ufrm() + U_CTRL, 32'h0, uprot());
    slow_mem(0);
    // a new command runs normally (no left-over stop request)
    c = mk(0, 0, 'h2000, 'h2000, 64);
    init_src(c);
    drun(c, 64, "after all-channel stop");
  endtask
endclass
