//-----------------------------------------------------------------------------
// dma_reset_sync.sv
// Reset synchronizer: asynchronous assertion, synchronous de-assertion.
// When BYPASS=1 the incoming reset is used directly (integrator guarantees
// synchronous de-assertion, as required by the TRM for resetn).
//-----------------------------------------------------------------------------
module dma_reset_sync #(
  parameter int STAGES = 2,
  parameter bit BYPASS = 1'b0
) (
  input  logic clk,
  input  logic resetn_in,
  input  logic test_mode,   // scan: use primary reset directly
  output logic resetn_out
);

  generate
    if (BYPASS) begin : g_bypass
      assign resetn_out = resetn_in;
    end else begin : g_sync
      (* ASYNC_REG = "TRUE", dont_touch = "true" *)
      logic [STAGES-1:0] rst_ff;
      always_ff @(posedge clk or negedge resetn_in) begin
        if (!resetn_in) rst_ff <= '0;
        else            rst_ff <= {rst_ff[STAGES-2:0], 1'b1};
      end
      assign resetn_out = test_mode ? resetn_in : rst_ff[STAGES-1];
    end
  endgenerate

endmodule : dma_reset_sync
