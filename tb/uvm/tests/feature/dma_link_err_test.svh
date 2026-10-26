//-----------------------------------------------------------------------------
// dma_link_err_test.svh
//   Invalid command link headers (zero / reserved bits) -> CFGERR + LINKHDRERR.
//-----------------------------------------------------------------------------
class dma_link_err_test extends dma_feat_base;
  `uvm_component_utils(dma_link_err_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [31:0] ei;
    for (int k = 0; k < 3; k++) begin
      int ch = k % TB_NCH;
      dma_cmd c = simple(ch, 64);
      bit [31:0] w[$];
      c.linkaddren = 1;
      c.linkaddr = dsc_base(ch) + 'h40;
      w.push_back((k == 0) ? 32'h0 : (k == 1) ? 32'h0080_0010 : 32'h0000_0002);   // zero / reserved bits
      w.push_back(32'h1234_5678);
      put_desc(c.linkaddr, w);
      init_src(c);
      void'(expect_cmd(c));
      regs.program_cmd(c);
      regs.enable(ch);
      begin
        bit [31:0] st;
        regs.wait_idle(ch, st);
        regs.chr(ch, CH_ERRINFO, ei);                 // read before the status clear
        if ((st & 32'h000F_0000) != ((1 << ST_DONE) | (1 << ST_ERR)) || ei != 32'h0100_0002)
          `uvm_error("TEST", $sformatf("header %08h: status %08h ERRINFO %08h, expected ERR+DONE / 01000002",
                                       w[0], st, ei))
        void'(env.sb.check_done(ch, tname));
        env.sb.clear_reads(ch);
        regs.clear_status(ch);
        n_cmds++;
      end
    end
  endtask
endclass
