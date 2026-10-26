//-----------------------------------------------------------------------------
// dma_sram_2p.sv
// Synchronous two-port (1 write + 1 read) memory with byte write enables and
// 1-cycle registered read latency. This is the ONLY storage primitive used by
// the data FIFOs, so replacing it with a foundry SRAM / register-file macro is
// a single-file change:
//
//   * Read data is valid the cycle after rd_en (macro-like, no fall-through).
//   * rd_data holds its value when rd_en is low (matches most macros; the FIFO
//     controllers never rely on it, they capture data in the following cycle).
//   * Read and write of the same address in the same cycle is never issued by
//     the controllers (read-during-write behaviour is "don't care").
//
// MEM_IMPL: 0 = flop array (default, any depth)
//           1 = SRAM macro (define DMA_SRAM_MACRO and edit the g_macro branch)
//-----------------------------------------------------------------------------
module dma_sram_2p #(
  parameter int DEPTH    = 16,
  parameter int WIDTH    = 64,         // must be a multiple of 8
  parameter int MEM_IMPL = 0
) (
  input  logic                         clk,
  // write port
  input  logic                         wr_en,
  input  logic [$clog2(DEPTH>1?DEPTH:2)-1:0] wr_addr,
  input  logic [WIDTH-1:0]             wr_data,
  input  logic [WIDTH/8-1:0]           wr_be,
  // read port
  input  logic                         rd_en,
  input  logic [$clog2(DEPTH>1?DEPTH:2)-1:0] rd_addr,
  output logic [WIDTH-1:0]             rd_data
);

  localparam int NB = WIDTH / 8;

  generate
    if (MEM_IMPL == 1) begin : g_macro
`ifdef DMA_SRAM_MACRO
      // ---------------------------------------------------------------
      // Technology macro hook. Example (TSMC-like two-port RF):
      //   rf2p_<DEPTH>x<WIDTH> u_mem (
      //     .CLKA(clk), .CENA(~rd_en), .AA(rd_addr), .QA(rd_data),
      //     .CLKB(clk), .CENB(~wr_en), .AB(wr_addr), .DB(wr_data),
      //     .BWEB(~{8{wr_be}}) ... );
      // ---------------------------------------------------------------
      `DMA_SRAM_MACRO_INST
`else
      // Behavioural model of the macro (same timing as the flop version)
      logic [WIDTH-1:0] mem [DEPTH];
      always_ff @(posedge clk) begin
        if (wr_en) begin
          for (int b = 0; b < NB; b++)
            if (wr_be[b]) mem[wr_addr][b*8 +: 8] <= wr_data[b*8 +: 8];
        end
        if (rd_en) rd_data <= mem[rd_addr];
      end
`endif
    end else begin : g_flop
      logic [WIDTH-1:0] mem [DEPTH];
      always_ff @(posedge clk) begin
        if (wr_en) begin
          for (int b = 0; b < NB; b++)
            if (wr_be[b]) mem[wr_addr][b*8 +: 8] <= wr_data[b*8 +: 8];
        end
      end
      always_ff @(posedge clk) begin
        if (rd_en) rd_data <= mem[rd_addr];
      end
    end
  endgenerate

endmodule : dma_sram_2p
