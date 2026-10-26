//-----------------------------------------------------------------------------
// dma_lrg_arb.sv
// Two-layer arbiter described in TRM 5.8.2:
//   1. fixed-priority layer : only requesters with the highest QoS/priority
//                             value compete
//   2. least-recently-granted (LRG) layer between equal priority requesters
// The LRG history is a precedence matrix (prec[i][j]=1 -> i beats j), updated
// only when the grant is accepted (upd). Fully parallel, log-depth logic.
//-----------------------------------------------------------------------------
module dma_lrg_arb #(
  parameter int N  = 4,
  parameter int PW = 4
) (
  input  logic              clk,
  input  logic              resetn,
  input  logic [N-1:0]      req,
  input  logic [PW-1:0]     prio [N],
  input  logic              upd,       // grant accepted this cycle
  output logic [N-1:0]      gnt,       // one-hot (combinational)
  output logic [$clog2(N>1?N:2)-1:0] gnt_idx
);

  logic [N-1:0] prec [N];   // prec[i][j] : i has precedence over j
  logic [N-1:0] req_hp;     // requesters at the highest priority level

  // ---- priority layer: drop any requester beaten by a higher priority one
  always_comb begin
    for (int i = 0; i < N; i++) begin
      req_hp[i] = req[i];
      for (int j = 0; j < N; j++) begin
        if (j != i && req[j] && (prio[j] > prio[i])) req_hp[i] = 1'b0;
      end
    end
  end

  // ---- LRG layer
  always_comb begin
    for (int i = 0; i < N; i++) begin
      gnt[i] = req_hp[i];
      for (int j = 0; j < N; j++) begin
        if (j != i && req_hp[j] && !prec[i][j]) gnt[i] = 1'b0;
      end
    end
  end

  always_comb begin
    gnt_idx = '0;
    for (int i = 0; i < N; i++) if (gnt[i]) gnt_idx = i[$bits(gnt_idx)-1:0];
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
          prec[i][j] <= (i < j);
    end else if (upd) begin
      for (int i = 0; i < N; i++) begin
        if (gnt[i]) begin
          for (int j = 0; j < N; j++) begin
            if (j != i) begin
              prec[i][j] <= 1'b0;   // granted one becomes most recent
              prec[j][i] <= 1'b1;
            end
          end
        end
      end
    end
  end

endmodule : dma_lrg_arb
