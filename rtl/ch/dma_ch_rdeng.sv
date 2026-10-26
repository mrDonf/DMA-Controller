//-----------------------------------------------------------------------------
// dma_ch_rdeng.sv
// FIFO consumer engine. Converts consumer descriptors into per-beat FIFO read
// requests and collects the (lane aligned) FIFO output into an output queue.
//
// Descriptor kinds:
//   K_AXI    : AXI write burst  (lane/size/burst/nb/len) - data or fill
//   K_STREAM : one AXI-Stream beat (nb bytes from lane 0, tlast flag)
//   K_SKIP   : discard nb (<= DWB) bytes (excess data dropping / flush)
//
// Output beats: {data, strb, last}. Throughput 1 beat / cycle; the FIFO read
// pipeline latency (3 cycles) is covered by credit-based output queueing.
//-----------------------------------------------------------------------------
module dma_ch_rdeng
  import dma_pkg::*;
#(
  parameter int DW     = 64,
  parameter int QDEPTH = 8,
  parameter int ODEPTH = 6
) (
  input  logic                    clk,
  input  logic                    resetn,
  input  logic                    clr,
  input  logic [DW-1:0]           fill_pat,     // replicated fill pattern
  // ---- descriptor input
  input  logic                    d_push,
  input  logic [1:0]              d_kind,
  input  logic [$clog2(DW/8)-1:0] d_alo,
  input  logic [2:0]              d_size,
  input  logic [1:0]              d_burst,
  input  logic [8:0]              d_nb,
  input  logic                    d_fill,
  input  logic                    d_tlast,
  output logic                    d_full,
  output logic                    idle,         // nothing queued or in flight
  // ---- FIFO read port
  output logic                    f_rd_valid,
  output logic                    f_rd_skip,
  output logic [$clog2(DW/8)-1:0] f_rd_lane,
  output logic [$clog2(DW/8):0]   f_rd_nb,
  output logic [DW/8+1:0]         f_rd_tag,
  input  logic                    f_out_valid,
  input  logic [DW-1:0]           f_out_data,
  input  logic [DW/8+1:0]         f_out_tag,
  // ---- bytes released from the FIFO (for free-space accounting)
  output logic                    rel_valid,
  output logic [$clog2(DW/8):0]   rel_nb,
  // ---- output beats
  output logic                    o_valid,
  input  logic                    o_ready,
  output logic [DW-1:0]           o_data,
  output logic [DW/8-1:0]         o_strb,
  output logic                    o_last
);

  localparam int DWB = DW / 8;
  localparam int LB  = $clog2(DWB);

  localparam logic [1:0] K_AXI = 2'd0, K_STREAM = 2'd1, K_SKIP = 2'd2;

  // ---------------- descriptor queue
  localparam int QW = 2 + LB + 3 + 2 + 9 + 1 + 1;
  logic [QW-1:0] q_dout;
  logic          q_empty, q_pop;

  dma_fifo_ff #(.WIDTH(QW), .DEPTH(QDEPTH)) u_q (
    .clk   (clk),
    .resetn(resetn),
    .clr   (clr),
    .push  (d_push),
    .din   ({d_kind, d_alo, d_size, d_burst, d_nb, d_fill, d_tlast}),
    .full  (d_full),
    .pop   (q_pop),
    .dout  (q_dout),
    .empty (q_empty),
    .count ()
  );

  logic [1:0]    h_kind;
  logic [LB-1:0] h_alo;
  logic [2:0]    h_size;
  logic [1:0]    h_burst;
  logic [8:0]    h_nb;
  logic          h_fill, h_tlast;
  assign {h_kind, h_alo, h_size, h_burst, h_nb, h_fill, h_tlast} = q_dout;

  // ---------------- output queue + credits
  localparam int OW = DW + DWB + 1;
  logic          oq_push, oq_empty, oq_full;
  logic [OW-1:0] oq_dout;
  logic [$clog2(ODEPTH+1)-1:0] oq_cnt;
  logic [2:0]    inflight;

  // ---------------- beat sequencing
  logic          first;
  logic [LB-1:0] lane_q;
  logic [8:0]    rem_q;
  logic [LB-1:0] lane;
  logic [8:0]    rem;
  logic [LB:0]   bsz, nb;
  logic          last_beat;
  logic          credit_ok;
  logic          issue;

  always_comb begin
    bsz = (LB+1)'(1) << h_size;
    rem = first ? h_nb : rem_q;
    if (h_kind != K_AXI) begin
      lane = '0;
      nb   = (rem > 9'(DWB)) ? (LB+1)'(DWB) : rem[LB:0];
    end else begin
      if (first)                     lane = h_alo;
      else if (h_burst == AXI_FIXED) lane = lane_q;
      else                           lane = LB'((lane_q & ~LB'(bsz - 1'b1)) + bsz);
      nb = bsz - (LB+1)'(lane & LB'(bsz - 1'b1));
      if (9'(nb) > rem) nb = rem[LB:0];
    end
    last_beat = (9'(nb) >= rem);
  end

  assign credit_ok = ((oq_cnt + inflight) < ODEPTH);
  assign issue     = ~q_empty & ((h_kind == K_SKIP) | credit_ok);
  assign q_pop     = issue & last_beat;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      first  <= 1'b1;
      lane_q <= '0;
      rem_q  <= '0;
    end else if (clr) begin
      first  <= 1'b1;
    end else if (issue) begin
      first  <= last_beat;
      lane_q <= lane;
      rem_q  <= rem - 9'(nb);
    end
  end

  // strobe of the beat
  logic [DWB-1:0] strb;
  always_comb begin
    strb = DWB'(((2*DWB)'(1) << nb) - 1'b1) << lane;
  end

  wire data_beat = ~(h_kind == K_AXI && h_fill);

  assign f_rd_valid = issue & data_beat;
  assign f_rd_skip  = (h_kind == K_SKIP);
  assign f_rd_lane  = lane;
  assign f_rd_nb    = nb;
  assign f_rd_tag   = {1'b0, (h_kind == K_STREAM) ? (h_tlast & last_beat) : last_beat, strb};

  assign rel_valid  = issue & data_beat;
  assign rel_nb     = nb;

  // fill beats do not use the FIFO: they are delayed through a matching
  // 3-stage pipe so ordering with data beats is preserved.
  logic [2:0]        fl_v;
  logic [DWB+1:0]    fl_tag [3];
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn)  fl_v <= '0;
    else if (clr) fl_v <= '0;
    else          fl_v <= {fl_v[1:0], issue & ~data_beat};
  end
  always_ff @(posedge clk) begin
    fl_tag[0] <= {1'b0, last_beat, strb};
    fl_tag[1] <= fl_tag[0];
    fl_tag[2] <= fl_tag[1];
  end

  // in-flight counter (requests whose result has not reached the queue yet)
  wire req_in  = issue & (h_kind != K_SKIP);
  wire res_out = f_out_valid | fl_v[2];
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn)  inflight <= '0;
    else if (clr) inflight <= '0;
    else          inflight <= inflight + req_in - res_out;
  end

  // unused byte lanes are driven to zero (no stale / X data on the bus)
  function automatic logic [DW-1:0] lane_mask(input logic [DW-1:0] d, input logic [DWB-1:0] st);
    logic [DW-1:0] r;
    for (int b = 0; b < DWB; b++) r[8*b +: 8] = st[b] ? d[8*b +: 8] : 8'h00;
    return r;
  endfunction

  logic [OW-1:0] oq_din;
  always_comb begin
    if (fl_v[2]) oq_din = {lane_mask(fill_pat,   fl_tag[2][DWB-1:0]),  fl_tag[2][DWB-1:0],  fl_tag[2][DWB]};
    else         oq_din = {lane_mask(f_out_data, f_out_tag[DWB-1:0]),  f_out_tag[DWB-1:0],  f_out_tag[DWB]};
  end
  assign oq_push = res_out;

  dma_fifo_ff #(.WIDTH(OW), .DEPTH(ODEPTH)) u_oq (
    .clk   (clk),
    .resetn(resetn),
    .clr   (clr),
    .push  (oq_push),
    .din   (oq_din),
    .full  (oq_full),
    .pop   (o_valid & o_ready),
    .dout  (oq_dout),
    .empty (oq_empty),
    .count (oq_cnt)
  );

  assign o_valid = ~oq_empty;
  assign {o_data, o_strb, o_last} = oq_dout;

  assign idle = q_empty & (inflight == '0) & oq_empty;

endmodule : dma_ch_rdeng
