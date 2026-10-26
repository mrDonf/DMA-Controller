//-----------------------------------------------------------------------------
// dma_bug03_pause_trigout_test.svh
//   BUG-03: a pause at the entry of the trigger-output step must not hang the channel.
//-----------------------------------------------------------------------------
class dma_bug03_pause_trigout_test extends dma_dir_base;
  `uvm_component_utils(dma_bug03_pause_trigout_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    if (TB_NTO == 0) begin `uvm_info("TEST", "no trigger output: skipped", UVM_NONE) return; end
    env.trig.out_auto_ack[0] = 1;
    env.trig.out_ack_dly_max = 0;
    // sweep the pause position over the whole command so that one of the
    // pauses lands exactly on the entry of the trigger-output step
    for (int d = 0; d < 140; d++) begin
      dma_cmd c = mk(0, 0, 'h40 * (d % 32), 'h40 * (d % 32), 8);
      bit [31:0] st;
      c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = 0;
      init_src(c);
      void'(expect_cmd(c));
      regs.program_cmd(c);
      regs.enable(0);
      repeat (d) @(posedge vif.clk);
      if (TB_SECEXT) vif.allch_pause_req_sec <= 1'b1; else vif.allch_pause_req_nonsec <= 1'b1;
      repeat (20) @(posedge vif.clk);
      if (TB_SECEXT) vif.allch_pause_req_sec <= 1'b0; else vif.allch_pause_req_nonsec <= 1'b0;
      regs.wait_idle(0, st, 5000);
      chk(st[ST_DONE] && !st[ST_ERR], $sformatf("BUG-03: pause %0d cycles after enable: status %08h", d, st));
      if (vif.ch_enabled[0] === 1'b1) begin
        `uvm_error("DIRECTED", $sformatf("BUG-03: channel hung (pause at cycle %0d)", d))
        return;
      end
      void'(env.sb.check_done(0, tname));
      regs.clear_status(0);
      n_cmds++;
    end
  endtask
endclass
