//-----------------------------------------------------------------------------
// dma_tb_top.sv - UVM test bench top for the AXI DMA controller
//   * APB VIP (requester), AXI5 VIP subordinates on M0 / M1 (shared memory),
//     AXI4-Stream VIPs on the stream channels, dma_ctrl_if for side bands
//   * divided AXI / APB clocks through the clock enables (+ACLK_DIV= / +PCLK_DIV=)
//   * asynchronous peripheral clock for trigger CDC tests (+PER_CLK_PS=)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "dma_tb_defines.svh"

module dma_tb_top;
  import uvm_pkg::*;
  import apb_pkg::*;
  import axi5_pkg::*;
  import axis_pkg::*;
  import dma_tb_pkg::*;
  import dma_test_pkg::*;      // registers the test cases with the factory

  localparam int NCH  = `DMA_NUM_CH;
  localparam int AW   = `DMA_AW;
  localparam int DW   = `DMA_DW;
  localparam int CHW_ = `DMA_CHID_W;
  localparam int CHW  = (CHW_ > 0) ? CHW_ : 1;
  localparam int GW   = (`DMA_GPO_W > 0) ? `DMA_GPO_W : 1;
  localparam int NTI  = (`DMA_NTI > 0) ? `DMA_NTI : 1;
  localparam int NTO  = (`DMA_NTO > 0) ? `DMA_NTO : 1;
  localparam int IDW  = (NCH > 1) ? $clog2(NCH) : 1;
  localparam int DWB  = DW / 8;
  localparam int PW   = (DW + 63) / 64;
  localparam logic [7:0] STREAM_MASK = `DMA_STREAM_MASK;

  // ---------------------------------------------------------------- clocks / reset
  logic clk = 1'b0, resetn = 1'b0, per_clk = 1'b0;
  int   clk_half_ps = 5000, per_half_ps = 7300;
  int   aclk_div = 1, pclk_div = 1;

  initial begin
    if ($value$plusargs("ACLK_DIV=%d", aclk_div)) ;
    if ($value$plusargs("PCLK_DIV=%d", pclk_div)) ;
    if ($value$plusargs("PER_CLK_PS=%d", per_half_ps)) per_half_ps = per_half_ps / 2;
    if (aclk_div < 1) aclk_div = 1;
    if (pclk_div < 1) pclk_div = 1;
  end
  always #(clk_half_ps * 1ps) clk = ~clk;
  always #(per_half_ps * 1ps) per_clk = ~per_clk;

  // clock enables and the matching gated clocks seen by the VIPs
  int acnt = 0, pcnt = 0;
  logic aclken, pclken, aen_l = 1'b1, pen_l = 1'b1;
  always @(posedge clk) begin
    acnt <= (acnt + 1 >= aclk_div) ? 0 : acnt + 1;
    pcnt <= (pcnt + 1 >= pclk_div) ? 0 : pcnt + 1;
  end
  assign aclken = (aclk_div == 1) ? 1'b1 : (acnt == aclk_div - 1);
  assign pclken = (pclk_div == 1) ? 1'b1 : (pcnt == pclk_div - 1);
  always @(negedge clk) begin aen_l <= aclken; pen_l <= pclken; end   // ICG latch model
  wire aclk_vip = clk & aen_l;
  wire pclk_vip = clk & pen_l;

  // ---------------------------------------------------------------- interfaces
  vip_apb_if  #(13, 32)                         apb   (.pclk(pclk_vip), .presetn(resetn));
  vip_axi5_if #(AW, DW, IDW, 1, 4)              axi_m0(.aclk(aclk_vip), .aresetn(resetn));
  vip_axi5_if #(AW, DW, IDW, 1, 4)              axi_m1(.aclk(aclk_vip), .aresetn(resetn));
  dma_ctrl_if #(NCH, NTI, NTO, GW, CHW, AW)     ctrl  (.clk(clk), .resetn(resetn));

  assign ctrl.aclken_m0 = aclken;
  assign ctrl.aclken_m1 = aclken;
  assign ctrl.pclken    = pclken;
  assign ctrl.per_clk   = per_clk;

  // stream interfaces (one in / out pair per channel; only stream channels used)
  logic [NCH-1:0]         so_tvalid, so_tready, so_tlast, si_tvalid, si_tready, si_tlast;
  logic [NCH-1:0][DW-1:0] so_tdata, si_tdata;
  logic [NCH-1:0][DWB-1:0] so_tstrb, si_tstrb;

  for (genvar c = 0; c < NCH; c++) begin : g_str
    vip_axis_if #(DW, 4, 4, 4) so (.aclk(clk), .aresetn(resetn));
    vip_axis_if #(DW, 4, 4, 4) si (.aclk(clk), .aresetn(resetn));
    // DUT stream out -> VIP receiver
    assign so.tvalid = so_tvalid[c];
    assign so.tdata  = so_tdata[c];
    assign so.tstrb  = so_tstrb[c];
    assign so.tkeep  = '1;
    assign so.tlast  = so_tlast[c];
    assign so.tid    = '0;
    assign so.tdest  = '0;
    assign so.tuser  = '0;
    assign so_tready[c] = STREAM_MASK[c] ? so.tready : 1'b0;
    // VIP transmitter -> DUT stream in
    assign si_tvalid[c] = STREAM_MASK[c] ? si.tvalid : 1'b0;
    assign si_tdata[c]  = si.tdata;
    assign si_tstrb[c]  = si.tstrb;
    assign si_tlast[c]  = si.tlast;
    assign si.tready    = si_tready[c];
    if (!STREAM_MASK[c]) begin : g_idle
      // no VIP agent on a non-stream channel: keep the links idle
      assign so.tready = 1'b0;
      assign si.tvalid = 1'b0; assign si.tdata = '0; assign si.tstrb = '0; assign si.tkeep = '0;
      assign si.tlast  = 1'b0; assign si.tid = '0;   assign si.tdest = '0; assign si.tuser = '0;
    end
    initial begin
      uvm_config_db #(axis_vif_t)::set(null, "*", $sformatf("str_out_vif_%0d", c), so);
      uvm_config_db #(axis_vif_t)::set(null, "*", $sformatf("str_in_vif_%0d", c), si);
    end
  end

  // ---------------------------------------------------------------- DUT
  logic [IDW-1:0] awid0, arid0, awid1, arid1;
  dma_top #(
    .NUM_CHANNELS(NCH), .ADDR_WIDTH(AW), .DATA_WIDTH(DW), .CHID_WIDTH(CHW_), .GPO_WIDTH(`DMA_GPO_W),
    .CH_GPO_MASK(`DMA_GPO_MASK), .CH_STREAM_MASK(STREAM_MASK), .CH_EXT_FEAT_MASK(`DMA_EXT_MASK),
    .CH_FIFO_DEPTH('{`DMA_FIFO_D0, `DMA_FIFO_D1, `DMA_FIFO_D2, `DMA_FIFO_D3,
                     `DMA_FIFO_D0, `DMA_FIFO_D1, `DMA_FIFO_D2, `DMA_FIFO_D3}),
    .NUM_TRIGGER_IN(`DMA_NTI), .NUM_TRIGGER_OUT(`DMA_NTO),
    .TRIG_IN_SYNC_EN_MASK(`DMA_TI_SYNC), .TRIG_OUT_SYNC_EN_MASK(`DMA_TO_SYNC),
    .AXI5_M1_PRESENT(`DMA_M1), .SECEXT_PRESENT(`DMA_SECEXT)
  ) dut (
    .clk(clk), .resetn(resetn), .aclken_m0(ctrl.aclken_m0), .aclken_m1(ctrl.aclken_m1), .pclken(ctrl.pclken),
    .clk_qreqn(ctrl.clk_qreqn), .clk_qacceptn(ctrl.clk_qacceptn), .clk_qdeny(ctrl.clk_qdeny), .clk_qactive(ctrl.clk_qactive),
    .preq(ctrl.preq), .pstate(ctrl.pstate), .paccept(ctrl.paccept), .pdeny(ctrl.pdeny), .pactive(ctrl.pactive),
    .psel(apb.psel), .penable(apb.penable), .pprot(apb.pprot), .pwrite(apb.pwrite), .paddr(apb.paddr),
    .pwdata(apb.pwdata), .pstrb(apb.pstrb), .pready(apb.pready), .pslverr(apb.pslverr), .prdata(apb.prdata),
    .pwakeup(ctrl.pwakeup), .pdebug(ctrl.pdebug),
    // M0
    .awakeup_m0(axi_m0.awakeup), .awvalid_m0(axi_m0.awvalid), .awready_m0(axi_m0.awready), .awaddr_m0(axi_m0.awaddr),
    .awburst_m0(axi_m0.awburst), .awid_m0(axi_m0.awid), .awlen_m0(axi_m0.awlen), .awsize_m0(axi_m0.awsize),
    .awqos_m0(axi_m0.awqos), .awprot_m0(axi_m0.awprot), .awcache_m0(axi_m0.awcache),
    .awdomain_m0(ctrl.awdomain[0]), .awinner_m0(ctrl.awinner[0]), .awchid_m0(ctrl.awchid[0]),
    .awchidvalid_m0(ctrl.awchidvalid[0]),
    .arvalid_m0(axi_m0.arvalid), .arready_m0(axi_m0.arready), .araddr_m0(axi_m0.araddr), .arburst_m0(axi_m0.arburst),
    .arid_m0(axi_m0.arid), .arlen_m0(axi_m0.arlen), .arsize_m0(axi_m0.arsize), .arqos_m0(axi_m0.arqos),
    .arprot_m0(axi_m0.arprot), .arcache_m0(axi_m0.arcache), .ardomain_m0(ctrl.ardomain[0]),
    .arinner_m0(ctrl.arinner[0]), .archid_m0(ctrl.archid[0]), .archidvalid_m0(ctrl.archidvalid[0]),
    .arcmdlink_m0(ctrl.arcmdlink[0]),
    .wvalid_m0(axi_m0.wvalid), .wready_m0(axi_m0.wready), .wlast_m0(axi_m0.wlast), .wstrb_m0(axi_m0.wstrb),
    .wdata_m0(axi_m0.wdata), .rvalid_m0(axi_m0.rvalid), .rready_m0(axi_m0.rready), .rid_m0(axi_m0.rid),
    .rlast_m0(axi_m0.rlast), .rdata_m0(axi_m0.rdata), .rpoison_m0(axi_m0.rpoison), .rresp_m0(axi_m0.rresp),
    .bvalid_m0(axi_m0.bvalid), .bready_m0(axi_m0.bready), .bid_m0(axi_m0.bid), .bresp_m0(axi_m0.bresp),
    // M1
    .awakeup_m1(axi_m1.awakeup), .awvalid_m1(axi_m1.awvalid), .awready_m1(axi_m1.awready), .awaddr_m1(axi_m1.awaddr),
    .awburst_m1(axi_m1.awburst), .awid_m1(axi_m1.awid), .awlen_m1(axi_m1.awlen), .awsize_m1(axi_m1.awsize),
    .awqos_m1(axi_m1.awqos), .awprot_m1(axi_m1.awprot), .awcache_m1(axi_m1.awcache),
    .awdomain_m1(ctrl.awdomain[1]), .awinner_m1(ctrl.awinner[1]), .awchid_m1(ctrl.awchid[1]),
    .awchidvalid_m1(ctrl.awchidvalid[1]),
    .arvalid_m1(axi_m1.arvalid), .arready_m1(axi_m1.arready), .araddr_m1(axi_m1.araddr), .arburst_m1(axi_m1.arburst),
    .arid_m1(axi_m1.arid), .arlen_m1(axi_m1.arlen), .arsize_m1(axi_m1.arsize), .arqos_m1(axi_m1.arqos),
    .arprot_m1(axi_m1.arprot), .arcache_m1(axi_m1.arcache), .ardomain_m1(ctrl.ardomain[1]),
    .arinner_m1(ctrl.arinner[1]), .archid_m1(ctrl.archid[1]), .archidvalid_m1(ctrl.archidvalid[1]),
    .arcmdlink_m1(ctrl.arcmdlink[1]),
    .wvalid_m1(axi_m1.wvalid), .wready_m1(axi_m1.wready), .wlast_m1(axi_m1.wlast), .wstrb_m1(axi_m1.wstrb),
    .wdata_m1(axi_m1.wdata), .rvalid_m1(axi_m1.rvalid), .rready_m1(axi_m1.rready), .rid_m1(axi_m1.rid),
    .rlast_m1(axi_m1.rlast), .rdata_m1(axi_m1.rdata), .rpoison_m1(axi_m1.rpoison), .rresp_m1(axi_m1.rresp),
    .bvalid_m1(axi_m1.bvalid), .bready_m1(axi_m1.bready), .bid_m1(axi_m1.bid), .bresp_m1(axi_m1.bresp),
    // triggers
    .trig_in_req(ctrl.trig_in_req), .trig_in_req_type(ctrl.trig_in_req_type), .trig_in_ack(ctrl.trig_in_ack),
    .trig_in_ack_type(ctrl.trig_in_ack_type), .trig_out_req(ctrl.trig_out_req), .trig_out_ack(ctrl.trig_out_ack),
    // interrupts
    .irq_channel(ctrl.irq_channel), .irq_comb_nonsec(ctrl.irq_comb_nonsec), .irq_comb_sec(ctrl.irq_comb_sec),
    .irq_sec_viol_err(ctrl.irq_sec_viol_err),
    // streams
    .str_out_tvalid(so_tvalid), .str_out_tready(so_tready), .str_out_tdata(so_tdata), .str_out_tstrb(so_tstrb),
    .str_out_tlast(so_tlast), .str_in_tvalid(si_tvalid), .str_in_tready(si_tready), .str_in_tdata(si_tdata),
    .str_in_tstrb(si_tstrb), .str_in_tlast(si_tlast), .str_in_flush(ctrl.str_in_flush),
    // control / status
    .gpo_ch(ctrl.gpo_ch),
    .allch_stop_req_nonsec(ctrl.allch_stop_req_nonsec), .allch_stop_ack_nonsec(ctrl.allch_stop_ack_nonsec),
    .allch_pause_req_nonsec(ctrl.allch_pause_req_nonsec), .allch_pause_ack_nonsec(ctrl.allch_pause_ack_nonsec),
    .allch_stop_req_sec(ctrl.allch_stop_req_sec), .allch_stop_ack_sec(ctrl.allch_stop_ack_sec),
    .allch_pause_req_sec(ctrl.allch_pause_req_sec), .allch_pause_ack_sec(ctrl.allch_pause_ack_sec),
    .halt_req(ctrl.halt_req), .restart_req(ctrl.restart_req), .halted(ctrl.halted),
    .ch_enabled(ctrl.ch_enabled), .ch_err(ctrl.ch_err), .ch_stopped(ctrl.ch_stopped), .ch_paused(ctrl.ch_paused),
    .ch_priv(ctrl.ch_priv), .ch_nonsec(ctrl.ch_nonsec),
    .boot_en(ctrl.boot_en), .boot_addr(ctrl.boot_addr), .boot_memattr(ctrl.boot_memattr),
    .boot_shareattr(ctrl.boot_shareattr)
  );

  // AXI VIP signals the DMA does not have: tie to legal constant values
  for (genvar p = 0; p < 2; p++) begin : g_tie
    if (p == 0) begin : g0
      assign axi_m0.awlock = 1'b0;  assign axi_m0.awregion = '0; assign axi_m0.awuser = '0;
      assign axi_m0.awatop = '0;    assign axi_m0.awidunq = 1'b0; assign axi_m0.awtrace = 1'b0; assign axi_m0.awloop = '0;
      assign axi_m0.wuser = '0;     assign axi_m0.wpoison = '0;  assign axi_m0.wdatachk = '0;  assign axi_m0.wtrace = 1'b0;
      assign axi_m0.arlock = 1'b0;  assign axi_m0.arregion = '0; assign axi_m0.aruser = '0;
      assign axi_m0.aridunq = 1'b0; assign axi_m0.artrace = 1'b0; assign axi_m0.arloop = '0;
    end else begin : g1
      assign axi_m1.awlock = 1'b0;  assign axi_m1.awregion = '0; assign axi_m1.awuser = '0;
      assign axi_m1.awatop = '0;    assign axi_m1.awidunq = 1'b0; assign axi_m1.awtrace = 1'b0; assign axi_m1.awloop = '0;
      assign axi_m1.wuser = '0;     assign axi_m1.wpoison = '0;  assign axi_m1.wdatachk = '0;  assign axi_m1.wtrace = 1'b0;
      assign axi_m1.arlock = 1'b0;  assign axi_m1.arregion = '0; assign axi_m1.aruser = '0;
      assign axi_m1.aridunq = 1'b0; assign axi_m1.artrace = 1'b0; assign axi_m1.arloop = '0;
    end
  end

  // APB wakeup: registered PSEL (TRM 4.2.2)
  always_ff @(posedge clk or negedge resetn)
    if (!resetn) ctrl.pwakeup <= 1'b0; else ctrl.pwakeup <= apb.psel;

  // ---------------------------------------------------------------- reset / run
  initial begin
    automatic int rst_cycles = 20;
    resetn = 1'b0;
    repeat (rst_cycles) @(posedge clk);
    resetn <= 1'b1;
  end

  initial begin
    uvm_config_db #(apb_vif_t)::set(null, "*", "apb_vif", apb);
    uvm_config_db #(axi5_vif_t)::set(null, "*", "axi_m0_vif", axi_m0);
    uvm_config_db #(axi5_vif_t)::set(null, "*", "axi_m1_vif", axi_m1);
    uvm_config_db #(dma_ctrl_vif_t)::set(null, "*", "ctrl_vif", ctrl);
    run_test();
  end

endmodule : dma_tb_top
