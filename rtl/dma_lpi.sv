//-----------------------------------------------------------------------------
// dma_lpi.sv
// AMBA Low Power Interface controllers (TRM 4.6 / 5.9.1):
//   * clock Q-Channel : accept when the DMAC is inactive or only waiting for
//                       an event, deny when active
//   * power P-Channel : ON / WARM_RST / FULL_RET / OFF, DISMINPWR / IDLERETEN
//                       rules, pactive[8]=ON, pactive[5]=FULL_RET
// CDC: clk_qreqn and preq are synchronized (dma_cdc_sync); pstate is only
// sampled after the synchronized preq is seen high (held stable by the LPI
// protocol). All handshake outputs are flops.
// clk_qactive additionally ORs raw wake-up sources (pwakeup, trigger
// requests, control requests): this is the intended asynchronous wake path
// to the clock controller (synchronized there), it never feeds DMAC logic.
//-----------------------------------------------------------------------------
module dma_lpi
  import dma_pkg::*;
(
  input  logic        clk,
  input  logic        resetn,
  // Q-Channel
  input  logic        clk_qreqn,
  output logic        clk_qacceptn,
  output logic        clk_qdeny,
  output logic        clk_qactive,
  // P-Channel
  input  logic        preq,
  input  logic [3:0]  pstate,
  output logic        paccept,
  output logic        pdeny,
  output logic [9:0]  pactive,
  // activity information
  input  logic        dmac_active,     // transfers / APB / link in progress
  input  logic        ns_waiting,      // a Non-secure channel waits for an event
  input  logic        s_waiting,       // a Secure channel waits for an event
  input  logic        any_enabled,
  input  logic        all_paused,      // every enabled channel is paused
  input  logic        ns_present,      // at least one Non-secure channel
  input  logic        s_present,
  input  logic [1:0]  ns_dis_minpwr,
  input  logic [1:0]  s_dis_minpwr,
  input  logic        ns_idleret,
  input  logic        s_idleret,
  input  logic        async_wake,      // raw OR of asynchronous wake sources
  // control
  output logic        run,             // DMAC activity allowed
  output logic        warm_rst_pause,
  output logic        lpi_active       // both channels in their active state
);

  // ---------------- synchronizers
  logic qreqn_s, preq_s;
  dma_cdc_sync #(.WIDTH(1), .STAGES(2), .RST_VAL(1'b0)) u_qsync (
    .clk(clk), .resetn(resetn), .d_async(clk_qreqn), .q_sync(qreqn_s));
  dma_cdc_sync #(.WIDTH(1), .STAGES(2), .RST_VAL(1'b0)) u_psync (
    .clk(clk), .resetn(resetn), .d_async(preq), .q_sync(preq_s));

  wire waiting = ns_waiting | s_waiting;

  // ==========================================================================
  // Q-Channel
  // ==========================================================================
  typedef enum logic [1:0] { Q_STOPPED, Q_RUN, Q_DENIED } qst_e;
  qst_e qst;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      qst          <= Q_STOPPED;
      clk_qacceptn <= 1'b0;
      clk_qdeny    <= 1'b0;
    end else begin
      case (qst)
        Q_STOPPED: if (qreqn_s) begin
                     clk_qacceptn <= 1'b1;
                     qst          <= Q_RUN;
                   end
        Q_RUN:     if (!qreqn_s) begin
                     if (!dmac_active) begin
                       clk_qacceptn <= 1'b0;
                       qst          <= Q_STOPPED;
                     end else begin
                       clk_qdeny <= 1'b1;
                       qst       <= Q_DENIED;
                     end
                   end
        Q_DENIED:  if (qreqn_s) begin
                     clk_qdeny <= 1'b0;
                     qst       <= Q_RUN;
                   end
        default:   qst <= Q_STOPPED;
      endcase
    end
  end

  logic act_q;
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) act_q <= 1'b0;
    else         act_q <= dmac_active;
  end
  assign clk_qactive = act_q | async_wake;

  // ==========================================================================
  // P-Channel
  // ==========================================================================
  typedef enum logic [1:0] { P_IDLE, P_WRST, P_ACC, P_DENY } pst_e;
  pst_e        pst;
  logic [3:0]  cur, tgt;

  function automatic logic [1:0] lvl(input logic [3:0] s);
    case (s)
      PS_OFF:      return 2'd0;
      PS_FULL_RET: return 2'd1;
      default:     return 2'd2;
    endcase
  endfunction

  logic minpwr_ok, ret_ok, decide_acc;
  always_comb begin
    minpwr_ok = !((ns_present && ns_dis_minpwr > lvl(pstate)) ||
                  (s_present  && s_dis_minpwr  > lvl(pstate)));
    ret_ok    = !((ns_waiting && !ns_idleret) || (s_waiting && !s_idleret));
    case (pstate)
      PS_ON:       decide_acc = 1'b1;
      PS_WARM_RST: decide_acc = 1'b1;
      PS_FULL_RET: decide_acc = minpwr_ok && !dmac_active && ret_ok;
      PS_OFF:      decide_acc = minpwr_ok && !any_enabled;
      default:     decide_acc = 1'b0;
    endcase
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      pst     <= P_IDLE;
      cur     <= PS_ON;
      tgt     <= PS_ON;
      paccept <= 1'b0;
      pdeny   <= 1'b0;
    end else begin
      case (pst)
        P_IDLE: if (preq_s) begin
                  tgt <= pstate;
                  if (pstate == PS_WARM_RST)  pst <= P_WRST;
                  else if (decide_acc) begin
                    paccept <= 1'b1;
                    pst     <= P_ACC;
                  end else begin
                    pdeny <= 1'b1;
                    pst   <= P_DENY;
                  end
                end
        P_WRST: if (all_paused) begin       // channels paused before accepting
                  paccept <= 1'b1;
                  pst     <= P_ACC;
                end
        P_ACC:  if (!preq_s) begin
                  paccept <= 1'b0;
                  cur     <= tgt;
                  pst     <= P_IDLE;
                end
        P_DENY: if (!preq_s) begin
                  pdeny <= 1'b0;
                  pst   <= P_IDLE;
                end
        default: pst <= P_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) pactive <= '0;
    else begin
      pactive    <= '0;
      pactive[8] <= dmac_active;
      pactive[5] <= waiting & ~dmac_active;
    end
  end

  wire p_on = (cur == PS_ON) || (cur == PS_WARM_RST);
  assign warm_rst_pause = (pst == P_WRST) || (cur == PS_WARM_RST) ||
                          (pst == P_ACC && tgt == PS_WARM_RST);
  assign run        = (qst != Q_STOPPED) && p_on && !(pst == P_ACC && (tgt == PS_OFF || tgt == PS_FULL_RET));
  assign lpi_active = (qst == Q_RUN || qst == Q_DENIED) && (cur == PS_ON);

endmodule : dma_lpi
