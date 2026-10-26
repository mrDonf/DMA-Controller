//-----------------------------------------------------------------------------
// dma_ch_rdp.sv
// Read data path of a channel: R beats (already routed by the BIU to this
// channel) are matched with the burst descriptors queued at AR issue time and
// converted into (lane, byte count) writes into the channel byte FIFO, or are
// forwarded to the command-link unit for descriptor fetches.
//-----------------------------------------------------------------------------
module dma_ch_rdp
  import dma_pkg::*;
#(
  parameter int DW      = 64,
  parameter int QDEPTH  = 8      // max outstanding reads of the channel
) (
  input  logic                    clk,
  input  logic                    resetn,
  input  logic                    clr,
  // ---- descriptor push at AR issue
  input  logic                    q_push,
  input  logic [$clog2(DW/8)-1:0] q_alo,
  input  logic [2:0]              q_size,
  input  logic [1:0]              q_burst,
  input  logic [8:0]              q_nb,
  input  logic                    q_link,
  output logic                    q_full,
  // ---- R beats from the BIU (always accepted)
  input  logic                    r_valid,
  input  logic [DW-1:0]           r_data,
  input  logic [1:0]              r_resp,
  input  logic                    r_last,
  input  logic                    r_poison,
  // ---- to FIFO write port
  output logic                    f_valid,
  output logic [DW-1:0]           f_data,
  output logic [$clog2(DW/8)-1:0] f_lane,
  output logic [$clog2(DW/8):0]   f_nb,
  // ---- to command link unit
  output logic                    l_valid,
  output logic [DW-1:0]           l_data,
  output logic [$clog2(DW/8)-1:0] l_lane,
  output logic [$clog2(DW/8):0]   l_nb,
  // ---- completion / errors
  output logic                    burst_done,    // last beat of a burst received
  output logic                    burst_link,    // ... and it was a link fetch
  output logic                    err_resp,      // pulse
  output logic                    err_poison,    // pulse
  output logic                    q_empty
);

  localparam int DWB = DW / 8;
  localparam int LB  = $clog2(DWB);
  localparam int QW  = LB + 3 + 2 + 9 + 1;

  logic [QW-1:0] q_dout;
  logic          q_pop;

  dma_fifo_ff #(.WIDTH(QW), .DEPTH(QDEPTH)) u_q (
    .clk   (clk),
    .resetn(resetn),
    .clr   (clr),
    .push  (q_push),
    .din   ({q_alo, q_size, q_burst, q_nb, q_link}),
    .full  (q_full),
    .pop   (q_pop),
    .dout  (q_dout),
    .empty (q_empty),
    .count ()
  );

  logic [LB-1:0] h_alo;
  logic [2:0]    h_size;
  logic [1:0]    h_burst;
  logic [8:0]    h_nb;
  logic          h_link;
  assign {h_alo, h_size, h_burst, h_nb, h_link} = q_dout;

  // running beat state
  logic          first;       // next beat is the first of the burst
  logic [LB-1:0] lane_q;      // lane of the previous beat
  logic [8:0]    rem_q;       // bytes remaining in burst

  logic [LB-1:0] lane;
  logic [8:0]    rem;
  logic [LB:0]   bsz;         // beat size in bytes
  logic [LB:0]   nb;

  always_comb begin
    bsz = (LB+1)'(1) << h_size;
    if (first) begin
      lane = h_alo;
      rem  = h_nb;
    end else begin
      rem  = rem_q;
      if (h_burst == AXI_FIXED) lane = lane_q;
      else                      lane = LB'((lane_q & ~LB'(bsz - 1'b1)) + bsz);
    end
    // bytes in this beat: up to the next size boundary, limited by remainder
    nb = bsz - (LB+1)'(lane & LB'(bsz - 1'b1));
    if (9'(nb) > rem) nb = rem[LB:0];
  end

  wire beat = r_valid;
  assign q_pop = beat & r_last;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      first  <= 1'b1;
      lane_q <= '0;
      rem_q  <= '0;
    end else if (clr) begin
      first  <= 1'b1;
    end else if (beat) begin
      first  <= r_last;
      lane_q <= lane;
      rem_q  <= rem - 9'(nb);
    end
  end

  wire bad = (r_resp[1] == 1'b1) | r_poison;

  assign f_valid    = beat & ~h_link & ~bad & (nb != '0);
  assign f_data     = r_data;
  assign f_lane     = lane;
  assign f_nb       = nb;

  assign l_valid    = beat & h_link & ~bad & (nb != '0);
  assign l_data     = r_data;
  assign l_lane     = lane;
  assign l_nb       = nb;

  assign burst_done = beat & r_last;
  assign burst_link = h_link;
  assign err_resp   = beat & r_resp[1];
  assign err_poison = beat & r_poison;

endmodule : dma_ch_rdp
