//-----------------------------------------------------------------------------
// dma_ref_model.svh - reference model of a DMA command (element level, written
// directly from the TRM rules, independent from the RTL implementation).
//
// Produces the ordered list of destination byte writes, the stream-out bytes
// and the set of source bytes the DMA may read.
//-----------------------------------------------------------------------------
class dma_exp extends uvm_object;
  `uvm_object_utils(dma_exp)
  int              ch;
  bit              rd_active, wr_active;
  longint unsigned wr_addr[$];          // expected byte writes, in order
  byte unsigned    wr_data[$];
  byte unsigned    so_bytes[$];         // expected stream-out packet
  bit              rd_ok [longint unsigned];
  int unsigned     n_src_elem, n_dst_slot, n_fill;
  function new(string name = "dma_exp"); super.new(name); endfunction
endclass : dma_exp

class dma_ref_model;

  static function longint unsigned amask(longint unsigned a);
    if (TB_AW >= 64) return a;
    return a & ((64'h1 << TB_AW) - 1);
  endfunction

  // address of element x of line `line` on one side (TRM 5.2 / 5.3)
  static function longint unsigned elem_addr(longint unsigned base, bit [15:0] stride, longint unsigned line,
                                             longint unsigned x, bit [15:0] inc, bit [4:0] tsz, bit [31:0] tm,
                                             int esz, bit is2d);
    longint          sline, sinc;
    longint unsigned b;
    b = base & ~longint'(esz - 1);
    if (is2d) begin
      sline = longint'($signed(stride)) * longint'(line);
      b     = b + longint'(sline * esz);
    end
    if (tsz != 0) begin
      int pos[$];
      longint unsigned blk, idx;
      tm[0] = 1'b1;
      for (int i = 0; i <= tsz; i++) if (tm[i]) pos.push_back(i);
      blk = x / pos.size();
      idx = x % pos.size();
      return amask(b + (blk * (tsz + 1) + pos[idx]) * esz);
    end
    sinc = longint'($signed(inc));
    return amask(b + longint'(sinc * longint'(x) * esz));
  endfunction

  static function longint unsigned umin(longint unsigned a, longint unsigned b);
    return (a < b) ? a : b;
  endfunction

  static function byte unsigned fill_byte(bit [31:0] fv, int esz, int b);
    if (esz <= 4) return fv[8*b +: 8];
    return fv[8*(b % 4) +: 8];
  endfunction

  // si_bytes: stream-in data (stream in modes), whole packet
  static function dma_exp predict(dma_cmd c, vip_sparse_mem mem, byte unsigned si_bytes[$]);
    dma_exp e = new("exp");
    int esz;
    bit is2d, str_in, str_out, io, axi_src, axi_dst, a2a, srcempty, desempty, no_rd, no_wr;
    bit xwrap, xfill, ywrap, yfill, ycont;
    longint unsigned SX, DX, SY, DY;
    longint unsigned src_el[$];
    byte unsigned    data[$];
    typedef struct { longint unsigned a; bit f; } slot_t;
    slot_t           slots[$];

    e.ch  = c.ch;
    esz   = c.esize();
    is2d  = c.is2d();
    SX = c.srcxsize; DX = c.desxsize;
    SY = is2d ? c.srcysize : 1;
    DY = is2d ? c.desysize : 1;
    xwrap = (c.xtype == T_WRAP); xfill = (c.xtype == T_FILL);
    ywrap = is2d && (c.ytype == T_WRAP); yfill = is2d && (c.ytype == T_FILL); ycont = is2d && (c.ytype == T_CONTINUE);
    str_in  = c.use_stream && (c.streamtype == SM_INOUT || c.streamtype == SM_IN);
    str_out = c.use_stream && (c.streamtype == SM_INOUT || c.streamtype == SM_OUT);
    io      = c.use_stream && (c.streamtype == SM_INOUT);
    axi_src = !c.use_stream || (c.streamtype != SM_IN);
    axi_dst = !c.use_stream || (c.streamtype != SM_OUT);
    a2a     = !c.use_stream || io;
    srcempty = (SX == 0) || (is2d && SY == 0);
    desempty = (DX == 0) || (is2d && DY == 0);
    no_rd = (c.xtype == T_DISABLE) || (c.use_stream && c.streamtype == SM_IN) ||
            (axi_src && srcempty) || (a2a && desempty);
    no_wr = (c.xtype == T_DISABLE) || (c.use_stream && c.streamtype == SM_OUT) ||
            (axi_dst && desempty) ||
            (a2a && srcempty && ((is2d && c.ytype != T_FILL) || (!is2d && c.xtype != T_FILL)));
    e.rd_active = !no_rd;
    e.wr_active = !no_wr;

    // ---------------------------------------------------------------- source elements
    if (!no_rd) begin
      if (c.xtype == T_CONTINUE || str_out) begin
        longint unsigned total;
        total = ywrap ? DX * DY : SX * SY;
        for (longint unsigned k = 0; k < total; k++)
          src_el.push_back(elem_addr(c.srcaddr, c.srcystride, (k / SX) % SY, k % SX,
                                     c.srcxinc, c.srctsize, c.srctmplt, esz, is2d));
      end else begin
        longint unsigned L, nr;
        L  = is2d ? (ywrap ? DY : umin(SY, DY)) : 1;
        nr = xwrap ? DX : umin(SX, DX);
        for (longint unsigned j = 0; j < L; j++) begin
          longint unsigned s = ywrap ? (j % SY) : j;
          for (longint unsigned x = 0; x < nr; x++)
            src_el.push_back(elem_addr(c.srcaddr, c.srcystride, s, x % SX,
                                       c.srcxinc, c.srctsize, c.srctmplt, esz, is2d));
        end
      end
    end
    e.n_src_elem = src_el.size();
    foreach (src_el[i])
      for (int b = 0; b < esz; b++) begin
        longint unsigned a = amask(src_el[i] + b);
        e.rd_ok[a] = 1'b1;
        if (!str_in || io) data.push_back(mem.read_byte(a));
      end
    if (str_out) e.so_bytes = data;
    if (str_in)  data = si_bytes;

    // ---------------------------------------------------------------- destination slots
    if (!no_wr) begin
      if (c.xtype == T_CONTINUE) begin
        longint unsigned D;
        bit stop;
        D    = (str_in || ywrap) ? DX * DY : SX * SY;
        stop = 0;
        for (longint unsigned j = 0; j < DY && !stop; j++)
          for (longint unsigned x = 0; x < DX && !stop; x++) begin
            longint unsigned k = j * DX + x;
            longint unsigned a = elem_addr(c.desaddr, c.desystride, j, x, c.desxinc, c.destsize, c.destmplt, esz, is2d);
            if (k < D)      slots.push_back('{a, 1'b0});
            else if (yfill) slots.push_back('{a, 1'b1});
            else            stop = 1;
          end
      end else begin
        longint unsigned L, sy_eff, dcnt;
        bit srcne, fill_empty, stop;
        L          = (is2d && ycont) ? umin(SY, DY) : DY;
        sy_eff     = str_in ? DY : SY;
        srcne      = str_in || (SX > 0 && SY > 0);
        fill_empty = is2d ? yfill : xfill;
        stop       = 0;
        for (longint unsigned j = 0; j < L && !stop; j++) begin
          bit hassrc = srcne && (ywrap || j < sy_eff);
          if (hassrc) begin
            dcnt = (xwrap || str_in) ? DX : umin(SX, DX);
            for (longint unsigned x = 0; x < DX; x++) begin
              longint unsigned a = elem_addr(c.desaddr, c.desystride, j, x, c.desxinc, c.destsize, c.destmplt, esz, is2d);
              if (x < dcnt)      slots.push_back('{a, 1'b0});
              else if (xfill)    slots.push_back('{a, 1'b1});
              else               break;
            end
          end else if (fill_empty) begin
            for (longint unsigned x = 0; x < DX; x++)
              slots.push_back('{elem_addr(c.desaddr, c.desystride, j, x, c.desxinc, c.destsize, c.destmplt, esz, is2d), 1'b1});
          end else stop = 1;
        end
      end
    end

    // ---------------------------------------------------------------- data assignment
    begin
      int di;
      bit exhausted, fill_mode;
      di        = 0;
      exhausted = 0;
      fill_mode = is2d ? yfill : xfill;
      foreach (slots[i]) begin
        bit f = slots[i].f;
        if (!f && (exhausted || di + esz > data.size())) begin
          exhausted = 1;
          if (fill_mode) f = 1;
          else break;
        end
        e.n_dst_slot++;
        if (f) e.n_fill++;
        for (int b = 0; b < esz; b++) begin
          e.wr_addr.push_back(amask(slots[i].a + b));
          e.wr_data.push_back(f ? fill_byte(c.fillval, esz, b) : data[di + b]);
        end
        if (!f) di += esz;
      end
    end
    return e;
  endfunction

endclass : dma_ref_model
