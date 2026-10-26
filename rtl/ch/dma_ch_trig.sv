//-----------------------------------------------------------------------------
// dma_ch_trig.sv
// Channel side trigger handling (TRM 5.4):
//   dma_ch_trigin  : one trigger input side (source or destination)
//                    - command mode    : start of the whole command
//                    - flow control    : DMA driven (10) / peripheral driven (11)
//                    - SW trigger request bits (CH_CMD.*SWTRIGINREQ)
//   dma_ch_trigout : trigger output (end of command), HW / internal / SW ack
// The 4-phase handshake is: req^ -> ack^ -> req_ -> ack_.
// All outputs are registered. hw_req / hw_ack inputs are already synchronized
// (trigger matrix).
//-----------------------------------------------------------------------------
module dma_ch_trigin
  import dma_pkg::*;
(
  input  logic        clk,
  input  logic        resetn,
  input  logic        clr,           // command end / stop: return to idle
  input  logic        pause,         // freeze handshake progress
  // configuration of the current command
  input  logic        en,            // side uses a trigger input
  input  logic        hw_type,       // HW or internal source (else SW only)
  input  logic        fc_mode,       // flow control mode (else command mode)
  input  logic        fc_per,        // peripheral driven flow control
  input  logic [7:0]  blksize,       // TRIGINBLKSIZE (elements - 1)
  // phase control from channel FSM
  input  logic        cmd_phase,     // channel waiting for command triggers
  input  logic        cmd_go,        // all command triggers received -> ack
  input  logic        xfer_phase,    // data transfer state
  // hardware request (through trigger matrix)
  input  logic        hw_req,
  input  logic [1:0]  hw_reqtype,
  output logic        hw_ack,
  output logic [1:0]  hw_acktype,
  // software request
  input  logic        sw_req,
  input  logic [1:0]  sw_type,
  output logic        sw_req_clr,    // pulse: clear CH_CMD.*SWTRIGINREQ
  // flow control interface with the side engine
  input  logic        side_active,   // side still has elements to move
  input  logic        side_idle,     // no outstanding transactions on side
  input  logic        pop,           // descriptor issued on this side
  input  logic [8:0]  pop_nelem,
  output logic        blk_en,
  output logic [8:0]  blk_rem,
  output logic        per_last,      // peripheral signalled LAST: end side
  // status
  output logic        stat_wait,     // STAT_*TRIGINWAIT
  output logic        cmd_got,       // command trigger received
  output logic        cmd_done,      // command handshake completed (ack low)
  output logic        fc_done,       // flow controlled side completed
  output logic        busy           // handshake not idle
);

  typedef enum logic [2:0] {
    T_IDLE, T_WAIT, T_GOT, T_XFER, T_ACKH, T_FIN
  } st_e;

  st_e        st;
  logic       src_hw;      // current request came from HW
  logic       last_q;      // LAST request type (peripheral flow control)
  logic       final_q;     // current block is the final one

  wire hw_in = hw_type & hw_req;
  // the CH_CMD request bit is cleared one cycle after sw_req_clr: the request
  // being cleared must not start a second flow control block (a new APB write
  // in that cycle has priority over the clear and is seen one cycle later)
  wire sw_in = sw_req & ~sw_req_clr;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      st         <= T_IDLE;
      src_hw     <= 1'b0;
      last_q     <= 1'b0;
      final_q    <= 1'b0;
      hw_ack     <= 1'b0;
      hw_acktype <= ACK_OKAY;
      blk_rem    <= '0;
      sw_req_clr <= 1'b0;
      per_last   <= 1'b0;
    end else if (clr) begin
      st         <= T_IDLE;
      hw_ack     <= 1'b0;
      hw_acktype <= ACK_OKAY;
      blk_rem    <= '0;
      sw_req_clr <= 1'b0;
      per_last   <= 1'b0;
      last_q     <= 1'b0;
      final_q    <= 1'b0;
    end else begin
      sw_req_clr <= 1'b0;
      if (pop) blk_rem <= (blk_rem > pop_nelem) ? (blk_rem - pop_nelem) : 9'd0;

      if (!pause) begin
        case (st)
          T_IDLE: begin
            if (en && ((!fc_mode && cmd_phase) || (fc_mode && xfer_phase)))
              st <= T_WAIT;
          end

          T_WAIT: begin
            if (fc_mode && !side_active) begin
              // nothing left on this side (e.g. other side ended the command)
              st <= T_FIN;
            end else if (hw_in || sw_in) begin
              src_hw <= hw_in;
              if (!hw_in) sw_req_clr <= ~fc_mode;
              if (fc_mode) begin
                logic [1:0] t;
                t       = hw_in ? hw_reqtype : sw_type;
                blk_rem <= t[1] ? ({1'b0, blksize} + 9'd1) : 9'd1;
                last_q  <= fc_per & t[0];
                st      <= T_XFER;
              end else begin
                st <= T_GOT;
              end
            end
          end

          T_GOT: begin          // command mode: wait until all sides received
            if (cmd_go) begin
              if (src_hw) begin
                hw_ack     <= 1'b1;
                hw_acktype <= ACK_OKAY;
                st         <= T_ACKH;
              end else begin
                st <= T_FIN;
              end
            end
          end

          T_XFER: begin         // flow control block in progress
            if ((blk_rem == 9'd0 || !side_active || per_last) && side_idle) begin
              final_q <= !side_active || last_q;
              if (src_hw) begin
                hw_ack     <= 1'b1;
                hw_acktype <= (!side_active || last_q) ? ACK_LAST_OKAY : ACK_OKAY;
                st         <= T_ACKH;
              end else begin
                sw_req_clr <= 1'b1;
                st         <= (!side_active || last_q) ? T_FIN : T_WAIT;
              end
              blk_rem <= '0;
            end
          end

          T_ACKH: begin         // wait for req low, then release ack
            if (!hw_req) begin
              hw_ack <= 1'b0;
              if (!fc_mode)      st <= T_FIN;
              else if (final_q)  st <= T_FIN;
              else               st <= T_WAIT;
            end
          end

          T_FIN: ;

          default: st <= T_IDLE;
        endcase
      end

      // peripheral LAST: the side ends once the current block is issued
      if (st == T_XFER && last_q && blk_rem == 9'd0) per_last <= 1'b1;
    end
  end

  assign blk_en    = en & fc_mode;
  assign stat_wait = (st == T_WAIT);
  assign cmd_got   = (st == T_GOT) | (st == T_ACKH) | (st == T_FIN);
  assign cmd_done  = (st == T_FIN) | ~en | fc_mode;
  assign fc_done   = (st == T_FIN) | ~en | ~fc_mode;
  assign busy      = hw_ack;

endmodule : dma_ch_trigin


module dma_ch_trigout
  import dma_pkg::*;
(
  input  logic clk,
  input  logic resetn,
  input  logic clr,
  input  logic pause,
  input  logic en,           // USETRIGOUT for current command
  input  logic hw_type,      // HW or internal (else SW only)
  input  logic start,        // channel entered trigger-out state
  input  logic hw_ack,       // synchronized ack from matrix
  input  logic sw_ack,       // CH_CMD.SWTRIGOUTACK (level)
  output logic sw_ack_clr,   // pulse: clear SWTRIGOUTACK
  output logic hw_req,
  output logic stat_wait,    // STAT_TRIGOUTACKWAIT
  output logic done          // trigger output step finished
);

  typedef enum logic [1:0] { O_IDLE, O_REQ, O_LOW, O_DONE } st_e;
  st_e st;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      st         <= O_IDLE;
      hw_req     <= 1'b0;
      sw_ack_clr <= 1'b0;
    end else if (clr) begin
      st         <= O_IDLE;
      hw_req     <= 1'b0;
      sw_ack_clr <= 1'b0;
    end else begin
      sw_ack_clr <= 1'b0;
      if (!pause) begin
        case (st)
          O_IDLE: if (start) begin
                    if (!en) st <= O_DONE;
                    else begin
                      st     <= O_REQ;
                      hw_req <= hw_type;
                    end
                  end
          O_REQ:  if ((hw_type && hw_ack) || sw_ack) begin
                    hw_req     <= 1'b0;
                    sw_ack_clr <= sw_ack;
                    st         <= (hw_type && hw_ack) ? O_LOW : O_DONE;
                  end
          O_LOW:  if (!hw_ack) st <= O_DONE;
          O_DONE: ;
        endcase
      end
    end
  end

  assign stat_wait = (st == O_REQ);
  assign done      = (st == O_DONE);

endmodule : dma_ch_trigout
