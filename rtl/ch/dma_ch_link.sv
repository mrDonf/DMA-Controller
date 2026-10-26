//-----------------------------------------------------------------------------
// dma_ch_link.sv
// Command link fetch unit (TRM 5.7). Fetches a command descriptor at LINKADDR
// with bus-width INCR bursts (arprot[2]=1 / arcmdlink=1 are added by the
// channel), decodes the header bitmap and writes the selected channel
// registers in header order.
//
//   1. header fetch : one beat at LINKADDR (returns header + following words
//                     up to the bus boundary)
//   2. body fetch   : remaining words, bursts limited by 16 beats, 1KB and the
//                     free space of the command word buffer
//   3. decode       : one register write per cycle from the word buffer
//-----------------------------------------------------------------------------
module dma_ch_link
  import dma_pkg::*;
#(
  parameter int AW     = 32,
  parameter int DW     = 64,
  parameter int CMDBUF = 16          // command word buffer (words, pow2 >= DW/32*2)
) (
  input  logic                    clk,
  input  logic                    resetn,
  input  logic                    start,
  input  logic                    abort,
  input  logic [AW-1:0]           link_addr,   // word aligned
  input  logic                    run,         // not paused
  // ---- read request (to channel read issue)
  output logic                    rq_valid,
  input  logic                    rq_ready,
  output logic [AW-1:0]           rq_addr,
  output logic [7:0]              rq_len,
  output logic [8:0]              rq_nb,
  // ---- data from read path
  input  logic                    rd_valid,
  input  logic [DW-1:0]           rd_data,
  input  logic [$clog2(DW/8)-1:0] rd_lane,
  input  logic [$clog2(DW/8):0]   rd_nb,
  input  logic                    rd_burst_done,  // link burst completed
  // ---- register update
  output logic                    reg_clear,      // REGCLEAR
  output logic                    reg_we,
  output logic [4:0]              reg_idx,        // header bit index
  output logic [31:0]             reg_wdata,
  // ---- status
  output logic                    busy,
  output logic                    done,           // pulse, descriptor applied
  output logic                    hdr_err         // pulse, invalid header
);

  localparam int DWB  = DW / 8;
  localparam int LB   = $clog2(DWB);
  localparam int WPB  = DWB / 4;                   // words per beat
  localparam int BW   = $clog2(CMDBUF);
  localparam logic [31:0] HDR_RSVD = 32'h0A80_0002; // bits 1,23,25,27

  // ---------------- word buffer (multi-write, single read)
  logic [31:0]  wbuf [CMDBUF];
  logic [BW:0]  wcnt;              // words stored
  logic [BW-1:0] wp, rp;
  logic [BW:0]  resv;              // words reserved by issued fetches (not yet in buffer)

  // words in the incoming beat
  logic [LB:0]   k_words;
  logic [LB-1:0] w_first;          // first word index in the beat (0 for 32-bit buses)
  assign k_words = rd_nb >> 2;
  assign w_first = rd_lane >> 2;

  // data of a fetch aborted by a stop / error is dropped (engine back in idle)
  logic rd_acc;

  // ---------------- fetch FSM
  typedef enum logic [2:0] { F_IDLE, F_HDR, F_HDRW, F_BODY, F_WAIT, F_DONE } fst_e;
  fst_e        fst;
  assign rd_acc = rd_valid && (fst != F_IDLE);
  logic [AW-1:0] faddr;           // next fetch address
  logic [5:0]  fetched;            // words requested so far (incl. header)
  logic [5:0]  need;               // total words of descriptor (valid after hdr)
  logic        need_v;
  logic [3:0]  outst;              // outstanding link bursts

  // ---------------- decode FSM
  typedef enum logic [1:0] { P_HDR, P_BODY, P_END } pst_e;
  pst_e        pst;
  logic [31:0] hdr_rem;
  logic        pop;

  wire hdr_avail = (wcnt != '0);

  // lowest set bit in remaining header (bits 2..31)
  logic [4:0] nbit;
  always_comb begin
    nbit = 5'd0;
    for (int b = 31; b >= 1; b--) if (hdr_rem[b]) nbit = b[4:0];
  end

  // ---------------- body burst sizing
  logic [5:0]  rem_words;
  logic [10:0] to1k_b;
  logic [8:0]  bnb, rem_b;
  logic [5:0]  bbeats, need_beats;
  logic [10:0] lim_beats, b1k, bbuf;      // full width: up to 1024 / DWB beats
  logic [BW:0] freew;
  always_comb begin
    rem_words  = need - fetched;
    rem_b      = {1'b0, rem_words, 2'b00};
    to1k_b     = 11'd1024 - {1'b0, faddr[9:0]};
    freew      = (BW+1)'(CMDBUF) - wcnt - resv;
    // beats limited by 16, the 1KB boundary and command buffer space; the
    // comparisons are done at full width (no truncation of 64 / 128 beats)
    b1k        = to1k_b >> LB;
    bbuf       = (11'(freew) << 2) >> LB;
    lim_beats  = 11'd16;
    if (b1k  < lim_beats) lim_beats = b1k;
    if (bbuf < lim_beats) lim_beats = bbuf;
    need_beats = 6'((rem_b + 9'(DWB-1)) >> LB);
    bbeats     = (11'(need_beats) < lim_beats) ? need_beats : 6'(lim_beats);
    bnb        = (rem_b < (9'(bbeats) << LB)) ? rem_b : (9'(bbeats) << LB);
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      fst     <= F_IDLE;
      faddr   <= '0;
      fetched <= '0;
      outst   <= '0;
      resv    <= '0;
    end else begin
      // bus accounting continues across an abort: the bursts of an aborted
      // fetch are still outstanding and their data arrives later (dropped)
      if (rq_valid && rq_ready) outst <= outst + 1'b1 - rd_burst_done;
      else if (rd_burst_done)   outst <= outst - 1'b1;

      if (rq_valid && rq_ready) resv <= resv + (BW+1)'(rq_nb >> 2) - (rd_valid ? k_words : '0);
      else if (rd_valid)        resv <= resv - k_words;

      if (abort) fst <= F_IDLE;
      else case (fst)
        F_IDLE: if (start) begin
                  fst     <= F_HDR;
                  faddr   <= link_addr;
                  fetched <= '0;
                end
        F_HDR:  if (rq_valid && rq_ready) begin
                  fetched <= 6'(WPB - int'(link_addr[LB-1:0] >> 2));
                  faddr   <= {faddr[AW-1:LB] + 1'b1, {LB{1'b0}}};
                  fst     <= F_HDRW;
                end
        F_HDRW: if (need_v) fst <= (fetched >= need) ? F_WAIT : F_BODY;
        F_BODY: if (rq_valid && rq_ready) begin
                  fetched <= fetched + 6'(rq_nb >> 2);
                  faddr   <= faddr + AW'(rq_nb);
                  if (fetched + 6'(rq_nb >> 2) >= need) fst <= F_WAIT;
                end
        F_WAIT: if (pst == P_END && outst == '0 && !(rq_valid && rq_ready)) fst <= F_DONE;
        F_DONE: fst <= F_IDLE;
        default: fst <= F_IDLE;
      endcase
      if (hdr_err && !abort) fst <= F_WAIT;
    end
  end

  always_comb begin
    rq_valid = 1'b0;
    rq_addr  = faddr;
    rq_len   = 8'd0;
    rq_nb    = 9'(DWB) - 9'(faddr[LB-1:0]);
    if (run) begin
      if (fst == F_HDR) begin
        rq_valid = ((BW+1)'(CMDBUF) - wcnt - resv) >= (BW+1)'(WPB);
      end else if (fst == F_BODY && !hdr_err) begin
        rq_nb    = bnb;
        rq_len   = 8'(bbeats - 1'b1);
        rq_valid = (bnb != 9'd0);
      end
    end
  end

  // ---------------- word buffer write / read
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      wp   <= '0;
      rp   <= '0;
      wcnt <= '0;
    end else if (abort || start || fst == F_DONE) begin
      wp   <= '0;
      rp   <= '0;
      wcnt <= '0;
    end else begin
      if (rd_acc) wp <= wp + BW'(k_words);
      if (pop)    rp <= rp + 1'b1;
      wcnt <= wcnt + (rd_acc ? k_words : '0) - pop;
    end
  end

  always_ff @(posedge clk) begin
    if (rd_acc) begin
      for (int i = 0; i < WPB; i++) begin
        if (i < k_words)
          wbuf[BW'(wp + BW'(i))] <= rd_data[32*(int'(w_first) + i) +: 32];
      end
    end
  end

  // ---------------- decode
  wire [31:0] head = wbuf[rp];
  assign pop = hdr_avail && run && (pst == P_HDR || (pst == P_BODY && hdr_rem[31:1] != '0));

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      pst     <= P_HDR;
      hdr_rem <= '0;
      need    <= '0;
      need_v  <= 1'b0;
    end else if (abort || start) begin
      pst     <= P_HDR;
      hdr_rem <= '0;
      need    <= '0;
      need_v  <= 1'b0;
    end else begin
      case (pst)
        P_HDR: if (pop) begin
                 hdr_rem <= head & ~32'd1;
                 need    <= 6'(popcount32(head & ~32'd1)) + 6'd1;
                 need_v  <= 1'b1;
                 if (head == 32'd0 || (head & HDR_RSVD) != 32'd0) pst <= P_END;
                 else if ((head & ~32'd1) == 32'd0)              pst <= P_END;
                 else                                           pst <= P_BODY;
               end
        P_BODY: if (pop) begin
                  hdr_rem[nbit] <= 1'b0;
                  if ((hdr_rem & ~(32'd1 << nbit)) == 32'd0) pst <= P_END;
                end
        P_END: ;
        default: pst <= P_HDR;
      endcase
    end
  end

  assign reg_clear = (pst == P_HDR) && pop && head[0] && ((head & HDR_RSVD) == 32'd0);
  assign reg_we    = (pst == P_BODY) && pop;
  assign reg_idx   = nbit;
  assign reg_wdata = head;
  assign hdr_err   = (pst == P_HDR) && pop && (head == 32'd0 || (head & HDR_RSVD) != 32'd0);

  assign busy = (fst != F_IDLE);
  assign done = (fst == F_DONE);

`ifndef SYNTHESIS
  // read data must always belong to a reserved fetch (no reservation underflow,
  // no command buffer overflow)
  always @(posedge clk) if (resetn) begin
    if (rd_valid && !(rq_valid && rq_ready) && resv < (BW+1)'(k_words))
      $error("%m: link read data without reservation (resv=%0d words=%0d)", resv, k_words);
    if (wcnt > (BW+1)'(CMDBUF))
      $error("%m: command buffer overflow (wcnt=%0d)", wcnt);
  end
`endif

endmodule : dma_ch_link
