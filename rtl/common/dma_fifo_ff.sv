//-----------------------------------------------------------------------------
// dma_fifo_ff.sv
// Small flop-based synchronous FIFO (show-ahead) used for control / sideband
// queues (burst descriptors, W ordering, response tracking...).
// Data FIFOs use dma_ch_fifo (SRAM-macro friendly) instead.
//-----------------------------------------------------------------------------
module dma_fifo_ff #(
  parameter int WIDTH = 8,
  parameter int DEPTH = 4            // >= 1
) (
  input  logic             clk,
  input  logic             resetn,
  input  logic             clr,      // synchronous flush
  input  logic             push,
  input  logic [WIDTH-1:0] din,
  output logic             full,
  input  logic             pop,
  output logic [WIDTH-1:0] dout,
  output logic             empty,
  output logic [$clog2(DEPTH+1)-1:0] count
);

  localparam int AW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW-1:0]    wp, rp;
  logic [$clog2(DEPTH+1)-1:0] cnt;

  wire do_push = push & ~full;
  wire do_pop  = pop  & ~empty;

  function automatic logic [AW-1:0] inc(input logic [AW-1:0] p);
    if (DEPTH == 1) return '0;
    else if (p == AW'(DEPTH-1)) return '0;
    else return p + 1'b1;
  endfunction

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      wp  <= '0;
      rp  <= '0;
      cnt <= '0;
    end else if (clr) begin
      wp  <= '0;
      rp  <= '0;
      cnt <= '0;
    end else begin
      if (do_push) wp <= inc(wp);
      if (do_pop)  rp <= inc(rp);
      cnt <= cnt + do_push - do_pop;
    end
  end

  always_ff @(posedge clk) begin
    if (do_push) mem[wp] <= din;
  end

  assign dout  = mem[rp];
  assign empty = (cnt == '0);
  assign full  = (cnt == DEPTH[$clog2(DEPTH+1)-1:0]);
  assign count = cnt;

endmodule : dma_fifo_ff
