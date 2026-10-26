//-----------------------------------------------------------------------------
// dma_ctrl_base.svh
//   Base class of the control tests: unit control frame helpers, slow memory profile,
//   expected-error command runner.
//-----------------------------------------------------------------------------
class dma_ctrl_base extends dma_feat_base;
  `uvm_component_utils(dma_ctrl_base)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // control frame of the default (reset) channel security
  function int ufrm();       return TB_SECEXT ? R_SECCTRL : R_NSCTRL; endfunction
  function bit [2:0] uprot(); return TB_SECEXT ? PROT_S_P : PROT_NS_P; endfunction

  task slow_mem(bit on);
    for (int p = 0; p < 2; p++) begin
      env.axi_cfg[p].arready_pct = on ? 30 : 100;
      env.axi_cfg[p].awready_pct = on ? 30 : 100;
      env.axi_cfg[p].wready_pct  = on ? 50 : 100;
      env.axi_cfg[p].r_delay_max = on ? 6 : 0;
      env.axi_cfg[p].b_delay_max = on ? 6 : 0;
    end
  endtask

  // run a command that must end with an error, check ERRINFO bits
  task run_err(dma_cmd c, bit [31:0] ei_bits, bit traffic_ok = 0);
    bit [31:0] st, ei;
    set_attr_exp(c);
    if (traffic_ok) begin
      void'(expect_cmd(c));
      env.sb.relax(c.ch);
    end
    regs.program_cmd(c);
    regs.enable(c.ch);
    regs.wait_idle(c.ch, st);
    regs.chr(c.ch, CH_ERRINFO, ei);
    if (!st[ST_ERR] || (ei & ei_bits) != ei_bits)
      `uvm_error("TEST", $sformatf("ch%0d expected error %08h: status %08h ERRINFO %08h (%s)",
                                   c.ch, ei_bits, st, ei, c.convert2string()))
    if (vif.ch_err[c.ch] !== 1'b1) `uvm_error("TEST", "ch_err status output not set")
    regs.clear_status(c.ch);
    regs.chr(c.ch, CH_ERRINFO, ei);
    if (ei != 0) `uvm_error("TEST", "ERRINFO not cleared with STAT_ERR")
    env.sb.unrelax(c.ch);
    env.sb.clear_reads(c.ch);
    n_cmds++;
  endtask
endclass
