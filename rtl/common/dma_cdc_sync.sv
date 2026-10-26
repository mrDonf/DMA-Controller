//-----------------------------------------------------------------------------
// dma_cdc_sync.sv
// Multi-flop level synchronizer for single-bit (independent) signals.
//
// CDC rules enforced by construction:
//  * Each bit is synchronized independently - only use it for signals whose
//    bits are not related (or for a single-bit level / 4-phase handshake).
//  * The input must be driven directly from a flop in the source domain
//    (no combinational logic in front of the first stage).
//  * Multi-bit qualifiers that travel with a handshake are NOT passed through
//    this cell: they are sampled in the destination domain only after the
//    synchronized request is seen (data held stable by protocol).
//
// Replace the body with a technology synchronizer cell if required, keeping
// the module name / ports (single point of change for the whole design).
//-----------------------------------------------------------------------------
module dma_cdc_sync #(
  parameter int WIDTH    = 1,
  parameter int STAGES   = 2,          // >= 2
  parameter bit RST_VAL  = 1'b0
) (
  input  logic             clk,
  input  logic             resetn,
  input  logic [WIDTH-1:0] d_async,
  output logic [WIDTH-1:0] q_sync
);

  (* ASYNC_REG = "TRUE", dont_touch = "true" *)
  logic [WIDTH-1:0] sync_ff [STAGES];

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      for (int i = 0; i < STAGES; i++) sync_ff[i] <= {WIDTH{RST_VAL}};
    end else begin
      sync_ff[0] <= d_async;
      for (int i = 1; i < STAGES; i++) sync_ff[i] <= sync_ff[i-1];
    end
  end

  assign q_sync = sync_ff[STAGES-1];

endmodule : dma_cdc_sync
