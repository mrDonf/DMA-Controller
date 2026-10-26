//-----------------------------------------------------------------------------
// dma_cmd.svh - one DMA channel command (all programmable fields) and its
// encodings: register image, command link descriptor.
//-----------------------------------------------------------------------------
class dma_cmd extends uvm_object;
  `uvm_object_utils(dma_cmd)

  int              ch;
  // CH_CTRL
  bit [2:0]        ts         = 0;
  bit [3:0]        prio       = 0;
  bit [2:0]        xtype      = T_CONTINUE;
  bit [2:0]        ytype      = T_DISABLE;
  bit [2:0]        regreload  = 0;
  bit [2:0]        donetype   = 3'b001;
  bit              donepause  = 0;
  bit              use_srctrig, use_destrig, use_trigout, use_gpo, use_stream;
  // addresses / sizes
  longint unsigned srcaddr, desaddr;
  bit [31:0]       srcxsize, desxsize;
  bit [15:0]       srcysize, desysize;
  // transfer configuration
  bit [7:0]        src_memattr = 8'h44, des_memattr = 8'h44;
  bit [1:0]        src_share = 0, des_share = 0;
  bit              src_nonsec = 1, des_nonsec = 1, src_priv = 0, des_priv = 0;
  bit [3:0]        src_maxburst = 4'hF, des_maxburst = 4'hF;
  bit [15:0]       srcxinc = 1, desxinc = 1, srcystride = 0, desystride = 0;
  bit [31:0]       fillval;
  bit [31:0]       srctmplt = 1, destmplt = 1;
  bit [4:0]        srctsize = 0, destsize = 0;
  // triggers
  bit [7:0]        srctrig_sel, destrig_sel, srctrig_blk, destrig_blk;
  bit [1:0]        srctrig_type, destrig_type, srctrig_mode, destrig_mode;
  bit [5:0]        trigout_sel;
  bit [1:0]        trigout_type;
  // GPO / stream
  bit [31:0]       gpoen, gpoval;
  bit [1:0]        streamtype;
  // link / auto restart
  bit [9:0]        linkattr = 10'h044;
  bit [15:0]       restartcnt;
  bit              restartinf;
  longint unsigned linkaddr;
  bit              linkaddren;
  bit [10:0]       intren = 11'h00F;

  function new(string name = "dma_cmd");
    super.new(name);
  endfunction

  function int esize();
    return 1 << ts;
  endfunction

  function bit is2d();
    return ytype != T_DISABLE;
  endfunction

  // ---------------------------------------------------------------- register image
  function bit [31:0] reg_value(int off);
    bit [31:0] v;
    v = '0;
    case (off)
      CH_INTREN:      v = {21'd0, intren};
      CH_CTRL:        v = {2'b00, use_stream, use_gpo, use_trigout, use_destrig, use_srctrig, donepause,
                           donetype, regreload, 3'b000, ytype, xtype, 1'b0, prio, 1'b0, ts};
      CH_SRCADDR:     v = srcaddr[31:0];
      CH_SRCADDRHI:   v = srcaddr[63:32];
      CH_DESADDR:     v = desaddr[31:0];
      CH_DESADDRHI:   v = desaddr[63:32];
      CH_XSIZE:       v = {desxsize[15:0], srcxsize[15:0]};
      CH_XSIZEHI:     v = {desxsize[31:16], srcxsize[31:16]};
      CH_SRCTRANSCFG: v = {12'd0, src_maxburst, 4'd0, src_priv, src_nonsec, src_share, src_memattr};
      CH_DESTRANSCFG: v = {12'd0, des_maxburst, 4'd0, des_priv, des_nonsec, des_share, des_memattr};
      CH_XADDRINC:    v = {desxinc, srcxinc};
      CH_YADDRSTRIDE: v = {desystride, srcystride};
      CH_FILLVAL:     v = fillval;
      CH_YSIZE:       v = {desysize, srcysize};
      CH_TMPLTCFG:    v = {11'd0, destsize, 3'd0, srctsize, 8'd0};
      CH_SRCTMPLT:    v = srctmplt;
      CH_DESTMPLT:    v = destmplt;
      CH_SRCTRIGINCFG: v = {8'd0, srctrig_blk, 4'd0, srctrig_mode, srctrig_type, srctrig_sel};
      CH_DESTRIGINCFG: v = {8'd0, destrig_blk, 4'd0, destrig_mode, destrig_type, destrig_sel};
      CH_TRIGOUTCFG:  v = {22'd0, trigout_type, 2'b00, trigout_sel};
      CH_GPOEN0:      v = gpoen;
      CH_GPOVAL0:     v = gpoval;
      CH_STREAMINTCFG: v = {21'd0, streamtype, 9'd0};
      CH_LINKATTR:    v = {22'd0, linkattr};
      CH_AUTOCFG:     v = {15'd0, restartinf, restartcnt};
      CH_LINKADDR:    v = {linkaddr[31:2], 1'b0, linkaddren};
      CH_LINKADDRHI:  v = linkaddr[63:32];
      default:        v = '0;
    endcase
    return v;
  endfunction

  // registers loaded by command link, index = header bit (offset = 4*bit)
  static function bit is_link_reg(int bitn);
    return (bitn >= 2 && bitn <= 31) && !(bitn inside {23, 25, 27});
  endfunction

  // descriptor words for a header (bit 0 = REGCLEAR)
  function void descriptor(bit [31:0] header, ref bit [31:0] words[$]);
    words.delete();
    words.push_back(header);
    for (int b = 1; b < 32; b++)
      if (header[b]) words.push_back(reg_value(4 * b));
  endfunction

  // full header: every linkable register (+REGCLEAR)
  static function bit [31:0] full_header(bit with_hi = 0);
    bit [31:0] h;
    h = 32'h0000_0001;
    for (int b = 2; b < 32; b++) if (is_link_reg(b)) h[b] = 1'b1;
    if (!with_hi) begin h[5] = 0; h[7] = 0; h[31] = 0; end
    return h;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    dma_cmd r;
    super.do_copy(rhs);
    $cast(r, rhs);
    ch = r.ch; ts = r.ts; prio = r.prio; xtype = r.xtype; ytype = r.ytype; regreload = r.regreload;
    donetype = r.donetype; donepause = r.donepause; use_srctrig = r.use_srctrig; use_destrig = r.use_destrig;
    use_trigout = r.use_trigout; use_gpo = r.use_gpo; use_stream = r.use_stream;
    srcaddr = r.srcaddr; desaddr = r.desaddr; srcxsize = r.srcxsize; desxsize = r.desxsize;
    srcysize = r.srcysize; desysize = r.desysize; src_memattr = r.src_memattr; des_memattr = r.des_memattr;
    src_share = r.src_share; des_share = r.des_share; src_nonsec = r.src_nonsec; des_nonsec = r.des_nonsec;
    src_priv = r.src_priv; des_priv = r.des_priv; src_maxburst = r.src_maxburst; des_maxburst = r.des_maxburst;
    srcxinc = r.srcxinc; desxinc = r.desxinc; srcystride = r.srcystride; desystride = r.desystride;
    fillval = r.fillval; srctmplt = r.srctmplt; destmplt = r.destmplt; srctsize = r.srctsize; destsize = r.destsize;
    srctrig_sel = r.srctrig_sel; destrig_sel = r.destrig_sel; srctrig_blk = r.srctrig_blk; destrig_blk = r.destrig_blk;
    srctrig_type = r.srctrig_type; destrig_type = r.destrig_type; srctrig_mode = r.srctrig_mode;
    destrig_mode = r.destrig_mode; trigout_sel = r.trigout_sel; trigout_type = r.trigout_type;
    gpoen = r.gpoen; gpoval = r.gpoval; streamtype = r.streamtype; linkattr = r.linkattr;
    restartcnt = r.restartcnt; restartinf = r.restartinf; linkaddr = r.linkaddr; linkaddren = r.linkaddren;
    intren = r.intren;
  endfunction

  virtual function string convert2string();
    string s;
    s = $sformatf("ch%0d ts=%0d x=%0d y=%0d src=%0h des=%0h sx=%0d dx=%0d sy=%0d dy=%0d sinc=%0d dinc=%0d ss=%0d ds=%0d",
                  ch, ts, xtype, ytype, srcaddr, desaddr, srcxsize, desxsize, srcysize, desysize,
                  $signed(srcxinc), $signed(desxinc), $signed(srcystride), $signed(desystride));
    s = {s, $sformatf(" attr=%0h/%0h mb=%0d/%0d tmpl=%0d:%0h/%0d:%0h", src_memattr, des_memattr,
                      src_maxburst, des_maxburst, srctsize, srctmplt, destsize, destmplt)};
    if (use_stream)  s = {s, $sformatf(" STREAM=%0d", streamtype)};
    if (use_srctrig) s = {s, $sformatf(" STRIG(t%0d m%0d s%0d b%0d)", srctrig_type, srctrig_mode, srctrig_sel, srctrig_blk)};
    if (use_destrig) s = {s, $sformatf(" DTRIG(t%0d m%0d s%0d b%0d)", destrig_type, destrig_mode, destrig_sel, destrig_blk)};
    if (use_trigout) s = {s, $sformatf(" TOUT(t%0d s%0d)", trigout_type, trigout_sel)};
    if (linkaddren)  s = {s, $sformatf(" LINK=%0h", linkaddr)};
    if (restartinf || restartcnt != 0) s = {s, $sformatf(" RESTART=%0d/%0d rl=%0d", restartinf, restartcnt, regreload)};
    return s;
  endfunction
endclass : dma_cmd
