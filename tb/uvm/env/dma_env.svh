//-----------------------------------------------------------------------------
// dma_env.svh - register access API, memory helper and the environment
//-----------------------------------------------------------------------------
class dma_reg_api extends uvm_object;
  `uvm_object_utils(dma_reg_api)
  apb_api_seq    bus;
  dma_ctrl_vif_t vif;
  bit            ch_ns [int];        // current channel security (TB view)
  bit            ch_pv [int];        // channel privileged
  bit [2:0]      def_prot = PROT_S_P;
  int unsigned   n_acc;

  function new(string name = "dma_reg_api"); super.new(name); endfunction

  task wr(int addr, bit [31:0] d, bit [2:0] prot = 3'b111, bit check = 1);
    bit e;
    if (prot == 3'b111) prot = def_prot;
    bus.write(13'(addr), d, e, 4'hF, prot);
    n_acc++;
    if (check && e) `uvm_error("REG", $sformatf("write 0x%0h=0x%0h got PSLVERR", addr, d))
  endtask

  task rd(int addr, output bit [31:0] d, input bit [2:0] prot = 3'b111, input bit check = 1);
    bit e;
    if (prot == 3'b111) prot = def_prot;
    bus.read(13'(addr), d, e, prot);
    n_acc++;
    if (check && e) `uvm_error("REG", $sformatf("read 0x%0h got PSLVERR", addr))
  endtask

  task wr_e(int addr, bit [31:0] d, bit [2:0] prot, output bit e);
    bus.write(13'(addr), d, e, 4'hF, prot);
    n_acc++;
  endtask

  task rd_e(int addr, output bit [31:0] d, input bit [2:0] prot, output bit e);
    bus.read(13'(addr), d, e, prot);
    n_acc++;
  endtask

  function bit [2:0] ch_prot(int ch);
    bit ns = ch_ns.exists(ch) ? ch_ns[ch] : !TB_SECEXT;
    return {1'b0, ns, 1'b1};
  endfunction

  task chw(int ch, int off, bit [31:0] d);
    wr(R_CH(ch) + off, d, ch_prot(ch));
  endtask

  task chr(int ch, int off, output bit [31:0] d);
    rd(R_CH(ch) + off, d, ch_prot(ch));
  endtask

  // channel security / privilege (SCFG_CHSEC0 / SEC_CHCFG)
  task set_ch_attr(int ch, bit ns, bit priv);
    bit [31:0] v;
    if (TB_SECEXT) begin
      rd(R_SECCFG + SCFG_CHSEC0, v, PROT_S_P);
      v[ch] = ns;
      wr(R_SECCFG + SCFG_CHSEC0, v, PROT_S_P);
      wr(R_SECCTRL + U_CHPTR, ch, PROT_S_P);
      rd(R_SECCTRL + U_CHCFG, v, PROT_S_P);
      v[17] = priv;
      wr(R_SECCTRL + U_CHCFG, v, PROT_S_P);
    end else begin
      wr(R_NSCTRL + U_CHPTR, ch, PROT_NS_P);
      rd(R_NSCTRL + U_CHCFG, v, PROT_NS_P);
      v[17] = priv;
      wr(R_NSCTRL + U_CHCFG, v, PROT_NS_P);
    end
    ch_ns[ch] = TB_SECEXT ? ns : 1'b1;
    ch_pv[ch] = priv;
  endtask

  // program every configuration register of a command
  task program_cmd(dma_cmd c);
    int offs[$] = '{CH_INTREN, CH_CTRL, CH_SRCADDR, CH_DESADDR, CH_XSIZE, CH_XSIZEHI, CH_SRCTRANSCFG,
                    CH_DESTRANSCFG, CH_XADDRINC, CH_YADDRSTRIDE, CH_FILLVAL, CH_YSIZE, CH_TMPLTCFG,
                    CH_SRCTMPLT, CH_DESTMPLT, CH_SRCTRIGINCFG, CH_DESTRIGINCFG, CH_TRIGOUTCFG,
                    CH_GPOEN0, CH_GPOVAL0, CH_STREAMINTCFG, CH_LINKATTR, CH_AUTOCFG, CH_LINKADDR};
    if (TB_AW > 32) begin
      offs.push_back(CH_SRCADDRHI); offs.push_back(CH_DESADDRHI); offs.push_back(CH_LINKADDRHI);
    end
    foreach (offs[i]) chw(c.ch, offs[i], c.reg_value(offs[i]));
  endtask

  task enable(int ch);
    chw(ch, CH_CMD, 32'h1);
  endtask

  // wait until the channel is no longer enabled, return CH_STATUS
  task wait_idle(int ch, output bit [31:0] st, input longint timeout = 2000000);
    longint t = 0;
    @(posedge vif.clk);
    while (vif.ch_enabled[ch] === 1'b1 && t < timeout) begin @(posedge vif.clk); t++; end
    if (t >= timeout) `uvm_error("REG", $sformatf("ch%0d still enabled after %0d cycles", ch, timeout))
    chr(ch, CH_STATUS, st);
  endtask

  task clear_status(int ch);
    chw(ch, CH_STATUS, 32'h000F_0000);
  endtask
endclass : dma_reg_api

// -----------------------------------------------------------------------------
class dma_env extends uvm_env;
  `uvm_component_utils(dma_env)

  apb_agent         apb;
  axi5_agent        axi [2];
  axis_agent        so  [TB_NCH];
  axis_agent        si  [TB_NCH];
  dma_so_sub        so_sub [TB_NCH];
  dma_stream_engine eng [TB_NCH];
  dma_scoreboard    sb;
  dma_coverage      cov;
  dma_perf_mon      perf;
  dma_trig_agent    trig;
  dma_lpi_driver    lpi;
  vip_sparse_mem    mem;
  dma_ctrl_vif_t    vif;
  apb_agent_cfg     apb_cfg;
  axi5_agent_cfg    axi_cfg [2];
  axis_agent_cfg    so_cfg [TB_NCH];
  axis_agent_cfg    si_cfg [TB_NCH];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(dma_ctrl_vif_t)::get(this, "", "ctrl_vif", vif)) `uvm_fatal("ENV", "no ctrl_vif")
    mem = new();
    mem.init_mode = MEM_INIT_ADDR_HASH;

    apb_cfg = apb_agent_cfg::type_id::create("apb_cfg");
    if (!uvm_config_db #(apb_vif_t)::get(this, "", "apb_vif", apb_cfg.vif)) `uvm_fatal("ENV", "no apb_vif")
    apb_cfg.role = VIP_MASTER;
    apb_cfg.timeout_cycles = 200;
    uvm_config_db #(apb_agent_cfg)::set(this, "apb*", "cfg", apb_cfg);
    apb = apb_agent::type_id::create("apb", this);

    for (int p = 0; p < 2; p++) begin
      axi_cfg[p] = axi5_agent_cfg::type_id::create($sformatf("axi_cfg%0d", p));
      if (!uvm_config_db #(axi5_vif_t)::get(this, "", $sformatf("axi_m%0d_vif", p), axi_cfg[p].vif))
        `uvm_fatal("ENV", "no axi vif")
      axi_cfg[p].role        = VIP_SLAVE;
      axi_cfg[p].mem         = mem;
      axi_cfg[p].mem_init    = MEM_INIT_ADDR_HASH;
      axi_cfg[p].datachk_en  = 1'b0;      // the DMA has no data check signals
      axi_cfg[p].wakeup_en   = 1'b1;
      axi_cfg[p].atomics_en  = 1'b0;
      axi_cfg[p].poison_en   = 1'b1;
      axi_cfg[p].timeout_cycles = 100000;
      uvm_config_db #(axi5_agent_cfg)::set(this, $sformatf("axi%0d*", p), "cfg", axi_cfg[p]);
      axi[p] = axi5_agent::type_id::create($sformatf("axi%0d", p), this);
    end

    for (int c = 0; c < TB_NCH; c++) begin
      if (!TB_STREAM_MASK[c]) continue;
      so_cfg[c] = axis_agent_cfg::type_id::create($sformatf("so_cfg%0d", c));
      if (!uvm_config_db #(axis_vif_t)::get(this, "", $sformatf("str_out_vif_%0d", c), so_cfg[c].vif))
        `uvm_fatal("ENV", "no str_out vif")
      so_cfg[c].role = VIP_SLAVE;
      so_cfg[c].ready_mode = AXIS_RDY_RANDOM;
      so_cfg[c].ready_pct  = 80;
      uvm_config_db #(axis_agent_cfg)::set(this, $sformatf("so%0d*", c), "cfg", so_cfg[c]);
      so[c] = axis_agent::type_id::create($sformatf("so%0d", c), this);

      si_cfg[c] = axis_agent_cfg::type_id::create($sformatf("si_cfg%0d", c));
      if (!uvm_config_db #(axis_vif_t)::get(this, "", $sformatf("str_in_vif_%0d", c), si_cfg[c].vif))
        `uvm_fatal("ENV", "no str_in vif")
      si_cfg[c].role = VIP_MASTER;
      si_cfg[c].drive_junk = 1'b1;
      uvm_config_db #(axis_agent_cfg)::set(this, $sformatf("si%0d*", c), "cfg", si_cfg[c]);
      si[c] = axis_agent::type_id::create($sformatf("si%0d", c), this);

      so_sub[c] = dma_so_sub::type_id::create($sformatf("so_sub%0d", c), this);
      so_sub[c].ch = c;
      eng[c] = dma_stream_engine::type_id::create($sformatf("eng%0d", c), this);
      eng[c].ch = c;
    end

    sb   = dma_scoreboard::type_id::create("sb", this);
    cov  = dma_coverage::type_id::create("cov", this);
    perf = dma_perf_mon::type_id::create("perf", this);
    trig = dma_trig_agent::type_id::create("trig", this);
    lpi  = dma_lpi_driver::type_id::create("lpi", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    axi[0].ap.connect(sb.imp_m0);
    axi[1].ap.connect(sb.imp_m1);
    axi[0].ap.connect(perf.imp0);
    axi[1].ap.connect(perf.imp1);
    axi[0].ap.connect(cov.axi_imp);
    apb.ap.connect(cov.apb_imp);
    cov.vif = vif;
    axi[1].ap.connect(cov.axi_imp);
    trig.vif = vif;
    lpi.vif  = vif;
    for (int c = 0; c < TB_NCH; c++) begin
      if (!TB_STREAM_MASK[c]) continue;
      so_sub[c].sb = sb;
      so[c].ap.connect(so_sub[c].analysis_export);
      so_sub[c].fwd.connect(eng[c].analysis_export);
      eng[c].sqr = si[c].sqr;
    end
  endfunction
endclass : dma_env
