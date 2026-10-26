//-----------------------------------------------------------------------------
// dma_trig_fc_test.svh
//   Flow control triggers: DMA / peripheral driven, source / destination, BLOCK / SINGLE.
//-----------------------------------------------------------------------------
class dma_trig_fc_test extends dma_feat_base;
  `uvm_component_utils(dma_trig_fc_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    if (TB_NTI == 0) begin `uvm_info("TEST", "no trigger inputs: skipped", UVM_NONE) return; end
    env.trig.async_mode = $test$plusargs("TRIG_ASYNC");
    for (int k = 0; k < 12; k++) begin
      int ch    = k % TB_NCH;
      int p     = $urandom_range(0, TB_NTI - 1);
      bit dst   = k[0];
      bit per   = k[1];
      bit sgl   = (k % 5 == 4);
      int blk   = $urandom_range(0, 40);
      dma_cmd c = simple(ch, $urandom_range(32, 600));
      dma_cmd pc;
      int n = c.srcxsize;
      int nblk, eff;
      if (dst) begin c.use_destrig = 1; c.destrig_type = TT_HW; c.destrig_sel = p; c.destrig_blk = blk;
                     c.destrig_mode = per ? TM_PERFC : TM_DMAFC; end
      else     begin c.use_srctrig = 1; c.srctrig_type = TT_HW; c.srctrig_sel = p; c.srctrig_blk = blk;
                     c.srctrig_mode = per ? TM_PERFC : TM_DMAFC; end
      eff  = sgl ? 1 : blk + 1;
      // peripheral driven: stop after about half of the data
      nblk = per ? (((n / 2) + eff - 1) / eff) : 0;
      if (per && nblk == 0) nblk = 1;
      $cast(pc, c.clone());
      if (per) begin
        int kel = (nblk * eff < n) ? nblk * eff : n;
        pc.srcxsize = kel;
        pc.desxsize = kel;
      end
      init_src(c);
      `uvm_info("FC", $sformatf("%s %s blk=%0d single=%0d nblk=%0d : %s", dst ? "DES" : "SRC",
                per ? "PERFC" : "DMAFC", blk, sgl, nblk, c.convert2string()), UVM_LOW)
      void'(expect_cmd(pc));
      env.sb.allow_read(ch, c.srcaddr & ~longint'(c.esize() - 1), n * c.esize());
      regs.program_cmd(c);
      regs.enable(ch);
      env.trig.fc_peripheral(p, per, nblk, 20, sgl);
      finish_cmd(c);
    end
  endtask
endclass
