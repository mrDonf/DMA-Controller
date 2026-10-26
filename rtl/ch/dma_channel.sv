//-----------------------------------------------------------------------------
// dma_channel.sv
// One DMA channel: register frame, command life-cycle FSM (TRM 5.6.1),
// configuration checking, read / write burst generation, byte FIFO(s),
// command linking, trigger handling, AXI-Stream expansion interface and GPO.
//
// Command flow:
//   IDLE -> (LINK) -> CFG -> CHK -> (MUL) -> ALLOC -> GPO -> CMDTRIG -> XFER
//        -> TRIGOUT -> DONE -> {CFG (auto restart) | LINK | IDLE}
//   any error / stop -> STOP (quiesce, flush) -> FIN -> IDLE
//
// The channel presents registered AR / AW requests (2-entry queues) to the
// BIU, accepts R / B already routed to it, and offers W beats in AW order.
//-----------------------------------------------------------------------------
module dma_channel
  import dma_pkg::*;
  import dma_addr_map_pkg::*;
#(
  parameter int CH_IDX       = 0,
  parameter int NUM_CH       = 1,
  parameter int AW           = 32,
  parameter int DW           = 64,
  parameter bit EXT          = 1'b1,
  parameter bit STREAM       = 1'b0,
  parameter int GPO_W        = 0,
  parameter int FIFO_DEPTH   = 16,
  parameter int NUM_TRIG_IN  = 0,
  parameter int NUM_TRIG_OUT = 0,
  parameter bit M1_PRESENT   = 1'b0,
  parameter int MEM_IMPL     = 0,
  parameter int CMDBUF       = 16
) (
  input  logic                clk,
  input  logic                resetn,

  // ---- register access (from APB decode, already security checked)
  input  logic                reg_wr,
  input  logic                reg_rd,
  input  logic [7:0]          reg_off,
  input  logic [31:0]         reg_wdata,
  output logic [31:0]         reg_rdata,

  // ---- attributes / unit control
  input  logic                ch_nonsec,
  input  logic                ch_priv,
  input  logic                attr_chg,
  input  logic                u_pause,      // all-channel pause (SW/HW/CTI/warm reset)
  input  logic                u_stop,       // all-channel stop (SW/HW)
  input  logic                u_run,        // LPI: activity allowed
  input  logic                boot_start,
  input  logic [AW-1:0]       boot_addr,
  input  logic [7:0]          boot_memattr,
  input  logic [1:0]          boot_shareattr,

  // ---- status
  output logic                st_enabled,
  output logic                st_err,
  output logic                st_stopped,
  output logic                st_paused,
  output logic                st_waiting,   // enabled, waiting for an event
  output logic                irq,

  // ---- AR request
  output logic                ar_valid,
  input  logic                ar_ready,
  output logic [AW-1:0]       ar_addr,
  output logic [7:0]          ar_len,
  output logic [2:0]          ar_size,
  output logic [1:0]          ar_burst,
  output logic [3:0]          ar_cache,
  output logic [2:0]          ar_prot,
  output logic [3:0]          ar_qos,
  output logic [1:0]          ar_domain,
  output logic [3:0]          ar_inner,
  output logic                ar_cmdlink,
  output logic                ar_port,
  // ---- R (routed)
  input  logic                r_valid,
  input  logic [DW-1:0]       r_data,
  input  logic [1:0]          r_resp,
  input  logic                r_last,
  input  logic                r_poison,
  // ---- AW request
  output logic                aw_valid,
  input  logic                aw_ready,
  output logic [AW-1:0]       aw_addr,
  output logic [7:0]          aw_len,
  output logic [2:0]          aw_size,
  output logic [1:0]          aw_burst,
  output logic [3:0]          aw_cache,
  output logic [2:0]          aw_prot,
  output logic [3:0]          aw_qos,
  output logic [1:0]          aw_domain,
  output logic [3:0]          aw_inner,
  output logic                aw_port,
  // ---- W
  output logic                w_valid,
  input  logic                w_ready,
  output logic [DW-1:0]       w_data,
  output logic [DW/8-1:0]     w_strb,
  output logic                w_last,
  // ---- B (routed)
  input  logic                b_valid,
  input  logic [1:0]          b_resp,

  // ---- trigger matrix
  output logic                tm_alloc,
  output logic                tm_src_use,
  output logic                tm_src_int,
  output logic [7:0]          tm_src_sel,
  output logic                tm_des_use,
  output logic                tm_des_int,
  output logic [7:0]          tm_des_sel,
  output logic                tm_out_use,
  output logic [7:0]          tm_out_sel,
  input  logic                tm_alloc_done,
  input  logic                tm_src_err,
  input  logic                tm_des_err,
  input  logic                tm_out_err,
  output logic                tm_release,
  input  logic                tm_src_req,
  input  logic [1:0]          tm_src_reqtype,
  output logic                tm_src_ack,
  output logic [1:0]          tm_src_acktype,
  input  logic                tm_des_req,
  input  logic [1:0]          tm_des_reqtype,
  output logic                tm_des_ack,
  output logic [1:0]          tm_des_acktype,
  output logic                tm_out_req,
  output logic                tm_out_int,
  input  logic                tm_out_ack,

  // ---- AXI-Stream
  output logic                so_tvalid,
  input  logic                so_tready,
  output logic [DW-1:0]       so_tdata,
  output logic [DW/8-1:0]     so_tstrb,
  output logic                so_tlast,
  input  logic                si_tvalid,
  output logic                si_tready,
  input  logic [DW-1:0]       si_tdata,
  input  logic [DW/8-1:0]     si_tstrb,
  input  logic                si_tlast,
  output logic                si_flush,

  // ---- GPO
  output logic [31:0]         gpo
);

  localparam int DWB   = DW / 8;
  localparam int LB    = $clog2(DWB);
  localparam int FD    = (FIFO_DEPTH < 2) ? 2 : FIFO_DEPTH;
  localparam int CAPB  = FD * DWB;                     // FIFO capacity (bytes)
  localparam int HALFB = ((FIFO_DEPTH/2 < 1) ? 1 : FIFO_DEPTH/2) * DWB;
  localparam int PW    = $clog2(CAPB) + 1;             // byte counter width
  localparam int MAXOUT = 8;

  // ==========================================================================
  // Register frame
  // ==========================================================================
  logic        enabled;
  logic        cmd_start, clear_do, reload_do, zero_src, zero_des, boot_load, restart_dec;
  logic        hw_src_we, hw_des_we, hw_sxopt_we, hw_syopt_we;
  logic [31:0] hw_sxopt;
  logic [15:0] hw_syopt;
  logic        set_done, set_err, set_disabled, set_stopped;
  logic        stat_paused, stat_resumewait;
  logic        stw_src, stw_des, stw_out;
  logic [31:0] errinfo_set;
  logic [31:0] gpo_q;

  logic        cmd_enable, c_clear, c_disable, c_stop, c_pause, cmd_resume;
  logic        clr_clear, clr_disable, clr_stop, clr_pause;
  logic        sw_src_req, sw_des_req, sw_out_ack;
  logic [1:0]  sw_src_type, sw_des_type;
  logic        clr_sw_src, clr_sw_des, clr_sw_out;

  logic [31:0] r_intren, r_ctrl, r_srcxsize, r_desxsize, r_srctc, r_destc, r_fillval;
  logic [AW-1:0] r_srcaddr, r_desaddr, r_linkaddr;
  logic [15:0] r_srcxinc, r_desxinc, r_srcys, r_desys, r_srcysz, r_desysz, r_rcnt;
  logic [4:0]  r_srctsz, r_destsz;
  logic [31:0] r_srctm, r_destm, r_srctic, r_destic, r_toc, r_gpoen, r_gpoval;
  logic [1:0]  r_strt;
  logic [9:0]  r_lattr;
  logic        r_rinf, r_laden;
  logic [2:0]  r_icap;

  logic        lk_clear, lk_we;
  logic [4:0]  lk_idx;
  logic [31:0] lk_wdata;

  // agen status
  logic [AW-1:0] ra_st_addr, wa_st_addr, ra_lbase, wa_lbase;
  logic [31:0]   ra_st_x, wa_st_x;
  logic [15:0]   ra_st_y, wa_st_y;

  dma_ch_regs #(
    .AW(AW), .DW(DW), .EXT(EXT), .STREAM(STREAM), .GPO_W(GPO_W),
    .FIFO_DEPTH(FD), .CMDBUF(CMDBUF), .NUM_TRIG_IN(NUM_TRIG_IN), .NUM_TRIG_OUT(NUM_TRIG_OUT)
  ) u_regs (
    .clk(clk), .resetn(resetn),
    .apb_wr(reg_wr), .apb_rd(reg_rd), .apb_off(reg_off), .apb_wdata(reg_wdata), .apb_rdata(reg_rdata),
    .ch_nonsec(ch_nonsec), .ch_priv(ch_priv), .attr_chg(attr_chg),
    .lk_clear(lk_clear), .lk_we(lk_we), .lk_idx(lk_idx), .lk_wdata(lk_wdata),
    .enabled(enabled), .cmd_start(cmd_start), .clear_do(clear_do), .reload_do(reload_do),
    .sizes_zero_src(zero_src), .sizes_zero_des(zero_des),
    .boot_load(boot_load), .boot_addr(boot_addr), .boot_memattr(boot_memattr),
    .boot_shareattr(boot_shareattr), .restart_dec(restart_dec),
    .hw_src_we(hw_src_we), .hw_srcaddr(ra_st_addr), .hw_srcxsize(ra_st_x), .hw_srcysize(ra_st_y),
    .hw_des_we(hw_des_we), .hw_desaddr(wa_st_addr), .hw_desxsize(wa_st_x), .hw_desysize(wa_st_y),
    .hw_sxopt_we(hw_sxopt_we), .hw_sxopt(hw_sxopt), .hw_syopt_we(hw_syopt_we), .hw_syopt(hw_syopt),
    .wk_src_lbase(ra_lbase), .wk_des_lbase(wa_lbase),
    .set_done(set_done), .set_err(set_err), .set_disabled(set_disabled), .set_stopped(set_stopped),
    .stat_paused(stat_paused), .stat_resumewait(stat_resumewait),
    .stat_srctrigwait(stw_src), .stat_destrigwait(stw_des), .stat_trigoutwait(stw_out),
    .errinfo_set(errinfo_set), .gpo_read(gpo_q),
    .cmd_enable(cmd_enable), .cmd_clear_pend(c_clear), .cmd_disable_pend(c_disable),
    .cmd_stop_pend(c_stop), .cmd_pause_pend(c_pause), .cmd_resume(cmd_resume),
    .clr_clear(clr_clear), .clr_disable(clr_disable), .clr_stop(clr_stop), .clr_pause(clr_pause),
    .sw_src_req(sw_src_req), .sw_src_type(sw_src_type), .sw_des_req(sw_des_req), .sw_des_type(sw_des_type),
    .sw_out_ack(sw_out_ack), .clr_sw_src(clr_sw_src), .clr_sw_des(clr_sw_des), .clr_sw_out(clr_sw_out),
    .r_intren(r_intren), .r_ctrl(r_ctrl), .r_srcaddr(r_srcaddr), .r_desaddr(r_desaddr),
    .r_srcxsize(r_srcxsize), .r_desxsize(r_desxsize), .r_srctranscfg(r_srctc), .r_destranscfg(r_destc),
    .r_srcxinc(r_srcxinc), .r_desxinc(r_desxinc), .r_srcystride(r_srcys), .r_desystride(r_desys),
    .r_fillval(r_fillval), .r_srcysize(r_srcysz), .r_desysize(r_desysz),
    .r_srctmpltsize(r_srctsz), .r_destmpltsize(r_destsz), .r_srctmplt(r_srctm), .r_destmplt(r_destm),
    .r_srctrigincfg(r_srctic), .r_destrigincfg(r_destic), .r_trigoutcfg(r_toc),
    .r_gpoen(r_gpoen), .r_gpoval(r_gpoval), .r_streamtype(r_strt), .r_linkattr(r_lattr),
    .r_restartcnt(r_rcnt), .r_restartinf(r_rinf), .r_linkaddr(r_linkaddr), .r_linkaddren(r_laden),
    .r_issuecap(r_icap), .irq(irq)
  );

  // ==========================================================================
  // Field decode (combinational from the registers)
  // ==========================================================================
  wire [2:0] f_ts   = r_ctrl[2:0];
  wire [3:0] f_prio = r_ctrl[7:4];
  wire [2:0] f_xt   = r_ctrl[11:9];
  wire [2:0] f_yt   = r_ctrl[14:12];
  wire [2:0] f_rrt  = r_ctrl[20:18];
  wire [2:0] f_dt   = r_ctrl[23:21];
  wire       f_dpen = r_ctrl[24];
  wire       f_usrc = r_ctrl[25];
  wire       f_udes = r_ctrl[26];
  wire       f_uout = r_ctrl[27];
  wire       f_ugpo = r_ctrl[28];
  wire       f_ustr = r_ctrl[29];

  wire       f_is2d = (f_yt != XT_DISABLE);
  wire [31:0] f_sx  = r_srcxsize;
  wire [31:0] f_dx  = r_desxsize;
  wire [15:0] f_sy  = f_is2d ? r_srcysz : 16'd1;
  wire [15:0] f_dy  = f_is2d ? r_desysz : 16'd1;

  wire f_str_in   = f_ustr && (r_strt == STRT_INOUT || r_strt == STRT_IN);
  wire f_str_out  = f_ustr && (r_strt == STRT_INOUT || r_strt == STRT_OUT);
  wire f_str_io   = f_ustr && (r_strt == STRT_INOUT);
  wire f_axi_src  = !f_ustr || (r_strt != STRT_IN);
  wire f_axi_dst  = !f_ustr || (r_strt != STRT_OUT);
  wire f_a2a      = !f_ustr || f_str_io;      // AXI -> (stream) -> AXI
  wire f_srcempty = (f_sx == 32'd0) || (f_is2d && f_sy == 16'd0);
  wire f_desempty = (f_dx == 32'd0) || (f_is2d && f_dy == 16'd0);

  // empty command rules (TRM 5.9.2.2)
  wire f_no_rd = (f_xt == XT_DISABLE) || (f_ustr && r_strt == STRT_IN) ||
                 (f_axi_src && f_srcempty) || (f_a2a && f_desempty);
  wire f_no_wr = (f_xt == XT_DISABLE) || (f_ustr && r_strt == STRT_OUT) ||
                 (f_axi_dst && f_desempty) ||
                 (f_a2a && f_srcempty && ((f_is2d && f_yt != XT_FILL) || (!f_is2d && f_xt != XT_FILL)));

  // trigger decode
  function automatic logic t_int(input logic [1:0] ty);
    return (ty == TRIGTYPE_INT) && (NUM_CH > 1);
  endfunction
  function automatic logic t_hw(input logic [1:0] ty);
    return (ty == TRIGTYPE_HW) || ((ty == TRIGTYPE_INT) && (NUM_CH == 1));
  endfunction

  wire [1:0] f_sty = r_srctic[9:8],  f_smd = r_srctic[11:10];
  wire [1:0] f_dty = r_destic[9:8],  f_dmd = r_destic[11:10];
  wire [1:0] f_oty = r_toc[9:8];
  wire f_s_int = f_usrc && t_int(f_sty);
  wire f_s_hw  = f_usrc && t_hw(f_sty);
  wire f_s_fc  = f_usrc && f_smd[1] && !t_int(f_sty);
  wire f_d_int = f_udes && t_int(f_dty);
  wire f_d_hw  = f_udes && t_hw(f_dty);
  wire f_d_fc  = f_udes && f_dmd[1] && !t_int(f_dty);
  wire f_o_int = f_uout && t_int(f_oty);
  wire f_o_hw  = f_uout && t_hw(f_oty);

  // ---------------- configuration checks
  logic chk_regval, chk_confl;
  always_comb begin
    chk_regval = 1'b0;
    if (f_ts > 3'(LB))                                       chk_regval = 1'b1;
    if (f_xt > XT_FILL || f_yt > XT_FILL)                    chk_regval = 1'b1;
    if (!EXT && (f_xt == XT_WRAP || f_xt == XT_FILL))        chk_regval = 1'b1;
    if (!(f_dt == 3'b000 || f_dt == 3'b001 || f_dt == 3'b011)) chk_regval = 1'b1;
    if (f_rrt != 3'b000 && !f_rrt[0])                        chk_regval = 1'b1;
    if (f_usrc) begin
      if (f_sty == 2'b01 || f_smd == 2'b01)                  chk_regval = 1'b1;
      if (f_smd[1] && NUM_TRIG_IN == 0 && !t_int(f_sty))     chk_regval = 1'b1;
      if (t_hw(f_sty) && (NUM_TRIG_IN == 0 || r_srctic[7:0] >= 8'(NUM_TRIG_IN))) chk_regval = 1'b1;
      if (t_int(f_sty) && (r_srctic[7:0] >= 8'(NUM_CH) || r_srctic[7:0] == 8'(CH_IDX))) chk_regval = 1'b1;
    end
    if (f_udes) begin
      if (f_dty == 2'b01 || f_dmd == 2'b01)                  chk_regval = 1'b1;
      if (f_dmd[1] && NUM_TRIG_IN == 0 && !t_int(f_dty))     chk_regval = 1'b1;
      if (t_hw(f_dty) && (NUM_TRIG_IN == 0 || r_destic[7:0] >= 8'(NUM_TRIG_IN))) chk_regval = 1'b1;
      if (t_int(f_dty) && (r_destic[7:0] >= 8'(NUM_CH) || r_destic[7:0] == 8'(CH_IDX))) chk_regval = 1'b1;
    end
    if (f_uout) begin
      if (f_oty == 2'b01)                                    chk_regval = 1'b1;
      if (t_hw(f_oty) && (NUM_TRIG_OUT == 0 || r_toc[5:0] >= 6'(NUM_TRIG_OUT))) chk_regval = 1'b1;
    end
    if (f_ustr && r_strt == 2'b11)                           chk_regval = 1'b1;

    chk_confl = 1'b0;
    if (f_s_fc && f_xt != XT_DISABLE && f_is2d && f_sy > 16'd1)            chk_confl = 1'b1;
    if (f_d_fc && f_xt != XT_DISABLE && f_is2d && f_dy > 16'd1)            chk_confl = 1'b1;
    if ((f_s_fc || f_d_fc) && f_ustr)                                       chk_confl = 1'b1;
    if (f_s_fc && (f_xt == XT_WRAP || f_yt == XT_WRAP))                     chk_confl = 1'b1;
    if (f_s_fc && f_no_rd)                                                  chk_confl = 1'b1;
    if (f_d_fc && f_no_wr)                                                  chk_confl = 1'b1;
    if (f_ustr && ((f_xt == XT_WRAP && !f_is2d) ||
                   (f_xt == XT_CONTINUE && f_yt == XT_WRAP) ||
                   ((f_xt == XT_WRAP || f_xt == XT_FILL) && f_is2d)))      chk_confl = 1'b1;
    if (f_str_io && ((f_xt == XT_FILL && !f_is2d) || (f_xt == XT_CONTINUE && f_yt == XT_FILL)) && f_no_rd)
                                                                            chk_confl = 1'b1;
    if (f_is2d && (r_srctsz != 5'd0 || r_destsz != 5'd0))                  chk_confl = 1'b1;
  end

  // ==========================================================================
  // Captured command configuration
  // ==========================================================================
  logic        c_rd_act, c_wr_act, c_is2d, c_modelb, c_xwrap, c_xfill, c_ywrap, c_yfill, c_ycont;
  logic        c_str_in, c_str_out, c_str_io;
  logic        c_s_use, c_s_hw, c_s_int, c_s_fc, c_s_per;
  logic        c_d_use, c_d_hw, c_d_int, c_d_fc, c_d_per;
  logic        c_o_use, c_o_hw, c_o_int;
  logic [7:0]  c_s_blk, c_d_blk;
  logic [2:0]  c_ts;
  logic [31:0] c_sx, c_dx;
  logic [15:0] c_sy, c_dy;
  logic [3:0]  c_rd_cache, c_wr_cache, c_rd_inner, c_wr_inner;
  logic [2:0]  c_rd_prot, c_wr_prot;
  logic [1:0]  c_rd_dom, c_wr_dom;
  logic [3:0]  c_qos;
  logic [DW-1:0] c_fillpat;
  logic        c_conserv;

  // products SX*SY / DX*DY (radix-4 sequential multiplier)
  logic [47:0] p_src, p_dst;
  logic [47:0] m_acc1, m_acc2;
  logic [33:0] m_a1, m_a2;     // multiplicand (32b) and x3 precomputed
  logic [15:0] m_b1, m_b2;
  logic [3:0]  m_cnt;

  function automatic logic [47:0] r4term(input logic [31:0] a, input logic [1:0] d);
    case (d)
      2'd0: return 48'd0;
      2'd1: return {16'd0, a};
      2'd2: return {15'd0, a, 1'b0};
      default: return {16'd0, a} + {15'd0, a, 1'b0};
    endcase
  endfunction

  // ==========================================================================
  // FSM
  // ==========================================================================
  typedef enum logic [3:0] {
    S_IDLE, S_LINK, S_CFG, S_CHK, S_MUL, S_ALLOC, S_ALLOCW, S_GPO,
    S_CMDTRIG, S_XFER, S_TRIGOUT, S_DONE, S_STOP, S_FIN
  } st_e;

  st_e   st;
  logic  donepause;
  logic  err_q;         // error terminated command
  logic  stopreq_q;     // stop terminated command
  logic  agen_start;
  logic  agen_abort;
  logic  lk_start;
  logic  to_start;
  logic  fifo_clr;
  logic  quiet;         // no outstanding activity
  logic  xfer_done;
  logic  cmd_go;

  // pause / stop
  wire pause_req = c_pause | donepause | u_pause;
  wire stop_req  = c_stop  | u_stop;
  wire active_st = (st != S_IDLE) && (st != S_STOP) && (st != S_FIN);
  wire run       = enabled && !pause_req && u_run && active_st;

  assign stat_paused     = enabled && pause_req && quiet && active_st;
  assign stat_resumewait = stat_paused && (c_pause || donepause);

  // error sources (pulses / levels collected during XFER / LINK)
  logic        e_rdresp, e_rdpois, e_wrresp, e_strb, e_overrun, e_early, e_hdr;
  logic        e_any;
  logic [31:0] e_info;

  // ==========================================================================
  // Data-path signals (declared before the FSM uses them)
  // ==========================================================================
  // read agen
  logic          ra_dv, ra_pop, ra_fill, ra_last, ra_active;
  logic [AW-1:0] ra_addr;
  logic [7:0]    ra_len;
  logic [2:0]    ra_size;
  logic [1:0]    ra_burst;
  logic [8:0]    ra_nb, ra_nelem;
  // write agen
  logic          wa_dv, wa_pop, wa_fill, wa_last, wa_active, wa_recomp;
  logic [AW-1:0] wa_addr;
  logic [7:0]    wa_len;
  logic [2:0]    wa_size;
  logic [1:0]    wa_burst;
  logic [8:0]    wa_nb, wa_nelem;

  // counters
  logic [3:0]    rd_infl, wr_infl;
  logic          rd_port_l, wr_port_l;
  logic [11:0]   rd_pend_b, si_pend_b;
  logic [PW-1:0] free_a, avail_a, free_b, avail_b;
  logic          rdp_qempty;
  logic          weng_idle, seng_idle;
  logic          si_last_seen, si_done, so_tlast_sent, flush_q;

  // trigger side status
  logic s_blk_en, d_blk_en, s_per_last, d_per_last;
  logic [8:0] s_blk_rem, d_blk_rem;
  logic s_cmd_got, d_cmd_got, s_cmd_done, d_cmd_done, s_fc_done, d_fc_done;
  logic to_done;

  // link
  logic lk_busy, lk_done, lk_hdr_err;

  // software trigger request clears from the trigger blocks
  logic s_sw_clr, d_sw_clr, o_sw_clr;

  // XFER state excluding its entry cycle (generators load on entry)
  logic xfer_run;

  wire rd_complete = !ra_active && (rd_infl == 4'd0) && (rd_pend_b == 12'd0);
  wire wr_complete = !wa_active && (wr_infl == 4'd0) && weng_idle;
  wire si_final    = si_last_seen && (si_pend_b == 12'd0);
  logic si_pending;   // stream-in packet of this command not finished yet

  assign quiet = (rd_infl == 4'd0) && (wr_infl == 4'd0) && weng_idle;

  // ==========================================================================
  // FSM sequential
  // ==========================================================================
  logic need_alloc;
  assign need_alloc = f_s_hw | f_s_int | f_d_hw | f_d_int | f_o_hw;

  // ERRINFO bits for the error events of this cycle (TRM table 5-9)
  logic [31:0] e_now;
  always_comb begin
    e_now = '0;
    if (e_rdresp)  e_now |= 32'h0001_0001;   // AXIRDRESPERR + BUSERR
    if (e_wrresp)  e_now |= 32'h0002_0001;   // AXIWRRESPERR + BUSERR
    if (e_rdpois)  e_now |= 32'h0004_0001;   // AXIRDPOISERR + BUSERR
    if (e_strb)    e_now |= 32'h0008_0080;   // STRINTSTRBERR + STREAMERR
    if (e_overrun) e_now |= 32'h0010_0080;   // STRINOVERRUN + STREAMERR
    if (e_early)   e_now |= 32'h0020_0080;   // STRINEARLYTERM + STREAMERR
    if (e_hdr)     e_now |= 32'h0100_0002;   // LINKHDRERR + CFGERR
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      st        <= S_IDLE;
      enabled   <= 1'b0;
      donepause <= 1'b0;
      err_q     <= 1'b0;
      stopreq_q <= 1'b0;
      gpo_q     <= '0;
      m_cnt     <= '0;
      e_info    <= '0;
    end else begin
      // resume
      if (cmd_resume && stat_resumewait) donepause <= 1'b0;

      case (st)
        // -------------------------------------------------------------------
        S_IDLE: begin
          err_q     <= 1'b0;
          stopreq_q <= 1'b0;
          e_info    <= '0;
          if (boot_start) begin
            enabled <= 1'b1;
            st      <= S_LINK;
          end else if (cmd_enable) begin
            enabled <= 1'b1;
            if (stop_req) begin
              stopreq_q <= 1'b1;
              st        <= S_FIN;
            end else begin
              st <= S_CFG;
            end
          end
        end
        // -------------------------------------------------------------------
        S_LINK: begin
          if (lk_done)                st <= S_CFG;
        end
        // -------------------------------------------------------------------
        S_CFG: if (!pause_req) st <= S_CHK;
        // -------------------------------------------------------------------
        S_CHK: begin
          if (chk_regval || chk_confl) begin
            err_q  <= 1'b1;
            e_info <= e_info | 32'h2 | (chk_regval ? 32'h0200_0000 : 32'h0) |
                                       (chk_confl  ? 32'h0400_0000 : 32'h0);
            st     <= S_STOP;
          end else if (c_is2d) begin
            m_cnt <= 4'd0;
            st    <= S_MUL;
          end else begin
            st <= S_ALLOC;
          end
        end
        // -------------------------------------------------------------------
        S_MUL: begin
          m_cnt <= m_cnt + 1'b1;
          if (m_cnt == 4'd7) st <= S_ALLOC;
        end
        // -------------------------------------------------------------------
        S_ALLOC: if (!pause_req) st <= need_alloc ? S_ALLOCW : S_GPO;
        S_ALLOCW: begin
          if (tm_alloc_done) begin
            if (tm_src_err || tm_des_err || tm_out_err) begin
              err_q  <= 1'b1;
              e_info <= e_info | (tm_src_err ? 32'h4 : 32'h0) |
                                 (tm_des_err ? 32'h8 : 32'h0) |
                                 (tm_out_err ? 32'h10 : 32'h0);
              st     <= S_STOP;
            end else begin
              st <= S_GPO;
            end
          end
        end
        // -------------------------------------------------------------------
        S_GPO: begin
          if (!pause_req) begin
            if (f_ugpo) gpo_q <= (gpo_q & ~r_gpoen) | (r_gpoval & r_gpoen);
            st <= S_CMDTRIG;
          end
        end
        // -------------------------------------------------------------------
        S_CMDTRIG: if (cmd_go) st <= S_XFER;
        // -------------------------------------------------------------------
        S_XFER: if (xfer_done) st <= S_TRIGOUT;
        // -------------------------------------------------------------------
        S_TRIGOUT: if (to_done) st <= S_DONE;
        // -------------------------------------------------------------------
        S_DONE: begin
          if (!pause_req) begin
            logic rst_en, lnk_en, sdone;
            rst_en = (r_rinf || r_rcnt != 16'd0) && !c_disable;
            lnk_en = r_laden && !rst_en && !c_disable;
            sdone  = (f_dt == 3'b001 && !rst_en) || (f_dt == 3'b011);
            if (c_disable) begin
              enabled   <= 1'b0;
              donepause <= 1'b0;
              st        <= S_IDLE;
            end else if (rst_en) begin
              if (sdone && f_dpen) donepause <= 1'b1;
              st <= S_CFG;
            end else if (lnk_en) begin
              if (sdone && f_dpen) donepause <= 1'b1;
              st <= S_LINK;
            end else begin
              enabled   <= 1'b0;
              donepause <= 1'b0;
              st        <= S_IDLE;
            end
          end
        end
        // -------------------------------------------------------------------
        S_STOP: begin
          // a stream-in packet must be completed (flushed up to TLAST)
          // before the command can conclude (TRM 5.5.1)
          if (quiet && seng_idle && !si_pending) st <= S_FIN;
        end
        S_FIN: begin
          enabled   <= 1'b0;
          donepause <= 1'b0;
          st        <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase

      // errors and stops abort any active state
      if (active_st && st != S_IDLE) begin
        if (e_any) begin
          err_q  <= 1'b1;
          e_info <= e_info | e_now;
          st     <= S_STOP;
        end else if (stop_req && st != S_DONE) begin
          stopreq_q <= 1'b1;
          st        <= S_STOP;
        end
      end else if (st == S_STOP && e_any) begin
        e_info <= e_info | e_now;
        err_q  <= 1'b1;
      end
    end
  end

  // one-cycle event strobes derived from state transitions
  st_e st_d;
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) st_d <= S_IDLE;
    else         st_d <= st;
  end

  wire ent_link  = (st == S_LINK)    && (st_d != S_LINK);
  wire ent_xfer  = (st == S_XFER)    && (st_d != S_XFER);
  assign xfer_run = (st == S_XFER)   && (st_d == S_XFER);
  wire ent_to    = (st == S_TRIGOUT) && (st_d != S_TRIGOUT);
  wire ent_stop  = (st == S_STOP)    && (st_d != S_STOP);
  wire ent_alloc = (st == S_ALLOCW)  && (st_d != S_ALLOCW);
  wire ent_gpo   = (st == S_GPO)     && (st_d != S_GPO);

  assign lk_start   = ent_link;
  assign agen_start = ent_xfer;
  // level (not a pulse): a pause at the entry of the trigger-out state must
  // not lose the start request
  assign to_start   = (st == S_TRIGOUT);
  assign agen_abort = ent_stop;
  assign fifo_clr   = ent_gpo;
  assign tm_alloc   = ent_alloc;
  assign boot_load  = (st == S_IDLE) && boot_start;

  // command start bookkeeping (INITIAL work registers / size optimisation)
  assign cmd_start   = ent_gpo;
  assign hw_sxopt_we = ent_gpo && c_rd_act && c_modelb && (c_dx < c_sx);
  assign hw_sxopt    = c_dx;
  assign hw_syopt_we = ent_gpo && c_rd_act && c_modelb && c_is2d && !c_ywrap && (c_sy > c_dy);
  assign hw_syopt    = c_dy;

  // DONE / FIN strobes
  wire done_go = (st == S_DONE) && !pause_req;
  logic dn_rst, dn_lnk, dn_sdone;
  always_comb begin
    dn_rst   = (r_rinf || r_rcnt != 16'd0) && !c_disable;
    dn_lnk   = r_laden && !dn_rst && !c_disable;
    dn_sdone = (f_dt == 3'b001 && !dn_rst) || (f_dt == 3'b011);
  end

  wire   going_idle   = (done_go && (c_disable || (!dn_rst && !dn_lnk))) || (st == S_FIN);
  assign set_done     = done_go && dn_sdone;
  assign reload_do    = done_go;
  assign zero_src     = done_go && (c_rd_act || c_wr_act);
  assign zero_des     = done_go && (c_rd_act || c_wr_act);
  assign restart_dec  = done_go && dn_rst;
  assign set_disabled = done_go && c_disable;
  // pending DISABLE / PAUSE requests never survive the end of a command
  // (e.g. a STOP while paused or while a disable was pending)
  assign clr_disable  = (done_go && c_disable) || (st == S_FIN);
  assign set_err      = (st == S_FIN) && err_q;
  assign set_stopped  = (st == S_FIN) && stopreq_q && !err_q;
  assign clr_stop     = (st == S_FIN);
  assign tm_release   = done_go || (st == S_FIN);
  assign errinfo_set  = (st == S_FIN && err_q) ? e_info : 32'd0;
  assign clr_pause    = (cmd_resume && stat_resumewait) || going_idle;
  assign clear_do     = c_clear && ((st == S_IDLE && !cmd_enable) || going_idle);
  assign clr_clear    = clear_do;
  assign clr_sw_src   = (going_idle || done_go) ? 1'b1 : s_sw_clr;
  assign clr_sw_des   = (going_idle || done_go) ? 1'b1 : d_sw_clr;
  assign clr_sw_out   = going_idle ? 1'b1 : o_sw_clr;

  // live register updates (from the cycle after the generators were loaded)
  assign hw_src_we = xfer_run && c_rd_act;
  assign hw_des_we = xfer_run && c_wr_act;

  // ==========================================================================
  // Configuration capture (S_CFG) and products (S_MUL)
  // ==========================================================================
  function automatic logic [31:0] min32(input logic [31:0] a, input logic [31:0] b);
    return (a < b) ? a : b;
  endfunction
  function automatic logic [15:0] min16(input logic [15:0] a, input logic [15:0] b);
    return (a < b) ? a : b;
  endfunction

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      c_rd_act <= 1'b0; c_wr_act <= 1'b0; c_is2d <= 1'b0; c_modelb <= 1'b0;
      c_xwrap <= 1'b0; c_xfill <= 1'b0; c_ywrap <= 1'b0; c_yfill <= 1'b0; c_ycont <= 1'b0;
      c_str_in <= 1'b0; c_str_out <= 1'b0; c_str_io <= 1'b0;
      c_s_use <= 1'b0; c_s_hw <= 1'b0; c_s_int <= 1'b0; c_s_fc <= 1'b0; c_s_per <= 1'b0;
      c_d_use <= 1'b0; c_d_hw <= 1'b0; c_d_int <= 1'b0; c_d_fc <= 1'b0; c_d_per <= 1'b0;
      c_o_use <= 1'b0; c_o_hw <= 1'b0; c_o_int <= 1'b0;
      c_s_blk <= '0; c_d_blk <= '0; c_ts <= '0;
      c_sx <= '0; c_dx <= '0; c_sy <= '0; c_dy <= '0;
      c_rd_cache <= '0; c_wr_cache <= '0; c_rd_inner <= '0; c_wr_inner <= '0;
      c_rd_prot <= '0; c_wr_prot <= '0; c_rd_dom <= '0; c_wr_dom <= '0; c_qos <= '0;
      c_fillpat <= '0; c_conserv <= 1'b0;
      p_src <= '0; p_dst <= '0;
      m_acc1 <= '0; m_acc2 <= '0; m_a1 <= '0; m_a2 <= '0; m_b1 <= '0; m_b2 <= '0;
    end else begin
      if (st == S_CFG) begin
        c_rd_act  <= !f_no_rd;
        c_wr_act  <= !f_no_wr;
        c_is2d    <= f_is2d;
        c_modelb  <= (f_xt == XT_WRAP) || (f_xt == XT_FILL);
        c_xwrap   <= (f_xt == XT_WRAP);
        c_xfill   <= (f_xt == XT_FILL);
        c_ywrap   <= f_is2d && (f_yt == XT_WRAP);
        c_yfill   <= f_is2d && (f_yt == XT_FILL);
        c_ycont   <= f_is2d && (f_yt == XT_CONTINUE);
        c_str_in  <= f_str_in;
        c_str_out <= f_str_out;
        c_str_io  <= f_str_io;
        c_s_use   <= f_usrc;  c_s_hw <= f_s_hw | f_s_int; c_s_int <= f_s_int;
        c_s_fc    <= f_s_fc;  c_s_per <= f_s_fc & f_smd[0];
        c_d_use   <= f_udes;  c_d_hw <= f_d_hw | f_d_int; c_d_int <= f_d_int;
        c_d_fc    <= f_d_fc;  c_d_per <= f_d_fc & f_dmd[0];
        c_o_use   <= f_uout;  c_o_hw <= f_o_hw | f_o_int; c_o_int <= f_o_int;
        c_s_blk   <= r_srctic[23:16];
        c_d_blk   <= r_destic[23:16];
        c_ts      <= f_ts;
        c_sx      <= f_sx;  c_dx <= f_dx;  c_sy <= f_sy;  c_dy <= f_dy;
        c_rd_cache <= memattr_to_cache(r_srctc[7:4], r_srctc[3:0], 1'b0);
        c_rd_inner <= memattr_to_inner(r_srctc[7:4], r_srctc[3:0], 1'b0);
        c_rd_dom   <= share_to_domain(r_srctc[7:4], r_srctc[3:0], r_srctc[9:8]);
        c_rd_prot  <= {1'b0, r_srctc[10], r_srctc[11]};
        c_wr_cache <= memattr_to_cache(r_destc[7:4], r_destc[3:0], 1'b1);
        c_wr_inner <= memattr_to_inner(r_destc[7:4], r_destc[3:0], 1'b1);
        c_wr_dom   <= share_to_domain(r_destc[7:4], r_destc[3:0], r_destc[9:8]);
        c_wr_prot  <= {1'b0, r_destc[10], r_destc[11]};
        c_qos      <= f_prio;
        c_conserv  <= f_str_in | (f_s_fc & f_smd[0]);
        case (f_ts)
          3'd0:    c_fillpat <= {DWB{r_fillval[7:0]}};
          3'd1:    c_fillpat <= {(DWB/2){r_fillval[15:0]}};
          default: c_fillpat <= {(DWB/4){r_fillval[31:0]}};
        endcase
        // products default (1D)
        p_src <= {16'd0, f_sx};
        p_dst <= {16'd0, f_dx};
        // multiplier operands
        m_a1  <= {2'b00, f_sx};  m_b1 <= f_sy;  m_acc1 <= '0;
        m_a2  <= {2'b00, f_dx};  m_b2 <= f_dy;  m_acc2 <= '0;
      end
      if (st == S_MUL) begin
        logic [47:0] n1, n2;
        n1 = m_acc1 + (r4term(m_a1[31:0], m_b1[2*m_cnt +: 2]) << (2*m_cnt));
        n2 = m_acc2 + (r4term(m_a2[31:0], m_b2[2*m_cnt +: 2]) << (2*m_cnt));
        m_acc1 <= n1;
        m_acc2 <= n2;
        if (m_cnt == 4'd7) begin
          p_src <= n1;
          p_dst <= n2;
        end
      end
    end
  end

  // ==========================================================================
  // Link attributes (captured when a link fetch starts)
  // ==========================================================================
  logic [3:0] c_lk_cache, c_lk_inner;
  logic [1:0] c_lk_dom;
  logic [2:0] c_lk_prot;
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      c_lk_cache <= '0; c_lk_inner <= '0; c_lk_dom <= '0; c_lk_prot <= '0;
    end else if (ent_link) begin
      c_lk_cache <= memattr_to_cache(r_lattr[7:4], r_lattr[3:0], 1'b0);
      c_lk_inner <= memattr_to_inner(r_lattr[7:4], r_lattr[3:0], 1'b0);
      c_lk_dom   <= share_to_domain(r_lattr[7:4], r_lattr[3:0], r_lattr[9:8]);
      c_lk_prot  <= {1'b1, ch_nonsec, ch_priv};
    end
  end

  // ==========================================================================
  // Address generators
  // ==========================================================================
  function automatic logic [AW-1:0] stride_b(input logic [15:0] s, input logic [2:0] ts);
    return AW'({{(AW-16){s[15]}}, s}) << ts;
  endfunction
  function automatic logic [AW-1:0] align_ts(input logic [AW-1:0] a, input logic [2:0] ts);
    return a & ~((AW'(1) << ts) - 1'b1);
  endfunction

  // read side model selection
  wire        rd_modelb = c_modelb && !c_str_out;    // stream-out reads full source
  wire [15:0] rd_lines  = c_is2d ? (c_ywrap ? c_dy : min16(c_sy, c_dy)) : 16'd1;
  wire [31:0] rd_lcnt   = c_xwrap ? c_dx : min32(c_sx, c_dx);
  wire [47:0] rd_tot    = c_ywrap ? p_dst : p_src;

  // write side
  wire        wr_src_si = c_str_in;
  wire [15:0] wr_lines  = (c_modelb && c_ycont) ? min16(c_sy, c_dy) : c_dy;
  wire [31:0] wr_lcnt   = (wr_src_si || c_xwrap) ? c_dx : min32(c_sx, c_dx);
  wire [47:0] wr_tot    = (wr_src_si || c_ywrap) ? p_dst : p_src;
  wire        wr_fille  = c_is2d ? c_yfill : c_xfill;

  logic        r_ok_run, w_ok_run;
  logic [PW-1:0] wsrc_avail;
  logic        w_dlim_en, w_exhaust;
  logic [9:0]  w_dlim;
  logic        src_final;

  wire full_clear = clear_do | attr_chg;   // CLEARCMD / security or privilege change

  dma_ch_agen #(.AW(AW), .DW(DW), .IS_WR(1'b0), .HALF_BYTES(HALFB)) u_ragen (
    .clk(clk), .resetn(resetn), .clr(full_clear),
    .start(agen_start && c_rd_act), .abort(agen_abort | (c_s_per & s_per_last) | (c_d_per & d_per_last & !wa_active)),
    .i_base(align_ts(r_srcaddr, c_ts)), .i_ts(c_ts), .i_inc(r_srcxinc),
    .i_stride_b(c_is2d ? stride_b(r_srcys, c_ts) : '0),
    .i_tmpl_en(r_srctsz != 5'd0), .i_tmpl(r_srctm), .i_tsize(r_srctsz),
    .i_opt(r_srctc[7:4] != 4'd0), .i_maxbeats(5'(r_srctc[19:16]) + 5'd1),
    .i_modelb(rd_modelb), .i_is2d(c_is2d), .i_xwrap(c_xwrap), .i_xfill(c_xfill),
    .i_ywrap(c_ywrap), .i_fill_empty(1'b0), .i_src_nonempty(1'b1),
    .i_sx(c_sx), .i_sy(c_sy), .i_dx(c_dx), .i_lines(rd_lines), .i_tot(rd_tot), .i_lcnt(rd_lcnt),
    // no fast path while a trigger block limits the side: the block counter
    // is only updated after the issue, so the next step must use the new value
    .run(r_ok_run), .fast_ok(!(s_blk_en & c_s_fc)),
    .blk_en(s_blk_en & c_s_fc), .blk_rem(s_blk_rem),
    .dlim_en(1'b0), .dlim(10'h3FF), .exhaust(1'b0), .recompute(1'b0),
    .d_valid(ra_dv), .d_pop(ra_pop), .d_addr(ra_addr), .d_len(ra_len), .d_size(ra_size),
    .d_burst(ra_burst), .d_nb(ra_nb), .d_nelem(ra_nelem), .d_fill(ra_fill), .d_last(ra_last),
    .active(ra_active), .st_addr(ra_st_addr), .st_xrem(ra_st_x), .st_yrem(ra_st_y), .st_lbase(ra_lbase)
  );

  dma_ch_agen #(.AW(AW), .DW(DW), .IS_WR(1'b1), .HALF_BYTES(HALFB)) u_wagen (
    .clk(clk), .resetn(resetn), .clr(full_clear),
    .start(agen_start && c_wr_act), .abort(agen_abort | (c_d_per & d_per_last)),
    .i_base(align_ts(r_desaddr, c_ts)), .i_ts(c_ts), .i_inc(r_desxinc),
    .i_stride_b(c_is2d ? stride_b(r_desys, c_ts) : '0),
    .i_tmpl_en(r_destsz != 5'd0), .i_tmpl(r_destm), .i_tsize(r_destsz),
    .i_opt(r_destc[7:4] != 4'd0), .i_maxbeats(5'(r_destc[19:16]) + 5'd1),
    .i_modelb(c_modelb), .i_is2d(c_is2d), .i_xwrap(c_xwrap), .i_xfill(c_xfill),
    .i_ywrap(c_ywrap), .i_fill_empty(wr_fille),
    .i_src_nonempty(wr_src_si || (c_sx != 32'd0 && c_sy != 16'd0)),
    .i_sx(c_sx), .i_sy(wr_src_si ? c_dy : c_sy), .i_dx(c_dx), .i_lines(wr_lines),
    .i_tot(wr_tot), .i_lcnt(wr_lcnt),
    .run(w_ok_run), .fast_ok(!(d_blk_en & c_d_fc)),
    .blk_en(d_blk_en & c_d_fc), .blk_rem(d_blk_rem),
    .dlim_en(w_dlim_en), .dlim(w_dlim), .exhaust(w_exhaust), .recompute(wa_recomp),
    .d_valid(wa_dv), .d_pop(wa_pop), .d_addr(wa_addr), .d_len(wa_len), .d_size(wa_size),
    .d_burst(wa_burst), .d_nb(wa_nb), .d_nelem(wa_nelem), .d_fill(wa_fill), .d_last(wa_last),
    .active(wa_active), .st_addr(wa_st_addr), .st_xrem(wa_st_x), .st_yrem(wa_st_y), .st_lbase(wa_lbase)
  );

  assign r_ok_run = run && (st == S_XFER);
  assign w_ok_run = run && (st == S_XFER);

  // write side runtime data limit (stream-in / peripheral driven source)
  assign src_final  = c_str_in ? si_final : (c_s_per && s_per_last && rd_complete);
  assign w_dlim_en  = c_conserv && src_final;
  assign w_dlim     = (|(wsrc_avail >> c_ts) >> 10) ? 10'h3FF : 10'(wsrc_avail >> c_ts);
  assign w_exhaust  = w_dlim_en && (wsrc_avail == '0);
  assign wa_recomp  = wa_dv && !wa_fill && w_dlim_en && (PW'(wa_nb) > wsrc_avail);

  // ==========================================================================
  // Command link unit
  // ==========================================================================
  logic          lk_rq_valid, lk_rq_ready;
  logic [AW-1:0] lk_rq_addr;
  logic [7:0]    lk_rq_len;
  logic [8:0]    lk_rq_nb;
  logic          rdp_l_valid, rdp_bdone, rdp_blink;
  logic [DW-1:0] rdp_l_data;
  logic [LB-1:0] rdp_l_lane;
  logic [LB:0]   rdp_l_nb;

  dma_ch_link #(.AW(AW), .DW(DW), .CMDBUF(CMDBUF)) u_link (
    .clk(clk), .resetn(resetn),
    .start(lk_start), .abort(agen_abort),
    .link_addr({r_linkaddr[AW-1:2], 2'b00}), .run(run),
    .rq_valid(lk_rq_valid), .rq_ready(lk_rq_ready), .rq_addr(lk_rq_addr), .rq_len(lk_rq_len), .rq_nb(lk_rq_nb),
    .rd_valid(rdp_l_valid), .rd_data(rdp_l_data), .rd_lane(rdp_l_lane), .rd_nb(rdp_l_nb),
    .rd_burst_done(rdp_bdone && rdp_blink),
    .reg_clear(lk_clear), .reg_we(lk_we), .reg_idx(lk_idx), .reg_wdata(lk_wdata),
    .busy(lk_busy), .done(lk_done), .hdr_err(lk_hdr_err)
  );

  // ==========================================================================
  // Read issue -> AR queue
  // ==========================================================================
  localparam int ARQW = AW + 8 + 3 + 2 + 1 + 1;
  logic            arq_full, arq_empty, arq_push;
  logic [ARQW-1:0] arq_din, arq_dout;

  wire [3:0] cap = {1'b0, r_icap} + 4'd1;

  logic rd_port_n;
  wire  rd_link_sel = (st == S_LINK);
  always_comb begin
    rd_port_n = 1'b0;
    if (M1_PRESENT) rd_port_n = dma_port_sel(64'(rd_link_sel ? lk_rq_addr : ra_addr));
  end
  wire rd_port_ok = (rd_infl == 4'd0) || (rd_port_n == rd_port_l);
  wire rd_cap_ok  = (rd_infl < cap);

  wire push_rd_data = !rd_link_sel && ra_dv && r_ok_run && !arq_full && rd_cap_ok && rd_port_ok &&
                      (free_a >= PW'(ra_nb));
  wire push_rd_link = rd_link_sel && lk_rq_valid && !arq_full && rd_cap_ok && rd_port_ok;

  assign ra_pop      = push_rd_data;
  assign lk_rq_ready = push_rd_link;
  assign arq_push    = push_rd_data | push_rd_link;
  assign arq_din     = rd_link_sel ? {lk_rq_addr, lk_rq_len, 3'(LB), AXI_INCR, 1'b1, rd_port_n}
                                   : {ra_addr, ra_len, ra_size, ra_burst, 1'b0, rd_port_n};

  dma_fifo_ff #(.WIDTH(ARQW), .DEPTH(2)) u_arq (
    .clk(clk), .resetn(resetn), .clr(1'b0),
    .push(arq_push), .din(arq_din), .full(arq_full),
    .pop(ar_valid & ar_ready), .dout(arq_dout), .empty(arq_empty), .count()
  );

  assign ar_valid = ~arq_empty;
  assign {ar_addr, ar_len, ar_size, ar_burst, ar_cmdlink, ar_port} = arq_dout;
  assign ar_cache  = ar_cmdlink ? c_lk_cache : c_rd_cache;
  assign ar_inner  = ar_cmdlink ? c_lk_inner : c_rd_inner;
  assign ar_domain = ar_cmdlink ? c_lk_dom   : c_rd_dom;
  assign ar_prot   = ar_cmdlink ? c_lk_prot  : c_rd_prot;
  assign ar_qos    = c_qos;

  // ==========================================================================
  // Read data path
  // ==========================================================================
  logic          rdp_f_valid;
  logic [DW-1:0] rdp_f_data;
  logic [LB-1:0] rdp_f_lane;
  logic [LB:0]   rdp_f_nb;
  logic          rdp_err_resp, rdp_err_pois;

  dma_ch_rdp #(.DW(DW), .QDEPTH(MAXOUT)) u_rdp (
    .clk(clk), .resetn(resetn), .clr(1'b0),
    .q_push(arq_push), .q_alo(rd_link_sel ? lk_rq_addr[LB-1:0] : ra_addr[LB-1:0]),
    .q_size(rd_link_sel ? 3'(LB) : ra_size), .q_burst(rd_link_sel ? AXI_INCR : ra_burst),
    .q_nb(rd_link_sel ? lk_rq_nb : ra_nb), .q_link(rd_link_sel), .q_full(),
    .r_valid(r_valid), .r_data(r_data), .r_resp(r_resp), .r_last(r_last), .r_poison(r_poison),
    .f_valid(rdp_f_valid), .f_data(rdp_f_data), .f_lane(rdp_f_lane), .f_nb(rdp_f_nb),
    .l_valid(rdp_l_valid), .l_data(rdp_l_data), .l_lane(rdp_l_lane), .l_nb(rdp_l_nb),
    .burst_done(rdp_bdone), .burst_link(rdp_blink),
    .err_resp(rdp_err_resp), .err_poison(rdp_err_pois), .q_empty(rdp_qempty)
  );

  // ==========================================================================
  // FIFO A (main) and FIFO B (stream-in in "in & out" mode)
  // ==========================================================================
  localparam int TAGW = DWB + 2;

  logic          fa_wv, fa_com;
  logic [DW-1:0] fa_wd;
  logic [LB-1:0] fa_wl;
  logic [LB:0]   fa_wn, fa_comnb;
  logic          fa_rv, fa_rskip, fa_ov;
  logic [LB-1:0] fa_rl;
  logic [LB:0]   fa_rn;
  logic [TAGW-1:0] fa_rtag, fa_otag;
  logic [DW-1:0] fa_od;

  dma_ch_fifo #(.DW(DW), .DEPTH(FD), .MEM_IMPL(MEM_IMPL), .TAGW(TAGW)) u_fifo_a (
    .clk(clk), .resetn(resetn), .clr(fifo_clr),
    .wr_valid(fa_wv), .wr_data(fa_wd), .wr_lane(fa_wl), .wr_nb(fa_wn),
    .wr_commit(fa_com), .wr_commit_nb(fa_comnb),
    .rd_valid(fa_rv), .rd_skip(fa_rskip), .rd_lane(fa_rl), .rd_nb(fa_rn), .rd_tag(fa_rtag),
    .out_valid(fa_ov), .out_data(fa_od), .out_tag(fa_otag)
  );

  logic          fb_wv, fb_com;
  logic [DW-1:0] fb_wd;
  logic [LB:0]   fb_wn, fb_comnb;
  logic          fb_rv, fb_rskip, fb_ov;
  logic [LB-1:0] fb_rl;
  logic [LB:0]   fb_rn;
  logic [TAGW-1:0] fb_rtag, fb_otag;
  logic [DW-1:0] fb_od;

  generate
    if (STREAM) begin : g_fifo_b
      dma_ch_fifo #(.DW(DW), .DEPTH(FD), .MEM_IMPL(MEM_IMPL), .TAGW(TAGW)) u_fifo_b (
        .clk(clk), .resetn(resetn), .clr(fifo_clr),
        .wr_valid(fb_wv), .wr_data(fb_wd), .wr_lane('0), .wr_nb(fb_wn),
        .wr_commit(fb_com), .wr_commit_nb(fb_comnb),
        .rd_valid(fb_rv), .rd_skip(fb_rskip), .rd_lane(fb_rl), .rd_nb(fb_rn), .rd_tag(fb_rtag),
        .out_valid(fb_ov), .out_data(fb_od), .out_tag(fb_otag)
      );
    end else begin : g_no_fifo_b
      assign fb_com = 1'b0; assign fb_comnb = '0; assign fb_ov = 1'b0;
      assign fb_od = '0; assign fb_otag = '0;
    end
  endgenerate

  // ==========================================================================
  // Stream-in producer
  // ==========================================================================
  logic si_acc, si_bad, si_target_b;
  logic [LB:0] si_nb;
  logic si_active;

  assign si_target_b = c_str_io;
  assign si_active   = STREAM && c_str_in && (st == S_XFER || st == S_STOP) && !si_done;

  always_comb begin
    logic contig;
    si_nb  = '0;
    for (int i = 0; i < DWB; i++) si_nb = si_nb + si_tstrb[i];
    contig = ((si_tstrb & (si_tstrb + 1'b1)) == '0);       // ones from bit 0
    si_bad = 1'b0;
    if (!si_tlast) si_bad = (si_tstrb != '1);
    else           si_bad = !contig || (si_nb == '0) ||
                            ((si_nb & ((LB+1)'(1 << c_ts) - 1'b1)) != '0);
  end

  wire [PW-1:0] si_free = si_target_b ? free_b : free_a;
  assign si_tready = si_active && (flush_q || (st == S_XFER && si_free >= PW'(DWB)));
  assign si_acc    = si_tvalid && si_tready;
  assign si_flush  = flush_q && STREAM;
  assign si_pending = STREAM && c_str_in && c_wr_act && !si_last_seen && !si_done;

  wire si_wr = si_acc && !flush_q && !si_bad;

  // ==========================================================================
  // FIFO write port muxing
  // ==========================================================================
  assign fa_wv = c_str_in && !c_str_io ? si_wr : rdp_f_valid;
  assign fa_wd = c_str_in && !c_str_io ? si_tdata : rdp_f_data;
  assign fa_wl = c_str_in && !c_str_io ? '0 : rdp_f_lane;
  assign fa_wn = c_str_in && !c_str_io ? si_nb : rdp_f_nb;
  assign fb_wv = c_str_io && si_wr;
  assign fb_wd = si_tdata;
  assign fb_wn = si_nb;

  // ==========================================================================
  // Write issue -> AW queue + W engine
  // ==========================================================================
  localparam int AWQW = AW + 8 + 3 + 2 + 1;
  logic            awq_full, awq_empty, awq_push;
  logic [AWQW-1:0] awq_din, awq_dout;
  logic            weng_full;

  logic wr_port_n;
  always_comb begin
    wr_port_n = 1'b0;
    if (M1_PRESENT) wr_port_n = dma_port_sel(64'(wa_addr));
  end
  wire wr_port_ok = (wr_infl == 4'd0) || (wr_port_n == wr_port_l);
  wire wr_cap_ok  = (wr_infl < cap);
  assign wsrc_avail = c_str_io ? avail_b : avail_a;

  wire push_wr = wa_dv && !wa_recomp && w_ok_run && !awq_full && !weng_full && wr_cap_ok &&
                 wr_port_ok && (wa_fill || (wsrc_avail >= PW'(wa_nb)));

  assign wa_pop   = push_wr;
  assign awq_push = push_wr;
  assign awq_din  = {wa_addr, wa_len, wa_size, wa_burst, wr_port_n};

  dma_fifo_ff #(.WIDTH(AWQW), .DEPTH(2)) u_awq (
    .clk(clk), .resetn(resetn), .clr(1'b0),
    .push(awq_push), .din(awq_din), .full(awq_full),
    .pop(aw_valid & aw_ready), .dout(awq_dout), .empty(awq_empty), .count()
  );

  assign aw_valid = ~awq_empty;
  assign {aw_addr, aw_len, aw_size, aw_burst, aw_port} = awq_dout;
  assign aw_cache  = c_wr_cache;
  assign aw_inner  = c_wr_inner;
  assign aw_domain = c_wr_dom;
  assign aw_prot   = c_wr_prot;
  assign aw_qos    = c_qos;

  // drain of excess source data (AXI -> AXI only)
  wire drain_push = !c_str_out && !c_str_in && c_wr_act && !wa_active && xfer_run &&
                    (avail_a != '0) && !weng_full && !push_wr;
  wire do_drain   = drain_push;
  wire [LB:0] drain_nb = (avail_a > PW'(DWB)) ? (LB+1)'(DWB) : (LB+1)'(avail_a);

  logic          weng_rel;
  logic [LB:0]   weng_relnb;
  logic          weng_frv, weng_fskip;
  logic [LB-1:0] weng_frl;
  logic [LB:0]   weng_frn;
  logic [TAGW-1:0] weng_ftag;

  dma_ch_rdeng #(.DW(DW), .QDEPTH(MAXOUT+2), .ODEPTH(6)) u_weng (
    .clk(clk), .resetn(resetn), .clr(1'b0), .fill_pat(c_fillpat),
    .d_push(push_wr | do_drain), .d_kind(do_drain && !push_wr ? 2'd2 : 2'd0),
    .d_alo(push_wr ? wa_addr[LB-1:0] : '0), .d_size(wa_size), .d_burst(wa_burst),
    .d_nb(push_wr ? wa_nb : 9'(drain_nb)), .d_fill(push_wr & wa_fill), .d_tlast(1'b0),
    .d_full(weng_full), .idle(weng_idle),
    .f_rd_valid(weng_frv), .f_rd_skip(weng_fskip), .f_rd_lane(weng_frl), .f_rd_nb(weng_frn),
    .f_rd_tag(weng_ftag),
    .f_out_valid(c_str_io ? fb_ov : (c_str_out ? 1'b0 : fa_ov)), .f_out_data(c_str_io ? fb_od : fa_od),
    .f_out_tag(c_str_io ? fb_otag : fa_otag),
    .rel_valid(weng_rel), .rel_nb(weng_relnb),
    .o_valid(w_valid), .o_ready(w_ready), .o_data(w_data), .o_strb(w_strb), .o_last(w_last)
  );

  // ==========================================================================
  // Stream-out engine (FIFO A consumer when stream out is used)
  // ==========================================================================
  logic          seng_full, seng_push, seng_tlast;
  logic [LB:0]   seng_nb;
  logic          seng_rel;
  logic [LB:0]   seng_relnb;
  logic          seng_frv, seng_fskip;
  logic [LB-1:0] seng_frl;
  logic [LB:0]   seng_frn;
  logic [TAGW-1:0] seng_ftag;
  logic          so_last_pend;

  generate
    if (STREAM) begin : g_seng
      assign seng_push  = c_str_out && (st == S_XFER) && !seng_full && !so_last_pend &&
                          ((avail_a > PW'(DWB)) || (rd_complete && avail_a != '0));
      assign seng_tlast = rd_complete && (avail_a <= PW'(DWB));
      assign seng_nb    = (avail_a > PW'(DWB)) ? (LB+1)'(DWB) : (LB+1)'(avail_a);

      dma_ch_rdeng #(.DW(DW), .QDEPTH(4), .ODEPTH(6)) u_seng (
        .clk(clk), .resetn(resetn), .clr(1'b0), .fill_pat('0),
        .d_push(seng_push), .d_kind(2'd1), .d_alo('0), .d_size(3'(LB)), .d_burst(AXI_INCR),
        .d_nb(9'(seng_nb)), .d_fill(1'b0), .d_tlast(seng_tlast),
        .d_full(seng_full), .idle(seng_idle),
        .f_rd_valid(seng_frv), .f_rd_skip(seng_fskip), .f_rd_lane(seng_frl), .f_rd_nb(seng_frn),
        .f_rd_tag(seng_ftag),
        .f_out_valid(fa_ov & c_str_out), .f_out_data(fa_od), .f_out_tag(fa_otag),
        .rel_valid(seng_rel), .rel_nb(seng_relnb),
        .o_valid(so_tvalid), .o_ready(so_tready), .o_data(so_tdata), .o_strb(so_tstrb), .o_last(so_tlast)
      );
    end else begin : g_no_seng
      assign seng_push = 1'b0; assign seng_tlast = 1'b0; assign seng_nb = '0;
      assign seng_full = 1'b0; assign seng_idle = 1'b1;
      assign seng_frv = 1'b0; assign seng_fskip = 1'b0; assign seng_frl = '0; assign seng_frn = '0;
      assign seng_ftag = '0; assign seng_rel = 1'b0; assign seng_relnb = '0;
      assign so_tvalid = 1'b0; assign so_tdata = '0; assign so_tstrb = '0; assign so_tlast = 1'b0;
    end
  endgenerate

  // FIFO read port muxing: A is read by the stream-out engine (stream out
  // modes) or by the W engine; B is always read by the W engine.
  wire a_by_seng = c_str_out;
  assign fa_rv    = a_by_seng ? seng_frv   : (!c_str_io & weng_frv);
  assign fa_rskip = a_by_seng ? seng_fskip : weng_fskip;
  assign fa_rl    = a_by_seng ? seng_frl   : weng_frl;
  assign fa_rn    = a_by_seng ? seng_frn   : weng_frn;
  assign fa_rtag  = a_by_seng ? seng_ftag  : weng_ftag;
  assign fb_rv    = c_str_io & weng_frv;
  assign fb_rskip = weng_fskip;
  assign fb_rl    = weng_frl;
  assign fb_rn    = weng_frn;
  assign fb_rtag  = weng_ftag;

  // ==========================================================================
  // Byte accounting
  // ==========================================================================
  // FIFO A
  wire [PW-1:0] a_res = push_rd_data ? PW'(ra_nb) : ((si_wr && !si_target_b) ? PW'(si_nb) : '0);
  wire [PW-1:0] a_rel = a_by_seng ? (seng_rel ? PW'(seng_relnb) : '0)
                                  : ((weng_rel && !c_str_io) ? PW'(weng_relnb) : '0);
  wire [PW-1:0] a_com = fa_com ? PW'(fa_comnb) : '0;
  wire [PW-1:0] a_clm = (push_wr && !wa_fill && !c_str_io) ? PW'(wa_nb) :
                        (do_drain && !push_wr)             ? PW'(drain_nb) :
                        seng_push                          ? PW'(seng_nb) : '0;
  // FIFO B
  wire [PW-1:0] b_res = (si_wr && si_target_b) ? PW'(si_nb) : '0;
  wire [PW-1:0] b_rel = (weng_rel && c_str_io) ? PW'(weng_relnb) : '0;
  wire [PW-1:0] b_com = fb_com ? PW'(fb_comnb) : '0;
  wire [PW-1:0] b_clm = (push_wr && !wa_fill && c_str_io) ? PW'(wa_nb) : '0;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      free_a <= PW'(CAPB); avail_a <= '0; free_b <= PW'(CAPB); avail_b <= '0;
    end else if (fifo_clr) begin
      free_a <= PW'(CAPB); avail_a <= '0; free_b <= PW'(CAPB); avail_b <= '0;
    end else begin
      free_a  <= free_a  - a_res + a_rel;
      avail_a <= avail_a + a_com - a_clm;
      free_b  <= free_b  - b_res + b_rel;
      avail_b <= avail_b + b_com - b_clm;
    end
  end

  // pending (reserved but not yet committed) bytes
  wire rd_to_a = !(c_str_in && !c_str_io);
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      rd_pend_b <= '0;
      si_pend_b <= '0;
    end else if (fifo_clr) begin
      rd_pend_b <= '0;
      si_pend_b <= '0;
    end else begin
      // (bytes of errored read beats are never committed; the command is
      //  stopped in that case and the counter is cleared with the FIFO)
      rd_pend_b <= rd_pend_b + (push_rd_data ? 12'(ra_nb) : 12'd0)
                             - ((fa_com && rd_to_a) ? 12'(fa_comnb) : 12'd0);
      si_pend_b <= si_pend_b + (si_wr ? 12'(si_nb) : 12'd0)
                             - ((fa_com && !rd_to_a) ? 12'(fa_comnb) : 12'd0)
                             - (fb_com ? 12'(fb_comnb) : 12'd0);
    end
  end

  // outstanding transaction counters
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      rd_infl <= '0; wr_infl <= '0; rd_port_l <= 1'b0; wr_port_l <= 1'b0;
    end else begin
      rd_infl <= rd_infl + arq_push - rdp_bdone;
      wr_infl <= wr_infl + push_wr  - b_valid;
      if (arq_push) rd_port_l <= rd_port_n;
      if (push_wr)  wr_port_l <= wr_port_n;
    end
  end

  // ==========================================================================
  // Stream state
  // ==========================================================================
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      si_last_seen  <= 1'b0;
      si_done       <= 1'b0;
      so_tlast_sent <= 1'b0;
      so_last_pend  <= 1'b0;
      flush_q       <= 1'b0;
    end else if (fifo_clr) begin
      // cleared at command set-up (S_GPO), before the stream interfaces are
      // active: a beat accepted in the first XFER cycle keeps its TLAST
      si_last_seen  <= 1'b0;
      si_done       <= 1'b0;
      so_tlast_sent <= 1'b0;
      so_last_pend  <= 1'b0;
      flush_q       <= 1'b0;
    end else begin
      if (si_acc && si_tlast) begin
        si_last_seen <= 1'b1;
        if (flush_q) begin
          flush_q <= 1'b0;
          si_done <= 1'b1;
        end
      end
      if (seng_push && seng_tlast)               so_last_pend  <= 1'b1;
      if (so_tvalid && so_tready && so_tlast)    so_tlast_sent <= 1'b1;
      // flush request: command ends before the stream-in packet finished
      if (STREAM && c_str_in && !si_last_seen && !si_done &&
          ((st == S_STOP) || e_any))             flush_q <= 1'b1;
      if (st == S_FIN)                           flush_q <= 1'b0;
    end
  end

  // ==========================================================================
  // Error detection
  // ==========================================================================
  assign e_rdresp  = rdp_err_resp;
  assign e_rdpois  = rdp_err_pois;
  assign e_wrresp  = b_valid && b_resp[1];
  assign e_strb    = si_acc && !flush_q && si_bad;
  assign e_overrun = xfer_run && c_str_in && c_wr_act && !wa_active && (wr_infl == 4'd0) &&
                     (!si_last_seen || (si_pend_b != 12'd0) || (wsrc_avail != '0));
  assign e_early   = xfer_run && c_str_io && si_last_seen && c_rd_act && !so_tlast_sent;
  assign e_hdr     = lk_hdr_err;
  assign e_any     = e_rdresp | e_rdpois | e_wrresp | e_strb | e_overrun | e_early | e_hdr;

  // ==========================================================================
  // Triggers
  // ==========================================================================
  wire trig_pause = pause_req || !u_run;
  wire trig_clr   = (st == S_IDLE) || (st == S_FIN) || done_go || ent_stop;

  dma_ch_trigin u_tsrc (
    .clk(clk), .resetn(resetn), .clr(trig_clr), .pause(trig_pause),
    .en(c_s_use), .hw_type(c_s_hw), .fc_mode(c_s_fc), .fc_per(c_s_per), .blksize(c_s_blk),
    .cmd_phase(st == S_CMDTRIG), .cmd_go(cmd_go), .xfer_phase(st == S_XFER),
    .hw_req(tm_src_req), .hw_reqtype(tm_src_reqtype), .hw_ack(tm_src_ack), .hw_acktype(tm_src_acktype),
    .sw_req(sw_src_req), .sw_type(sw_src_type), .sw_req_clr(s_sw_clr),
    .side_active(ra_active), .side_idle(rd_infl == 4'd0 && rd_pend_b == 12'd0),
    .pop(push_rd_data), .pop_nelem(ra_nelem),
    .blk_en(s_blk_en), .blk_rem(s_blk_rem), .per_last(s_per_last),
    .stat_wait(stw_src), .cmd_got(s_cmd_got), .cmd_done(s_cmd_done), .fc_done(s_fc_done), .busy()
  );

  dma_ch_trigin u_tdes (
    .clk(clk), .resetn(resetn), .clr(trig_clr), .pause(trig_pause),
    .en(c_d_use), .hw_type(c_d_hw), .fc_mode(c_d_fc), .fc_per(c_d_per), .blksize(c_d_blk),
    .cmd_phase(st == S_CMDTRIG), .cmd_go(cmd_go), .xfer_phase(st == S_XFER),
    .hw_req(tm_des_req), .hw_reqtype(tm_des_reqtype), .hw_ack(tm_des_ack), .hw_acktype(tm_des_acktype),
    .sw_req(sw_des_req), .sw_type(sw_des_type), .sw_req_clr(d_sw_clr),
    .side_active(wa_active), .side_idle(wr_infl == 4'd0),
    .pop(push_wr), .pop_nelem(wa_nelem),
    .blk_en(d_blk_en), .blk_rem(d_blk_rem), .per_last(d_per_last),
    .stat_wait(stw_des), .cmd_got(d_cmd_got), .cmd_done(d_cmd_done), .fc_done(d_fc_done), .busy()
  );

  // command trigger synchronisation: ack all command-mode sides together
  wire s_cmd_need = c_s_use && !c_s_fc;
  wire d_cmd_need = c_d_use && !c_d_fc;
  assign cmd_go = (st == S_CMDTRIG) && !trig_pause &&
                  (!s_cmd_need || s_cmd_got) && (!d_cmd_need || d_cmd_got);

  dma_ch_trigout u_tout (
    .clk(clk), .resetn(resetn), .clr(trig_clr), .pause(trig_pause),
    .en(c_o_use), .hw_type(c_o_hw), .start(to_start), .hw_ack(tm_out_ack),
    .sw_ack(sw_out_ack), .sw_ack_clr(o_sw_clr), .hw_req(tm_out_req),
    .stat_wait(stw_out), .done(to_done)
  );

  // transfer completion
  assign xfer_done = xfer_run && rd_complete && wr_complete &&
                     (!c_str_out || !c_rd_act || so_tlast_sent) && seng_idle &&
                     (!c_str_in  || !c_wr_act || si_final) &&
                     (avail_a == '0) && (!c_str_io || avail_b == '0) &&
                     s_fc_done && d_fc_done && s_cmd_done && d_cmd_done;

  // trigger matrix requests
  assign tm_src_use = f_s_hw | f_s_int;
  assign tm_src_int = f_s_int;
  assign tm_src_sel = r_srctic[7:0];
  assign tm_des_use = f_d_hw | f_d_int;
  assign tm_des_int = f_d_int;
  assign tm_des_sel = r_destic[7:0];
  assign tm_out_use = f_o_hw;
  assign tm_out_sel = {2'b00, r_toc[5:0]};
  assign tm_out_int = c_o_int;

  // ==========================================================================
  // Status outputs
  // ==========================================================================
  assign st_enabled = enabled;
  assign st_paused  = stat_paused;
  assign st_waiting = enabled && quiet && !(st == S_XFER && (ra_active || wa_active)) &&
                      (stw_src || stw_des || stw_out || stat_paused || st == S_CMDTRIG);
  assign gpo        = gpo_q;

  // error / stopped status (mirrors STAT_* via the register block)
  logic st_err_q, st_stop_q;
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      st_err_q  <= 1'b0;
      st_stop_q <= 1'b0;
    end else begin
      if (cmd_enable || clear_do || attr_chg) begin st_err_q <= 1'b0; st_stop_q <= 1'b0; end
      if (set_err)     st_err_q  <= 1'b1;
      if (set_stopped) st_stop_q <= 1'b1;
      if (reg_wr && reg_off == CH_STATUS) begin
        if (reg_wdata[17]) st_err_q  <= 1'b0;
        if (reg_wdata[19]) st_stop_q <= 1'b0;
      end
    end
  end
  assign st_err     = st_err_q;
  assign st_stopped = st_stop_q;

endmodule : dma_channel
