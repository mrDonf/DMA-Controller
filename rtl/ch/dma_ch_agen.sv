//-----------------------------------------------------------------------------
// dma_ch_agen.sv
// Address / burst generator for one side (read or write) of a DMA channel.
//
// The command is decomposed into LINES (segments that bursts never cross):
//   read  model A (XTYPE continue)  : source lines of SX elements, cyclic over
//                                     SY lines when YTYPE=wrap, until TOT reads
//   read  model B (XTYPE wrap/fill) : one segment per destination line holding
//                                     LCNT reads, cycling every SX elements
//   write model A (XTYPE continue)  : destination lines of DX slots; the first
//                                     TOT slots are data, the rest fill (YTYPE
//                                     fill) or the command ends
//   write model B (XTYPE wrap/fill) : per destination line LCNT data slots,
//                                     then fill slots (XTYPE fill)
//
// Each step produces one AXI burst descriptor, limited by: line end, source
// wrap point, data/fill boundary, trigger block, runtime data limit,
// MAXBURSTLEN, FIFO/2, 1KB boundary and the bandwidth optimisation rules of
// TRM 4.3.6 (wide beats on normal memory with unit increment).
//
// Timing structure: registered state S_cur, registered descriptor D and the
// registered post-descriptor state S_nxt. The step logic is a single
// combinational cloud evaluated from a registered state:
//   * D invalid  : (D,S_nxt) <= step(S_cur)
//   * D popped   : S_cur <= S_nxt ; (D,S_nxt) <= step(S_nxt)   (fast path,
//                  one descriptor per cycle)
//   * recompute  : D dropped, recomputed from S_cur (runtime limit changed)
//-----------------------------------------------------------------------------
module dma_ch_agen
  import dma_pkg::*;
#(
  parameter int  AW         = 32,
  parameter int  DW         = 64,
  parameter bit  IS_WR      = 1'b0,
  parameter int  HALF_BYTES = 64     // FIFO capacity / 2 in bytes
) (
  input  logic            clk,
  input  logic            resetn,
  input  logic            clr,          // channel clear: forget all state

  // ---------------- command configuration (stable while active)
  input  logic            start,        // load configuration, begin
  input  logic            abort,        // stop generating (stop / error)
  input  logic [AW-1:0]   i_base,
  input  logic [2:0]      i_ts,
  input  logic [15:0]     i_inc,
  input  logic [AW-1:0]   i_stride_b,   // line stride in bytes (0 for 1D)
  input  logic            i_tmpl_en,
  input  logic [31:0]     i_tmpl,
  input  logic [4:0]      i_tsize,
  input  logic            i_opt,        // normal memory -> optimisation allowed
  input  logic [4:0]      i_maxbeats,   // 1..16
  input  logic            i_modelb,
  input  logic            i_is2d,
  input  logic            i_xwrap,
  input  logic            i_xfill,
  input  logic            i_ywrap,
  input  logic            i_fill_empty, // (wr) lines without source -> fill
  input  logic            i_src_nonempty,
  input  logic [31:0]     i_sx,
  input  logic [15:0]     i_sy,
  input  logic [31:0]     i_dx,
  input  logic [15:0]     i_lines,
  input  logic [47:0]     i_tot,
  input  logic [31:0]     i_lcnt,

  // ---------------- runtime control
  input  logic            run,          // allowed to compute (not paused)
  input  logic            fast_ok,      // allow back-to-back fast path
  input  logic            blk_en,       // flow-control block limit active
  input  logic [8:0]      blk_rem,      // elements left in granted block
  input  logic            dlim_en,      // (wr) runtime data limit active
  input  logic [9:0]      dlim,         // (wr) data elements available (sat)
  input  logic            exhaust,      // (wr) producer final & no data left
  input  logic            recompute,

  // ---------------- descriptor output
  output logic            d_valid,
  input  logic            d_pop,
  output logic [AW-1:0]   d_addr,
  output logic [7:0]      d_len,
  output logic [2:0]      d_size,
  output logic [1:0]      d_burst,
  output logic [8:0]      d_nb,         // bytes moved (data or fill)
  output logic [8:0]      d_nelem,
  output logic            d_fill,
  output logic            d_last,       // final descriptor of this side

  // ---------------- status
  output logic            active,       // side has work left (incl. pending D)
  output logic [AW-1:0]   st_addr,
  output logic [31:0]     st_xrem,
  output logic [15:0]     st_yrem,
  output logic [AW-1:0]   st_lbase
);

  localparam int DWB = DW / 8;
  localparam int LB  = $clog2(DWB);

  // --------------------------------------------------------------------------
  // static configuration registers (captured at start)
  // --------------------------------------------------------------------------
  logic [2:0]    c_ts;
  logic [15:0]   c_inc;
  logic [AW-1:0] c_stride, c_first;
  logic          c_tmpl_en, c_opt, c_modelb, c_is2d, c_xwrap, c_xfill, c_ywrap;
  logic          c_fill_empty, c_src_nonempty;
  logic [31:0]   c_tmpl;
  logic [4:0]    c_tsize, c_maxbeats;
  logic [31:0]   c_sx, c_dx, c_lcnt;
  logic [15:0]   c_sy;
  logic [1:0]    c_mode;       // 0 contig, 1 fixed, 2 single, 3 template

  localparam logic [1:0] M_CONTIG = 2'd0, M_FIXED = 2'd1, M_SINGLE = 2'd2, M_TMPL = 2'd3;

  // --------------------------------------------------------------------------
  // dynamic state
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic          act;      // side still active
    logic          exh;      // (wr) data exhausted -> fill / end
    logic [AW-1:0] addr;     // next element address
    logic [AW-1:0] tbase;    // template block base
    logic [4:0]    tpos;     // template bit position
    logic [AW-1:0] lbase;    // current line base
    logic [31:0]   k_rem;    // slots left in current line
    logic [31:0]   d_rem;    // (wr) data slots left in current line
    logic [31:0]   c_rem;    // (rd) elements left before source wrap
    logic [15:0]   j_rem;    // lines left including current
    logic [15:0]   ly_rem;   // source lines left including current
    logic [47:0]   t_rem;    // model A remaining total after current line
  } st_t;

  st_t s_cur, s_nxt, si, so;

  // descriptor computed by the step logic
  logic [AW-1:0] n_addr;
  logic [7:0]    n_len;
  logic [2:0]    n_size;
  logic [1:0]    n_burst;
  logic [8:0]    n_nb, n_nelem;
  logic          n_fill, n_last, n_ok;

  // --------------------------------------------------------------------------
  // helpers
  // --------------------------------------------------------------------------
  function automatic logic [9:0] sat10(input logic [47:0] v);
    return (|v[47:10]) ? 10'h3FF : v[9:0];
  endfunction

  function automatic logic [9:0] min10(input logic [9:0] a, input logic [9:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [11:0] min12(input logic [11:0] a, input logic [11:0] b);
    return (a < b) ? a : b;
  endfunction

  function automatic logic [31:0] min32(input logic [31:0] a, input logic [47:0] b);
    return (|b[47:32] || (b[31:0] > a)) ? a : b[31:0];
  endfunction

  // --------------------------------------------------------------------------
  // STEP : combinational, from state si
  // --------------------------------------------------------------------------
  logic        wr_fill_now;      // this burst is fill
  logic        wr_end_now;       // (wr) data exhausted & no fill -> side ends
  logic [9:0]  lim_e;
  logic [11:0] lim_b, to1k, half_b, cap, mb_b, mb_w;
  logic [LB-1:0] a_lo;
  logic [4:0]  next_tbit;
  logic        tbit_found;

  // line advance results
  logic [AW-1:0] nl_lbase;
  logic [15:0]   nl_ly_rem;
  logic [31:0]   nl_k, nl_d, nl_c;
  logic [47:0]   nl_t;
  logic          nl_more;
  logic          nl_hassrc;

  always_comb begin
    so       = si;
    n_addr   = si.addr;
    n_len    = '0;
    n_size   = c_ts;
    n_burst  = AXI_INCR;
    n_nb     = '0;
    n_nelem  = '0;
    n_fill   = 1'b0;
    n_last   = 1'b0;
    n_ok     = 1'b0;
    wr_fill_now = 1'b0;
    wr_end_now  = 1'b0;
    lim_e    = '0;
    lim_b    = '0;
    cap      = '0;
    a_lo     = si.addr[LB-1:0];
    to1k     = 12'd1024 - {2'b00, si.addr[9:0]};
    half_b   = 12'(HALF_BYTES);
    mb_b     = 12'(c_maxbeats) << c_ts;            // max bytes, narrow beats
    mb_w     = (12'(c_maxbeats) << LB) - 12'(a_lo); // max bytes, wide beats
    next_tbit  = '0;
    tbit_found = 1'b0;

    // ---------------- line advance (computed in parallel with the burst)
    // Y wrap restarts the SOURCE lines only; destination lines always advance
    nl_lbase  = (!IS_WR && c_ywrap && si.ly_rem == 16'd1) ? c_first : (si.lbase + c_stride);
    nl_ly_rem = (si.ly_rem == 16'd1) ? (c_ywrap ? c_sy : 16'd0)
                                      : ((si.ly_rem == 16'd0) ? 16'd0 : si.ly_rem - 1'b1);
    nl_k      = '0;
    nl_d      = '0;
    nl_c      = c_sx;
    nl_t      = si.t_rem;
    nl_more   = 1'b0;
    nl_hassrc = 1'b0;
    if (!IS_WR) begin
      if (!c_modelb) begin
        nl_k    = min32(c_sx, si.t_rem);
        nl_t    = si.t_rem - {16'd0, nl_k};
        nl_more = (si.t_rem != 48'd0);
      end else begin
        nl_k    = c_lcnt;
        nl_more = (si.j_rem > 16'd1);
      end
    end else begin
      if (!c_modelb) begin
        nl_d    = si.exh ? 32'd0 : min32(c_dx, si.t_rem);
        nl_k    = c_fill_empty ? c_dx : nl_d;
        nl_t    = si.t_rem - {16'd0, nl_d};
        nl_more = (si.j_rem > 16'd1) && (nl_k != 32'd0);
      end else begin
        nl_hassrc = c_src_nonempty && !si.exh && (c_ywrap || nl_ly_rem != 16'd0);
        nl_d      = nl_hassrc ? c_lcnt : 32'd0;
        nl_k      = nl_hassrc ? ((c_xwrap || c_xfill) ? c_dx : c_lcnt)
                              : (c_fill_empty ? c_dx : 32'd0);
        nl_more   = (si.j_rem > 16'd1) && (nl_k != 32'd0);
      end
    end

    // ---------------- template: next set bit after tpos within tsize
    for (int b = 31; b >= 1; b--) begin
      if (c_tmpl[b] && (b > si.tpos) && (b <= c_tsize)) begin
        next_tbit  = b[4:0];
        tbit_found = 1'b1;
      end
    end

    // ---------------- element limit
    if (IS_WR) begin
      wr_fill_now = (si.d_rem == 32'd0) || si.exh;
      if (!wr_fill_now && exhaust) begin
        // producer finished: remaining data slots become fill or end the side
        if (c_fill_empty) wr_fill_now = 1'b1;
        else              wr_end_now  = 1'b1;
      end
    end

    lim_e = sat10({16'd0, si.k_rem});
    if (IS_WR && !wr_fill_now)            lim_e = min10(lim_e, sat10({16'd0, si.d_rem}));
    if (!IS_WR && c_modelb && c_xwrap)    lim_e = min10(lim_e, sat10({16'd0, si.c_rem}));
    if (blk_en)                           lim_e = min10(lim_e, {1'b0, blk_rem});
    if (IS_WR && dlim_en && !wr_fill_now) lim_e = min10(lim_e, dlim);

    // ---------------- burst shaping
    if (si.act && !wr_end_now && lim_e != 10'd0) begin
      n_ok   = 1'b1;
      n_fill = wr_fill_now;
      case (c_mode)
        M_SINGLE, M_TMPL: begin
          n_nelem = 9'd1;
          n_nb    = 9'd1 << c_ts;
          n_len   = 8'd0;
          n_size  = c_ts;
        end
        M_FIXED: begin
          logic [9:0] fe;
          fe = min10(lim_e, {5'd0, c_maxbeats});
          fe = min10(fe, 10'(HALF_BYTES >> 0) >> c_ts);
          if (fe == 10'd0) fe = 10'd1;
          n_nelem = fe[8:0];
          n_nb    = 9'(fe << c_ts);
          n_len   = 8'(fe - 1'b1);
          n_size  = c_ts;
          n_burst = AXI_FIXED;
        end
        default: begin // M_CONTIG
          lim_b = (lim_e > (10'h3FF >> c_ts)) ? 12'hFFF : (12'(lim_e) << c_ts);
          if (!c_opt) begin
            cap     = min12(min12(lim_b, to1k), min12(half_b, mb_b));
            n_nb    = cap[8:0];
            n_size  = c_ts;
            n_len   = 8'((cap >> c_ts) - 1'b1);
          end else if (IS_WR) begin
            cap     = min12(min12(lim_b, to1k), min12(half_b, mb_w));
            n_nb    = cap[8:0];
            n_size  = 3'(LB);
            n_len   = 8'(((12'(a_lo) + cap + 12'(DWB-1)) >> LB) - 1'b1);
          end else begin
            cap = min12(min12(lim_b, to1k), min12(half_b, mb_w));
            if (a_lo != '0) begin
              if (cap >= (12'(DWB) - 12'(a_lo))) begin
                logic [11:0] endb;
                endb   = 12'(a_lo) + cap;
                endb   = endb & ~12'(DWB-1);
                n_nb   = 9'(endb - 12'(a_lo));
                n_size = 3'(LB);
                n_len  = 8'((endb >> LB) - 1'b1);
              end else begin
                logic [11:0] c2;
                c2     = min12(cap, mb_b);
                n_nb   = c2[8:0];
                n_size = c_ts;
                n_len  = 8'((c2 >> c_ts) - 1'b1);
              end
            end else begin
              if (cap >= 12'(DWB)) begin
                n_nb   = 9'(cap & ~12'(DWB-1));
                n_size = 3'(LB);
                n_len  = 8'((cap >> LB) - 1'b1);
              end else begin
                // aligned tail shorter than the bus: largest power of two
                n_size = c_ts;
                for (int s = 0; s <= LB; s++)
                  if ((12'(1) << s) <= cap && s >= c_ts) n_size = 3'(s);
                n_nb  = 9'(1) << n_size;
                n_len = 8'd0;
              end
            end
          end
          n_nelem = n_nb >> c_ts;
        end
      endcase

      // ---------------- state advance
      case (c_mode)
        M_CONTIG: so.addr = si.addr + AW'(n_nb);
        M_FIXED : so.addr = si.addr;
        M_SINGLE: so.addr = si.addr + (AW'({{(AW-16){c_inc[15]}}, c_inc}) << c_ts);
        default : begin // template
          if (tbit_found) begin
            so.tpos = next_tbit;
            so.addr = si.tbase + (AW'(next_tbit) << c_ts);
          end else begin
            so.tpos  = 5'd0;
            so.tbase = si.tbase + (AW'({1'b0, c_tsize} + 6'd1) << c_ts);
            so.addr  = so.tbase;
          end
        end
      endcase

      so.k_rem = si.k_rem - 32'(n_nelem);
      if (IS_WR) begin
        if (wr_fill_now) begin
          so.d_rem = 32'd0;
          if (!si.exh && si.d_rem != 32'd0) begin
            // converted data slots: count them as fill
            so.exh = 1'b1;
          end
        end else begin
          so.d_rem = si.d_rem - 32'(n_nelem);
        end
        if (exhaust && c_fill_empty) so.exh = 1'b1;
      end else begin
        so.c_rem = si.c_rem - 32'(n_nelem);
        if (c_modelb && c_xwrap && so.c_rem == 32'd0 && so.k_rem != 32'd0) begin
          // source wrap inside the destination line
          so.addr  = si.lbase;
          so.tbase = si.lbase;
          so.tpos  = 5'd0;
          so.c_rem = c_sx;
        end
      end

      if (so.k_rem == 32'd0) begin
        // ---- end of line
        if (nl_more && !(IS_WR && wr_end_now)) begin
          so.lbase  = nl_lbase;
          so.addr   = nl_lbase;
          so.tbase  = nl_lbase;
          so.tpos   = 5'd0;
          so.k_rem  = nl_k;
          so.d_rem  = nl_d;
          so.c_rem  = nl_c;
          so.t_rem  = nl_t;
          so.j_rem  = si.j_rem - 1'b1;
          so.ly_rem = nl_ly_rem;
        end else begin
          so.act    = 1'b0;
          n_last    = 1'b1;
          so.j_rem  = 16'd0;
          so.ly_rem = nl_ly_rem;
          // address after the final line (TRM tables 5-10 / 5-11)
          if (c_is2d || (!IS_WR && c_xwrap)) begin
            so.addr  = nl_lbase;
            so.lbase = nl_lbase;
          end
        end
      end
    end else if (si.act && IS_WR && wr_end_now) begin
      // data ended (stream tlast / peripheral LAST) and no fill: finish side
      so.act = 1'b0;
    end

    n_addr = si.addr;
  end

  // --------------------------------------------------------------------------
  // sequencing registers
  // --------------------------------------------------------------------------
  logic use_nxt;   // step input is S_nxt (fast path)
  logic do_pop, do_comp_cur, do_comp_nxt;

  assign do_pop      = d_valid & d_pop;
  assign do_comp_nxt = do_pop & fast_ok & run & ~recompute & s_nxt.act;
  assign do_comp_cur = (~d_valid | recompute) & ~do_pop & run & s_cur.act;
  assign use_nxt     = do_pop;

  always_comb si = use_nxt ? s_nxt : s_cur;

  // initial state from configuration
  st_t s_init;
  always_comb begin
    s_init        = '0;
    s_init.addr   = i_base;
    s_init.tbase  = i_base;
    s_init.lbase  = i_base;
    s_init.tpos   = 5'd0;
    s_init.ly_rem = i_sy;
    s_init.j_rem  = i_lines;
    s_init.c_rem  = i_sx;
    if (!IS_WR) begin
      if (!i_modelb) begin
        s_init.k_rem = min32(i_sx, i_tot);
        s_init.t_rem = i_tot - {16'd0, s_init.k_rem};
        s_init.j_rem = 16'hFFFF;
      end else begin
        s_init.k_rem = (i_lines != 16'd0) ? i_lcnt : 32'd0;
      end
    end else begin
      if (!i_modelb) begin
        s_init.d_rem = min32(i_dx, i_tot);
        s_init.k_rem = i_fill_empty ? i_dx : s_init.d_rem;
        s_init.t_rem = i_tot - {16'd0, s_init.d_rem};
      end else begin
        logic hs;
        hs = i_src_nonempty && (i_ywrap || i_sy != 16'd0);
        s_init.d_rem = hs ? i_lcnt : 32'd0;
        s_init.k_rem = hs ? ((i_xwrap || i_xfill) ? i_dx : i_lcnt)
                          : (i_fill_empty ? i_dx : 32'd0);
      end
      if (i_lines == 16'd0) s_init.k_rem = 32'd0;
    end
    s_init.act = (s_init.k_rem != 32'd0);
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      s_cur   <= '0;
      s_nxt   <= '0;
      d_valid <= 1'b0;
    end else if (clr) begin
      s_cur   <= '0;
      s_nxt   <= '0;
      d_valid <= 1'b0;
    end else if (start) begin
      s_cur   <= s_init;
      s_nxt   <= '0;
      d_valid <= 1'b0;
    end else if (abort) begin
      s_cur.act <= 1'b0;
      d_valid   <= 1'b0;
    end else begin
      if (do_pop) s_cur <= s_nxt;

      if (do_comp_nxt || do_comp_cur) begin
        if (n_ok) begin
          d_valid <= 1'b1;
          s_nxt   <= so;
        end else begin
          d_valid <= 1'b0;
          // side may terminate without a descriptor (data exhausted)
          if (!so.act) begin
            if (do_comp_nxt) s_cur     <= so;
            else             s_cur.act <= 1'b0;
          end
        end
      end else if (do_pop || recompute) begin
        d_valid <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if ((do_comp_nxt || do_comp_cur) && n_ok) begin
      d_addr  <= n_addr;
      d_len   <= n_len;
      d_size  <= n_size;
      d_burst <= n_burst;
      d_nb    <= n_nb;
      d_nelem <= n_nelem;
      d_fill  <= n_fill;
      d_last  <= n_last;
    end
  end

  // --------------------------------------------------------------------------
  // configuration capture
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      c_ts <= '0; c_inc <= '0; c_stride <= '0; c_first <= '0;
      c_tmpl_en <= 1'b0; c_opt <= 1'b0; c_modelb <= 1'b0; c_is2d <= 1'b0;
      c_xwrap <= 1'b0; c_xfill <= 1'b0; c_ywrap <= 1'b0; c_fill_empty <= 1'b0;
      c_src_nonempty <= 1'b0; c_tmpl <= '0; c_tsize <= '0; c_maxbeats <= 5'd1;
      c_sx <= '0; c_dx <= '0; c_lcnt <= '0; c_sy <= '0; c_mode <= M_CONTIG;
    end else if (start) begin
      c_ts           <= i_ts;
      c_inc          <= i_inc;
      c_stride       <= i_stride_b;
      c_first        <= i_base;
      c_tmpl_en      <= i_tmpl_en;
      c_opt          <= i_opt & ~i_tmpl_en & (i_inc == 16'd1);
      c_modelb       <= i_modelb;
      c_is2d         <= i_is2d;
      c_xwrap        <= i_xwrap;
      c_xfill        <= i_xfill;
      c_ywrap        <= i_ywrap;
      c_fill_empty   <= i_fill_empty;
      c_src_nonempty <= i_src_nonempty;
      c_tmpl         <= i_tmpl | 32'd1;
      c_tsize        <= i_tsize;
      c_maxbeats     <= (i_maxbeats == 5'd0) ? 5'd1 : i_maxbeats;
      c_sx           <= i_sx;
      c_dx           <= i_dx;
      c_lcnt         <= i_lcnt;
      c_sy           <= i_sy;
      c_mode         <= i_tmpl_en           ? M_TMPL  :
                        (i_inc == 16'd1)    ? M_CONTIG :
                        (i_inc == 16'd0)    ? M_FIXED  : M_SINGLE;
    end
  end

  // --------------------------------------------------------------------------
  // status
  // --------------------------------------------------------------------------
  assign active   = s_cur.act | d_valid;
  assign st_addr  = s_cur.addr;
  assign st_xrem  = s_cur.k_rem;
  assign st_yrem  = (!IS_WR && !c_modelb) ? s_cur.ly_rem : s_cur.j_rem;
  assign st_lbase = s_cur.lbase;

endmodule : dma_ch_agen
