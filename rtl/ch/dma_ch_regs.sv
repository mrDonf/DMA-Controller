//-----------------------------------------------------------------------------
// dma_ch_regs.sv
// DMACH<n> register frame (TRM 6.5.1).
//   * APB access port (security / privilege already checked by the unit)
//   * command link write port (header bit index -> offset idx*4)
//   * hardware update ports (live address / size, status flags, reload)
// Configuration registers are read-only while the channel is enabled.
//-----------------------------------------------------------------------------
module dma_ch_regs
  import dma_pkg::*;
#(
  parameter int AW         = 32,
  parameter int DW         = 64,
  parameter bit EXT        = 1'b1,    // 2D / wrap / template
  parameter bit STREAM     = 1'b0,
  parameter int GPO_W      = 0,       // 0..32 (0 = no GPO for this channel)
  parameter int FIFO_DEPTH = 16,
  parameter int CMDBUF     = 16,
  parameter int NUM_TRIG_IN  = 0,
  parameter int NUM_TRIG_OUT = 0
) (
  input  logic        clk,
  input  logic        resetn,

  // ---- APB register access (one cycle strobes)
  input  logic        apb_wr,
  input  logic        apb_rd,
  input  logic [7:0]  apb_off,
  input  logic [31:0] apb_wdata,
  output logic [31:0] apb_rdata,

  // ---- channel attributes from unit
  input  logic        ch_nonsec,
  input  logic        ch_priv,
  input  logic        attr_chg,        // security / privilege changed -> clear

  // ---- command link writes
  input  logic        lk_clear,
  input  logic        lk_we,
  input  logic [4:0]  lk_idx,
  input  logic [31:0] lk_wdata,

  // ---- control from channel FSM
  input  logic        enabled,         // channel enabled (ENABLECMD readback)
  input  logic        cmd_start,       // capture INITIAL work registers
  input  logic        clear_do,        // perform CLEARCMD now
  input  logic        reload_do,       // apply REGRELOADTYPE
  input  logic        sizes_zero_src,  // command done: zero src sizes
  input  logic        sizes_zero_des,
  input  logic        boot_load,       // autoboot: load link registers
  input  logic [AW-1:0] boot_addr,
  input  logic [7:0]  boot_memattr,
  input  logic [1:0]  boot_shareattr,
  input  logic        restart_dec,     // decrement CMDRESTARTCNT

  // live updates
  input  logic        hw_src_we,
  input  logic [AW-1:0] hw_srcaddr,
  input  logic [31:0] hw_srcxsize,
  input  logic [15:0] hw_srcysize,
  input  logic        hw_des_we,
  input  logic [AW-1:0] hw_desaddr,
  input  logic [31:0] hw_desxsize,
  input  logic [15:0] hw_desysize,
  input  logic        hw_sxopt_we,     // size optimisation at command start
  input  logic [31:0] hw_sxopt,
  input  logic        hw_syopt_we,
  input  logic [15:0] hw_syopt,
  input  logic [AW-1:0] wk_src_lbase,  // line initial addresses (work regs)
  input  logic [AW-1:0] wk_des_lbase,

  // status flag events
  input  logic        set_done,
  input  logic        set_err,
  input  logic        set_disabled,
  input  logic        set_stopped,
  input  logic        stat_paused,
  input  logic        stat_resumewait,
  input  logic        stat_srctrigwait,
  input  logic        stat_destrigwait,
  input  logic        stat_trigoutwait,
  input  logic [31:0] errinfo_set,     // OR-ed into ERRINFO
  input  logic [31:0] gpo_read,

  // command bit handshakes
  output logic        cmd_enable,      // pulse: ENABLECMD written while idle
  output logic        cmd_clear_pend,
  output logic        cmd_disable_pend,
  output logic        cmd_stop_pend,
  output logic        cmd_pause_pend,
  output logic        cmd_resume,      // pulse
  input  logic        clr_clear,
  input  logic        clr_disable,
  input  logic        clr_stop,
  input  logic        clr_pause,
  output logic        sw_src_req,
  output logic [1:0]  sw_src_type,
  output logic        sw_des_req,
  output logic [1:0]  sw_des_type,
  output logic        sw_out_ack,
  input  logic        clr_sw_src,
  input  logic        clr_sw_des,
  input  logic        clr_sw_out,

  // ---- register fields
  output logic [31:0] r_intren,
  output logic [31:0] r_ctrl,
  output logic [AW-1:0] r_srcaddr,
  output logic [AW-1:0] r_desaddr,
  output logic [31:0] r_srcxsize,
  output logic [31:0] r_desxsize,
  output logic [31:0] r_srctranscfg,
  output logic [31:0] r_destranscfg,
  output logic [15:0] r_srcxinc,
  output logic [15:0] r_desxinc,
  output logic [15:0] r_srcystride,
  output logic [15:0] r_desystride,
  output logic [31:0] r_fillval,
  output logic [15:0] r_srcysize,
  output logic [15:0] r_desysize,
  output logic [4:0]  r_srctmpltsize,
  output logic [4:0]  r_destmpltsize,
  output logic [31:0] r_srctmplt,
  output logic [31:0] r_destmplt,
  output logic [31:0] r_srctrigincfg,
  output logic [31:0] r_destrigincfg,
  output logic [31:0] r_trigoutcfg,
  output logic [31:0] r_gpoen,
  output logic [31:0] r_gpoval,
  output logic [1:0]  r_streamtype,
  output logic [9:0]  r_linkattr,
  output logic [15:0] r_restartcnt,
  output logic        r_restartinf,
  output logic [AW-1:0] r_linkaddr,
  output logic        r_linkaddren,
  output logic [2:0]  r_issuecap,
  output logic        irq                   // channel interrupt
);

  localparam int DWB   = DW / 8;
  localparam int LB    = $clog2(DWB);
  localparam bit HAS_XHI_DES = EXT | STREAM;   // DESXSIZE writable
  localparam bit HAS_TRIGIN  = (NUM_TRIG_IN > 0);
  localparam bit HAS_TRIGOUT = (NUM_TRIG_OUT > 0);
  localparam int AH = (AW > 32) ? AW - 32 : 1;

  // --------------------------------------------------------------------------
  // storage
  // --------------------------------------------------------------------------
  logic [10:0] intren_q;
  logic [29:0] ctrl_q;
  logic [AW-1:0] srcaddr_q, desaddr_q;
  logic [31:0] srcx_q, desx_q;
  logic [19:0] srctc_q, destc_q;
  logic [15:0] srcinc_q, desinc_q, srcys_q, desys_q;
  logic [31:0] fill_q;
  logic [15:0] srcysz_q, desysz_q;
  logic [4:0]  srcts_q, dests_q;
  logic [31:1] srctm_q, destm_q;
  logic [23:0] srctic_q, destic_q;
  logic [9:0]  toc_q;
  logic [31:0] gpoen_q, gpoval_q;
  logic [1:0]  strt_q;
  logic [9:0]  lattr_q;
  logic [15:0] rcnt_q;
  logic        rinf_q;
  logic [AW-1:0] laddr_q;
  logic        laden_q;
  logic [2:0]  icap_q;
  logic [3:0]  wptr_q;
  logic [7:0]  errinfo_q;   // bits [7:0]
  logic [15:0] errinfo_hi_q;// bits [31:16]

  // initial work registers
  logic [AW-1:0] ini_srcaddr, ini_desaddr;
  logic [31:0]   ini_srcx, ini_desx;
  logic [15:0]   ini_srcy, ini_desy;

  // status
  logic st_done, st_err, st_dis, st_stop;
  logic in_done, in_err, in_dis, in_stop, in_stw, in_dtw, in_tow;

  // command bits
  logic c_clear, c_disable, c_stop, c_pause;
  logic sws_req, swd_req, swo_ack;
  logic [1:0] sws_type, swd_type;

  // gpo mask
  localparam logic [31:0] GPO_MASK = (GPO_W >= 32) ? 32'hFFFF_FFFF :
                                     ((GPO_W == 0) ? 32'h0 : ((32'h1 << GPO_W) - 1));

  // --------------------------------------------------------------------------
  // write port mux: APB (locked when enabled) / link (always)
  // --------------------------------------------------------------------------
  logic        cw;          // config write
  logic [7:0]  coff;
  logic [31:0] cdat;

  wire cfg_lock = enabled;
  always_comb begin
    cw   = 1'b0;
    coff = apb_off;
    cdat = apb_wdata;
    if (lk_we) begin
      cw   = 1'b1;
      coff = {1'b0, lk_idx, 2'b00};
      cdat = lk_wdata;
    end else if (apb_wr && !cfg_lock) begin
      cw = 1'b1;
    end
  end

  // reset values
  localparam logic [29:0] CTRL_RST  = 30'h0020_0200;
  localparam logic [19:0] TC_RST    = 20'hF_0400;

  wire do_clear   = clear_do | lk_clear | attr_chg;   // linkable configuration
  wire full_clear = clear_do | attr_chg;              // + status / work registers (not REGCLEAR)

  // --------------------------------------------------------------------------
  // configuration registers
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      intren_q <= '0; ctrl_q <= CTRL_RST; srcaddr_q <= '0; desaddr_q <= '0;
      srcx_q <= '0; desx_q <= '0; srctc_q <= TC_RST; destc_q <= TC_RST;
      srcinc_q <= '0; desinc_q <= '0; srcys_q <= '0; desys_q <= '0; fill_q <= '0;
      srcysz_q <= '0; desysz_q <= '0; srcts_q <= '0; dests_q <= '0;
      srctm_q <= '0; destm_q <= '0; srctic_q <= '0; destic_q <= '0; toc_q <= '0;
      gpoen_q <= '0; gpoval_q <= '0; strt_q <= '0; lattr_q <= '0;
      rcnt_q <= '0; rinf_q <= 1'b0; laddr_q <= '0; laden_q <= 1'b0;
      icap_q <= 3'd7;
    end else begin
      if (do_clear) begin
        intren_q <= '0; ctrl_q <= CTRL_RST; srcaddr_q <= '0; desaddr_q <= '0;
        srcx_q <= '0; desx_q <= '0; srctc_q <= TC_RST; destc_q <= TC_RST;
        srcinc_q <= '0; desinc_q <= '0; srcys_q <= '0; desys_q <= '0; fill_q <= '0;
        srcysz_q <= '0; desysz_q <= '0; srcts_q <= '0; dests_q <= '0;
        srctm_q <= '0; destm_q <= '0; srctic_q <= '0; destic_q <= '0; toc_q <= '0;
        gpoen_q <= '0; gpoval_q <= '0; strt_q <= '0; lattr_q <= '0;
        rcnt_q <= '0; rinf_q <= 1'b0; laddr_q <= '0; laden_q <= 1'b0;
        if (!lk_clear) icap_q <= 3'd7;
      end

      if (boot_load) begin
        laddr_q <= boot_addr;
        laden_q <= 1'b1;
        lattr_q <= {boot_shareattr, boot_memattr};
      end

      // hardware live updates
      if (hw_src_we) begin
        srcaddr_q      <= hw_srcaddr;
        srcx_q         <= hw_srcxsize;
        if (EXT) srcysz_q <= hw_srcysize;
      end
      if (hw_des_we) begin
        desaddr_q      <= hw_desaddr;
        desx_q         <= hw_desxsize;
        if (EXT) desysz_q <= hw_desysize;
      end
      if (hw_sxopt_we) srcx_q   <= hw_sxopt;
      if (hw_syopt_we && EXT) srcysz_q <= hw_syopt;
      if (sizes_zero_src) begin srcx_q <= '0; srcysz_q <= '0; end
      if (sizes_zero_des) begin desx_q <= '0; desysz_q <= '0; end
      if (restart_dec && rcnt_q != 16'd0) rcnt_q <= rcnt_q - 1'b1;

      if (reload_do) begin
        logic [2:0] rt;
        rt = ctrl_q[20:18];
        if (rt[0]) begin
          srcx_q <= ini_srcx;  desx_q <= ini_desx;
          if (EXT) begin srcysz_q <= ini_srcy; desysz_q <= ini_desy; end
        end
        if (rt[0] && rt[1]) srcaddr_q <= ini_srcaddr;
        if (rt[0] && rt[2]) desaddr_q <= ini_desaddr;
      end

      if (cw) begin
        case (coff)
          CH_INTREN:      intren_q <= {cdat[10:8], 4'b0, cdat[3:0]} & 11'h70F;
          CH_CTRL: begin
            ctrl_q[2:0]   <= (LB >= 4) ? cdat[2:0] : {1'b0, cdat[1:0]};
            ctrl_q[7:4]   <= cdat[7:4];
            ctrl_q[11:9]  <= cdat[11:9];
            ctrl_q[14:12] <= EXT ? cdat[14:12] : 3'b000;
            ctrl_q[20:18] <= cdat[20:18];
            ctrl_q[23:21] <= cdat[23:21];
            ctrl_q[24]    <= cdat[24];
            ctrl_q[25]    <= cdat[25];
            ctrl_q[26]    <= cdat[26];
            ctrl_q[27]    <= cdat[27];
            ctrl_q[28]    <= (GPO_W > 0) ? cdat[28] : 1'b0;
            ctrl_q[29]    <= STREAM ? cdat[29] : 1'b0;
          end
          CH_SRCADDR:     srcaddr_q[31:0] <= cdat;
          CH_SRCADDRHI:   if (AW > 32) srcaddr_q <= AW'({cdat[AH-1:0], srcaddr_q[31:0]});   // no out-of-range select when AW = 32
          CH_DESADDR:     desaddr_q[31:0] <= cdat;
          CH_DESADDRHI:   if (AW > 32) desaddr_q <= AW'({cdat[AH-1:0], desaddr_q[31:0]});   // no out-of-range select when AW = 32
          CH_XSIZE: begin
            srcx_q[15:0] <= cdat[15:0];
            desx_q[15:0] <= HAS_XHI_DES ? cdat[31:16] : cdat[15:0];
          end
          CH_XSIZEHI: begin
            srcx_q[31:16] <= cdat[15:0];
            desx_q[31:16] <= HAS_XHI_DES ? cdat[31:16] : cdat[15:0];
          end
          CH_SRCTRANSCFG: srctc_q <= {cdat[19:16], 4'h0, cdat[11:0]};
          CH_DESTRANSCFG: destc_q <= {cdat[19:16], 4'h0, cdat[11:0]};
          CH_XADDRINC:    begin srcinc_q <= cdat[15:0]; desinc_q <= cdat[31:16]; end
          CH_YADDRSTRIDE: if (EXT) begin srcys_q <= cdat[15:0]; desys_q <= cdat[31:16]; end
          CH_FILLVAL:     if (EXT) fill_q <= cdat;
          CH_YSIZE:       if (EXT) begin srcysz_q <= cdat[15:0]; desysz_q <= cdat[31:16]; end
          CH_TMPLTCFG:    if (EXT) begin srcts_q <= cdat[12:8]; dests_q <= cdat[20:16]; end
          CH_SRCTMPLT:    if (EXT) srctm_q <= cdat[31:1];
          CH_DESTMPLT:    if (EXT) destm_q <= cdat[31:1];
          CH_SRCTRIGINCFG: srctic_q <= {cdat[23:16], 4'h0, cdat[11:0]} &
                                       {HAS_TRIGIN ? 8'hFF : 8'h00, 4'h0, 12'hFFF};
          CH_DESTRIGINCFG: destic_q <= {cdat[23:16], 4'h0, cdat[11:0]} &
                                       {HAS_TRIGIN ? 8'hFF : 8'h00, 4'h0, 12'hFFF};
          CH_TRIGOUTCFG:  toc_q <= {cdat[9:8], 2'b00, HAS_TRIGOUT ? cdat[5:0] : 6'h0};
          CH_GPOEN0:      gpoen_q  <= cdat & GPO_MASK;
          CH_GPOVAL0:     gpoval_q <= cdat & GPO_MASK;
          CH_STREAMINTCFG: if (STREAM) strt_q <= cdat[10:9];
          CH_LINKATTR:    lattr_q <= cdat[9:0];
          CH_AUTOCFG:     begin rcnt_q <= cdat[15:0]; rinf_q <= cdat[16]; end
          CH_LINKADDR:    begin laddr_q[31:2] <= cdat[31:2]; laddr_q[1:0] <= 2'b00; laden_q <= cdat[0]; end
          CH_LINKADDRHI:  if (AW > 32) laddr_q <= AW'({cdat[AH-1:0], laddr_q[31:0]});   // no out-of-range select when AW = 32
          CH_ISSUECAP:    if (!lk_we) icap_q <= cdat[2:0];
          default: ;
        endcase
      end
    end
  end

  // WRKREGPTR is writable at any time
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn)                                    wptr_q <= '0;
    else if (full_clear)                            wptr_q <= '0;
    else if (apb_wr && apb_off == CH_WRKREGPTR)     wptr_q <= apb_wdata[3:0];
  end

  // initial values captured at the start of each command
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      ini_srcaddr <= '0; ini_desaddr <= '0; ini_srcx <= '0; ini_desx <= '0;
      ini_srcy <= '0; ini_desy <= '0;
    end else if (full_clear) begin
      // no information of a previous (possibly Secure) command stays visible
      ini_srcaddr <= '0; ini_desaddr <= '0; ini_srcx <= '0; ini_desx <= '0;
      ini_srcy <= '0; ini_desy <= '0;
    end else if (cmd_start) begin
      ini_srcaddr <= srcaddr_q; ini_desaddr <= desaddr_q;
      ini_srcx    <= srcx_q;    ini_desx    <= desx_q;
      ini_srcy    <= srcysz_q;  ini_desy    <= desysz_q;
    end
  end

  // --------------------------------------------------------------------------
  // CH_CMD
  // --------------------------------------------------------------------------
  wire wr_cmd = apb_wr && (apb_off == CH_CMD);

  assign cmd_enable = wr_cmd && apb_wdata[0] && !enabled;
  assign cmd_resume = wr_cmd && apb_wdata[5];

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      c_clear <= 1'b0; c_disable <= 1'b0; c_stop <= 1'b0; c_pause <= 1'b0;
      sws_req <= 1'b0; swd_req <= 1'b0; swo_ack <= 1'b0;
      sws_type <= '0; swd_type <= '0;
    end else begin
      if (clr_clear)   c_clear   <= 1'b0;
      if (clr_disable) c_disable <= 1'b0;
      if (clr_stop)    c_stop    <= 1'b0;
      if (clr_pause)   c_pause   <= 1'b0;
      if (clr_sw_src)  sws_req   <= 1'b0;
      if (clr_sw_des)  swd_req   <= 1'b0;
      if (clr_sw_out)  swo_ack   <= 1'b0;
      if (wr_cmd) begin
        // clear: allowed any time (executes after the current operation)
        if (apb_wdata[1]) c_clear <= 1'b1;
        // disable / stop / pause ignored when set together with ENABLECMD
        // or when the channel is not enabled
        if (enabled && !apb_wdata[0]) begin
          if (apb_wdata[2]) c_disable <= 1'b1;
          if (apb_wdata[3]) c_stop    <= 1'b1;
          if (apb_wdata[4]) c_pause   <= 1'b1;
        end
        if (enabled) begin
          if (!sws_req) sws_type <= apb_wdata[18:17];
          if (!swd_req) swd_type <= apb_wdata[22:21];
          if (apb_wdata[16]) sws_req <= 1'b1;
          if (apb_wdata[20]) swd_req <= 1'b1;
          if (apb_wdata[24]) swo_ack <= 1'b1;
        end
      end
      if (!enabled && !wr_cmd) begin
        sws_req <= 1'b0; swd_req <= 1'b0; swo_ack <= 1'b0;
      end
    end
  end

  assign cmd_clear_pend   = c_clear;
  assign cmd_disable_pend = c_disable;
  assign cmd_stop_pend    = c_stop;
  assign cmd_pause_pend   = c_pause;
  assign sw_src_req  = sws_req;
  assign sw_src_type = sws_type;
  assign sw_des_req  = swd_req;
  assign sw_des_type = swd_type;
  assign sw_out_ack  = swo_ack;

  // --------------------------------------------------------------------------
  // CH_STATUS / interrupts / ERRINFO
  // --------------------------------------------------------------------------
  wire wr_status = apb_wr && (apb_off == CH_STATUS);

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      st_done <= 1'b0; st_err <= 1'b0; st_dis <= 1'b0; st_stop <= 1'b0;
      in_done <= 1'b0; in_err <= 1'b0; in_dis <= 1'b0; in_stop <= 1'b0;
      in_stw  <= 1'b0; in_dtw <= 1'b0; in_tow <= 1'b0;
      errinfo_q <= '0; errinfo_hi_q <= '0;
    end else begin
      // W1C
      if (wr_status) begin
        if (apb_wdata[16]) st_done <= 1'b0;
        if (apb_wdata[17]) begin st_err <= 1'b0; errinfo_q <= '0; errinfo_hi_q <= '0; end
        if (apb_wdata[18]) st_dis  <= 1'b0;
        if (apb_wdata[19]) st_stop <= 1'b0;
      end
      // ENABLECMD clears status flags
      if (cmd_enable) begin
        st_done <= 1'b0; st_err <= 1'b0; st_dis <= 1'b0; st_stop <= 1'b0;
        errinfo_q <= '0; errinfo_hi_q <= '0;
      end
      if (set_done)     st_done <= 1'b1;
      if (set_err)      st_err  <= 1'b1;
      if (set_disabled) st_dis  <= 1'b1;
      if (set_stopped)  st_stop <= 1'b1;
      if (|errinfo_set) begin
        errinfo_q    <= errinfo_q    | errinfo_set[7:0];
        errinfo_hi_q <= errinfo_hi_q | errinfo_set[31:16];
      end

      // interrupt flags: latched while status set & enabled, cleared with status
      in_done <= st_done & (in_done | intren_q[0]);
      in_err  <= st_err  & (in_err  | intren_q[1]);
      in_dis  <= st_dis  & (in_dis  | intren_q[2]);
      in_stop <= st_stop & (in_stop | intren_q[3]);
      in_stw  <= stat_srctrigwait & (in_stw | intren_q[8]);
      in_dtw  <= stat_destrigwait & (in_dtw | intren_q[9]);
      in_tow  <= stat_trigoutwait & (in_tow | intren_q[10]);

      // CLEARCMD / security or privilege change: status, ERRINFO and the
      // interrupt flags are channel registers too
      if (full_clear) begin
        st_done <= 1'b0; st_err <= 1'b0; st_dis <= 1'b0; st_stop <= 1'b0;
        in_done <= 1'b0; in_err <= 1'b0; in_dis <= 1'b0; in_stop <= 1'b0;
        in_stw  <= 1'b0; in_dtw <= 1'b0; in_tow <= 1'b0;
        errinfo_q <= '0; errinfo_hi_q <= '0;
      end
    end
  end

  assign irq = in_done | in_err | in_dis | in_stop | in_stw | in_dtw | in_tow;

  // --------------------------------------------------------------------------
  // field outputs (with tie-offs)
  // --------------------------------------------------------------------------
  assign r_intren      = {21'd0, intren_q};
  assign r_ctrl        = {2'b00, ctrl_q};
  assign r_srcaddr     = srcaddr_q;
  assign r_desaddr     = desaddr_q;
  assign r_srcxsize    = srcx_q;
  assign r_desxsize    = desx_q;
  // PRIVATTR tied to 0 for unprivileged channels, NONSECATTR tied to 1 for
  // Non-secure channels (TRM 6.5.1.11 / 6.5.1.12)
  assign r_srctranscfg = {12'd0, srctc_q[19:16], 4'd0,
                          ch_priv & srctc_q[11], ch_nonsec | srctc_q[10], srctc_q[9:0]};
  assign r_destranscfg = {12'd0, destc_q[19:16], 4'd0,
                          ch_priv & destc_q[11], ch_nonsec | destc_q[10], destc_q[9:0]};
  assign r_srcxinc     = srcinc_q;
  assign r_desxinc     = desinc_q;
  assign r_srcystride  = srcys_q;
  assign r_desystride  = desys_q;
  assign r_fillval     = fill_q;
  assign r_srcysize    = srcysz_q;
  assign r_desysize    = desysz_q;
  assign r_srctmpltsize = srcts_q;
  assign r_destmpltsize = dests_q;
  assign r_srctmplt    = EXT ? {srctm_q, 1'b1} : 32'd0;
  assign r_destmplt    = EXT ? {destm_q, 1'b1} : 32'd0;
  assign r_srctrigincfg = {8'd0, srctic_q};
  assign r_destrigincfg = {8'd0, destic_q};
  assign r_trigoutcfg  = {22'd0, toc_q};
  assign r_gpoen       = gpoen_q;
  assign r_gpoval      = gpoval_q;
  assign r_streamtype  = strt_q;
  assign r_linkattr    = lattr_q;
  assign r_restartcnt  = rcnt_q;
  assign r_restartinf  = rinf_q;
  assign r_linkaddr    = laddr_q;
  assign r_linkaddren  = laden_q;
  assign r_issuecap    = icap_q;

  // --------------------------------------------------------------------------
  // build configuration constants
  // --------------------------------------------------------------------------
  localparam logic [31:0] BUILDCFG0 = {2'b00, 4'd15, 1'b0, 3'(LB), 6'(AW-1),
                                       8'(CMDBUF-1), 8'(FIFO_DEPTH-1)};
  localparam logic [31:0] BUILDCFG1 = {6'd0, 7'(GPO_W), 1'b0, 5'd0, 1'b0,
                                       STREAM, 1'b1, 1'b1, 1'b1, 1'b1,
                                       HAS_TRIGOUT, HAS_TRIGIN, 1'b1,
                                       EXT, EXT, EXT, 1'b1};

  // --------------------------------------------------------------------------
  // read mux
  // --------------------------------------------------------------------------
  logic [31:0] wrkval;
  always_comb begin
    case (wptr_q)
      4'd1:  wrkval = ini_srcaddr[31:0];
      4'd2:  wrkval = (AW > 32) ? 32'(ini_srcaddr >> 32) : 32'd0;
      4'd3:  wrkval = ini_desaddr[31:0];
      4'd4:  wrkval = (AW > 32) ? 32'(ini_desaddr >> 32) : 32'd0;
      4'd5:  wrkval = ini_srcx;
      4'd6:  wrkval = ini_desx;
      4'd7:  wrkval = wk_src_lbase[31:0];
      4'd8:  wrkval = (AW > 32) ? 32'(wk_src_lbase >> 32) : 32'd0;
      4'd9:  wrkval = wk_des_lbase[31:0];
      4'd10: wrkval = (AW > 32) ? 32'(wk_des_lbase >> 32) : 32'd0;
      4'd11: wrkval = EXT ? {16'd0, ini_srcy} : 32'd0;
      4'd12: wrkval = EXT ? {16'd0, ini_desy} : 32'd0;
      default: wrkval = 32'd0;
    endcase
  end

  always_comb begin
    apb_rdata = 32'd0;
    case (apb_off)
      CH_CMD:          apb_rdata = {7'd0, swo_ack, 1'b0, swd_type, swd_req, 1'b0,
                                    sws_type, sws_req, 10'd0, 1'b0, c_pause, c_stop,
                                    c_disable, c_clear, enabled};
      CH_STATUS:       apb_rdata = {5'd0, stat_trigoutwait, stat_destrigwait, stat_srctrigwait,
                                    2'b00, stat_resumewait, stat_paused, st_stop, st_dis,
                                    st_err, st_done, 5'd0, in_tow, in_dtw, in_stw, 4'd0,
                                    in_stop, in_dis, in_err, in_done};
      CH_INTREN:       apb_rdata = r_intren;
      CH_CTRL:         apb_rdata = r_ctrl;
      CH_SRCADDR:      apb_rdata = srcaddr_q[31:0];
      CH_SRCADDRHI:    apb_rdata = (AW > 32) ? 32'(srcaddr_q >> 32) : 32'd0;
      CH_DESADDR:      apb_rdata = desaddr_q[31:0];
      CH_DESADDRHI:    apb_rdata = (AW > 32) ? 32'(desaddr_q >> 32) : 32'd0;
      CH_XSIZE:        apb_rdata = {desx_q[15:0], srcx_q[15:0]};
      CH_XSIZEHI:      apb_rdata = {desx_q[31:16], srcx_q[31:16]};
      CH_SRCTRANSCFG:  apb_rdata = r_srctranscfg;
      CH_DESTRANSCFG:  apb_rdata = r_destranscfg;
      CH_XADDRINC:     apb_rdata = {desinc_q, srcinc_q};
      CH_YADDRSTRIDE:  apb_rdata = {desys_q, srcys_q};
      CH_FILLVAL:      apb_rdata = fill_q;
      CH_YSIZE:        apb_rdata = {desysz_q, srcysz_q};
      CH_TMPLTCFG:     apb_rdata = {11'd0, dests_q, 3'd0, srcts_q, 8'd0};
      CH_SRCTMPLT:     apb_rdata = r_srctmplt;
      CH_DESTMPLT:     apb_rdata = r_destmplt;
      CH_SRCTRIGINCFG: apb_rdata = r_srctrigincfg;
      CH_DESTRIGINCFG: apb_rdata = r_destrigincfg;
      CH_TRIGOUTCFG:   apb_rdata = r_trigoutcfg;
      CH_GPOEN0:       apb_rdata = gpoen_q;
      CH_GPOVAL0:      apb_rdata = gpoval_q;
      CH_STREAMINTCFG: apb_rdata = {21'd0, strt_q, 9'd0};
      CH_LINKATTR:     apb_rdata = {22'd0, lattr_q};
      CH_AUTOCFG:      apb_rdata = {15'd0, rinf_q, rcnt_q};
      CH_LINKADDR:     apb_rdata = {laddr_q[31:2], 1'b0, laden_q};
      CH_LINKADDRHI:   apb_rdata = (AW > 32) ? 32'(laddr_q >> 32) : 32'd0;
      CH_GPOREAD0:     apb_rdata = gpo_read & GPO_MASK;
      CH_WRKREGPTR:    apb_rdata = {28'd0, wptr_q};
      CH_WRKREGVAL:    apb_rdata = wrkval;
      CH_ERRINFO:      apb_rdata = {errinfo_hi_q, 8'd0, errinfo_q};
      CH_IIDR:         apb_rdata = IIDR_VAL;
      CH_AIDR:         apb_rdata = AIDR_VAL;
      CH_ISSUECAP:     apb_rdata = {29'd0, icap_q};
      CH_BUILDCFG0:    apb_rdata = BUILDCFG0;
      CH_BUILDCFG1:    apb_rdata = BUILDCFG1;
      default:         apb_rdata = 32'd0;
    endcase
  end

  wire unused = apb_rd;

endmodule : dma_ch_regs
