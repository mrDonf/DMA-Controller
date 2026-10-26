//-----------------------------------------------------------------------------
// dma_biu.sv
// Bus Interface Unit: routes the channel requests to one or two AXI5 manager
// ports (TRM 3.1 / 4.3 / 5.8).
//   * per port and direction a 2-layer priority + LRG arbiter (dma_lrg_arb),
//     arbitration after every burst
//   * AXI ID = channel number (same ID for data and command link reads ->
//     per-channel in-order responses, no reorder buffers needed)
//   * W data issued in AW order through a per-port W order queue; a channel
//     only gets an AW grant when the W order queue can take it
//   * R / B routed back by ID; channels always accept responses
//   * full register slices on every channel of every port with clock-enable
//     (aclken_m*) support; outputs are flop driven
//   * per-port outstanding limits (MAX_RD / MAX_WR)
//-----------------------------------------------------------------------------
module dma_biu
  import dma_pkg::*;
#(
  parameter int NUM_CH     = 2,
  parameter int AW         = 32,
  parameter int DW         = 64,
  parameter int IDW        = 1,
  parameter int CHIDW      = 1,      // >= 1 (port width; CHID_WIDTH=0 -> tied off at top)
  parameter bit M1_PRESENT = 1'b0,
  parameter int MAX_RD     = 32,
  parameter int MAX_WR     = 32
) (
  input  logic                   clk,
  input  logic                   resetn,
  input  logic [1:0]             aclken,

  // ---------------- channel side
  input  logic [NUM_CH-1:0]      c_ar_valid,
  output logic [NUM_CH-1:0]      c_ar_ready,
  input  logic [AW-1:0]          c_ar_addr   [NUM_CH],
  input  logic [7:0]             c_ar_len    [NUM_CH],
  input  logic [2:0]             c_ar_size   [NUM_CH],
  input  logic [1:0]             c_ar_burst  [NUM_CH],
  input  logic [3:0]             c_ar_cache  [NUM_CH],
  input  logic [2:0]             c_ar_prot   [NUM_CH],
  input  logic [3:0]             c_ar_qos    [NUM_CH],
  input  logic [1:0]             c_ar_domain [NUM_CH],
  input  logic [3:0]             c_ar_inner  [NUM_CH],
  input  logic [NUM_CH-1:0]      c_ar_cmdlink,
  input  logic [NUM_CH-1:0]      c_ar_port,

  output logic [NUM_CH-1:0]      c_r_valid,
  output logic [DW-1:0]          c_r_data    [NUM_CH],
  output logic [1:0]             c_r_resp    [NUM_CH],
  output logic [NUM_CH-1:0]      c_r_last,
  output logic [NUM_CH-1:0]      c_r_poison,

  input  logic [NUM_CH-1:0]      c_aw_valid,
  output logic [NUM_CH-1:0]      c_aw_ready,
  input  logic [AW-1:0]          c_aw_addr   [NUM_CH],
  input  logic [7:0]             c_aw_len    [NUM_CH],
  input  logic [2:0]             c_aw_size   [NUM_CH],
  input  logic [1:0]             c_aw_burst  [NUM_CH],
  input  logic [3:0]             c_aw_cache  [NUM_CH],
  input  logic [2:0]             c_aw_prot   [NUM_CH],
  input  logic [3:0]             c_aw_qos    [NUM_CH],
  input  logic [1:0]             c_aw_domain [NUM_CH],
  input  logic [3:0]             c_aw_inner  [NUM_CH],
  input  logic [NUM_CH-1:0]      c_aw_port,

  input  logic [NUM_CH-1:0]      c_w_valid,
  output logic [NUM_CH-1:0]      c_w_ready,
  input  logic [DW-1:0]          c_w_data    [NUM_CH],
  input  logic [DW/8-1:0]        c_w_strb    [NUM_CH],
  input  logic [NUM_CH-1:0]      c_w_last,

  output logic [NUM_CH-1:0]      c_b_valid,
  output logic [1:0]             c_b_resp    [NUM_CH],

  input  logic [CHIDW-1:0]       c_chid      [NUM_CH],
  input  logic [NUM_CH-1:0]      c_chidvld,
  input  logic                   any_enabled,

  // ---------------- AXI manager ports [0]=M0 [1]=M1
  output logic [1:0]             m_awakeup,
  output logic [1:0]             m_awvalid,
  input  logic [1:0]             m_awready,
  output logic [AW-1:0]          m_awaddr   [2],
  output logic [1:0]             m_awburst  [2],
  output logic [IDW-1:0]         m_awid     [2],
  output logic [7:0]             m_awlen    [2],
  output logic [2:0]             m_awsize   [2],
  output logic [3:0]             m_awqos    [2],
  output logic [2:0]             m_awprot   [2],
  output logic [3:0]             m_awcache  [2],
  output logic [1:0]             m_awdomain [2],
  output logic [3:0]             m_awinner  [2],
  output logic [CHIDW-1:0]       m_awchid   [2],
  output logic [1:0]             m_awchidvalid,
  output logic [1:0]             m_arvalid,
  input  logic [1:0]             m_arready,
  output logic [AW-1:0]          m_araddr   [2],
  output logic [1:0]             m_arburst  [2],
  output logic [IDW-1:0]         m_arid     [2],
  output logic [7:0]             m_arlen    [2],
  output logic [2:0]             m_arsize   [2],
  output logic [3:0]             m_arqos    [2],
  output logic [2:0]             m_arprot   [2],
  output logic [3:0]             m_arcache  [2],
  output logic [1:0]             m_ardomain [2],
  output logic [3:0]             m_arinner  [2],
  output logic [CHIDW-1:0]       m_archid   [2],
  output logic [1:0]             m_archidvalid,
  output logic [1:0]             m_arcmdlink,
  output logic [1:0]             m_wvalid,
  input  logic [1:0]             m_wready,
  output logic [1:0]             m_wlast,
  output logic [DW/8-1:0]        m_wstrb    [2],
  output logic [DW-1:0]          m_wdata    [2],
  input  logic [1:0]             m_rvalid,
  output logic [1:0]             m_rready,
  input  logic [IDW-1:0]         m_rid      [2],
  input  logic [1:0]             m_rlast,
  input  logic [DW-1:0]          m_rdata    [2],
  input  logic [1:0]             m_rpoison,     // OR of the poison bits of a beat
  input  logic [1:0]             m_rresp    [2],
  input  logic [1:0]             m_bvalid,
  output logic [1:0]             m_bready,
  input  logic [IDW-1:0]         m_bid      [2],
  input  logic [1:0]             m_bresp    [2]
);

  localparam int NP   = M1_PRESENT ? 2 : 1;
  localparam int CW   = (NUM_CH > 1) ? $clog2(NUM_CH) : 1;
  localparam int DWB  = DW / 8;
  localparam int ARW  = IDW + AW + 8 + 3 + 2 + 4 + 3 + 4 + 2 + 4 + CHIDW + 1 + 1;
  localparam int AWW  = IDW + AW + 8 + 3 + 2 + 4 + 3 + 4 + 2 + 4 + CHIDW + 1;
  localparam int WWW  = DW + DWB + 1;
  localparam int RW   = IDW + DW + 2 + 1 + 1;
  localparam int BW   = IDW + 2;

  logic [NUM_CH-1:0] ar_rdy_p [2];
  logic [NUM_CH-1:0] aw_rdy_p [2];
  logic [NUM_CH-1:0] w_rdy_p  [2];
  logic [NUM_CH-1:0] r_v_p    [2];
  logic [NUM_CH-1:0] b_v_p    [2];
  logic [DW-1:0]     r_d_p    [2];
  logic [1:0]        r_resp_p [2];
  logic [1:0]        b_resp_p [2];
  logic [1:0]        r_last_p, r_pois_p;
  logic [1:0]        busy_p;

  for (genvar p = 0; p < 2; p++) begin : g_port
    if (p < NP) begin : g_on
      // =====================================================================
      // AR
      // =====================================================================
      logic [NUM_CH-1:0] ar_req, ar_gnt;
      logic [CW-1:0]     ar_gi;
      logic [3:0]        ar_prio [NUM_CH];
      logic              ar_in_v, ar_in_r;
      logic [ARW-1:0]    ar_in_d, ar_out_d;
      logic [$clog2(MAX_RD+1)-1:0] rd_out;

      for (genvar c = 0; c < NUM_CH; c++) begin : g_arreq
        assign ar_req[c]  = c_ar_valid[c] && (c_ar_port[c] == p[0]) && (rd_out < MAX_RD);
        assign ar_prio[c] = c_ar_qos[c];
      end

      dma_lrg_arb #(.N(NUM_CH), .PW(4)) u_ar_arb (
        .clk(clk), .resetn(resetn), .req(ar_req), .prio(ar_prio),
        .upd(ar_in_v & ar_in_r), .gnt(ar_gnt), .gnt_idx(ar_gi)
      );

      assign ar_in_v = |ar_req;
      always_comb begin
        ar_in_d = {IDW'(ar_gi), c_ar_addr[ar_gi], c_ar_len[ar_gi], c_ar_size[ar_gi],
                   c_ar_burst[ar_gi], c_ar_cache[ar_gi], c_ar_prot[ar_gi], c_ar_qos[ar_gi],
                   c_ar_domain[ar_gi], c_ar_inner[ar_gi], c_chid[ar_gi], c_chidvld[ar_gi],
                   c_ar_cmdlink[ar_gi]};
      end
      assign ar_rdy_p[p] = ar_gnt & {NUM_CH{ar_in_r}};

      dma_rs_out #(.WIDTH(ARW)) u_ar_rs (
        .clk(clk), .resetn(resetn), .en(aclken[p]),
        .in_valid(ar_in_v), .in_ready(ar_in_r), .in_data(ar_in_d),
        .out_valid(m_arvalid[p]), .out_ready(m_arready[p]), .out_data(ar_out_d)
      );
      assign {m_arid[p], m_araddr[p], m_arlen[p], m_arsize[p], m_arburst[p], m_arcache[p],
              m_arprot[p], m_arqos[p], m_ardomain[p], m_arinner[p], m_archid[p],
              m_archidvalid[p], m_arcmdlink[p]} = ar_out_d;

      // =====================================================================
      // R
      // =====================================================================
      logic           r_out_v;
      logic [RW-1:0]  r_out_d;
      logic [IDW-1:0] r_id;

      dma_rs_in #(.WIDTH(RW)) u_r_rs (
        .clk(clk), .resetn(resetn), .en(aclken[p]),
        .in_valid(m_rvalid[p]), .in_ready(m_rready[p]),
        .in_data({m_rid[p], m_rdata[p], m_rresp[p], m_rlast[p], m_rpoison[p]}),
        .out_valid(r_out_v), .out_ready(1'b1), .out_data(r_out_d)
      );
      assign {r_id, r_d_p[p], r_resp_p[p], r_last_p[p], r_pois_p[p]} = r_out_d;
      for (genvar c = 0; c < NUM_CH; c++) begin : g_rv
        assign r_v_p[p][c] = r_out_v && (r_id == IDW'(c));
      end

      always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) rd_out <= '0;
        else rd_out <= rd_out + (ar_in_v & ar_in_r) - (r_out_v & r_last_p[p]);
      end

      // =====================================================================
      // AW + W order queue
      // =====================================================================
      logic [NUM_CH-1:0] aw_req, aw_gnt;
      logic [CW-1:0]     aw_gi;
      logic [3:0]        aw_prio [NUM_CH];
      logic              aw_in_v, aw_in_r;
      logic [AWW-1:0]    aw_in_d, aw_out_d;
      logic              wq_full, wq_empty;
      logic [CW-1:0]     wq_head;
      logic [$clog2(MAX_WR+1)-1:0] wr_out;

      for (genvar c = 0; c < NUM_CH; c++) begin : g_awreq
        // the W order queue holds at most the outstanding writes (<= MAX_WR)
        assign aw_req[c]  = c_aw_valid[c] && (c_aw_port[c] == p[0]) && (wr_out < MAX_WR);
        assign aw_prio[c] = c_aw_qos[c];
      end

      dma_lrg_arb #(.N(NUM_CH), .PW(4)) u_aw_arb (
        .clk(clk), .resetn(resetn), .req(aw_req), .prio(aw_prio),
        .upd(aw_in_v & aw_in_r), .gnt(aw_gnt), .gnt_idx(aw_gi)
      );

      assign aw_in_v = |aw_req;
      always_comb begin
        aw_in_d = {IDW'(aw_gi), c_aw_addr[aw_gi], c_aw_len[aw_gi], c_aw_size[aw_gi],
                   c_aw_burst[aw_gi], c_aw_cache[aw_gi], c_aw_prot[aw_gi], c_aw_qos[aw_gi],
                   c_aw_domain[aw_gi], c_aw_inner[aw_gi], c_chid[aw_gi], c_chidvld[aw_gi]};
      end
      assign aw_rdy_p[p] = aw_gnt & {NUM_CH{aw_in_r}};

      dma_rs_out #(.WIDTH(AWW)) u_aw_rs (
        .clk(clk), .resetn(resetn), .en(aclken[p]),
        .in_valid(aw_in_v), .in_ready(aw_in_r), .in_data(aw_in_d),
        .out_valid(m_awvalid[p]), .out_ready(m_awready[p]), .out_data(aw_out_d)
      );
      assign {m_awid[p], m_awaddr[p], m_awlen[p], m_awsize[p], m_awburst[p], m_awcache[p],
              m_awprot[p], m_awqos[p], m_awdomain[p], m_awinner[p], m_awchid[p],
              m_awchidvalid[p]} = aw_out_d;

      // W order queue: channel index (= AWID) pushed when the AW handshake
      // completes on the bus, so W data never overtakes its AW (TRM 4.3.3)
      logic w_in_v, w_in_r;
      logic [WWW-1:0] w_in_d, w_out_d;

      dma_fifo_ff #(.WIDTH(CW), .DEPTH(MAX_WR)) u_wq (
        .clk(clk), .resetn(resetn), .clr(1'b0),
        .push(m_awvalid[p] & m_awready[p] & aclken[p]), .din(CW'(m_awid[p])), .full(wq_full),
        .pop(w_in_v & w_in_r & c_w_last[wq_head]), .dout(wq_head), .empty(wq_empty), .count()
      );

      assign w_in_v = !wq_empty && c_w_valid[wq_head];
      assign w_in_d = {c_w_data[wq_head], c_w_strb[wq_head], c_w_last[wq_head]};
      for (genvar c = 0; c < NUM_CH; c++) begin : g_wr
        assign w_rdy_p[p][c] = !wq_empty && (wq_head == CW'(c)) && w_in_r;
      end

      dma_rs_out #(.WIDTH(WWW)) u_w_rs (
        .clk(clk), .resetn(resetn), .en(aclken[p]),
        .in_valid(w_in_v), .in_ready(w_in_r), .in_data(w_in_d),
        .out_valid(m_wvalid[p]), .out_ready(m_wready[p]), .out_data(w_out_d)
      );
      assign {m_wdata[p], m_wstrb[p], m_wlast[p]} = w_out_d;

      // =====================================================================
      // B
      // =====================================================================
      logic           b_out_v;
      logic [BW-1:0]  b_out_d;
      logic [IDW-1:0] b_id;

      dma_rs_in #(.WIDTH(BW)) u_b_rs (
        .clk(clk), .resetn(resetn), .en(aclken[p]),
        .in_valid(m_bvalid[p]), .in_ready(m_bready[p]), .in_data({m_bid[p], m_bresp[p]}),
        .out_valid(b_out_v), .out_ready(1'b1), .out_data(b_out_d)
      );
      assign {b_id, b_resp_p[p]} = b_out_d;
      for (genvar c = 0; c < NUM_CH; c++) begin : g_bv
        assign b_v_p[p][c] = b_out_v && (b_id == IDW'(c));
      end

      always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) wr_out <= '0;
        else wr_out <= wr_out + (aw_in_v & aw_in_r) - b_out_v;
      end

      // =====================================================================
      // AWAKEUP (registered, changes on enabled edges only)
      // =====================================================================
      assign busy_p[p] = any_enabled | (rd_out != '0) | (wr_out != '0) | ar_in_v | aw_in_v |
                         !wq_empty | m_arvalid[p] | m_awvalid[p] | m_wvalid[p];
      always_ff @(posedge clk or negedge resetn) begin
        if (!resetn)         m_awakeup[p] <= 1'b0;
        else if (aclken[p])  m_awakeup[p] <= busy_p[p];
      end

    end else begin : g_off
      // unused secondary port: tie outputs
      assign ar_rdy_p[p] = '0;  assign aw_rdy_p[p] = '0;  assign w_rdy_p[p] = '0;
      assign r_v_p[p] = '0;     assign b_v_p[p] = '0;
      assign r_d_p[p] = '0;     assign r_resp_p[p] = '0; assign b_resp_p[p] = '0;
      assign r_last_p[p] = 1'b0; assign r_pois_p[p] = 1'b0; assign busy_p[p] = 1'b0;
      assign m_awakeup[p] = 1'b0; assign m_awvalid[p] = 1'b0; assign m_arvalid[p] = 1'b0;
      assign m_wvalid[p] = 1'b0; assign m_rready[p] = 1'b0; assign m_bready[p] = 1'b0;
      assign m_awaddr[p] = '0; assign m_awburst[p] = '0; assign m_awid[p] = '0; assign m_awlen[p] = '0;
      assign m_awsize[p] = '0; assign m_awqos[p] = '0; assign m_awprot[p] = '0; assign m_awcache[p] = '0;
      assign m_awdomain[p] = '0; assign m_awinner[p] = '0; assign m_awchid[p] = '0; assign m_awchidvalid[p] = 1'b0;
      assign m_araddr[p] = '0; assign m_arburst[p] = '0; assign m_arid[p] = '0; assign m_arlen[p] = '0;
      assign m_arsize[p] = '0; assign m_arqos[p] = '0; assign m_arprot[p] = '0; assign m_arcache[p] = '0;
      assign m_ardomain[p] = '0; assign m_arinner[p] = '0; assign m_archid[p] = '0; assign m_archidvalid[p] = 1'b0;
      assign m_arcmdlink[p] = 1'b0; assign m_wlast[p] = 1'b0; assign m_wstrb[p] = '0; assign m_wdata[p] = '0;
    end
  end

  // ---------------- merge ports towards the channels
  // A channel only has outstanding traffic on one port per direction, so the
  // R / B of the two ports never target the same channel in the same cycle.
  assign c_ar_ready = ar_rdy_p[0] | ar_rdy_p[1];
  assign c_aw_ready = aw_rdy_p[0] | aw_rdy_p[1];
  assign c_w_ready  = w_rdy_p[0]  | w_rdy_p[1];
  assign c_r_valid  = r_v_p[0] | r_v_p[1];
  assign c_b_valid  = b_v_p[0] | b_v_p[1];

  // per-channel response payload: 2:1 select by the delivering port (both
  // ports may deliver in the same cycle to different channels)
  for (genvar c = 0; c < NUM_CH; c++) begin : g_rsel
    assign c_r_data[c]   = r_v_p[1][c] ? r_d_p[1]    : r_d_p[0];
    assign c_r_resp[c]   = r_v_p[1][c] ? r_resp_p[1] : r_resp_p[0];
    assign c_r_last[c]   = r_v_p[1][c] ? r_last_p[1] : r_last_p[0];
    assign c_r_poison[c] = r_v_p[1][c] ? r_pois_p[1] : r_pois_p[0];
    assign c_b_resp[c]   = b_v_p[1][c] ? b_resp_p[1] : b_resp_p[0];
  end

endmodule : dma_biu
