//-----------------------------------------------------------------------------
// dma_trig_mtx_test.svh
//   Trigger matrix (TRM 5.4.1 / 5.4.3): software deny of an unselected pending
//   request, completion of interrupted handshakes after STOP (input and
//   output), internal trigger to a destination side, trigger port security.
//-----------------------------------------------------------------------------
class dma_trig_mtx_test extends dma_dir_base;
  `uvm_component_utils(dma_trig_mtx_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // 4-phase protocol monitor on all trigger pins
  int unsigned n_viol;
  task hs_monitor();
    bit [TB_NTIW-1:0] rq_d, ak_d;
    bit [TB_NTOW-1:0] orq_d, oak_d;
    forever begin
      @(posedge vif.clk);
      for (int p = 0; p < TB_NTI; p++) begin
        if (ak_d[p] && !vif.trig_in_ack[p] && vif.trig_in_req[p] && rq_d[p]) begin
          n_viol++;
          `uvm_error("TRIGHS", $sformatf("trig_in_%0d: ack dropped while req is still high", p))
        end
      end
      for (int q = 0; q < TB_NTO; q++) begin
        if (orq_d[q] && !vif.trig_out_req[q] && !oak_d[q]) begin
          n_viol++;
          `uvm_error("TRIGHS", $sformatf("trig_out_%0d: req withdrawn before ack", q))
        end
      end
      rq_d = vif.trig_in_req; ak_d = vif.trig_in_ack; orq_d = vif.trig_out_req; oak_d = vif.trig_out_ack;
    end
  endtask

  function int secfrm(); return TB_SECEXT ? R_SECCTRL : R_NSCTRL; endfunction

  task body();
    dma_cmd c;
    bit [1:0] at;
    bit [31:0] v, st;
    if (TB_NTI < 3 || TB_NTO < 2 || TB_NCH < 2) begin `uvm_info("TEST", "configuration too small: skipped", UVM_NONE) return; end
    fork hs_monitor(); join_none

    // ---------------- 1. software deny of a pending request on an unselected input
    env.trig.in_raise(2, RQ_BLOCK);
    repeat (10) @(posedge vif.clk);
    regs.wr(secfrm() + U_SIGNALPTR, 0, uprot());
    regs.rd(secfrm() + U_SIGNALVAL, v, uprot());
    chk(v[2], $sformatf("SIGNALVAL does not show the pending request (%08h)", v));
    regs.wr(secfrm() + U_SIGNALVAL, 32'h4, uprot());
    env.trig.in_drop_after_ack(2, at);
    chk(at == AK_DENY, $sformatf("software clear answered with acktype %0b, expected DENY", at));
    regs.rd(secfrm() + U_SIGNALVAL, v, uprot());
    chk(!v[2], "request still visible after the deny handshake");
    // the port is usable afterwards
    c = mk(0, 0, 0, 'h100, 32);
    c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 2;
    init_src(c); start_cmd(c);
    env.trig.in_req(2, RQ_BLOCK, at);
    finish_cmd(c);

    // ---------------- 2. STOP while the input handshake is still open (req held high)
    slow_mem(1);
    c = mk(0, $clog2(TB_DWB), 'h400, 'h400, 256);
    c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 1;
    init_src(c);
    void'(expect_cmd(c));
    env.sb.relax(0);
    regs.program_cmd(c);
    regs.enable(0);
    env.trig.in_raise(1, RQ_BLOCK);
    while (vif.trig_in_ack[1] !== 1'b1) @(posedge vif.clk);
    repeat (50) @(posedge vif.clk);                         // transfer running, req kept high
    regs.chw(0, CH_CMD, 1 << 3);                            // STOPCMD
    regs.wait_idle(0, st);
    repeat (20) @(posedge vif.clk);
    chk(vif.trig_in_ack[1] === 1'b1, "ack withdrawn by the stop although req is still high");
    vif.trig_in_req[1] <= 1'b0;                             // peripheral ends the handshake
    repeat (10) @(posedge vif.clk);
    chk(vif.trig_in_ack[1] === 1'b0, "ack not released after req went low");
    regs.clear_status(0);
    env.sb.unrelax(0);
    slow_mem(0);
    // the input can be selected again
    c = mk(0, 0, 'h800, 'h800, 16);
    c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 1;
    init_src(c); start_cmd(c);
    env.trig.in_req(1, RQ_SINGLE, at);
    finish_cmd(c);

    // ---------------- 3. STOP while the trigger output waits for its ack
    env.trig.out_auto_ack[1] = 0;
    c = mk(1, 0, 'h100, 'h100, 16);
    c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = 1;
    init_src(c);
    start_cmd(c);
    while (vif.trig_out_req[1] !== 1'b1) @(posedge vif.clk);
    regs.chw(1, CH_CMD, 1 << 3);
    regs.wait_idle(1, st);
    repeat (20) @(posedge vif.clk);
    chk(vif.trig_out_req[1] === 1'b1, "trigger output request withdrawn by the stop before its ack");
    env.trig.out_ack(1);
    repeat (10) @(posedge vif.clk);
    chk(vif.trig_out_req[1] === 1'b0, "trigger output request not released after the ack");
    void'(env.sb.check_done(1, tname));
    regs.clear_status(1);
    // output usable again
    env.trig.out_auto_ack[1] = 1;
    c = mk(1, 0, 'h200, 'h200, 16);
    c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = 1;
    init_src(c); run_cmd(c);

    // ---------------- 4. internal trigger to a destination side
    begin
      dma_cmd a = mk(0, 0, 'h900, 'h900, 64);
      dma_cmd b = mk(1, 0, 'h900, 'h900, 64);
      a.use_trigout = 1; a.trigout_type = TT_INT;
      b.use_destrig = 1; b.destrig_type = TT_INT; b.destrig_sel = 0;
      init_src(a); init_src(b);
      start_cmd(b);
      wait_status_bit(1, ST_DESTRIGWAIT);
      start_cmd(a);
      finish_cmd(a);
      finish_cmd(b);
    end

    // ---------------- 5. trigger port security
    if (TB_SECEXT) begin
      regs.wr(R_SECCFG + SCFG_TRIGINSEC0, 32'h8, PROT_S_P);  // input 3 Non-secure
      regs.wr(R_SECCFG + SCFG_TRIGOUTSEC0, 32'h1, PROT_S_P); // output 0 Non-secure
      regs.rd(R_SECCFG + SCFG_TRIGINSEC0, v, PROT_S_P);
      chk(v == 32'h8, "SCFG_TRIGINSEC0 read back");
      regs.rd(R_SECCFG + SCFG_TRIGOUTSEC0, v, PROT_S_P);
      chk(v == 32'h1, "SCFG_TRIGOUTSEC0 read back");
      c = mk(0, 0, 0, 0, 8);                                  // Secure channel, NS input
      c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 3;
      run_err(c, 32'h0000_0004);
      c = mk(0, 0, 0, 0, 8);                                  // Secure channel, NS output
      c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = 0;
      run_err(c, 32'h0000_0010);
      regs.set_ch_attr(1, 1, 0);                              // NS channel uses the NS input
      c = mk(1, 0, 'h300, 'h300, 8);
      c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 3;
      init_src(c); start_cmd(c);
      env.trig.in_raise(3, RQ_BLOCK);
      regs.wr(R_NSCTRL + U_SIGNALPTR, 0, PROT_NS_P);
      regs.rd(R_NSCTRL + U_SIGNALVAL, v, PROT_NS_P);
      chk(v[3] && !v[2], $sformatf("NSEC_SIGNALVAL masking (%08h)", v));
      regs.rd(R_SECCTRL + U_SIGNALVAL, v, PROT_S_P);
      chk(!v[3], "SEC_SIGNALVAL shows a Non-secure input");
      env.trig.in_drop_after_ack(3, at);
      finish_cmd(c);
      regs.set_ch_attr(1, 0, 0);
      regs.wr(R_SECCFG + SCFG_TRIGINSEC0, 32'h0, PROT_S_P);
      regs.wr(R_SECCFG + SCFG_TRIGOUTSEC0, 32'h0, PROT_S_P);
    end
    chk(n_viol == 0, $sformatf("%0d trigger handshake protocol violations", n_viol));
  endtask
endclass
