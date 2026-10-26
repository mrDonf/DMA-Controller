//-----------------------------------------------------------------------------
// dma_gpo_irq_test.svh
//   GPO driving / GPOREAD0, channel and combined interrupts, ALLCHIDLE, STATUSPTR.
//-----------------------------------------------------------------------------
class dma_gpo_irq_test extends dma_ctrl_base;
  `uvm_component_utils(dma_gpo_irq_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [31:0] v;
    dma_cmd c;
    // ---------------- GPO
    for (int ch = 0; ch < TB_NCH; ch++) begin
      bit [31:0] gm, exp;
      if (!(TB_GPO_MASK[ch] && TB_GPOW > 0)) continue;
      gm = (TB_GPOW >= 32) ? 32'hFFFF_FFFF : ((32'h1 << TB_GPOW) - 1);
      exp = 0;
      for (int k = 0; k < 3; k++) begin
        c = simple(ch, 32);
        c.use_gpo = 1;
        c.gpoen  = $urandom & gm;
        c.gpoval = $urandom & gm;
        exp = (exp & ~c.gpoen) | (c.gpoval & c.gpoen);
        init_src(c);
        run_cmd(c);
        if (32'(vif.gpo_ch[ch]) != exp) `uvm_error("GPO", $sformatf("ch%0d gpo %0h expected %0h", ch, vif.gpo_ch[ch], exp))
        regs.chr(ch, CH_GPOREAD0, v);
        if (v != exp) `uvm_error("GPO", $sformatf("ch%0d GPOREAD0 %0h expected %0h", ch, v, exp))
      end
    end
    // ---------------- channel interrupt + combined interrupt + all channel idle
    regs.wr(ufrm() + U_CTRL, 32'h3, uprot());                    // INTREN_ANYCHINTR | INTREN_ALLCHIDLE
    regs.wr(ufrm() + U_STATUS, 32'h000E_0000, uprot());
    c = simple(0, 256);
    c.intren = 11'h001;
    init_src(c);
    void'(expect_cmd(c));
    regs.program_cmd(c);
    regs.enable(0);
    regs.wait_idle(0, v);
    repeat (5) @(posedge vif.clk);
    if (vif.irq_channel[0] !== 1'b1) `uvm_error("IRQ", "irq_channel not asserted on DONE")
    if ((TB_SECEXT ? vif.irq_comb_sec : vif.irq_comb_nonsec) !== 1'b1) `uvm_error("IRQ", "combined interrupt not asserted")
    regs.rd(ufrm() + U_CHINTRSTATUS0, v, uprot());
    if (!v[0]) `uvm_error("IRQ", "CHINTRSTATUS0 bit not set")
    regs.rd(ufrm() + U_STATUS, v, uprot());
    if (!v[17] || !v[1] || !v[0]) `uvm_error("IRQ", $sformatf("unit STATUS %08h: ALLCHIDLE / interrupts", v))
    regs.chr(0, CH_STATUS, v);
    if (!v[0]) `uvm_error("IRQ", "INTR_DONE not set")
    regs.clear_status(0);
    regs.wr(ufrm() + U_STATUS, 32'h0002_0000, uprot());
    repeat (5) @(posedge vif.clk);
    if (vif.irq_channel[0] !== 1'b0) `uvm_error("IRQ", "irq_channel not cleared")
    if ((TB_SECEXT ? vif.irq_comb_sec : vif.irq_comb_nonsec) !== 1'b0) `uvm_error("IRQ", "combined interrupt not cleared")
    void'(env.sb.check_done(0, tname));
    n_cmds++;
    // ---------------- interrupt enable for error / stopped
    c = simple(0, 64);
    c.xtype = 3'b111;
    c.intren = 11'h002;
    regs.program_cmd(c);
    regs.enable(0);
    regs.wait_idle(0, v);
    repeat (3) @(posedge vif.clk);
    if (vif.irq_channel[0] !== 1'b1) `uvm_error("IRQ", "irq_channel not asserted on ERR")
    regs.clear_status(0);
    regs.wr(ufrm() + U_CTRL, 32'h0, uprot());
    // ---------------- status pointer registers
    regs.wr(ufrm() + U_STATUSPTR, 32'h0, uprot());
    regs.rd(ufrm() + U_STATUSVAL, v, uprot());
    if (v != 0) `uvm_error("IRQ", "STATUSVAL(enabled) not zero while idle")
  endtask
endclass
