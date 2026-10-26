//-----------------------------------------------------------------------------
// dma_dir_base.svh
//   Base class of the directed tests: fixed 4KB aligned bases, command builder, explicit
//   byte / traffic checks (drun).
//-----------------------------------------------------------------------------
class dma_dir_base extends dma_ctrl_base;
  `uvm_component_utils(dma_dir_base)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // 4KB aligned bases inside the channel windows: TRM offsets appear as is
  function longint unsigned sbase(int ch); return win_base(ch, 0, 0) + 64'h1000; endfunction
  function longint unsigned dbase(int ch); return win_base(ch, 1, 0) + 64'h1000; endfunction

  function dma_cmd mk(int ch, int ts, longint src_off, longint dst_off, int n = 1, bit normal = 1);
    dma_cmd c = dma_cmd::type_id::create("dcmd");
    c.ch = ch; c.ts = ts; c.xtype = T_CONTINUE;
    c.srcaddr = sbase(ch) + src_off;
    c.desaddr = dbase(ch) + dst_off;
    c.srcxsize = n; c.desxsize = n;
    c.src_memattr = normal ? 8'h44 : 8'h00;
    c.des_memattr = normal ? 8'h44 : 8'h00;
    c.fillval = 32'hA5C3_9617;
    return c;
  endfunction

  function byte unsigned m(longint unsigned a); return env.mem.read_byte(a); endfunction

  function void chk(bit cond, string msg);
    if (!cond) `uvm_error("DIRECTED", msg)
  endfunction

  // run a command; returns the number of bytes written and checks it
  // against the explicit expectation (exp_bytes < 0: no explicit check)
  task drun(dma_cmd c, int exp_bytes = -1, string tag = "", byte unsigned si[$] = {});
    int w0 = env.sb.n_wr_bytes, r0 = env.sb.n_rd_bursts;
    dma_exp e;
    `uvm_info("DIR", $sformatf("%s : %s", tag, c.convert2string()), UVM_LOW)
    e = expect_cmd(c, si);
    regs.program_cmd(c);
    regs.enable(c.ch);
    finish_cmd(c);
    if (exp_bytes >= 0) begin
      chk(env.sb.n_wr_bytes - w0 == exp_bytes,
          $sformatf("%s: %0d bytes written, expected %0d", tag, env.sb.n_wr_bytes - w0, exp_bytes));
      chk(e.wr_addr.size() == exp_bytes,
          $sformatf("%s: reference model predicts %0d bytes, TRM rule gives %0d", tag, e.wr_addr.size(), exp_bytes));
    end
    if (!e.rd_active) chk(env.sb.n_rd_bursts == r0, $sformatf("%s: reads issued by an empty source", tag));
  endtask
endclass
