//-----------------------------------------------------------------------------
// dma_lpi_test.svh
//   LPI: Q-Channel accept / deny, P-Channel OFF / FULL_RET / WARM_RST / ON rules,
//   IDLERETEN, DISMINPWR.
//-----------------------------------------------------------------------------
class dma_lpi_test extends dma_ctrl_base;
  `uvm_component_utils(dma_lpi_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit acc;
    bit [31:0] v;
    dma_cmd c;
    // ---------------- Q-Channel: idle -> accepted
    env.lpi.q_cycle(acc);
    if (!acc) `uvm_error("LPI", "Q-Channel request denied while idle")
    // ---------------- Q-Channel: busy -> denied
    slow_mem(1);
    c = simple(0, 4096, 3);
    init_src(c);
    start_cmd(c);
    repeat (100) @(posedge vif.clk);
    if (vif.pactive[8] !== 1'b1) `uvm_error("LPI", "pactive[ON] not asserted while transferring")
    if (vif.clk_qactive !== 1'b1) `uvm_error("LPI", "clk_qactive not asserted while transferring")
    env.lpi.q_cycle(acc);
    if (acc) `uvm_error("LPI", "Q-Channel request accepted while transferring")
    // P-Channel OFF denied while active
    env.lpi.p_request(4'd0, acc);
    if (acc) `uvm_error("LPI", "P-Channel OFF accepted while transferring")
    // warm reset pauses the channel, ON resumes it
    env.lpi.p_request(4'd9, acc);
    if (!acc) `uvm_error("LPI", "WARM_RST request denied")
    if (vif.ch_paused[0] !== 1'b1) `uvm_error("LPI", "channel not paused in WARM_RST")
    repeat (200) @(posedge vif.clk);
    env.lpi.p_request(4'd8, acc);
    if (!acc) `uvm_error("LPI", "ON request denied")
    finish_cmd(c);
    slow_mem(0);
    // ---------------- channel waiting for a trigger: FULL_RET depends on IDLERETEN
    c = simple(1 % TB_NCH, 128);
    c.use_srctrig = 1; c.srctrig_type = TT_SW;
    init_src(c);
    start_cmd(c);
    wait_status_bit(c.ch, ST_SRCTRIGWAIT);
    repeat (5) @(posedge vif.clk);
    env.lpi.p_request(4'd0, acc);
    if (acc) `uvm_error("LPI", "OFF accepted with an enabled channel")
    env.lpi.p_request(4'd5, acc);
    if (acc) `uvm_error("LPI", "FULL_RET accepted with IDLERETEN = 0")
    regs.rd(ufrm() + U_CTRL, v, uprot());
    regs.wr(ufrm() + U_CTRL, v | (1 << 29), uprot());
    env.lpi.p_request(4'd5, acc);
    if (!acc) `uvm_error("LPI", "FULL_RET denied with IDLERETEN = 1")
    if (vif.pactive[5] !== 1'b1) `uvm_error("LPI", "pactive[FULL_RET] not asserted while waiting")
    env.lpi.q_cycle(acc);
    if (!acc) `uvm_error("LPI", "Q-Channel denied while only waiting for a trigger")
    env.lpi.p_request(4'd8, acc);
    regs.chw(c.ch, CH_CMD, 1 << 16);
    finish_cmd(c);
    regs.wr(ufrm() + U_CTRL, v & ~(1 << 29), uprot());
    // ---------------- idle: OFF accepted, then ON
    env.lpi.p_request(4'd0, acc);
    if (!acc) `uvm_error("LPI", "OFF denied while idle")
    env.lpi.p_request(4'd8, acc);
    if (!acc) `uvm_error("LPI", "ON denied")
    // ---------------- DISMINPWR = ON forbids OFF
    regs.wr(ufrm() + U_CTRL, 32'h8000_0000, uprot());
    env.lpi.p_request(4'd0, acc);
    if (acc) `uvm_error("LPI", "OFF accepted with DISMINPWR = ON")
    regs.wr(ufrm() + U_CTRL, 32'h0, uprot());
    // ---------------- unsupported power state is denied
    env.lpi.p_request(4'd2, acc);
    if (acc) `uvm_error("LPI", "unsupported power state accepted")
    // normal operation afterwards
    c = gen_cmd(0);
    init_src(c);
    run_cmd(c);
  endtask
endclass
