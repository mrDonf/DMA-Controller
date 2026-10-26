//-----------------------------------------------------------------------------
// dma_reg_test.svh
//   Register map: reset values, write masks, BUILDCFG / ID registers, PSTRB errors,
//   reserved space, read-only while enabled.
//-----------------------------------------------------------------------------
class dma_reg_test extends dma_ctrl_base;
  `uvm_component_utils(dma_reg_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task chk(int addr, bit [31:0] expv, string what, bit [2:0] prot = PROT_S_P);
    bit [31:0] v;
    regs.rd(addr, v, TB_SECEXT ? prot : (prot | 3'b010));
    if (v !== expv) `uvm_error("REGS", $sformatf("%s @0x%03h = %08h expected %08h", what, addr, v, expv))
  endtask

  task body();
    int ts_bits = (TB_DWB == 16) ? 3 : 2;
    bit e;
    for (int ch = 0; ch < TB_NCH; ch++) begin
      int b = R_CH(ch);
      bit ext = TB_EXT_MASK[ch], str = TB_STREAM_MASK[ch], gpo = TB_GPO_MASK[ch] && TB_GPOW > 0;
      bit [31:0] gm = (TB_GPOW >= 32) ? 32'hFFFF_FFFF : ((32'h1 << TB_GPOW) - 1);
      bit [31:0] ctrlm, hi;
      // reset values
      chk(b + CH_CTRL,        32'h0020_0200, "CH_CTRL reset");
      chk(b + CH_SRCTRANSCFG, 32'h000F_0400, "CH_SRCTRANSCFG reset");
      chk(b + CH_DESTRANSCFG, 32'h000F_0400, "CH_DESTRANSCFG reset");
      chk(b + CH_SRCTMPLT,    ext ? 32'h1 : 32'h0, "CH_SRCTMPLT reset");
      chk(b + CH_ISSUECAP,    32'h7, "CH_ISSUECAP reset");
      chk(b + CH_IIDR,        32'h3A00_043B, "CH_IIDR");
      chk(b + CH_STATUS,      32'h0, "CH_STATUS reset");
      chk(b + CH_LINKADDR,    32'h0, "CH_LINKADDR reset");
      chk(b + CH_BUILDCFG0,   {2'b00, 4'd15, 1'b0, 3'($clog2(TB_DWB)), 6'(TB_AW - 1), 8'd15,
                               8'(tb_fifo_depth(ch) < 2 ? 1 : tb_fifo_depth(ch) - 1)}, "CH_BUILDCFG0");
      chk(b + CH_BUILDCFG1,   {6'd0, 7'(gpo ? TB_GPOW : 0), 1'b0, 5'd0, 1'b0, str, 4'b1111,
                               TB_NTO > 0, TB_NTI > 0, 1'b1, ext, ext, ext, 1'b1}, "CH_BUILDCFG1");
      // write ones / read back masks
      ctrlm = {2'b00, str, gpo, 4'hF, 3'b111, 3'b111, 3'b000, ext ? 3'b111 : 3'b000, 3'b111, 1'b0, 4'hF, 1'b0,
               3'((1 << ts_bits) - 1)};
      hi    = (TB_AW > 32) ? ((32'h1 << (TB_AW - 32)) - 1) : 32'h0;
      begin
        int offs[$] = '{CH_INTREN, CH_CTRL, CH_SRCADDR, CH_SRCADDRHI, CH_DESADDR, CH_XSIZE, CH_XSIZEHI,
                        CH_SRCTRANSCFG, CH_XADDRINC, CH_YADDRSTRIDE, CH_FILLVAL, CH_YSIZE, CH_TMPLTCFG,
                        CH_SRCTMPLT, CH_SRCTRIGINCFG, CH_TRIGOUTCFG, CH_GPOEN0, CH_GPOVAL0,
                        CH_STREAMINTCFG, CH_LINKATTR, CH_AUTOCFG, CH_LINKADDR, CH_LINKADDRHI,
                        CH_ISSUECAP, CH_WRKREGPTR, CH_IIDR, CH_BUILDCFG0};
        bit [31:0] msk[$] = '{32'h0000_070F, ctrlm, 32'hFFFF_FFFF, hi, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF,
                              32'h000F_07FF, 32'hFFFF_FFFF, ext ? 32'hFFFF_FFFF : 0, ext ? 32'hFFFF_FFFF : 0,
                              ext ? 32'hFFFF_FFFF : 0, ext ? 32'h001F_1F00 : 0, ext ? 32'hFFFF_FFFF : 0,
                              (TB_NTI > 0) ? 32'h00FF_0FFF : 32'h0000_0FFF,
                              (TB_NTO > 0) ? 32'h0000_033F : 32'h0000_0300,
                              gpo ? gm : 0, gpo ? gm : 0, str ? 32'h0000_0600 : 0, 32'h0000_03FF,
                              32'h0001_FFFF, 32'hFFFF_FFFD, hi, 32'h7, 32'hF, 32'h3A00_043B,
                              {2'b00, 4'd15, 1'b0, 3'($clog2(TB_DWB)), 6'(TB_AW - 1), 8'd15,
                               8'(tb_fifo_depth(ch) < 2 ? 1 : tb_fifo_depth(ch) - 1)}};
        foreach (offs[i]) begin
          regs.chw(ch, offs[i], 32'hFFFF_FFFF);
          chk(b + offs[i], msk[i], $sformatf("ch%0d mask off 0x%02h", ch, offs[i]));
        end
      end
      // CLEARCMD restores the reset values
      regs.chw(ch, CH_CMD, 32'h2);
      repeat (3) @(posedge vif.clk);
      chk(b + CH_CTRL, 32'h0020_0200, "CH_CTRL after CLEARCMD");
      chk(b + CH_ISSUECAP, 32'h7, "CH_ISSUECAP after CLEARCMD");
      chk(b + CH_FILLVAL, 32'h0, "CH_FILLVAL after CLEARCMD");
    end
    // unit information frame
    chk(R_INFO + 'hB0, {7'd0, 5'(TB_CHIDW), 1'b0, 3'($clog2(TB_DWB)), 6'(TB_AW - 1), 6'(TB_NCH - 1), 4'd0},
        "DMA_BUILDCFG0");
    chk(R_INFO + 'hB4, {15'd1, 7'(TB_NTO), 9'(TB_NTI)} | 32'h0001_0000, "DMA_BUILDCFG1");
    chk(R_INFO + 'hB8, {22'd0, 1'b1, TB_SECEXT, 1'b0, 7'd0}, "DMA_BUILDCFG2");
    chk(R_INFO + 'hC8, 32'h3A00_043B, "IIDR");
    chk(R_INFO + 'hE0, 32'hA0, "PIDR0");
    chk(R_INFO + 'hE4, 32'hB3, "PIDR1");
    chk(R_INFO + 'hE8, 32'h0B, "PIDR2");
    chk(R_INFO + 'hF0, 32'h0D, "CIDR0");
    chk(R_INFO + 'hF4, 32'hF0, "CIDR1");
    chk(R_INFO + 'hF8, 32'h05, "CIDR2");
    chk(R_INFO + 'hFC, 32'hB1, "CIDR3");
    chk(R_INFO + 'hFC, 32'hB1, "CIDR3 unprivileged NS", PROT_NS_U);
    // byte strobes are not supported: PSLVERR, no write
    begin
      bit [31:0] v;
      regs.bus.write(13'(R_CH(0) + CH_FILLVAL), 32'h1111_1111, e, 4'h3, TB_SECEXT ? PROT_S_P : PROT_NS_P);
      if (!e) `uvm_error("REGS", "partial PSTRB write did not answer PSLVERR")
      chk(R_CH(0) + CH_FILLVAL, 32'h0, "FILLVAL after partial-strobe write");
    end
    // reserved address space reads as zero
    chk('h0400, 32'h0, "reserved frame");
    if (TB_NCH < 8) chk(R_CH(TB_NCH) + CH_CTRL, 32'h0, "non-existing channel");
    // channel registers are read only while the channel is enabled
    begin
      dma_cmd c = simple(0, 2048, 0);
      bit [31:0] v;
      slow_mem(1);
      init_src(c);
      start_cmd(c);
      regs.chw(0, CH_FILLVAL, 32'hFFFF_FFFF);
      regs.chw(0, CH_LINKATTR, 32'h3FF);
      chk(R_CH(0) + CH_LINKATTR, 32'h044, "CH_LINKATTR written while enabled");
      finish_cmd(c);
      slow_mem(0);
    end
  endtask
endclass
