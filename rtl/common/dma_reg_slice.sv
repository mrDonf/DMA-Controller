//-----------------------------------------------------------------------------
// dma_reg_slice.sv
// Full-throughput valid/ready register slices with clock-enable support on the
// external side (aclken_m0 / aclken_m1 behaviour from the TRM):
//   * external-facing outputs change only on clock edges where en == 1
//   * external-facing inputs are sampled only on clock edges where en == 1
// With en tied to 1 these are ordinary full register slices (1 cycle latency,
// 1 transfer per cycle, all outputs driven from flops).
//-----------------------------------------------------------------------------

// Internal -> external (e.g. AW / AR / W towards the interconnect)
module dma_rs_out #(
  parameter int WIDTH = 32
) (
  input  logic             clk,
  input  logic             resetn,
  input  logic             en,          // external clock enable
  // internal (full rate) side
  input  logic             in_valid,
  output logic             in_ready,
  input  logic [WIDTH-1:0] in_data,
  // external side
  output logic             out_valid,
  input  logic             out_ready,
  output logic [WIDTH-1:0] out_data
);

  logic             skid_valid;
  logic [WIDTH-1:0] skid_data;

  wire accept   = in_valid & in_ready;
  wire out_fire = en & out_valid & out_ready;
  wire out_free = en & (~out_valid | out_ready);   // output reg may load this edge

  assign in_ready = ~skid_valid;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      out_valid  <= 1'b0;
      skid_valid <= 1'b0;
    end else begin
      if (out_free) begin
        if (skid_valid) begin
          out_valid  <= 1'b1;
          skid_valid <= accept;
        end else begin
          out_valid  <= accept;
        end
      end else if (accept) begin
        skid_valid <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (out_free) begin
      if (skid_valid) begin
        out_data <= skid_data;
        if (accept) skid_data <= in_data;
      end else if (accept) begin
        out_data <= in_data;
      end
    end else if (accept) begin
      skid_data <= in_data;
    end
  end

  // out_fire kept for readability / assertions
  wire unused_fire = out_fire;

endmodule : dma_rs_out


// External -> internal (e.g. R / B from the interconnect)
module dma_rs_in #(
  parameter int WIDTH = 32
) (
  input  logic             clk,
  input  logic             resetn,
  input  logic             en,          // external clock enable
  // external side
  input  logic             in_valid,
  output logic             in_ready,
  input  logic [WIDTH-1:0] in_data,
  // internal (full rate) side
  output logic             out_valid,
  input  logic             out_ready,
  output logic [WIDTH-1:0] out_data
);

  logic [WIDTH-1:0] buf_q [2];
  logic             rp, wp;
  logic [1:0]       cnt;
  logic             rdy_q;

  wire cap  = en & in_valid & rdy_q;
  wire pop  = out_valid & out_ready;
  wire [1:0] cnt_nxt = cnt + cap - pop;

  assign in_ready  = rdy_q;
  assign out_valid = (cnt != 2'd0);
  assign out_data  = buf_q[rp];

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      rp    <= 1'b0;
      wp    <= 1'b0;
      cnt   <= 2'd0;
      rdy_q <= 1'b0;
    end else begin
      if (cap) wp <= ~wp;
      if (pop) rp <= ~rp;
      cnt <= cnt_nxt;
      // ready is only allowed to change on enabled edges
      if (en) rdy_q <= (cnt_nxt < 2'd2);
    end
  end

  always_ff @(posedge clk) begin
    if (cap) buf_q[wp] <= in_data;
  end

endmodule : dma_rs_in
