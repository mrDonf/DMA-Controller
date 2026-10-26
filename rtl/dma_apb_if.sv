//-----------------------------------------------------------------------------
// dma_apb_if.sv
// APB4 subordinate front-end (TRM 4.2):
//   * pclken clock enable: inputs are sampled and outputs change only on
//     clock edges where pclken = 1
//   * the access is captured at the first ACCESS cycle, executed internally
//     one clock later from registered address / data (short timing paths),
//     and completed with a registered PREADY / PRDATA / PSLVERR
//   * only 32-bit accesses; PSTRB != 4'b1111 on a write -> PSLVERR
//   * paddr[1:0] ignored
//-----------------------------------------------------------------------------
module dma_apb_if (
  input  logic        clk,
  input  logic        resetn,
  input  logic        pclken,
  // APB4
  input  logic        psel,
  input  logic        penable,
  input  logic [2:0]  pprot,
  input  logic        pwrite,
  input  logic [12:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  input  logic        pdebug,
  output logic        pready,
  output logic        pslverr,
  output logic [31:0] prdata,
  // internal access (one-cycle strobes)
  output logic        acc_wr,
  output logic        acc_rd,
  output logic [12:0] acc_addr,
  output logic [31:0] acc_wdata,
  output logic [2:0]  acc_prot,
  output logic        acc_debug,
  output logic        acc_strb_err,
  input  logic [31:0] acc_rdata,
  input  logic        acc_err,
  output logic        busy
);

  typedef enum logic [1:0] { A_IDLE, A_EXEC, A_RESP, A_DONE } st_e;
  st_e st;

  logic        q_wr;
  logic [3:0]  q_strb;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      st        <= A_IDLE;
      pready    <= 1'b0;
      pslverr   <= 1'b0;
      prdata    <= '0;
      q_wr      <= 1'b0;
      q_strb    <= '0;
      acc_addr  <= '0;
      acc_wdata <= '0;
      acc_prot  <= '0;
      acc_debug <= 1'b0;
    end else begin
      case (st)
        A_IDLE: begin
          if (pclken && psel && penable) begin
            q_wr      <= pwrite;
            q_strb    <= pstrb;
            acc_addr  <= {paddr[12:2], 2'b00};
            acc_wdata <= pwdata;
            acc_prot  <= pprot;
            acc_debug <= pdebug;
            st        <= A_EXEC;
          end
        end
        A_EXEC: begin
          prdata  <= q_wr ? 32'd0 : acc_rdata;
          pslverr <= acc_err | acc_strb_err;
          st      <= A_RESP;
        end
        A_RESP: begin
          if (pclken) begin
            pready <= 1'b1;
            st     <= A_DONE;
          end
        end
        A_DONE: begin
          if (pclken) begin
            pready  <= 1'b0;
            pslverr <= 1'b0;
            st      <= A_IDLE;
          end
        end
        default: st <= A_IDLE;
      endcase
    end
  end

  assign acc_strb_err = q_wr && (q_strb != 4'hF);
  assign acc_wr       = (st == A_EXEC) &&  q_wr && !acc_strb_err;
  assign acc_rd       = (st == A_EXEC) && !q_wr;
  assign busy         = (st != A_IDLE);

endmodule : dma_apb_if
