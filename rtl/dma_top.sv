//-----------------------------------------------------------------------------
// dma_top.sv
// AXI DMA controller - top level (CoreLink DMA-350 compatible programmers
// model and interfaces, TRM).
//
// Per-index port groups of the TRM (trig_in_<TI>_*, str_out_<N>_*, gpo_ch_<N>)
// are exposed as packed vectors indexed by TI / N. scripts/gen_flat_top.py
// generates a wrapper with the exact per-index signal names for a given
// configuration.
//
// Interfaces : APB4 subordinate (pclken), AXI5 manager M0 (+M1) (aclken_m*),
//              AXI4-Stream in/out per channel, trigger in/out, LPI Q/P
//              channels, CTI, all-channel stop / pause, GPO, status, IRQ,
//              autoboot.
//-----------------------------------------------------------------------------
module dma_top
  import dma_pkg::*;
#(
  parameter int          NUM_CHANNELS          = 2,
  parameter int          ADDR_WIDTH            = 32,
  parameter int          DATA_WIDTH            = 64,
  parameter int          CHID_WIDTH            = 0,
  parameter int          GPO_WIDTH             = 8,
  parameter logic [7:0]  CH_GPO_MASK           = 8'hFF,
  parameter logic [7:0]  CH_STREAM_MASK        = 8'h00,
  parameter logic [7:0]  CH_EXT_FEAT_MASK      = 8'hFF,
  parameter int          CH_FIFO_DEPTH [8]     = '{16, 16, 16, 16, 16, 16, 16, 16},
  parameter int          NUM_TRIGGER_IN        = 4,
  parameter int          NUM_TRIGGER_OUT       = 4,
  parameter logic [31:0] TRIG_IN_SYNC_EN_MASK  = 32'hFFFF_FFFF,
  parameter logic [31:0] TRIG_OUT_SYNC_EN_MASK = 32'hFFFF_FFFF,
  parameter bit          AXI5_M1_PRESENT       = 1'b0,
  parameter bit          SECEXT_PRESENT        = 1'b1,
  // implementation options (not architectural)
  parameter int          MEM_IMPL              = 0,     // 0 flops, 1 SRAM macro
  parameter bit          RESET_SYNC_BYPASS     = 1'b0,
  parameter int          BIU_MAX_RD            = 32,
  parameter int          BIU_MAX_WR            = 32,
  // derived
  localparam int ID_WIDTH   = (NUM_CHANNELS > 1) ? $clog2(NUM_CHANNELS) : 1,
  localparam int STRB_WIDTH = DATA_WIDTH / 8,
  localparam int POIS_WIDTH = (DATA_WIDTH + 63) / 64,
  localparam int CHW        = (CHID_WIDTH > 0) ? CHID_WIDTH : 1,
  localparam int GW         = (GPO_WIDTH > 0) ? GPO_WIDTH : 1,
  localparam int NTI        = (NUM_TRIGGER_IN  > 0) ? NUM_TRIGGER_IN  : 1,
  localparam int NTO        = (NUM_TRIGGER_OUT > 0) ? NUM_TRIGGER_OUT : 1
) (
  // ---------------- clock / reset
  input  logic                         clk,
  input  logic                         resetn,
  input  logic                         aclken_m0,
  input  logic                         aclken_m1,
  input  logic                         pclken,
  // ---------------- Q-Channel
  input  logic                         clk_qreqn,
  output logic                         clk_qacceptn,
  output logic                         clk_qdeny,
  output logic                         clk_qactive,
  // ---------------- P-Channel
  input  logic                         preq,
  input  logic [3:0]                   pstate,
  output logic                         paccept,
  output logic                         pdeny,
  output logic [9:0]                   pactive,
  // ---------------- APB4
  input  logic                         psel,
  input  logic                         penable,
  input  logic [2:0]                   pprot,
  input  logic                         pwrite,
  input  logic [12:0]                  paddr,
  input  logic [31:0]                  pwdata,
  input  logic [3:0]                   pstrb,
  output logic                         pready,
  output logic                         pslverr,
  output logic [31:0]                  prdata,
  input  logic                         pwakeup,
  input  logic                         pdebug,
  // ---------------- AXI5 M0
  output logic                         awakeup_m0,
  output logic                         awvalid_m0,
  input  logic                         awready_m0,
  output logic [ADDR_WIDTH-1:0]        awaddr_m0,
  output logic [1:0]                   awburst_m0,
  output logic [ID_WIDTH-1:0]          awid_m0,
  output logic [7:0]                   awlen_m0,
  output logic [2:0]                   awsize_m0,
  output logic [3:0]                   awqos_m0,
  output logic [2:0]                   awprot_m0,
  output logic [3:0]                   awcache_m0,
  output logic [1:0]                   awdomain_m0,
  output logic [3:0]                   awinner_m0,
  output logic [CHW-1:0]               awchid_m0,
  output logic                         awchidvalid_m0,
  output logic                         arvalid_m0,
  input  logic                         arready_m0,
  output logic [ADDR_WIDTH-1:0]        araddr_m0,
  output logic [1:0]                   arburst_m0,
  output logic [ID_WIDTH-1:0]          arid_m0,
  output logic [7:0]                   arlen_m0,
  output logic [2:0]                   arsize_m0,
  output logic [3:0]                   arqos_m0,
  output logic [2:0]                   arprot_m0,
  output logic [3:0]                   arcache_m0,
  output logic [1:0]                   ardomain_m0,
  output logic [3:0]                   arinner_m0,
  output logic [CHW-1:0]               archid_m0,
  output logic                         archidvalid_m0,
  output logic                         arcmdlink_m0,
  output logic                         wvalid_m0,
  input  logic                         wready_m0,
  output logic                         wlast_m0,
  output logic [STRB_WIDTH-1:0]        wstrb_m0,
  output logic [DATA_WIDTH-1:0]        wdata_m0,
  input  logic                         rvalid_m0,
  output logic                         rready_m0,
  input  logic [ID_WIDTH-1:0]          rid_m0,
  input  logic                         rlast_m0,
  input  logic [DATA_WIDTH-1:0]        rdata_m0,
  input  logic [POIS_WIDTH-1:0]        rpoison_m0,
  input  logic [1:0]                   rresp_m0,
  input  logic                         bvalid_m0,
  output logic                         bready_m0,
  input  logic [ID_WIDTH-1:0]          bid_m0,
  input  logic [1:0]                   bresp_m0,
  // ---------------- AXI5 M1 (present when AXI5_M1_PRESENT = 1)
  output logic                         awakeup_m1,
  output logic                         awvalid_m1,
  input  logic                         awready_m1,
  output logic [ADDR_WIDTH-1:0]        awaddr_m1,
  output logic [1:0]                   awburst_m1,
  output logic [ID_WIDTH-1:0]          awid_m1,
  output logic [7:0]                   awlen_m1,
  output logic [2:0]                   awsize_m1,
  output logic [3:0]                   awqos_m1,
  output logic [2:0]                   awprot_m1,
  output logic [3:0]                   awcache_m1,
  output logic [1:0]                   awdomain_m1,
  output logic [3:0]                   awinner_m1,
  output logic [CHW-1:0]               awchid_m1,
  output logic                         awchidvalid_m1,
  output logic                         arvalid_m1,
  input  logic                         arready_m1,
  output logic [ADDR_WIDTH-1:0]        araddr_m1,
  output logic [1:0]                   arburst_m1,
  output logic [ID_WIDTH-1:0]          arid_m1,
  output logic [7:0]                   arlen_m1,
  output logic [2:0]                   arsize_m1,
  output logic [3:0]                   arqos_m1,
  output logic [2:0]                   arprot_m1,
  output logic [3:0]                   arcache_m1,
  output logic [1:0]                   ardomain_m1,
  output logic [3:0]                   arinner_m1,
  output logic [CHW-1:0]               archid_m1,
  output logic                         archidvalid_m1,
  output logic                         arcmdlink_m1,
  output logic                         wvalid_m1,
  input  logic                         wready_m1,
  output logic                         wlast_m1,
  output logic [STRB_WIDTH-1:0]        wstrb_m1,
  output logic [DATA_WIDTH-1:0]        wdata_m1,
  input  logic                         rvalid_m1,
  output logic                         rready_m1,
  input  logic [ID_WIDTH-1:0]          rid_m1,
  input  logic                         rlast_m1,
  input  logic [DATA_WIDTH-1:0]        rdata_m1,
  input  logic [POIS_WIDTH-1:0]        rpoison_m1,
  input  logic [1:0]                   rresp_m1,
  input  logic                         bvalid_m1,
  output logic                         bready_m1,
  input  logic [ID_WIDTH-1:0]          bid_m1,
  input  logic [1:0]                   bresp_m1,
  // ---------------- trigger interface
  input  logic [NTI-1:0]               trig_in_req,
  input  logic [NTI-1:0][1:0]          trig_in_req_type,
  output logic [NTI-1:0]               trig_in_ack,
  output logic [NTI-1:0][1:0]          trig_in_ack_type,
  output logic [NTO-1:0]               trig_out_req,
  input  logic [NTO-1:0]               trig_out_ack,
  // ---------------- interrupts
  output logic [NUM_CHANNELS-1:0]      irq_channel,
  output logic                         irq_comb_nonsec,
  output logic                         irq_comb_sec,
  output logic                         irq_sec_viol_err,
  // ---------------- AXI4-Stream (per channel)
  output logic [NUM_CHANNELS-1:0]                  str_out_tvalid,
  input  logic [NUM_CHANNELS-1:0]                  str_out_tready,
  output logic [NUM_CHANNELS-1:0][DATA_WIDTH-1:0]  str_out_tdata,
  output logic [NUM_CHANNELS-1:0][STRB_WIDTH-1:0]  str_out_tstrb,
  output logic [NUM_CHANNELS-1:0]                  str_out_tlast,
  input  logic [NUM_CHANNELS-1:0]                  str_in_tvalid,
  output logic [NUM_CHANNELS-1:0]                  str_in_tready,
  input  logic [NUM_CHANNELS-1:0][DATA_WIDTH-1:0]  str_in_tdata,
  input  logic [NUM_CHANNELS-1:0][STRB_WIDTH-1:0]  str_in_tstrb,
  input  logic [NUM_CHANNELS-1:0]                  str_in_tlast,
  output logic [NUM_CHANNELS-1:0]                  str_in_flush,
  // ---------------- status / control
  output logic [NUM_CHANNELS-1:0][GW-1:0]          gpo_ch,
  input  logic                         allch_stop_req_nonsec,
  output logic                         allch_stop_ack_nonsec,
  input  logic                         allch_pause_req_nonsec,
  output logic                         allch_pause_ack_nonsec,
  input  logic                         allch_stop_req_sec,
  output logic                         allch_stop_ack_sec,
  input  logic                         allch_pause_req_sec,
  output logic                         allch_pause_ack_sec,
  input  logic                         halt_req,
  input  logic                         restart_req,
  output logic                         halted,
  output logic [NUM_CHANNELS-1:0]      ch_enabled,
  output logic [NUM_CHANNELS-1:0]      ch_err,
  output logic [NUM_CHANNELS-1:0]      ch_stopped,
  output logic [NUM_CHANNELS-1:0]      ch_paused,
  output logic [NUM_CHANNELS-1:0]      ch_priv,
  output logic [NUM_CHANNELS-1:0]      ch_nonsec,
  // ---------------- configuration (static)
  input  logic                         boot_en,
  input  logic [ADDR_WIDTH-1:2]        boot_addr,
  input  logic [7:0]                   boot_memattr,
  input  logic [1:0]                   boot_shareattr
);

  localparam int NCH = NUM_CHANNELS;
  localparam int AW  = ADDR_WIDTH;
  localparam int DW  = DATA_WIDTH;

  // ==========================================================================
  // Reset synchronizer
  // ==========================================================================
  logic rstn;
  dma_reset_sync #(.STAGES(2), .BYPASS(RESET_SYNC_BYPASS)) u_rst (
    .clk(clk), .resetn_in(resetn), .test_mode(1'b0), .resetn_out(rstn));

  // ==========================================================================
  // APB front-end + unit
  // ==========================================================================
  logic        acc_wr, acc_rd, acc_debug, acc_strb_err, acc_err, apb_busy;
  logic [12:0] acc_addr;
  logic [31:0] acc_wdata, acc_rdata;
  logic [2:0]  acc_prot;

  dma_apb_if u_apb (
    .clk(clk), .resetn(rstn), .pclken(pclken),
    .psel(psel), .penable(penable), .pprot(pprot), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb), .pdebug(pdebug),
    .pready(pready), .pslverr(pslverr), .prdata(prdata),
    .acc_wr(acc_wr), .acc_rd(acc_rd), .acc_addr(acc_addr), .acc_wdata(acc_wdata),
    .acc_prot(acc_prot), .acc_debug(acc_debug), .acc_strb_err(acc_strb_err),
    .acc_rdata(acc_rdata), .acc_err(acc_err), .busy(apb_busy)
  );

  logic [NCH-1:0] ch_wr, ch_rd, c_nonsec, c_priv, c_attr_chg, c_chidvld, c_pause, c_stop;
  logic [7:0]     ch_off;
  logic [31:0]    ch_wdata;
  logic [31:0]    ch_rdata [NCH];
  logic [15:0]    c_chid [NCH];
  logic [NCH-1:0] s_enabled, s_err, s_stopped, s_paused, s_waiting, s_irq;
  logic [31:0]    tm_ti_req, tm_to_ack, tm_ti_sel, tm_deny, ti_nonsec, to_nonsec;
  logic           warm_rst_pause, lpi_run, lpi_active;
  logic [1:0]     ns_minpwr, s_minpwr;
  logic           ns_idleret, s_idleret;

  dma_unit #(
    .NUM_CH(NCH), .AW(AW), .DW(DW), .CHIDW(CHID_WIDTH), .NTI(NUM_TRIGGER_IN),
    .NTO(NUM_TRIGGER_OUT), .SECEXT(SECEXT_PRESENT), .GPOSEL(1'b0)
  ) u_unit (
    .clk(clk), .resetn(rstn),
    .acc_wr(acc_wr), .acc_rd(acc_rd), .acc_addr(acc_addr), .acc_wdata(acc_wdata),
    .acc_prot(acc_prot), .acc_debug(acc_debug), .acc_rdata(acc_rdata), .acc_err(acc_err),
    .ch_wr(ch_wr), .ch_rd(ch_rd), .ch_off(ch_off), .ch_wdata(ch_wdata), .ch_rdata(ch_rdata),
    .ch_nonsec(c_nonsec), .ch_priv(c_priv), .ch_attr_chg(c_attr_chg), .ch_chid(c_chid),
    .ch_chidvld(c_chidvld), .ch_pause(c_pause), .ch_stop(c_stop),
    .st_enabled(s_enabled), .st_stopped(s_stopped), .st_paused(s_paused), .st_irq(s_irq),
    .tm_ti_req(tm_ti_req), .tm_to_ack(tm_to_ack), .tm_ti_sel(tm_ti_sel), .tm_deny(tm_deny),
    .ti_nonsec(ti_nonsec), .to_nonsec(to_nonsec),
    .warm_rst_pause(warm_rst_pause), .ns_dis_minpwr(ns_minpwr), .s_dis_minpwr(s_minpwr),
    .ns_idleret(ns_idleret), .s_idleret(s_idleret),
    .allch_stop_req_nonsec(allch_stop_req_nonsec), .allch_stop_ack_nonsec(allch_stop_ack_nonsec),
    .allch_pause_req_nonsec(allch_pause_req_nonsec), .allch_pause_ack_nonsec(allch_pause_ack_nonsec),
    .allch_stop_req_sec(allch_stop_req_sec), .allch_stop_ack_sec(allch_stop_ack_sec),
    .allch_pause_req_sec(allch_pause_req_sec), .allch_pause_ack_sec(allch_pause_ack_sec),
    .halt_req(halt_req), .restart_req(restart_req), .halted(halted),
    .irq_comb_nonsec(irq_comb_nonsec), .irq_comb_sec(irq_comb_sec), .irq_sec_viol_err(irq_sec_viol_err)
  );

  // ==========================================================================
  // LPI
  // ==========================================================================
  wire [NCH-1:0] busy_ch = s_enabled & ~s_waiting;
  wire dmac_active = (|busy_ch) | apb_busy;
  wire async_wake  = pwakeup | (|trig_in_req) | allch_stop_req_nonsec | allch_pause_req_nonsec |
                     allch_stop_req_sec | allch_pause_req_sec | halt_req;

  dma_lpi u_lpi (
    .clk(clk), .resetn(rstn),
    .clk_qreqn(clk_qreqn), .clk_qacceptn(clk_qacceptn), .clk_qdeny(clk_qdeny), .clk_qactive(clk_qactive),
    .preq(preq), .pstate(pstate), .paccept(paccept), .pdeny(pdeny), .pactive(pactive),
    .dmac_active(dmac_active),
    .ns_waiting(|(s_enabled & s_waiting & c_nonsec)),
    .s_waiting(|(s_enabled & s_waiting & ~c_nonsec)),
    .any_enabled(|s_enabled), .all_paused(((s_enabled & ~s_paused) == '0)),
    .ns_present(|c_nonsec), .s_present(|(~c_nonsec)),
    .ns_dis_minpwr(ns_minpwr), .s_dis_minpwr(s_minpwr), .ns_idleret(ns_idleret), .s_idleret(s_idleret),
    .async_wake(async_wake),
    .run(lpi_run), .warm_rst_pause(warm_rst_pause), .lpi_active(lpi_active)
  );

  // ==========================================================================
  // Autoboot (channel 0)
  // ==========================================================================
  logic boot_done_q, boot_start;
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) boot_done_q <= 1'b0;
    else if (lpi_active) boot_done_q <= 1'b1;
  end
  assign boot_start = lpi_active && !boot_done_q && boot_en;

  // ==========================================================================
  // Channels
  // ==========================================================================
  logic [NCH-1:0] ar_valid, ar_ready, ar_cmdlink, ar_port;
  logic [AW-1:0]  ar_addr [NCH];
  logic [7:0]     ar_len  [NCH];
  logic [2:0]     ar_size [NCH], ar_prot [NCH];
  logic [1:0]     ar_burst[NCH], ar_domain [NCH];
  logic [3:0]     ar_cache[NCH], ar_qos [NCH], ar_inner [NCH];
  logic [NCH-1:0] aw_valid, aw_ready, aw_port;
  logic [AW-1:0]  aw_addr [NCH];
  logic [7:0]     aw_len  [NCH];
  logic [2:0]     aw_size [NCH], aw_prot [NCH];
  logic [1:0]     aw_burst[NCH], aw_domain [NCH];
  logic [3:0]     aw_cache[NCH], aw_qos [NCH], aw_inner [NCH];
  logic [NCH-1:0] w_valid, w_ready, w_last;
  logic [DW-1:0]  w_data [NCH];
  logic [DW/8-1:0] w_strb [NCH];
  logic [NCH-1:0] r_valid, r_last, r_poison, b_valid;
  logic [DW-1:0]  r_data [NCH];
  logic [1:0]     r_resp [NCH], b_resp [NCH];

  // trigger matrix channel side
  logic [NCH-1:0] tm_alloc, tm_src_use, tm_src_int, tm_des_use, tm_des_int, tm_out_use;
  logic [7:0]     tm_src_sel [NCH], tm_des_sel [NCH], tm_out_sel [NCH];
  logic [NCH-1:0] tm_alloc_done, tm_src_err, tm_des_err, tm_out_err, tm_release;
  logic [NCH-1:0] tm_src_req, tm_src_ack, tm_des_req, tm_des_ack, tm_out_req, tm_out_int, tm_out_ack;
  logic [1:0]     tm_src_reqtype [NCH], tm_src_acktype [NCH], tm_des_reqtype [NCH], tm_des_acktype [NCH];

  logic [31:0]    gpo_w [NCH];

  for (genvar c = 0; c < NCH; c++) begin : g_ch
    localparam bit CH_EXT    = CH_EXT_FEAT_MASK[c];
    localparam bit CH_STREAM = CH_STREAM_MASK[c];
    localparam int CH_GPO    = CH_GPO_MASK[c] ? GPO_WIDTH : 0;

    logic so_v, so_l, si_r, si_f;
    logic [DW-1:0] so_d;
    logic [DW/8-1:0] so_s;

    dma_channel #(
      .CH_IDX(c), .NUM_CH(NCH), .AW(AW), .DW(DW), .EXT(CH_EXT), .STREAM(CH_STREAM),
      .GPO_W(CH_GPO), .FIFO_DEPTH(CH_FIFO_DEPTH[c]), .NUM_TRIG_IN(NUM_TRIGGER_IN),
      .NUM_TRIG_OUT(NUM_TRIGGER_OUT), .M1_PRESENT(AXI5_M1_PRESENT), .MEM_IMPL(MEM_IMPL),
      .CMDBUF(16)
    ) u_ch (
      .clk(clk), .resetn(rstn),
      .reg_wr(ch_wr[c]), .reg_rd(ch_rd[c]), .reg_off(ch_off), .reg_wdata(ch_wdata), .reg_rdata(ch_rdata[c]),
      .ch_nonsec(c_nonsec[c]), .ch_priv(c_priv[c]), .attr_chg(c_attr_chg[c]),
      .u_pause(c_pause[c]), .u_stop(c_stop[c]), .u_run(lpi_run),
      .boot_start((c == 0) ? boot_start : 1'b0), .boot_addr({boot_addr, 2'b00}),
      .boot_memattr(boot_memattr), .boot_shareattr(boot_shareattr),
      .st_enabled(s_enabled[c]), .st_err(s_err[c]), .st_stopped(s_stopped[c]),
      .st_paused(s_paused[c]), .st_waiting(s_waiting[c]), .irq(s_irq[c]),
      .ar_valid(ar_valid[c]), .ar_ready(ar_ready[c]), .ar_addr(ar_addr[c]), .ar_len(ar_len[c]),
      .ar_size(ar_size[c]), .ar_burst(ar_burst[c]), .ar_cache(ar_cache[c]), .ar_prot(ar_prot[c]),
      .ar_qos(ar_qos[c]), .ar_domain(ar_domain[c]), .ar_inner(ar_inner[c]),
      .ar_cmdlink(ar_cmdlink[c]), .ar_port(ar_port[c]),
      .r_valid(r_valid[c]), .r_data(r_data[c]), .r_resp(r_resp[c]), .r_last(r_last[c]), .r_poison(r_poison[c]),
      .aw_valid(aw_valid[c]), .aw_ready(aw_ready[c]), .aw_addr(aw_addr[c]), .aw_len(aw_len[c]),
      .aw_size(aw_size[c]), .aw_burst(aw_burst[c]), .aw_cache(aw_cache[c]), .aw_prot(aw_prot[c]),
      .aw_qos(aw_qos[c]), .aw_domain(aw_domain[c]), .aw_inner(aw_inner[c]), .aw_port(aw_port[c]),
      .w_valid(w_valid[c]), .w_ready(w_ready[c]), .w_data(w_data[c]), .w_strb(w_strb[c]), .w_last(w_last[c]),
      .b_valid(b_valid[c]), .b_resp(b_resp[c]),
      .tm_alloc(tm_alloc[c]), .tm_src_use(tm_src_use[c]), .tm_src_int(tm_src_int[c]), .tm_src_sel(tm_src_sel[c]),
      .tm_des_use(tm_des_use[c]), .tm_des_int(tm_des_int[c]), .tm_des_sel(tm_des_sel[c]),
      .tm_out_use(tm_out_use[c]), .tm_out_sel(tm_out_sel[c]),
      .tm_alloc_done(tm_alloc_done[c]), .tm_src_err(tm_src_err[c]), .tm_des_err(tm_des_err[c]),
      .tm_out_err(tm_out_err[c]), .tm_release(tm_release[c]),
      .tm_src_req(tm_src_req[c]), .tm_src_reqtype(tm_src_reqtype[c]), .tm_src_ack(tm_src_ack[c]),
      .tm_src_acktype(tm_src_acktype[c]),
      .tm_des_req(tm_des_req[c]), .tm_des_reqtype(tm_des_reqtype[c]), .tm_des_ack(tm_des_ack[c]),
      .tm_des_acktype(tm_des_acktype[c]),
      .tm_out_req(tm_out_req[c]), .tm_out_int(tm_out_int[c]), .tm_out_ack(tm_out_ack[c]),
      .so_tvalid(so_v), .so_tready(str_out_tready[c]), .so_tdata(so_d), .so_tstrb(so_s), .so_tlast(so_l),
      .si_tvalid(str_in_tvalid[c]), .si_tready(si_r), .si_tdata(str_in_tdata[c]), .si_tstrb(str_in_tstrb[c]),
      .si_tlast(str_in_tlast[c]), .si_flush(si_f),
      .gpo(gpo_w[c])
    );

    assign str_out_tvalid[c] = CH_STREAM ? so_v : 1'b0;
    assign str_out_tdata[c]  = CH_STREAM ? so_d : '0;
    assign str_out_tstrb[c]  = CH_STREAM ? so_s : '0;
    assign str_out_tlast[c]  = CH_STREAM ? so_l : 1'b0;
    assign str_in_tready[c]  = CH_STREAM ? si_r : 1'b0;
    assign str_in_flush[c]   = CH_STREAM ? si_f : 1'b0;
    assign gpo_ch[c]         = (CH_GPO > 0) ? gpo_w[c][GW-1:0] : '0;
  end

  assign ch_enabled  = s_enabled;
  assign ch_err      = s_err;
  assign ch_stopped  = s_stopped;
  assign ch_paused   = s_paused;
  assign ch_priv     = c_priv;
  assign ch_nonsec   = SECEXT_PRESENT ? c_nonsec : '0;
  assign irq_channel = s_irq;

  // ==========================================================================
  // Trigger matrix
  // ==========================================================================
  logic [1:0] ti_rt [NTI];
  logic [1:0] ti_at [NTI];
  for (genvar p = 0; p < NTI; p++) begin : g_tit
    assign ti_rt[p] = trig_in_req_type[p];
    assign trig_in_ack_type[p] = ti_at[p];
  end

  dma_trig_mtx #(
    .NUM_CH(NCH), .NTI(NUM_TRIGGER_IN), .NTO(NUM_TRIGGER_OUT),
    .TI_SYNC(TRIG_IN_SYNC_EN_MASK), .TO_SYNC(TRIG_OUT_SYNC_EN_MASK), .SECEXT(SECEXT_PRESENT)
  ) u_tmx (
    .clk(clk), .resetn(rstn),
    .trig_in_req(trig_in_req), .trig_in_reqtype(ti_rt), .trig_in_ack(trig_in_ack), .trig_in_acktype(ti_at),
    .trig_out_req(trig_out_req), .trig_out_ack(trig_out_ack),
    .ti_nonsec(ti_nonsec), .to_nonsec(to_nonsec), .ch_nonsec(c_nonsec),
    .deny_req(tm_deny), .st_ti_req(tm_ti_req), .st_to_ack(tm_to_ack), .st_ti_sel(tm_ti_sel),
    .c_alloc(tm_alloc), .c_src_use(tm_src_use), .c_src_int(tm_src_int), .c_src_sel(tm_src_sel),
    .c_des_use(tm_des_use), .c_des_int(tm_des_int), .c_des_sel(tm_des_sel),
    .c_out_use(tm_out_use), .c_out_sel(tm_out_sel),
    .c_alloc_done(tm_alloc_done), .c_src_err(tm_src_err), .c_des_err(tm_des_err), .c_out_err(tm_out_err),
    .c_release(tm_release),
    .c_src_req(tm_src_req), .c_src_reqtype(tm_src_reqtype), .c_src_ack(tm_src_ack), .c_src_acktype(tm_src_acktype),
    .c_des_req(tm_des_req), .c_des_reqtype(tm_des_reqtype), .c_des_ack(tm_des_ack), .c_des_acktype(tm_des_acktype),
    .c_out_req(tm_out_req), .c_out_int(tm_out_int), .c_out_ack(tm_out_ack)
  );

  // ==========================================================================
  // BIU
  // ==========================================================================
  logic [CHW-1:0] c_chid_w [NCH];
  for (genvar c = 0; c < NCH; c++) begin : g_chidw
    assign c_chid_w[c] = c_chid[c][CHW-1:0];
  end

  logic [1:0]          m_awakeup, m_awvalid, m_awready, m_awchidvalid, m_arvalid, m_arready;
  logic [1:0]          m_archidvalid, m_arcmdlink, m_wvalid, m_wready, m_wlast, m_rvalid, m_rready;
  logic [1:0]          m_rlast, m_rpoison, m_bvalid, m_bready;
  logic [AW-1:0]       m_awaddr [2], m_araddr [2];
  logic [1:0]          m_awburst [2], m_arburst [2], m_awdomain [2], m_ardomain [2];
  logic [ID_WIDTH-1:0] m_awid [2], m_arid [2], m_rid [2], m_bid [2];
  logic [7:0]          m_awlen [2], m_arlen [2];
  logic [2:0]          m_awsize [2], m_arsize [2], m_awprot [2], m_arprot [2];
  logic [3:0]          m_awqos [2], m_arqos [2], m_awcache [2], m_arcache [2], m_awinner [2], m_arinner [2];
  logic [CHW-1:0]      m_awchid [2], m_archid [2];
  logic [DW/8-1:0]     m_wstrb [2];
  logic [DW-1:0]       m_wdata [2], m_rdata [2];
  logic [1:0]          m_rresp [2], m_bresp [2];

  dma_biu #(
    .NUM_CH(NCH), .AW(AW), .DW(DW), .IDW(ID_WIDTH), .CHIDW(CHW), .M1_PRESENT(AXI5_M1_PRESENT),
    .MAX_RD(BIU_MAX_RD), .MAX_WR(BIU_MAX_WR)
  ) u_biu (
    .clk(clk), .resetn(rstn), .aclken({aclken_m1, aclken_m0}),
    .c_ar_valid(ar_valid), .c_ar_ready(ar_ready), .c_ar_addr(ar_addr), .c_ar_len(ar_len),
    .c_ar_size(ar_size), .c_ar_burst(ar_burst), .c_ar_cache(ar_cache), .c_ar_prot(ar_prot),
    .c_ar_qos(ar_qos), .c_ar_domain(ar_domain), .c_ar_inner(ar_inner), .c_ar_cmdlink(ar_cmdlink),
    .c_ar_port(ar_port),
    .c_r_valid(r_valid), .c_r_data(r_data), .c_r_resp(r_resp), .c_r_last(r_last), .c_r_poison(r_poison),
    .c_aw_valid(aw_valid), .c_aw_ready(aw_ready), .c_aw_addr(aw_addr), .c_aw_len(aw_len),
    .c_aw_size(aw_size), .c_aw_burst(aw_burst), .c_aw_cache(aw_cache), .c_aw_prot(aw_prot),
    .c_aw_qos(aw_qos), .c_aw_domain(aw_domain), .c_aw_inner(aw_inner), .c_aw_port(aw_port),
    .c_w_valid(w_valid), .c_w_ready(w_ready), .c_w_data(w_data), .c_w_strb(w_strb), .c_w_last(w_last),
    .c_b_valid(b_valid), .c_b_resp(b_resp),
    .c_chid(c_chid_w), .c_chidvld(c_chidvld), .any_enabled(|s_enabled),
    .m_awakeup(m_awakeup), .m_awvalid(m_awvalid), .m_awready(m_awready), .m_awaddr(m_awaddr),
    .m_awburst(m_awburst), .m_awid(m_awid), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awqos(m_awqos),
    .m_awprot(m_awprot), .m_awcache(m_awcache), .m_awdomain(m_awdomain), .m_awinner(m_awinner),
    .m_awchid(m_awchid), .m_awchidvalid(m_awchidvalid),
    .m_arvalid(m_arvalid), .m_arready(m_arready), .m_araddr(m_araddr), .m_arburst(m_arburst),
    .m_arid(m_arid), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arqos(m_arqos), .m_arprot(m_arprot),
    .m_arcache(m_arcache), .m_ardomain(m_ardomain), .m_arinner(m_arinner), .m_archid(m_archid),
    .m_archidvalid(m_archidvalid), .m_arcmdlink(m_arcmdlink),
    .m_wvalid(m_wvalid), .m_wready(m_wready), .m_wlast(m_wlast), .m_wstrb(m_wstrb), .m_wdata(m_wdata),
    .m_rvalid(m_rvalid), .m_rready(m_rready), .m_rid(m_rid), .m_rlast(m_rlast), .m_rdata(m_rdata),
    .m_rpoison(m_rpoison), .m_rresp(m_rresp),
    .m_bvalid(m_bvalid), .m_bready(m_bready), .m_bid(m_bid), .m_bresp(m_bresp)
  );

  // ---------------- port 0
  assign awakeup_m0 = m_awakeup[0];   assign awvalid_m0 = m_awvalid[0];   assign m_awready[0] = awready_m0;
  assign awaddr_m0  = m_awaddr[0];    assign awburst_m0 = m_awburst[0];   assign awid_m0      = m_awid[0];
  assign awlen_m0   = m_awlen[0];     assign awsize_m0  = m_awsize[0];    assign awqos_m0     = m_awqos[0];
  assign awprot_m0  = m_awprot[0];    assign awcache_m0 = m_awcache[0];   assign awdomain_m0  = m_awdomain[0];
  assign awinner_m0 = m_awinner[0];   assign awchid_m0  = (CHID_WIDTH > 0) ? m_awchid[0] : '0;
  assign awchidvalid_m0 = (CHID_WIDTH > 0) ? m_awchidvalid[0] : 1'b0;
  assign arvalid_m0 = m_arvalid[0];   assign m_arready[0] = arready_m0;   assign araddr_m0   = m_araddr[0];
  assign arburst_m0 = m_arburst[0];   assign arid_m0    = m_arid[0];      assign arlen_m0     = m_arlen[0];
  assign arsize_m0  = m_arsize[0];    assign arqos_m0   = m_arqos[0];     assign arprot_m0    = m_arprot[0];
  assign arcache_m0 = m_arcache[0];   assign ardomain_m0 = m_ardomain[0]; assign arinner_m0   = m_arinner[0];
  assign archid_m0  = (CHID_WIDTH > 0) ? m_archid[0] : '0;
  assign archidvalid_m0 = (CHID_WIDTH > 0) ? m_archidvalid[0] : 1'b0;
  assign arcmdlink_m0 = m_arcmdlink[0];
  assign wvalid_m0  = m_wvalid[0];    assign m_wready[0] = wready_m0;     assign wlast_m0     = m_wlast[0];
  assign wstrb_m0   = m_wstrb[0];     assign wdata_m0   = m_wdata[0];
  assign m_rvalid[0] = rvalid_m0;     assign rready_m0  = m_rready[0];    assign m_rid[0]     = rid_m0;
  assign m_rlast[0] = rlast_m0;       assign m_rdata[0] = rdata_m0;       assign m_rpoison[0] = |rpoison_m0;
  assign m_rresp[0] = rresp_m0;
  assign m_bvalid[0] = bvalid_m0;     assign bready_m0  = m_bready[0];    assign m_bid[0]     = bid_m0;
  assign m_bresp[0] = bresp_m0;

  // ---------------- port 1
  assign awakeup_m1 = m_awakeup[1];   assign awvalid_m1 = m_awvalid[1];   assign m_awready[1] = AXI5_M1_PRESENT ? awready_m1 : 1'b0;
  assign awaddr_m1  = m_awaddr[1];    assign awburst_m1 = m_awburst[1];   assign awid_m1      = m_awid[1];
  assign awlen_m1   = m_awlen[1];     assign awsize_m1  = m_awsize[1];    assign awqos_m1     = m_awqos[1];
  assign awprot_m1  = m_awprot[1];    assign awcache_m1 = m_awcache[1];   assign awdomain_m1  = m_awdomain[1];
  assign awinner_m1 = m_awinner[1];   assign awchid_m1  = (CHID_WIDTH > 0) ? m_awchid[1] : '0;
  assign awchidvalid_m1 = (CHID_WIDTH > 0) ? m_awchidvalid[1] : 1'b0;
  assign arvalid_m1 = m_arvalid[1];   assign m_arready[1] = AXI5_M1_PRESENT ? arready_m1 : 1'b0;
  assign araddr_m1  = m_araddr[1];    assign arburst_m1 = m_arburst[1];   assign arid_m1      = m_arid[1];
  assign arlen_m1   = m_arlen[1];     assign arsize_m1  = m_arsize[1];    assign arqos_m1     = m_arqos[1];
  assign arprot_m1  = m_arprot[1];    assign arcache_m1 = m_arcache[1];   assign ardomain_m1  = m_ardomain[1];
  assign arinner_m1 = m_arinner[1];   assign archid_m1  = (CHID_WIDTH > 0) ? m_archid[1] : '0;
  assign archidvalid_m1 = (CHID_WIDTH > 0) ? m_archidvalid[1] : 1'b0;
  assign arcmdlink_m1 = m_arcmdlink[1];
  assign wvalid_m1  = m_wvalid[1];    assign m_wready[1] = AXI5_M1_PRESENT ? wready_m1 : 1'b0;
  assign wlast_m1   = m_wlast[1];     assign wstrb_m1   = m_wstrb[1];     assign wdata_m1     = m_wdata[1];
  assign m_rvalid[1] = AXI5_M1_PRESENT ? rvalid_m1 : 1'b0;  assign rready_m1 = m_rready[1];
  assign m_rid[1]   = rid_m1;         assign m_rlast[1] = rlast_m1;       assign m_rdata[1]   = rdata_m1;
  assign m_rpoison[1] = |rpoison_m1;  assign m_rresp[1] = rresp_m1;
  assign m_bvalid[1] = AXI5_M1_PRESENT ? bvalid_m1 : 1'b0;  assign bready_m1 = m_bready[1];
  assign m_bid[1]   = bid_m1;         assign m_bresp[1] = bresp_m1;

endmodule : dma_top
