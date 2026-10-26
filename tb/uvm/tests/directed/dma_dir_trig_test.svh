//-----------------------------------------------------------------------------
// dma_dir_trig_test.svh
//   Trigger scenarios of TRM figures 5-17 / 5-18 / 5-20 and the 6.2 block size example.
//-----------------------------------------------------------------------------
class dma_dir_trig_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_trig_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_cmd c;
    bit [1:0] at;
    int w0, r0;
    if (TB_NTI < 2) begin `uvm_info("TEST", "fewer than 2 trigger inputs: skipped", UVM_NONE) return; end
    env.trig.async_mode = $test$plusargs("TRIG_ASYNC");
    // ---- figure 5-17: source flow control, destination command trigger
    c = mk(0, 0, 0, 'h100, 40);
    c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 0; c.srctrig_mode = TM_DMAFC; c.srctrig_blk = 9;
    c.use_destrig = 1; c.destrig_type = TT_HW; c.destrig_sel = 1;
    init_src(c);
    start_cmd(c);
    r0 = env.sb.n_rd_bursts;
    env.trig.in_req(1, RQ_BLOCK, at);
    chk(at == AK_OKAY, "fig5-17: destination command trigger ack");
    repeat (100) @(posedge vif.clk);
    chk(env.sb.n_rd_bursts == r0, "fig5-17: reads before the first source trigger");
    env.trig.fc_peripheral(0, 0, 0, 5);
    chk(env.trig.last_acktype[0] == AK_LOKAY, "fig5-17: last block LAST OKAY");
    finish_cmd(c);
    // ---- figure 5-18: source command trigger, destination flow control
    c = mk(0, 0, 'h200, 'h300, 40);
    c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 0;
    c.use_destrig = 1; c.destrig_type = TT_HW; c.destrig_sel = 1; c.destrig_mode = TM_DMAFC; c.destrig_blk = 15;
    init_src(c);
    start_cmd(c);
    w0 = env.sb.n_wr_bytes;
    env.trig.in_req(0, RQ_BLOCK, at);
    repeat (300) @(posedge vif.clk);
    chk(env.sb.n_wr_bytes == w0, "fig5-18: writes before the destination trigger");
    env.trig.in_req(1, RQ_BLOCK, at);
    chk(env.sb.n_wr_bytes - w0 == 16 && at == AK_OKAY, "fig5-18: first destination block = 16 elements");
    env.trig.in_req(1, RQ_BLOCK, at);
    env.trig.in_req(1, RQ_BLOCK, at);
    chk(at == AK_LOKAY, "fig5-18: final (partial) block acknowledged with LAST OKAY");
    finish_cmd(c);
    // ---- 6.2 example: source block 5, destination block 8 (2 elements stay in the FIFO)
    c = mk(0, 0, 'h400, 'h500, 16);
    c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 0; c.srctrig_mode = TM_DMAFC; c.srctrig_blk = 4;
    c.use_destrig = 1; c.destrig_type = TT_HW; c.destrig_sel = 1; c.destrig_mode = TM_DMAFC; c.destrig_blk = 7;
    init_src(c);
    start_cmd(c);
    w0 = env.sb.n_wr_bytes;
    env.trig.in_req(0, RQ_BLOCK, at);
    env.trig.in_req(0, RQ_BLOCK, at);
    env.trig.in_req(1, RQ_BLOCK, at);
    chk(env.sb.n_wr_bytes - w0 == 8, $sformatf("6.2 example: %0d bytes after the first destination block", env.sb.n_wr_bytes - w0));
    env.trig.in_req(0, RQ_BLOCK, at);
    env.trig.in_req(0, RQ_SINGLE, at);                  // last element of the source as SINGLE
    chk(at == AK_LOKAY, "6.2 example: source end with LAST OKAY");
    env.trig.in_req(1, RQ_BLOCK, at);
    chk(at == AK_LOKAY, "6.2 example: destination end with LAST OKAY");
    finish_cmd(c);
    // ---- trigger output as end of command synchronisation (figure 5-20)
    if (TB_NTO > 0) begin
      c = mk(0, 0, 'h600, 'h700, 32);
      c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = 0;
      env.trig.out_auto_ack[0] = 0;
      init_src(c);
      start_cmd(c);
      env.trig.out_ack(0);
      finish_cmd(c);
      chk(vif.trig_out_req[0] == 1'b0, "trigger output request still high");
    end
  endtask
endclass
