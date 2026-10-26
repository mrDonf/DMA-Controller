//-----------------------------------------------------------------------------
// dma_coverage.svh - functional coverage model
//   cg_cmd   : command programming space (sampled for every executed command)
//   cg_axi   : burst shapes observed on the AXI manager ports
//   cg_event : error causes, channel control events, LPI decisions
// Directed tests close the specified cases; constrained random regression is
// used to fill the remaining cross bins.
//-----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_cov_axi)
`uvm_analysis_imp_decl(_cov_apb)

class dma_coverage extends uvm_component;
  `uvm_component_utils(dma_coverage)

  uvm_analysis_imp_cov_axi #(axi5_item, dma_coverage) axi_imp;
  uvm_analysis_imp_cov_apb #(apb_item, dma_coverage)  apb_imp;
  dma_ctrl_vif_t vif;

  // ---------------------------------------------------------------- sample variables
  dma_cmd    c;
  int        inc_s, inc_d;          // 0 zero, 1 one, 2 negative, 3 > 1
  int        szc_s, szc_d;          // 0 empty, 1 single, 2 <= bus, 3 large
  bit        al_s, al_d;            // address aligned to the bus
  bit        dev_s, dev_d;
  bit        port_s, port_d;
  int        trig_s, trig_d;        // 0 none, 1 SW cmd, 2 HW cmd, 3 INT cmd, 4 DMA FC, 5 PER FC
  int        trig_o;                // 0 none, 1 SW, 2 HW, 3 INT
  bit        linked, restart;
  axi5_item  t;
  int        t_len, t_size, t_burst;
  bit        t_unal, t_partial, t_wr, t_link;
  int        ev;

  typedef enum int { EV_RDRESP, EV_WRRESP, EV_POISON, EV_REGVAL, EV_CONFL, EV_LINKHDR, EV_TRIGSEL,
                     EV_STRB, EV_OVERRUN, EV_EARLY, EV_PAUSE, EV_STOP, EV_DISABLE, EV_ALLPAUSE,
                     EV_ALLSTOP, EV_HWPAUSE, EV_HWSTOP, EV_CTIHALT, EV_SECVIO, EV_Q_ACC, EV_Q_DENY,
                     EV_P_OFF, EV_P_RET, EV_P_WRST, EV_P_DENY, EV_AUTOBOOT, EV_CLEAR } ev_e;

  covergroup cg_cmd;
    option.per_instance = 1;
    cp_ts     : coverpoint c.ts { bins b[] = {[0:$clog2(TB_DWB)]}; }
    cp_xtype  : coverpoint c.xtype { bins dis = {0}; bins cont = {1}; bins wrap = {2}; bins fill = {3}; }
    cp_ytype  : coverpoint c.ytype { bins dis = {0}; bins cont = {1}; bins wrap = {2}; bins fill = {3}; }
    cx_type   : cross cp_xtype, cp_ytype { ignore_bins dis = binsof(cp_xtype.dis); }
    cp_inc_s  : coverpoint inc_s { bins zero = {0}; bins one = {1}; bins neg = {2}; bins big = {3}; }
    cp_inc_d  : coverpoint inc_d { bins zero = {0}; bins one = {1}; bins neg = {2}; bins big = {3}; }
    cx_inc_ts : cross cp_inc_s, cp_ts;
    cp_szc_s  : coverpoint szc_s { bins b[] = {[0:3]}; }
    cp_szc_d  : coverpoint szc_d { bins b[] = {[0:3]}; }
    cp_al     : coverpoint {al_s, al_d};
    cx_al_ts  : cross cp_al, cp_ts;
    cp_mem    : coverpoint {dev_s, dev_d};
    cp_mb_s   : coverpoint c.src_maxburst { bins one = {0}; bins mid = {[1:14]}; bins max = {15}; }
    cp_mb_d   : coverpoint c.des_maxburst { bins one = {0}; bins mid = {[1:14]}; bins max = {15}; }
    cp_tm_s   : coverpoint (c.srctsize != 0);
    cp_tm_d   : coverpoint (c.destsize != 0);
    cp_ystr_s : coverpoint $signed(c.srcystride) iff (c.ytype != 0) { bins neg = {[-32768:-1]}; bins zero = {0}; bins pos = {[1:32767]}; }
    cp_ystr_d : coverpoint $signed(c.desystride) iff (c.ytype != 0) { bins neg = {[-32768:-1]}; bins zero = {0}; bins pos = {[1:32767]}; }
    cp_stream : coverpoint {c.use_stream, c.streamtype} { bins none = {[0:3]}; bins io = {4}; bins out_only = {5}; bins in_only = {6}; }
    cp_str_ty : coverpoint {c.xtype, c.ytype} iff (c.use_stream) {
      bins x1d_cont = {6'b001_000}; bins x1d_fill = {6'b011_000};
      bins x2d_cc = {6'b001_001}; bins x2d_cf = {6'b001_011}; }
    cp_trig_s : coverpoint trig_s { bins b[] = {[0:5]}; }
    cp_trig_d : coverpoint trig_d { bins b[] = {[0:5]}; }
    cp_trig_o : coverpoint trig_o { bins b[] = {[0:3]}; }
    cp_port   : coverpoint {port_s, port_d} iff (TB_M1);
    cp_link   : coverpoint linked;
    cp_rst    : coverpoint restart;
    cp_reload : coverpoint c.regreload iff (restart) { bins b[] = {0, 1, 3, 5, 7}; }
    cp_done   : coverpoint {c.donetype, c.donepause} { bins none = {4'b000_0}; bins cmd = {4'b001_0}; bins cyc = {4'b011_0};
                                                       bins cmd_p = {4'b001_1}; bins cyc_p = {4'b011_1}; }
    cp_gpo    : coverpoint c.use_gpo;
    cp_ch     : coverpoint c.ch { bins b[] = {[0:TB_NCH-1]}; }
    cp_prio   : coverpoint c.prio { bins low = {0}; bins mid = {[1:14]}; bins high = {15}; }
  endgroup

  covergroup cg_axi;
    option.per_instance = 1;
    cp_dir   : coverpoint {t_link, t_wr} { bins rd = {2'b00}; bins wr = {2'b01}; bins link = {2'b10}; }
    cp_burst : coverpoint t_burst { bins fixed = {0}; bins incr = {1}; }
    cp_size  : coverpoint t_size { bins b[] = {[0:$clog2(TB_DWB)]}; }
    cp_len   : coverpoint t_len { bins single = {0}; bins mid = {[1:14]}; bins max = {15}; }
    cp_unal  : coverpoint t_unal;
    cp_part  : coverpoint t_partial iff (t_wr);
    // Unreachable by design:
    //  - link fetches are INCR, full bus width (ARSIZE = log2(DW/8));
    //  - a link burst is limited by the 16-word command buffer, so 16 beats
    //    only exist on a 32-bit bus;
    //  - narrow transfers (size < bus width) always use TRANSIZE on element
    //    aligned addresses: only full-width beats can be unaligned.
    cx_shape : cross cp_dir, cp_burst, cp_size, cp_len {
      ignore_bins link_fixed  = binsof(cp_dir.link) && binsof(cp_burst.fixed);
      ignore_bins link_narrow = binsof(cp_dir.link) && binsof(cp_size) intersect {[0:$clog2(TB_DWB)-1]};
      ignore_bins link_max    = binsof(cp_dir.link) && binsof(cp_len.max) &&
                                binsof(cp_size) intersect {(TB_DWB > 4) ? $clog2(TB_DWB) : 99}; }
    cx_unal  : cross cp_dir, cp_unal, cp_size {
      ignore_bins narrow_unal = binsof(cp_unal) intersect {1} && binsof(cp_size) intersect {[0:$clog2(TB_DWB)-1]};
      ignore_bins link_narrow = binsof(cp_dir.link) && binsof(cp_size) intersect {[0:$clog2(TB_DWB)-1]}; }
  endgroup

  covergroup cg_event;
    option.per_instance = 1;
    cp_ev : coverpoint ev { bins b[] = {[EV_RDRESP:EV_CLEAR]}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_cmd   = new();
    cg_axi   = new();
    cg_event = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axi_imp = new("axi_imp", this);
    apb_imp = new("apb_imp", this);
  endfunction

  // ---------------------------------------------------------------- APB observed events
  function void write_cov_apb(apb_item it);
    int a = it.addr;
    if (it.slverr || it.aborted) return;
    if (it.write) begin
      if (a >= 'h1000 && (a & 'hFF) == CH_CMD) begin
        if (it.data[1]) sample_event(EV_CLEAR);
        if (it.data[2]) sample_event(EV_DISABLE);
        if (it.data[3]) sample_event(EV_STOP);
        if (it.data[4]) sample_event(EV_PAUSE);
      end
      if ((a == R_SECCTRL + U_CTRL || a == R_NSCTRL + U_CTRL)) begin
        if (it.data[9]) sample_event(EV_ALLPAUSE);
        if (it.data[8]) sample_event(EV_ALLSTOP);
      end
    end else if (a >= 'h1000 && (a & 'hFF) == CH_ERRINFO) begin
      if (it.data[16]) sample_event(EV_RDRESP);
      if (it.data[17]) sample_event(EV_WRRESP);
      if (it.data[18]) sample_event(EV_POISON);
      if (it.data[19]) sample_event(EV_STRB);
      if (it.data[20]) sample_event(EV_OVERRUN);
      if (it.data[21]) sample_event(EV_EARLY);
      if (it.data[24]) sample_event(EV_LINKHDR);
      if (it.data[25]) sample_event(EV_REGVAL);
      if (it.data[26]) sample_event(EV_CONFL);
      if (|it.data[4:2]) sample_event(EV_TRIGSEL);
    end
  endfunction

  // ---------------------------------------------------------------- pin observed events
  task run_phase(uvm_phase phase);
    bit pa = 0, sa = 0, ha = 0, sv = 0, qa = 1, qd = 0, pac = 0, pde = 0, en0 = 0, boot_ok = 1;
    if (vif == null) return;
    forever begin
      @(posedge vif.clk);
      if (vif.resetn !== 1'b1) continue;
      if ((vif.allch_pause_ack_sec | vif.allch_pause_ack_nonsec) && !pa) sample_event(EV_HWPAUSE);
      if ((vif.allch_stop_ack_sec  | vif.allch_stop_ack_nonsec)  && !sa) sample_event(EV_HWSTOP);
      if (vif.halted && !ha)                                             sample_event(EV_CTIHALT);
      if (vif.irq_sec_viol_err && !sv)                                   sample_event(EV_SECVIO);
      if (!vif.clk_qacceptn && qa && !vif.clk_qreqn)                     sample_event(EV_Q_ACC);
      if (vif.clk_qdeny && !qd)                                          sample_event(EV_Q_DENY);
      if (vif.paccept && !pac) begin
        if (vif.pstate == 4'd0) sample_event(EV_P_OFF);
        if (vif.pstate == 4'd5) sample_event(EV_P_RET);
        if (vif.pstate == 4'd9) sample_event(EV_P_WRST);
      end
      if (vif.pdeny && !pde)                                             sample_event(EV_P_DENY);
      if (vif.ch_enabled[0] && !en0 && vif.boot_en && boot_ok)           sample_event(EV_AUTOBOOT);
      if (vif.ch_enabled[0] && !en0) boot_ok = 0;
      pa = vif.allch_pause_ack_sec | vif.allch_pause_ack_nonsec;
      sa = vif.allch_stop_ack_sec | vif.allch_stop_ack_nonsec;
      ha = vif.halted; sv = vif.irq_sec_viol_err; qa = vif.clk_qacceptn; qd = vif.clk_qdeny;
      pac = vif.paccept; pde = vif.pdeny; en0 = vif.ch_enabled[0];
    end
  endtask

  static function int inc_class(bit [15:0] i);
    if (i == 0) return 0;
    if (i == 1) return 1;
    if (i[15])  return 2;
    return 3;
  endfunction

  static function int size_class(longint unsigned bytes);
    if (bytes == 0) return 0;
    if (bytes <= 1) return 1;
    if (bytes <= TB_DWB) return 2;
    return 3;
  endfunction

  static function int trig_class(bit use_t, bit [1:0] ty, bit [1:0] md);
    if (!use_t) return 0;
    if (ty == TT_INT) return 3;
    if (md == TM_DMAFC) return 4;
    if (md == TM_PERFC) return 5;
    return (ty == TT_HW) ? 2 : 1;
  endfunction

  function void sample_cmd(dma_cmd cmd);
    longint unsigned sy, dy;
    c      = cmd;
    sy     = cmd.is2d() ? cmd.srcysize : 1;
    dy     = cmd.is2d() ? cmd.desysize : 1;
    inc_s  = inc_class(cmd.srcxinc);
    inc_d  = inc_class(cmd.desxinc);
    szc_s  = size_class(longint'(cmd.srcxsize) * sy * cmd.esize());
    szc_d  = size_class(longint'(cmd.desxsize) * dy * cmd.esize());
    al_s   = (cmd.srcaddr % TB_DWB) == 0;
    al_d   = (cmd.desaddr % TB_DWB) == 0;
    dev_s  = cmd.src_memattr[7:4] == 0;
    dev_d  = cmd.des_memattr[7:4] == 0;
    port_s = tb_port_of(cmd.srcaddr);
    port_d = tb_port_of(cmd.desaddr);
    trig_s = trig_class(cmd.use_srctrig, cmd.srctrig_type, cmd.srctrig_mode);
    trig_d = trig_class(cmd.use_destrig, cmd.destrig_type, cmd.destrig_mode);
    trig_o = !cmd.use_trigout ? 0 : (cmd.trigout_type == TT_INT) ? 3 : (cmd.trigout_type == TT_HW) ? 2 : 1;
    linked = cmd.linkaddren;
    restart = cmd.restartinf || cmd.restartcnt != 0;
    cg_cmd.sample();
  endfunction

  function void write_cov_axi(axi5_item it);
    if (it.aborted) return;
    t         = it;
    t_len     = it.len;
    t_size    = it.size;
    t_burst   = it.burst;
    t_wr      = it.write;
    t_link    = !it.write && it.prot[2];
    t_unal    = (it.addr % (1 << it.size)) != 0 || ((it.addr % TB_DWB) != 0 && it.size == $clog2(TB_DWB));
    t_partial = 0;
    if (it.write) foreach (it.strb[i]) if (it.strb[i] != it.valid_lanes(i)) t_partial = 1;
    cg_axi.sample();
  endfunction

  function void sample_event(ev_e e);
    ev = e;
    cg_event.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("functional coverage: commands %0.1f%%  axi %0.1f%%  events %0.1f%%",
                               cg_cmd.get_inst_coverage(), cg_axi.get_inst_coverage(), cg_event.get_inst_coverage()), UVM_NONE)
  endfunction
endclass : dma_coverage
