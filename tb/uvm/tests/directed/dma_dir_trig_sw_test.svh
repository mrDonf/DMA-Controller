//-----------------------------------------------------------------------------
// dma_dir_trig_sw_test.svh
//   Software triggers with DMA driven flow control (TRM 5.4) and the abort paths
//   of the trigger state machines:
//     1. source SW block requests, size not a multiple of the block (3 blocks)
//     2. source SW block requests, size an exact multiple of the block
//     3. destination SW block / single requests
//     4. STOP while waiting for a trigger input (no request)
//     5. STOP after the source command trigger, destination trigger missing
//     6. STOP in the middle of a flow control block
//     7. STOP while the trigger output waits for its ack to be released
//     8. source waiting for a SW block request, destination peripheral sends LAST
//   Every number of requests is fixed by the TRM rule: blocks of BLKSIZE+1 elements.
//-----------------------------------------------------------------------------
class dma_dir_trig_sw_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_trig_sw_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  localparam bit [31:0] SRC_BLK = (1 << 16) | (2'b10 << 17);
  localparam bit [31:0] SRC_SGL = (1 << 16);
  localparam bit [31:0] DES_BLK = (1 << 20) | (2'b10 << 21);
  localparam bit [31:0] DES_SGL = (1 << 20);

  // issue n software requests, each one after the channel reports the wait
  task sw_reqs(int ch, bit des, int n, bit single = 0);
    for (int i = 0; i < n; i++) begin
      wait_status_bit(ch, des ? ST_DESTRIGWAIT : ST_SRCTRIGWAIT);
      regs.chw(ch, CH_CMD, des ? (single ? DES_SGL : DES_BLK) : (single ? SRC_SGL : SRC_BLK));
    end
  endtask

  // start a command that is stopped (data not checked)
  task start_relaxed(dma_cmd c);
    init_src(c);
    void'(expect_cmd(c));
    env.sb.relax(c.ch);
    regs.program_cmd(c);
    regs.enable(c.ch);
  endtask

  task stop_and_check(int ch, string tag);
    bit [31:0] st;
    regs.chw(ch, CH_CMD, 1 << 3);
    regs.wait_idle(ch, st);
    chk(st[ST_STOPPED], $sformatf("%s: status %08h, expected STOPPED", tag, st));
    regs.chr(ch, CH_STATUS, st);
    chk(!st[ST_SRCTRIGWAIT] && !st[ST_DESTRIGWAIT] && !st[ST_TRIGOUTWAIT],
        $sformatf("%s: trigger wait status left after the stop (%08h)", tag, st));
    env.sb.clear_reads(ch);
    regs.clear_status(ch);
    env.sb.unrelax(ch);
  endtask

  task body();
    dma_cmd c;
    bit [31:0] st;
    if (TB_NTI == 0) begin `uvm_info("TEST", "no trigger support (CH_BUILDCFG1.HAS_TRIGIN = 0): skipped", UVM_NONE) return; end
    // ---------------- 1. source, 10 elements in blocks of 4 -> 3 requests
    c = mk(0, 0, 'h000, 'h000, 10);
    c.use_srctrig = 1; c.srctrig_type = TT_SW; c.srctrig_mode = TM_DMAFC; c.srctrig_blk = 3;
    init_src(c); start_cmd(c);
    sw_reqs(0, 0, 3);
    finish_cmd(c);
    // ---------------- 2. source, 8 elements in blocks of 4 -> 2 requests
    c = mk(0, $clog2(TB_DWB), 'h100, 'h100, 8);
    c.use_srctrig = 1; c.srctrig_type = TT_SW; c.srctrig_mode = TM_DMAFC; c.srctrig_blk = 3;
    init_src(c); start_cmd(c);
    sw_reqs(0, 0, 2);
    finish_cmd(c);
    // ---------------- 3. destination: 6 elements, blocks of 2 (3 requests), then singles
    c = mk(0, 1, 'h200, 'h200, 6);
    c.use_destrig = 1; c.destrig_type = TT_SW; c.destrig_mode = TM_DMAFC; c.destrig_blk = 1;
    init_src(c); start_cmd(c);
    sw_reqs(0, 1, 3);
    finish_cmd(c);
    c = mk(0, 2, 'h300, 'h300, 3);
    c.use_destrig = 1; c.destrig_type = TT_SW; c.destrig_mode = TM_DMAFC; c.destrig_blk = 7;
    init_src(c); start_cmd(c);
    sw_reqs(0, 1, 3, 1);                               // SINGLE: one element per request
    finish_cmd(c);
    // ---------------- 4. STOP while waiting for a trigger (command and flow control mode)
    if (TB_NTI > 0) begin
      c = mk(0, 0, 'h400, 'h400, 16);
      c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 0;
      start_relaxed(c);
      wait_status_bit(0, ST_SRCTRIGWAIT);
      stop_and_check(0, "stop in trigger wait (command mode)");
    end
    c = mk(0, 0, 'h400, 'h400, 16);
    c.use_destrig = 1; c.destrig_type = TT_SW; c.destrig_mode = TM_DMAFC; c.destrig_blk = 3;
    start_relaxed(c);
    wait_status_bit(0, ST_DESTRIGWAIT);
    stop_and_check(0, "stop in trigger wait (flow control)");
    // ---------------- 5. STOP with the source trigger received, destination trigger missing
    c = mk(0, 0, 'h500, 'h500, 16);
    c.use_srctrig = 1; c.srctrig_type = TT_SW;
    c.use_destrig = 1; c.destrig_type = TT_SW;
    start_relaxed(c);
    wait_status_bit(0, ST_SRCTRIGWAIT);
    regs.chw(0, CH_CMD, SRC_SGL);
    wait_status_bit(0, ST_SRCTRIGWAIT, 0);
    repeat (20) @(posedge vif.clk);
    regs.chr(0, CH_STATUS, st);
    chk(st[ST_DESTRIGWAIT], $sformatf("destination trigger wait expected (%08h)", st));
    stop_and_check(0, "stop with one command trigger received");
    // ---------------- 6. STOP in the middle of a flow control block
    slow_mem(1);
    c = mk(0, 0, 'h600, 'h600, 240);
    c.use_srctrig = 1; c.srctrig_type = TT_SW; c.srctrig_mode = TM_DMAFC; c.srctrig_blk = 255;
    start_relaxed(c);
    wait_status_bit(0, ST_SRCTRIGWAIT);
    regs.chw(0, CH_CMD, SRC_BLK);
    repeat (60) @(posedge vif.clk);
    chk(vif.ch_enabled[0] === 1'b1, "flow control block finished too early for the stop");
    stop_and_check(0, "stop in a flow control block");
    slow_mem(0);
    // the channel works normally afterwards
    c = mk(0, 0, 'h700, 'h700, 5);
    c.use_srctrig = 1; c.srctrig_type = TT_SW; c.srctrig_mode = TM_DMAFC; c.srctrig_blk = 1;
    init_src(c); start_cmd(c);
    sw_reqs(0, 0, 3);
    finish_cmd(c);
    // ---------------- 7. STOP while the trigger output waits for ack low
    if (TB_NTO > 0) begin
      env.trig.out_auto_ack[0] = 0;
      c = mk(0, 0, 'h800, 'h800, 8);
      c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = 0;
      start_relaxed(c);
      while (vif.trig_out_req[0] !== 1'b1) @(posedge vif.clk);
      vif.trig_out_ack[0] <= 1'b1;                     // ack held high
      while (vif.trig_out_req[0] !== 1'b0) @(posedge vif.clk);
      repeat (10) @(posedge vif.clk);
      stop_and_check(0, "stop with the trigger output ack still high");
      vif.trig_out_ack[0] <= 1'b0;
      repeat (10) @(posedge vif.clk);
      env.trig.out_auto_ack[0] = 1;
      c = mk(0, 0, 'h900, 'h900, 8);
      c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = 0;
      init_src(c); run_cmd(c);
    end
    // ---------------- 8. source waits for its next SW flow control request while the
    //                     destination peripheral ends the command (LAST BLOCK)
    begin
      dma_cmd pc;
      c = mk(0, 0, 'hA00, 'hA00, 32);
      c.use_srctrig = 1; c.srctrig_type = TT_SW; c.srctrig_mode = TM_DMAFC; c.srctrig_blk = 3;
      c.use_destrig = 1; c.destrig_type = TT_HW; c.destrig_sel = 0; c.destrig_mode = TM_PERFC; c.destrig_blk = 3;
      $cast(pc, c.clone());
      pc.srcxsize = 4; pc.desxsize = 4;                  // one block of 4 elements on each side
      init_src(c);
      void'(expect_cmd(pc));
      env.sb.allow_read(0, c.srcaddr, 4);
      regs.program_cmd(c);
      regs.enable(0);
      sw_reqs(0, 0, 1);
      wait_status_bit(0, ST_SRCTRIGWAIT);                // source back in its trigger wait
      env.trig.fc_peripheral(0, 1, 1, 5);
      finish_cmd(c);
    end
  endtask
endclass
