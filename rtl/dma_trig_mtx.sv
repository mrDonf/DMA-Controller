//-----------------------------------------------------------------------------
// dma_trig_mtx.sv
// Trigger matrix (TRM 5.4.3 / 5.4.4):
//   * allocation of external trigger input / output ports and internal
//     channel-to-channel connections, with the selection error rules
//     (busy, owned, simultaneous selection, security mismatch)
//   * routing of req / ack between ports and channel sides
//   * completion of interrupted handshakes after release / stop
//   * software deny of pending, unselected trigger input requests
//   * CDC: trigger input requests / output acknowledges are synchronized
//     with dma_cdc_sync when the TRIG_*_SYNC_EN_MASK bit is set. Request
//     qualifiers (reqtype) are only sampled after the synchronized req is
//     seen high (held stable by protocol). All pin outputs are flops.
//-----------------------------------------------------------------------------
module dma_trig_mtx
  import dma_pkg::*;
#(
  parameter int          NUM_CH  = 2,
  parameter int          NTI     = 1,      // number of trigger inputs  (0..32)
  parameter int          NTO     = 1,      // number of trigger outputs (0..32)
  parameter logic [31:0] TI_SYNC = '1,
  parameter logic [31:0] TO_SYNC = '1,
  parameter bit          SECEXT  = 1'b0
) (
  input  logic                clk,
  input  logic                resetn,
  // ---------------- external trigger pins (vectors sized >= 1)
  input  logic [(NTI>0?NTI:1)-1:0]   trig_in_req,
  input  logic [1:0]                 trig_in_reqtype [(NTI>0?NTI:1)],
  output logic [(NTI>0?NTI:1)-1:0]   trig_in_ack,
  output logic [1:0]                 trig_in_acktype [(NTI>0?NTI:1)],
  output logic [(NTO>0?NTO:1)-1:0]   trig_out_req,
  input  logic [(NTO>0?NTO:1)-1:0]   trig_out_ack,
  // ---------------- security mapping
  input  logic [31:0]         ti_nonsec,
  input  logic [31:0]         to_nonsec,
  input  logic [NUM_CH-1:0]   ch_nonsec,
  // ---------------- software deny (SIGNALVAL write, already security filtered)
  input  logic [31:0]         deny_req,
  // ---------------- status (SIGNALVAL read)
  output logic [31:0]         st_ti_req,
  output logic [31:0]         st_to_ack,
  output logic [31:0]         st_ti_sel,     // input selected by a channel
  // ---------------- channel interface
  input  logic [NUM_CH-1:0]   c_alloc,
  input  logic [NUM_CH-1:0]   c_src_use,
  input  logic [NUM_CH-1:0]   c_src_int,
  input  logic [7:0]          c_src_sel [NUM_CH],
  input  logic [NUM_CH-1:0]   c_des_use,
  input  logic [NUM_CH-1:0]   c_des_int,
  input  logic [7:0]          c_des_sel [NUM_CH],
  input  logic [NUM_CH-1:0]   c_out_use,
  input  logic [7:0]          c_out_sel [NUM_CH],
  output logic [NUM_CH-1:0]   c_alloc_done,
  output logic [NUM_CH-1:0]   c_src_err,
  output logic [NUM_CH-1:0]   c_des_err,
  output logic [NUM_CH-1:0]   c_out_err,
  input  logic [NUM_CH-1:0]   c_release,
  output logic [NUM_CH-1:0]   c_src_req,
  output logic [1:0]          c_src_reqtype [NUM_CH],
  input  logic [NUM_CH-1:0]   c_src_ack,
  input  logic [1:0]          c_src_acktype [NUM_CH],
  output logic [NUM_CH-1:0]   c_des_req,
  output logic [1:0]          c_des_reqtype [NUM_CH],
  input  logic [NUM_CH-1:0]   c_des_ack,
  input  logic [1:0]          c_des_acktype [NUM_CH],
  input  logic [NUM_CH-1:0]   c_out_req,
  input  logic [NUM_CH-1:0]   c_out_int,
  output logic [NUM_CH-1:0]   c_out_ack
);

  localparam int NI  = (NTI > 0) ? NTI : 1;
  localparam int NO  = (NTO > 0) ? NTO : 1;
  localparam int CW  = (NUM_CH > 1) ? $clog2(NUM_CH) : 1;
  localparam int IW  = (NI > 1) ? $clog2(NI) : 1;
  localparam int OW  = (NO > 1) ? $clog2(NO) : 1;

  // ==========================================================================
  // Synchronizers
  // ==========================================================================
  logic [NI-1:0] ti_req_s;
  logic [NO-1:0] to_ack_s;

  for (genvar p = 0; p < NI; p++) begin : g_tisync
    if (NTI > 0 && TI_SYNC[p]) begin : g_s
      dma_cdc_sync #(.WIDTH(1), .STAGES(2)) u_sync (
        .clk(clk), .resetn(resetn), .d_async(trig_in_req[p]), .q_sync(ti_req_s[p]));
    end else if (NTI > 0) begin : g_d
      assign ti_req_s[p] = trig_in_req[p];
    end else begin : g_z
      assign ti_req_s[p] = 1'b0;
    end
  end

  for (genvar q = 0; q < NO; q++) begin : g_tosync
    if (NTO > 0 && TO_SYNC[q]) begin : g_s
      dma_cdc_sync #(.WIDTH(1), .STAGES(2)) u_sync (
        .clk(clk), .resetn(resetn), .d_async(trig_out_ack[q]), .q_sync(to_ack_s[q]));
    end else if (NTO > 0) begin : g_d
      assign to_ack_s[q] = trig_out_ack[q];
    end else begin : g_z
      assign to_ack_s[q] = 1'b0;
    end
  end

  // ==========================================================================
  // Resource state
  // ==========================================================================
  // external inputs
  logic [NI-1:0]   ti_own;
  logic [CW-1:0]   ti_och  [NI];
  logic [NI-1:0]   ti_oside;          // 0 = src, 1 = des
  logic [NI-1:0]   ti_fin;            // finishing a handshake after release
  logic [NI-1:0]   ti_deny;           // software deny handshake
  logic [NI-1:0]   ti_ack_q;
  logic [1:0]      ti_at_q [NI];
  // external outputs
  logic [NO-1:0]   to_own;
  logic [CW-1:0]   to_och  [NO];
  logic [NO-1:0]   to_fin;            // finishing after release
  logic [NO-1:0]   to_req_q;
  // internal connections (producer channel a)
  logic [NUM_CH-1:0] in_own;
  logic [CW-1:0]     in_och  [NUM_CH];
  logic [NUM_CH-1:0] in_oside;
  // per-channel resource pointers
  logic [NUM_CH-1:0] s_v, s_ext, d_v, d_ext, o_v;
  logic [7:0]        s_idx [NUM_CH];
  logic [7:0]        d_idx [NUM_CH];
  logic [7:0]        o_idx [NUM_CH];

  // ==========================================================================
  // Allocation (requests registered, decided next cycle)
  // ==========================================================================
  logic [NUM_CH-1:0] a_q, a_src_use, a_src_int, a_des_use, a_des_int, a_out_use;
  logic [7:0]        a_src_sel [NUM_CH];
  logic [7:0]        a_des_sel [NUM_CH];
  logic [7:0]        a_out_sel [NUM_CH];

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      a_q <= '0; a_src_use <= '0; a_src_int <= '0; a_des_use <= '0; a_des_int <= '0; a_out_use <= '0;
      for (int c = 0; c < NUM_CH; c++) begin
        a_src_sel[c] <= '0; a_des_sel[c] <= '0; a_out_sel[c] <= '0;
      end
    end else begin
      a_q       <= c_alloc;
      a_src_use <= c_src_use & c_alloc;
      a_src_int <= c_src_int;
      a_des_use <= c_des_use & c_alloc;
      a_des_int <= c_des_int;
      a_out_use <= c_out_use & c_alloc;
      for (int c = 0; c < NUM_CH; c++) begin
        a_src_sel[c] <= c_src_sel[c];
        a_des_sel[c] <= c_des_sel[c];
        a_out_sel[c] <= c_out_sel[c];
      end
    end
  end

  // request counters per resource (simultaneous selection detection)
  logic [3:0] n_ti [NI];
  logic [3:0] n_to [NO];
  logic [3:0] n_in [NUM_CH];
  always_comb begin
    for (int p = 0; p < NI; p++) n_ti[p] = '0;
    for (int q = 0; q < NO; q++) n_to[q] = '0;
    for (int a = 0; a < NUM_CH; a++) n_in[a] = '0;
    for (int c = 0; c < NUM_CH; c++) begin
      if (a_src_use[c]) begin
        if (a_src_int[c]) begin
          if (a_src_sel[c] < NUM_CH) n_in[a_src_sel[c]] = n_in[a_src_sel[c]] + 1'b1;
        end else if (a_src_sel[c] < NI) n_ti[a_src_sel[c]] = n_ti[a_src_sel[c]] + 1'b1;
      end
      if (a_des_use[c]) begin
        if (a_des_int[c]) begin
          if (a_des_sel[c] < NUM_CH) n_in[a_des_sel[c]] = n_in[a_des_sel[c]] + 1'b1;
        end else if (a_des_sel[c] < NI) n_ti[a_des_sel[c]] = n_ti[a_des_sel[c]] + 1'b1;
      end
      if (a_out_use[c] && a_out_sel[c] < NO) n_to[a_out_sel[c]] = n_to[a_out_sel[c]] + 1'b1;
    end
  end

  // availability checks
  function automatic logic ti_free(input int p, input int c);
    return (NTI > 0) && (p < NI) && !ti_own[p] && !ti_fin[p] && !ti_deny[p] &&
           (n_ti[p] == 4'd1) && (!SECEXT || (ti_nonsec[p] == ch_nonsec[c]));
  endfunction
  function automatic logic in_free(input int a, input int c);
    return (a < NUM_CH) && (a != c) && !in_own[a] && (n_in[a] == 4'd1) &&
           (!SECEXT || (ch_nonsec[a] == ch_nonsec[c]));
  endfunction
  function automatic logic to_free(input int q, input int c);
    return (NTO > 0) && (q < NO) && !to_own[q] && !to_fin[q] && !to_req_q[q] && !to_ack_s[q] &&
           (n_to[q] == 4'd1) && (!SECEXT || (to_nonsec[q] == ch_nonsec[c]));
  endfunction

  logic [NUM_CH-1:0] e_s, e_d, e_o;
  always_comb begin
    for (int c = 0; c < NUM_CH; c++) begin
      e_s[c] = 1'b0; e_d[c] = 1'b0; e_o[c] = 1'b0;
      if (a_src_use[c])
        e_s[c] = a_src_int[c] ? !in_free(int'(a_src_sel[c]), c) : !ti_free(int'(a_src_sel[c]), c);
      if (a_des_use[c])
        e_d[c] = a_des_int[c] ? !in_free(int'(a_des_sel[c]), c) : !ti_free(int'(a_des_sel[c]), c);
      if (a_out_use[c])
        e_o[c] = !to_free(int'(a_out_sel[c]), c);
    end
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      c_alloc_done <= '0; c_src_err <= '0; c_des_err <= '0; c_out_err <= '0;
    end else begin
      c_alloc_done <= a_q;
      c_src_err    <= a_q & e_s;
      c_des_err    <= a_q & e_d;
      c_out_err    <= a_q & e_o;
    end
  end

  // ==========================================================================
  // Ownership tables, pin handshakes, release
  // ==========================================================================
  // channel side ack seen through ownership
  function automatic logic own_ack(input logic [CW-1:0] c, input logic side);
    return side ? c_des_ack[c] : c_src_ack[c];
  endfunction
  function automatic logic [1:0] own_acktype(input logic [CW-1:0] c, input logic side);
    return side ? c_des_acktype[c] : c_src_acktype[c];
  endfunction

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      ti_own <= '0; ti_oside <= '0; ti_fin <= '0; ti_deny <= '0; ti_ack_q <= '0;
      to_own <= '0; to_fin <= '0; to_req_q <= '0;
      in_own <= '0; in_oside <= '0;
      s_v <= '0; s_ext <= '0; d_v <= '0; d_ext <= '0; o_v <= '0;
      for (int p = 0; p < NI; p++) begin ti_och[p] <= '0; ti_at_q[p] <= ACK_OKAY; end
      for (int q = 0; q < NO; q++) to_och[q] <= '0;
      for (int a = 0; a < NUM_CH; a++) begin
        in_och[a] <= '0; s_idx[a] <= '0; d_idx[a] <= '0; o_idx[a] <= '0;
      end
    end else begin
      // ---------------- external input pins
      for (int p = 0; p < NI; p++) begin
        if (ti_fin[p] || ti_deny[p]) begin
          // matrix completes the handshake: ack stays high until req is low
          if (!ti_req_s[p]) begin
            ti_ack_q[p] <= 1'b0;
            ti_fin[p]   <= 1'b0;
            ti_deny[p]  <= 1'b0;
          end
        end else if (ti_own[p]) begin
          if (ti_ack_q[p] && ti_req_s[p] && !own_ack(ti_och[p], ti_oside[p])) begin
            // the owning channel withdrew its ack (stop / abort) while the
            // peripheral still holds req: keep ack until req goes low
            ti_fin[p] <= 1'b1;
          end else begin
            ti_ack_q[p] <= own_ack(ti_och[p], ti_oside[p]);
            ti_at_q[p]  <= own_acktype(ti_och[p], ti_oside[p]);
          end
        end else begin
          ti_ack_q[p] <= 1'b0;
          // software deny of a pending unselected request
          if (deny_req[p] && ti_req_s[p] && !ti_ack_q[p] && NTI > 0) begin
            ti_deny[p]  <= 1'b1;
            ti_ack_q[p] <= 1'b1;
            ti_at_q[p]  <= ACK_DENY;
          end
        end
      end

      // ---------------- external output pins
      for (int q = 0; q < NO; q++) begin
        if (to_fin[q]) begin
          // matrix completes the handshake: wait ack, drop req, wait ack low
          if (to_req_q[q] && to_ack_s[q]) to_req_q[q] <= 1'b0;
          if (!to_req_q[q] && !to_ack_s[q]) to_fin[q] <= 1'b0;
        end else if (to_own[q]) begin
          if (to_req_q[q] && !to_ack_s[q] && !c_out_req[to_och[q]]) begin
            // the owning channel withdrew a request that was never
            // acknowledged (stop): keep req high until the ack arrives
            to_fin[q] <= 1'b1;
          end else begin
            to_req_q[q] <= c_out_req[to_och[q]];
          end
        end else begin
          to_req_q[q] <= 1'b0;
        end
      end

      // ---------------- release
      for (int c = 0; c < NUM_CH; c++) begin
        if (c_release[c]) begin
          if (s_v[c]) begin
            if (s_ext[c]) begin
              ti_own[s_idx[c]] <= 1'b0;
              if (ti_ack_q[s_idx[c]] || own_ack(CW'(c), 1'b0)) begin
                ti_fin[s_idx[c]]   <= 1'b1;
                ti_ack_q[s_idx[c]] <= 1'b1;
              end
            end else begin
              in_own[s_idx[c]] <= 1'b0;
            end
          end
          if (d_v[c]) begin
            if (d_ext[c]) begin
              ti_own[d_idx[c]] <= 1'b0;
              if (ti_ack_q[d_idx[c]] || own_ack(CW'(c), 1'b1)) begin
                ti_fin[d_idx[c]]   <= 1'b1;
                ti_ack_q[d_idx[c]] <= 1'b1;
              end
            end else begin
              in_own[d_idx[c]] <= 1'b0;
            end
          end
          if (o_v[c]) begin
            to_own[o_idx[c]] <= 1'b0;
            if (to_req_q[o_idx[c]] || to_ack_s[o_idx[c]]) to_fin[o_idx[c]] <= 1'b1;
          end
          s_v[c] <= 1'b0;
          d_v[c] <= 1'b0;
          o_v[c] <= 1'b0;
        end
      end

      // ---------------- allocation (successful resources)
      for (int c = 0; c < NUM_CH; c++) begin
        if (a_q[c]) begin
          if (a_src_use[c] && !e_s[c]) begin
            s_v[c] <= 1'b1; s_ext[c] <= !a_src_int[c]; s_idx[c] <= a_src_sel[c];
            if (a_src_int[c]) begin
              in_own[a_src_sel[c]] <= 1'b1; in_och[a_src_sel[c]] <= CW'(c); in_oside[a_src_sel[c]] <= 1'b0;
            end else begin
              ti_own[a_src_sel[c]] <= 1'b1; ti_och[a_src_sel[c]] <= CW'(c); ti_oside[a_src_sel[c]] <= 1'b0;
            end
          end
          if (a_des_use[c] && !e_d[c]) begin
            d_v[c] <= 1'b1; d_ext[c] <= !a_des_int[c]; d_idx[c] <= a_des_sel[c];
            if (a_des_int[c]) begin
              in_own[a_des_sel[c]] <= 1'b1; in_och[a_des_sel[c]] <= CW'(c); in_oside[a_des_sel[c]] <= 1'b1;
            end else begin
              ti_own[a_des_sel[c]] <= 1'b1; ti_och[a_des_sel[c]] <= CW'(c); ti_oside[a_des_sel[c]] <= 1'b1;
            end
          end
          if (a_out_use[c] && !e_o[c]) begin
            o_v[c] <= 1'b1; o_idx[c] <= a_out_sel[c];
            to_own[a_out_sel[c]] <= 1'b1; to_och[a_out_sel[c]] <= CW'(c);
          end
        end
      end
    end
  end

  // ==========================================================================
  // Routing towards the channels
  // ==========================================================================
  // internal producer ack (consumer side ack)
  logic [NUM_CH-1:0] int_ack;
  always_comb begin
    for (int a = 0; a < NUM_CH; a++)
      int_ack[a] = in_own[a] ? own_ack(in_och[a], in_oside[a]) : 1'b0;
  end

  always_comb begin
    for (int c = 0; c < NUM_CH; c++) begin
      c_src_req[c]     = 1'b0;
      c_src_reqtype[c] = REQ_SINGLE;
      c_des_req[c]     = 1'b0;
      c_des_reqtype[c] = REQ_SINGLE;
      if (s_v[c]) begin
        if (s_ext[c]) begin
          c_src_req[c]     = ti_req_s[IW'(s_idx[c])];
          c_src_reqtype[c] = trig_in_reqtype[IW'(s_idx[c])];
        end else begin
          c_src_req[c]     = c_out_req[CW'(s_idx[c])] & c_out_int[CW'(s_idx[c])];
          c_src_reqtype[c] = REQ_BLOCK;
        end
      end
      if (d_v[c]) begin
        if (d_ext[c]) begin
          c_des_req[c]     = ti_req_s[IW'(d_idx[c])];
          c_des_reqtype[c] = trig_in_reqtype[IW'(d_idx[c])];
        end else begin
          c_des_req[c]     = c_out_req[CW'(d_idx[c])] & c_out_int[CW'(d_idx[c])];
          c_des_reqtype[c] = REQ_BLOCK;
        end
      end
      // trigger output acknowledge
      if (c_out_int[c])  c_out_ack[c] = int_ack[c];
      else if (o_v[c])   c_out_ack[c] = to_ack_s[OW'(o_idx[c])];
      else               c_out_ack[c] = 1'b0;
    end
  end

  // ==========================================================================
  // Pins and status
  // ==========================================================================
  always_comb begin
    for (int p = 0; p < NI; p++) begin
      trig_in_ack[p]     = (NTI > 0) ? ti_ack_q[p] : 1'b0;
      trig_in_acktype[p] = ti_at_q[p];
    end
    for (int q = 0; q < NO; q++) trig_out_req[q] = (NTO > 0) ? to_req_q[q] : 1'b0;
    st_ti_req = '0;
    st_to_ack = '0;
    st_ti_sel = '0;
    for (int p = 0; p < NI; p++) begin
      st_ti_req[p] = (NTI > 0) ? ti_req_s[p] : 1'b0;
      st_ti_sel[p] = ti_own[p] | ti_fin[p] | ti_deny[p];
    end
    for (int q = 0; q < NO; q++) st_to_ack[q] = (NTO > 0) ? to_ack_s[q] : 1'b0;
  end

endmodule : dma_trig_mtx
