//-----------------------------------------------------------------------------
// dma_ch_fifo.sv
// Channel data FIFO organised as a byte-granular circular buffer.
//
//  * Capacity = DEPTH words of DW bits (DEPTH >= 2, power of 2).
//  * Storage = two banks (even / odd words) of dma_sram_2p (1W1R, byte enable,
//    1-cycle read latency). Any write of <= DWB bytes touches at most one word
//    per bank and any read window of DWB bytes needs at most one word per bank,
//    so a single-ported-per-direction macro is sufficient (no bank conflicts).
//  * Write port : accepts a bus beat with a source byte lane + byte count and
//    packs the bytes contiguously at the write pointer (one rotator).
//  * Read port  : extracts nb bytes at the read pointer and places them at an
//    arbitrary destination lane (funnel shifter), or skips (discards) bytes.
//  * Byte accounting (free / available space) is done by the channel
//    controller; this block never stalls and never checks occupancy.
//
// Pipeline (all SRAM inputs and the output are registered):
//   write : in -> W0 reg -> rotate/BE -> W1 reg -> SRAM write  (wr_commit)
//   read  : in -> R0 reg -> SRAM read -> funnel shift -> R2 reg (out_valid)
//-----------------------------------------------------------------------------
module dma_ch_fifo #(
  parameter int DW       = 64,
  parameter int DEPTH    = 16,
  parameter int MEM_IMPL = 0,
  parameter int TAGW     = 8
) (
  input  logic                    clk,
  input  logic                    resetn,
  input  logic                    clr,          // reset pointers (FIFO empty)
  // ---- write (producer) port
  input  logic                    wr_valid,
  input  logic [DW-1:0]           wr_data,
  input  logic [$clog2(DW/8)-1:0] wr_lane,      // lane of first valid byte
  input  logic [$clog2(DW/8):0]   wr_nb,        // number of valid bytes (1..DWB)
  output logic                    wr_commit,    // SRAM write performed this cycle
  output logic [$clog2(DW/8):0]   wr_commit_nb,
  // ---- read (consumer) port
  input  logic                    rd_valid,
  input  logic                    rd_skip,      // discard nb bytes, no output
  input  logic [$clog2(DW/8)-1:0] rd_lane,      // destination lane of first byte
  input  logic [$clog2(DW/8):0]   rd_nb,
  input  logic [TAGW-1:0]         rd_tag,
  output logic                    out_valid,
  output logic [DW-1:0]           out_data,
  output logic [TAGW-1:0]         out_tag
);

  localparam int DWB = DW / 8;
  localparam int LB  = $clog2(DWB);
  localparam int WAW = $clog2(DEPTH);                 // word address width
  localparam int BD  = DEPTH / 2;                     // words per bank
  localparam int BAW = (BD > 1) ? $clog2(BD) : 1;     // bank address width
  localparam int PW  = WAW + LB;                      // byte pointer width

  // --------------------------------------------------------------------------
  // helpers
  // --------------------------------------------------------------------------
  function automatic logic [DW-1:0] rotl_bytes(input logic [DW-1:0] d,
                                               input logic [LB-1:0] r);
    logic [2*DW-1:0] dd;
    dd = {d, d} << (r * 8);
    return dd[2*DW-1:DW];
  endfunction

  function automatic logic [BAW-1:0] bank_addr(input logic [WAW-1:0] w);
    logic [WAW-1:0] t;
    t = w >> 1;
    return t[BAW-1:0];
  endfunction

  // --------------------------------------------------------------------------
  // Write path
  // --------------------------------------------------------------------------
  logic [PW-1:0]   wptr;
  logic            w0_v;
  logic [DW-1:0]   w0_data;
  logic [LB-1:0]   w0_rot, w0_wo;
  logic [LB:0]     w0_nb;
  logic [WAW-1:0]  w0_word;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      wptr <= '0;
      w0_v <= 1'b0;
    end else if (clr) begin
      wptr <= '0;
      w0_v <= 1'b0;
    end else begin
      w0_v <= wr_valid;
      if (wr_valid) wptr <= wptr + PW'(wr_nb);
    end
  end

  always_ff @(posedge clk) begin
    if (wr_valid) begin
      w0_data <= wr_data;
      w0_wo   <= wptr[LB-1:0];
      w0_rot  <= wptr[LB-1:0] - wr_lane;      // modulo DWB
      w0_nb   <= wr_nb;
      w0_word <= wptr[PW-1:LB];
    end
  end

  // rotate + byte enables (2*DWB-wide enable window starting at word w0_word)
  logic [2*DWB-1:0] w_be2;
  logic [DW-1:0]    w_rot_data;
  always_comb begin
    w_be2      = ((2*DWB)'(1) << w0_nb) - 1'b1;
    w_be2      = w_be2 << w0_wo;
    w_rot_data = rotl_bytes(w0_data, w0_rot);
  end

  // W1 registers = SRAM write inputs
  logic            b_wen  [2];
  logic [BAW-1:0]  b_waddr[2];
  logic [DWB-1:0]  b_wbe  [2];
  logic [DW-1:0]   b_wdata;
  logic            w1_v;
  logic [LB:0]     w1_nb;

  logic [WAW-1:0]  w0_word_p1;
  assign w0_word_p1 = w0_word + 1'b1;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      w1_v     <= 1'b0;
      b_wen[0] <= 1'b0;
      b_wen[1] <= 1'b0;
    end else if (clr) begin
      w1_v     <= 1'b0;
      b_wen[0] <= 1'b0;
      b_wen[1] <= 1'b0;
    end else begin
      w1_v <= w0_v;
      // word w   -> bank w[0],  word w+1 -> bank ~w[0]
      b_wen[w0_word[0]]  <= w0_v & (|w_be2[DWB-1:0]);
      b_wen[~w0_word[0]] <= w0_v & (|w_be2[2*DWB-1:DWB]);
    end
  end

  always_ff @(posedge clk) begin
    if (w0_v) begin
      b_wdata                <= w_rot_data;
      w1_nb                  <= w0_nb;
      b_waddr[w0_word[0]]    <= bank_addr(w0_word);
      b_wbe  [w0_word[0]]    <= w_be2[DWB-1:0];
      b_waddr[~w0_word[0]]   <= bank_addr(w0_word_p1);
      b_wbe  [~w0_word[0]]   <= w_be2[2*DWB-1:DWB];
    end
  end

  assign wr_commit    = w1_v;
  assign wr_commit_nb = w1_nb;

  // --------------------------------------------------------------------------
  // Read path
  // --------------------------------------------------------------------------
  logic [PW-1:0]   rptr;
  logic            r0_v, r0_skip;
  logic [LB-1:0]   r0_lane, r0_ro;
  logic [WAW-1:0]  r0_word;
  logic [TAGW-1:0] r0_tag;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      rptr    <= '0;
      r0_v    <= 1'b0;
      r0_skip <= 1'b0;
    end else if (clr) begin
      rptr    <= '0;
      r0_v    <= 1'b0;
      r0_skip <= 1'b0;
    end else begin
      r0_v    <= rd_valid & ~rd_skip;
      r0_skip <= rd_valid &  rd_skip;
      if (rd_valid) rptr <= rptr + PW'(rd_nb);
    end
  end

  always_ff @(posedge clk) begin
    if (rd_valid) begin
      r0_lane <= rd_lane;
      r0_ro   <= rptr[LB-1:0];
      r0_word <= rptr[PW-1:LB];
      r0_tag  <= rd_tag;
    end
  end

  logic [WAW-1:0] r0_word_p1;
  assign r0_word_p1 = r0_word + 1'b1;

  logic           b_ren  [2];
  logic [BAW-1:0] b_raddr[2];
  logic [DW-1:0]  b_rdata[2];

  always_comb begin
    b_ren[0]   = r0_v;
    b_ren[1]   = r0_v;
    b_raddr[0] = r0_word[0] ? bank_addr(r0_word_p1) : bank_addr(r0_word);
    b_raddr[1] = r0_word[0] ? bank_addr(r0_word)    : bank_addr(r0_word_p1);
  end

  // R1 stage bookkeeping
  logic            r1_v;
  logic            r1_odd;
  logic [LB:0]     r1_shift;       // (ro - lane) + DWB : 1 .. 2*DWB-1
  logic [TAGW-1:0] r1_tag;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn)    r1_v <= 1'b0;
    else if (clr)   r1_v <= 1'b0;
    else            r1_v <= r0_v;
  end

  always_ff @(posedge clk) begin
    if (r0_v) begin
      r1_odd   <= r0_word[0];
      r1_shift <= (LB+1)'(DWB) + (LB+1)'(r0_ro) - (LB+1)'(r0_lane);
      r1_tag   <= r0_tag;
    end
  end

  // funnel shift : ext = {word(w+1), word(w), DWB zero bytes}
  logic [3*DW-1:0] ext;
  logic [DW-1:0]   r_shifted;
  always_comb begin
    if (r1_odd) ext = {b_rdata[0], b_rdata[1], {DW{1'b0}}};
    else        ext = {b_rdata[1], b_rdata[0], {DW{1'b0}}};
    r_shifted = DW'(ext >> (r1_shift * 8));
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn)  out_valid <= 1'b0;
    else if (clr) out_valid <= 1'b0;
    else          out_valid <= r1_v;
  end

  always_ff @(posedge clk) begin
    if (r1_v) begin
      out_data <= r_shifted;
      out_tag  <= r1_tag;
    end
  end

  // --------------------------------------------------------------------------
  // Storage banks
  // --------------------------------------------------------------------------
  for (genvar b = 0; b < 2; b++) begin : g_bank
    dma_sram_2p #(
      .DEPTH    (BD),
      .WIDTH    (DW),
      .MEM_IMPL (MEM_IMPL)
    ) u_mem (
      .clk     (clk),
      .wr_en   (b_wen[b]),
      .wr_addr (b_waddr[b]),
      .wr_data (b_wdata),
      .wr_be   (b_wbe[b]),
      .rd_en   (b_ren[b]),
      .rd_addr (b_raddr[b]),
      .rd_data (b_rdata[b])
    );
  end

  wire unused_skip = r0_skip;

endmodule : dma_ch_fifo
