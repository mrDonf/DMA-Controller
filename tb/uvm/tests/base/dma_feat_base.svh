//-----------------------------------------------------------------------------
// dma_feat_base.svh
//   Base class of the feature tests: descriptor area, link header builder, simple 1D
//   command, status polling.
//-----------------------------------------------------------------------------
class dma_feat_base extends dma_base_test;
  `uvm_component_utils(dma_feat_base)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // descriptor area of a channel (M0 region, outside all data windows)
  function longint unsigned dsc_base(int ch);
    return 64'h0300_0000 + longint'(ch) * 64'h0001_0000;
  endfunction

  // write a descriptor into memory and allow the DMA to read it
  function void put_desc(longint unsigned a, bit [31:0] words[$]);
    foreach (words[i])
      for (int b = 0; b < 4; b++) env.mem.write_byte(a + 4 * i + b, words[i][8*b +: 8]);
    env.sb.allow_link_read(a, 4 * words.size());
  endfunction

  // header for loading `nxt` after `prv` was executed (dynamic registers are
  // always reloaded, the others only when they differ)
  function bit [31:0] link_header(dma_cmd prv, dma_cmd nxt, bit regclear);
    bit [31:0] h;
    if (regclear) return dma_cmd::full_header(TB_AW > 32);
    h = '0;
    for (int b = 2; b < 32; b++) begin
      if (!dma_cmd::is_link_reg(b)) continue;
      if (prv == null || prv.reg_value(4 * b) != nxt.reg_value(4 * b)) h[b] = 1'b1;
    end
    h[4] = 1; h[6] = 1; h[8] = 1; h[9] = 1; h[15] = 1;           // addresses / sizes
    if (TB_AW > 32) begin h[5] = 1; h[7] = 1; h[31] = 1; end
    else if ($urandom_range(3) == 0) h[5] = 1;                    // HI words are skipped when AW = 32
    return h;
  endfunction

  // simple 1D command
  function dma_cmd simple(int ch, int nbytes, int ts = -1);
    dma_cmd c = dma_cmd::type_id::create("simple");
    c.ch = ch;
    c.ts = (ts < 0) ? $urandom_range(0, $clog2(TB_DWB)) : ((ts > $clog2(TB_DWB)) ? $clog2(TB_DWB) : ts);
    c.xtype = T_CONTINUE;
    c.srcxsize = (nbytes >> c.ts) > 0 ? (nbytes >> c.ts) : 1;
    c.desxsize = c.srcxsize;
    c.src_maxburst = $urandom_range(3, 15);
    c.des_maxburst = $urandom_range(3, 15);
    c.srcaddr = win_base(ch, 0, 0) + ($urandom_range(0, 'h8000) & ~((1 << c.ts) - 1));
    c.desaddr = win_base(ch, 1, 0) + ($urandom_range(0, 'h8000) & ~((1 << c.ts) - 1));
    return c;
  endfunction

  task wait_status_bit(int ch, int bitn, bit val = 1, int timeout = 200000);
    bit [31:0] st;
    int t = 0;
    do begin
      regs.chr(ch, CH_STATUS, st);
      t++;
      if (st[bitn] !== val) repeat (10) @(posedge vif.clk);
    end while (st[bitn] !== val && t < timeout / 10);
    if (st[bitn] !== val) `uvm_error("TEST", $sformatf("ch%0d STATUS[%0d] never became %0d (%08h)", ch, bitn, val, st))
  endtask
endclass
