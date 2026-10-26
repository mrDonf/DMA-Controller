//-----------------------------------------------------------------------------
// dma_err_test.svh
//   Error handling: AXI read / write errors, poison, REGVALERR / CFGCONFLERR cases,
//   trigger selection errors, normal operation afterwards.
//-----------------------------------------------------------------------------
class dma_err_test extends dma_ctrl_base;
  `uvm_component_utils(dma_err_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_cmd c;
    bit [1:0] at;
    longint unsigned a;
    // ---------------- AXI read error response
    c = simple(0, 512);
    init_src(c);
    a = c.srcaddr & ~longint'(c.esize() - 1);
    env.axi_cfg[0].err_lo = a;                         // every read burst of the source fails
    env.axi_cfg[0].err_hi = a + 512;
    run_err(c, 32'h0001_0001, 1);
    env.axi_cfg[0].err_lo = '1; env.axi_cfg[0].err_hi = '0;
    // ---------------- AXI write error response
    c = simple(1 % TB_NCH, 512);
    init_src(c);
    a = c.desaddr & ~longint'(c.esize() - 1);
    env.axi_cfg[0].err_lo = a;
    env.axi_cfg[0].err_hi = a + 32;
    run_err(c, 32'h0002_0001, 1);
    env.axi_cfg[0].err_lo = '1; env.axi_cfg[0].err_hi = '0;
    // ---------------- read data poison
    c = simple(2 % TB_NCH, 256);
    init_src(c);
    a = (c.srcaddr + 40) & ~longint'(AXI5_CHUNK_B - 1);
    env.axi[0].sdrv.poisoned[a] = 1'b1;
    run_err(c, 32'h0004_0001, 1);
    env.axi[0].sdrv.poisoned.delete();
    // ---------------- configuration errors: illegal values (REGVALERR)
    c = simple(0, 64); c.xtype = 3'b100;              run_err(c, 32'h0200_0002);
    c = simple(0, 64); c.donetype = 3'b010;           run_err(c, 32'h0200_0002);
    c = simple(0, 64); c.regreload = 3'b010;          run_err(c, 32'h0200_0002);
    c = simple(0, 64); c.use_srctrig = 1; c.srctrig_type = 2'b01; run_err(c, 32'h0200_0002);
    if (TB_NTI > 0) begin
      c = simple(0, 64); c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = TB_NTI; run_err(c, 32'h0200_0002);
    end
    if (TB_NTO > 0) begin
      c = simple(0, 64); c.use_trigout = 1; c.trigout_type = TT_HW; c.trigout_sel = TB_NTO; run_err(c, 32'h0200_0002);
    end
    if (TB_NCH > 1) begin
      c = simple(1, 64); c.use_destrig = 1; c.destrig_type = TT_INT; c.destrig_sel = 1; run_err(c, 32'h0200_0002);
    end
    if (TB_DWB == 16) begin
      c = simple(0, 64, 0); c.ts = 5; run_err(c, 32'h0200_0002);
    end
    // ---------------- configuration errors: conflicting settings (CFGCONFLERR)
    if (TB_EXT_MASK[0]) begin
      c = simple(0, 64); c.ytype = T_CONTINUE; c.srcysize = 2; c.desysize = 2; c.srctsize = 3; c.srctmplt = 5;
      run_err(c, 32'h0400_0002);
      if (TB_NTI > 0) begin
        c = simple(0, 64); c.ytype = T_CONTINUE; c.srcysize = 3; c.desysize = 3;
        c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_mode = TM_DMAFC;
        run_err(c, 32'h0400_0002);
        c = simple(0, 64); c.xtype = T_WRAP; c.desxsize = 2 * c.srcxsize;
        c.use_srctrig = 1; c.srctrig_type = TT_SW; c.srctrig_mode = TM_PERFC;
        run_err(c, 32'h0400_0002);
      end
    end
    if (TB_STREAM_MASK[0]) begin
      c = simple(0, 64); c.use_stream = 1; c.streamtype = SM_OUT; c.xtype = T_WRAP; run_err(c, 32'h0400_0002);
      c = simple(0, 64); c.use_stream = 1; c.streamtype = 2'b11;                   run_err(c, 32'h0200_0002);
    end
    // ---------------- trigger selection errors
    if (TB_NTI > 0 && TB_NCH > 1) begin
      dma_cmd c0 = simple(0, 64);
      c0.use_srctrig = 1; c0.srctrig_type = TT_HW; c0.srctrig_sel = 0;
      init_src(c0);
      start_cmd(c0);
      wait_status_bit(0, ST_SRCTRIGWAIT);
      c = simple(1, 64);
      c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 0;   // port owned by ch0
      run_err(c, 32'h0000_0004);
      env.trig.in_req(0, RQ_BLOCK, at);
      finish_cmd(c0);
      if (TB_NTI > 1) begin
        c = simple(1, 64);                                             // same port for both sides
        c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 1;
        c.use_destrig = 1; c.destrig_type = TT_HW; c.destrig_sel = 1;
        run_err(c, 32'h0000_000C);
      end
      if (TB_SECEXT) begin                                             // security mismatch
        regs.set_ch_attr(1, 1, 0);
        c = simple(1, 64);
        c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = 0;
        run_err(c, 32'h0000_0004);
        regs.set_ch_attr(1, 0, 0);
      end
    end
    // ---------------- a normal command still works afterwards
    for (int ch = 0; ch < TB_NCH; ch++) begin
      c = gen_cmd(ch);
      init_src(c);
      run_cmd(c);
    end
  endtask
endclass
