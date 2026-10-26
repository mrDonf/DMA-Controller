//-----------------------------------------------------------------------------
// dma_sec_test.svh
//   Security / privilege: RAZ/WI and PSLVERR violations, interrupt, PDEBUG, Non-secure
//   channel, privileged channel, attribute change clear, SEC_CFG_LCK.
//-----------------------------------------------------------------------------
class dma_sec_test extends dma_ctrl_base;
  `uvm_component_utils(dma_sec_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [31:0] v;
    bit e;
    dma_cmd c;
    if (!TB_SECEXT) begin
      // without TrustZone: privilege checks only
      regs.set_ch_attr(0, 1, 1);
      regs.wr(R_CH(0) + CH_FILLVAL, 32'h1234_5678, PROT_NS_P);
      regs.rd(R_CH(0) + CH_FILLVAL, v, PROT_NS_U);
      if (v != 0) `uvm_error("TEST", "unprivileged access to a privileged channel not RAZ")
      regs.set_ch_attr(0, 1, 0);
      c = simple(0, 256); init_src(c); run_cmd(c);
      return;
    end
    // ---------------- Non-secure access to a Secure channel: RAZ/WI + violation status
    regs.wr(R_CH(0) + CH_FILLVAL, 32'hCAFE_0001, PROT_S_P);
    regs.wr(R_CH(0) + CH_FILLVAL, 32'h0BAD_0BAD, PROT_NS_P);
    regs.rd(R_CH(0) + CH_FILLVAL, v, PROT_NS_P);
    if (v != 0) `uvm_error("TEST", "Non-secure read of a Secure channel not RAZ")
    regs.rd(R_CH(0) + CH_FILLVAL, v, PROT_S_P);
    if (v != 32'hCAFE_0001) `uvm_error("TEST", "Non-secure write to a Secure channel not ignored")
    regs.rd(R_SECCFG + SCFG_INTRSTATUS, v, PROT_S_P);
    if (!v[16]) `uvm_error("TEST", "STAT_SECACCVIO not set")
    regs.wr(R_SECCFG + SCFG_CTRL, 32'h1, PROT_S_P);                    // INTREN_SECACCVIO
    repeat (3) @(posedge vif.clk);
    if (vif.irq_sec_viol_err !== 1'b1) `uvm_error("TEST", "irq_sec_viol_err not asserted")
    regs.wr(R_SECCFG + SCFG_INTRSTATUS, 32'h1_0000, PROT_S_P);
    repeat (3) @(posedge vif.clk);
    if (vif.irq_sec_viol_err !== 1'b0) `uvm_error("TEST", "irq_sec_viol_err not cleared")
    // ---------------- error response type
    regs.wr(R_SECCFG + SCFG_CTRL, 32'h3, PROT_S_P);
    regs.wr_e(R_SECCTRL + U_CTRL, 32'h0, PROT_NS_P, e);
    if (!e) `uvm_error("TEST", "RSPTYPE_SECACCVIO=1: no PSLVERR")
    regs.rd_e(R_SECCFG + SCFG_CHSEC0, v, PROT_NS_P, e);
    if (!e) `uvm_error("TEST", "RSPTYPE_SECACCVIO=1: no PSLVERR on read")
    // ---------------- debugger access (PDEBUG): no violation reported
    regs.wr(R_SECCFG + SCFG_INTRSTATUS, 32'h1_0000, PROT_S_P);
    vif.pdebug <= 1'b1;
    regs.rd_e(R_CH(0) + CH_CTRL, v, PROT_NS_P, e);
    vif.pdebug <= 1'b0;
    if (e || v != 0) `uvm_error("TEST", "PDEBUG access: expected RAZ without error")
    regs.rd(R_SECCFG + SCFG_INTRSTATUS, v, PROT_S_P);
    if (v[16]) `uvm_error("TEST", "PDEBUG access reported a violation")
    regs.wr(R_SECCFG + SCFG_CTRL, 32'h0, PROT_S_P);
    // ---------------- unprivileged access to the control frames
    regs.rd(R_SECCTRL + U_CTRL, v, PROT_S_U);
    regs.wr(R_NSCTRL + U_CTRL, 32'h0000_000F, PROT_NS_U);
    regs.rd(R_NSCTRL + U_CTRL, v, PROT_NS_P);
    if (v[3:0] != 0) `uvm_error("TEST", "unprivileged write to NSEC_CTRL not ignored")
    // ---------------- Non-secure channel: programmed by Non-secure SW, NS transfers
    regs.set_ch_attr(1 % TB_NCH, 1, 0);
    c = simple(1 % TB_NCH, 512);
    c.src_nonsec = 0; c.des_nonsec = 0; c.src_priv = 1;                  // tied: NS / unprivileged
    init_src(c);
    run_cmd(c);
    regs.chr(c.ch, CH_SRCTRANSCFG, v);
    if (!v[10] || v[11]) `uvm_error("TEST", $sformatf("NS channel SRCTRANSCFG ties: %08h", v))
    if (vif.ch_nonsec[c.ch] !== 1'b1) `uvm_error("TEST", "ch_nonsec output")
    // ---------------- Secure privileged channel with Secure / privileged transfers
    regs.set_ch_attr(0, 0, 1);
    c = simple(0, 512);
    c.src_nonsec = 0; c.src_priv = 1; c.des_nonsec = 1; c.des_priv = 1;
    init_src(c);
    run_cmd(c);
    regs.rd(R_CH(0) + CH_CTRL, v, PROT_S_U);
    if (v != 0) `uvm_error("TEST", "unprivileged read of a privileged channel not RAZ")
    if (vif.ch_priv[0] !== 1'b1) `uvm_error("TEST", "ch_priv output")
    // ---------------- attribute change clears the channel registers
    regs.chw(0, CH_FILLVAL, 32'h55AA_55AA);
    regs.set_ch_attr(0, 0, 0);
    regs.chr(0, CH_FILLVAL, v);
    if (v != 0) `uvm_error("TEST", "privilege change did not clear the channel registers")
    regs.set_ch_attr(1 % TB_NCH, 0, 0);
    // ---------------- security configuration lock
    regs.wr(R_SECCFG + SCFG_CTRL, 32'h8000_0000, PROT_S_P);
    regs.wr(R_SECCFG + SCFG_CHSEC0, 32'hFF, PROT_S_P);
    regs.rd(R_SECCFG + SCFG_CHSEC0, v, PROT_S_P);
    if (v != 0) `uvm_error("TEST", "SEC_CFG_LCK did not lock SCFG_CHSEC0")
  endtask
endclass
