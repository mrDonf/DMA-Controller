//-----------------------------------------------------------------------------
// dma_unit_status_test.svh
//   Unit level status / debug registers: STATUSPTR / STATUSVAL (enabled,
//   stopped, paused), SIGNALPTR / SIGNALVAL, information frame IDs,
//   DBGHALTEN / DBGHALTNSRO access rules, CTI halt cancelled by DBGHALTEN,
//   Non-secure all-channel pause / stop through NSEC_CTRL.
//-----------------------------------------------------------------------------
class dma_unit_status_test extends dma_dir_base;
  `uvm_component_utils(dma_unit_status_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task statusval(int frm, bit [2:0] prot, int ptr, output bit [31:0] v);
    regs.wr(frm + U_STATUSPTR, ptr, prot);
    regs.rd(frm + U_STATUSVAL, v, prot);
  endtask

  task body();
    dma_cmd c;
    bit [31:0] v, st;
    int nsch = (TB_NCH > 1) ? 1 : 0;
    // ---------------- information frame
    regs.rd(R_INFO + 'hCC, v); chk(v == 32'h0, "AIDR");
    regs.rd(R_INFO + 'hD0, v); chk(v == 32'h04, "PIDR4");
    regs.rd(R_INFO + 'hEC, v); chk(v == 32'h0, "PIDR3");
    // ---------------- channel status bitmaps through the status pointer
    slow_mem(1);
    c = mk(0, $clog2(TB_DWB), 0, 0, 256);
    init_src(c);
    start_cmd(c);
    repeat (50) @(posedge vif.clk);
    statusval(ufrm(), uprot(), 0, v);
    chk(v[0], $sformatf("STATUSVAL(enabled) %08h", v));
    regs.chw(0, CH_CMD, 1 << 4);
    wait_status_bit(0, ST_PAUSED);
    statusval(ufrm(), uprot(), 4, v);
    chk(v[0], $sformatf("STATUSVAL(paused) %08h", v));
    regs.chw(0, CH_CMD, 1 << 5);
    finish_cmd(c);
    c = mk(0, $clog2(TB_DWB), 'h800, 'h800, 256);
    init_src(c);
    void'(expect_cmd(c)); env.sb.relax(0);
    regs.program_cmd(c); regs.enable(0);
    repeat (50) @(posedge vif.clk);
    regs.chw(0, CH_CMD, 1 << 3);
    regs.wait_idle(0, st);
    statusval(ufrm(), uprot(), 2, v);
    chk(v[0], $sformatf("STATUSVAL(stopped) %08h", v));
    statusval(ufrm(), uprot(), 7, v);
    chk(v == 0, "STATUSVAL reserved pointer");
    regs.clear_status(0);
    env.sb.unrelax(0);
    slow_mem(0);
    // ---------------- signal pointer: trigger input requests / output acks
    if (TB_NTI > 0 && TB_NTO > 0) begin
      bit [1:0] at;
      regs.wr(ufrm() + U_SIGNALPTR, 0, uprot());
      regs.rd(ufrm() + U_SIGNALPTR, v, uprot());
      chk(v == 0, "SIGNALPTR read back");
      env.trig.in_raise(0, RQ_SINGLE);
      repeat (10) @(posedge vif.clk);
      regs.rd(ufrm() + U_SIGNALVAL, v, uprot());
      chk(v[0], "SIGNALVAL trigger input request");
      regs.wr(ufrm() + U_SIGNALVAL, 32'h1, uprot());
      env.trig.in_drop_after_ack(0, at);
      vif.trig_out_ack[0] <= 1'b1;
      repeat (10) @(posedge vif.clk);
      regs.wr(ufrm() + U_SIGNALPTR, 8, uprot());
      regs.rd(ufrm() + U_SIGNALVAL, v, uprot());
      chk(v[0], "SIGNALVAL trigger output ack");
      vif.trig_out_ack[0] <= 1'b0;
      regs.wr(ufrm() + U_SIGNALPTR, 5, uprot());
      regs.rd(ufrm() + U_SIGNALVAL, v, uprot());
      chk(v == 0, "SIGNALVAL reserved pointer");
    end
    // ---------------- DBGHALTEN / DBGHALTNSRO
    if (TB_SECEXT) begin
      regs.wr(R_SECCTRL + U_CTRL, 32'h0800_0000, PROT_S_P);        // DBGHALTNSRO = 1
      regs.wr(R_NSCTRL + U_CTRL, 32'h1000_0000, PROT_NS_P);        // NS tries DBGHALTEN
      regs.rd(R_NSCTRL + U_CTRL, v, PROT_NS_P);
      chk(!v[28] && v[27], $sformatf("DBGHALTEN writable by NS although DBGHALTNSRO (%08h)", v));
      regs.wr(R_SECCTRL + U_CTRL, 32'h0, PROT_S_P);
      regs.wr(R_NSCTRL + U_CTRL, 32'h1000_0000, PROT_NS_P);
      regs.rd(R_SECCTRL + U_CTRL, v, PROT_S_P);
      chk(v[28], "DBGHALTEN not writable by NS with DBGHALTNSRO = 0");
    end else begin
      regs.wr(R_NSCTRL + U_CTRL, 32'h1000_0000, PROT_NS_P);
    end
    // ---------------- CTI halt cancelled by clearing DBGHALTEN
    slow_mem(1);
    c = mk(0, $clog2(TB_DWB), 'h1000, 'h1000, 256);
    init_src(c);
    start_cmd(c);
    repeat (50) @(posedge vif.clk);
    vif.halt_req <= 1'b1;
    repeat (200) @(posedge vif.clk);
    chk(vif.ch_paused[0] === 1'b1, "channel not halted");
    vif.halt_req <= 1'b0;
    regs.wr(TB_SECEXT ? R_SECCTRL + U_CTRL : R_NSCTRL + U_CTRL, 32'h0, uprot());   // DBGHALTEN = 0
    finish_cmd(c);
    slow_mem(0);
    // ---------------- CTI halt withdrawn (DBGHALTEN = 0) before the channels are paused
    begin
      int n_halted = 0;
      regs.wr(TB_SECEXT ? R_SECCTRL + U_CTRL : R_NSCTRL + U_CTRL, 32'h1000_0000, uprot());
      for (int p = 0; p < 2; p++) begin env.axi_cfg[p].r_delay_min = 80; env.axi_cfg[p].r_delay_max = 100; end
      c = mk(0, $clog2(TB_DWB), 'h2800, 'h2800, 64);
      init_src(c);
      start_cmd(c);
      repeat (50) @(posedge vif.clk);
      fork
        forever begin @(posedge vif.halted); n_halted++; end
      join_none
      vif.halt_req <= 1'b1;                                   // read data outstanding: halt takes long
      repeat (8) @(posedge vif.clk);
      vif.halt_req <= 1'b0;
      regs.wr(TB_SECEXT ? R_SECCTRL + U_CTRL : R_NSCTRL + U_CTRL, 32'h0, uprot());
      for (int p = 0; p < 2; p++) begin env.axi_cfg[p].r_delay_min = 0; env.axi_cfg[p].r_delay_max = 0; end
      finish_cmd(c);
      disable fork;
      chk(n_halted == 0, "halt completed although DBGHALTEN was cleared during the halt");
    end
    // ---------------- Non-secure all-channel pause / stop (NSEC_CTRL)
    if (TB_SECEXT) regs.set_ch_attr(nsch, 1, 0);
    slow_mem(1);
    c = mk(nsch, $clog2(TB_DWB), 'h1800, 'h1800, 256);
    init_src(c);
    start_cmd(c);
    repeat (50) @(posedge vif.clk);
    regs.wr(R_NSCTRL + U_CTRL, 32'h0000_0200, PROT_NS_P);
    do regs.rd(R_NSCTRL + U_STATUS, v, PROT_NS_P); while (!v[19]);
    regs.wr(R_NSCTRL + U_STATUS, 32'h0008_0000, PROT_NS_P);
    finish_cmd(c);
    c = mk(nsch, $clog2(TB_DWB), 'h2000, 'h2000, 256);
    init_src(c);
    void'(expect_cmd(c)); env.sb.relax(nsch);
    regs.program_cmd(c); regs.enable(nsch);
    repeat (50) @(posedge vif.clk);
    regs.wr(R_NSCTRL + U_CTRL, 32'h0000_0100, PROT_NS_P);
    regs.wait_idle(nsch, st);
    do regs.rd(R_NSCTRL + U_STATUS, v, PROT_NS_P); while (!v[18]);
    regs.wr(R_NSCTRL + U_STATUS, 32'h0004_0000, PROT_NS_P);
    regs.clear_status(nsch);
    env.sb.unrelax(nsch);
    slow_mem(0);
    if (TB_SECEXT) regs.set_ch_attr(nsch, 0, 0);
  endtask
endclass
