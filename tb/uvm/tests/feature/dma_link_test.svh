//-----------------------------------------------------------------------------
// dma_link_test.svh
//   Command link chains with random headers (REGCLEAR / partial updates).
//-----------------------------------------------------------------------------
class dma_link_test extends dma_feat_base;
  `uvm_component_utils(dma_link_test)
  int nchains = 6;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    void'($value$plusargs("NCMD=%d", nchains));
    for (int k = 0; k < nchains; k++) begin
      int ch = $urandom_range(0, TB_NCH - 1);
      int n  = $urandom_range(2, 6);
      dma_cmd cs[$];
      longint unsigned da[$];
      longint unsigned off = 0;
      for (int i = 0; i < n; i++) begin
        dma_cmd c = gen_cmd(ch);
        if (i == 0 && $urandom_range(3) == 0) begin c.xtype = T_DISABLE; c.ytype = T_DISABLE; end
        c.linkattr = {2'b00, rnd_attr()};
        if (c.linkattr[7:4] == 0) c.linkattr[7:0] = 8'h44;
        cs.push_back(c);
        da.push_back(dsc_base(ch) + off + 4 * $urandom_range(0, 3));
        off += 'h100;
      end
      for (int i = 0; i < n; i++) begin
        cs[i].linkaddren = (i < n - 1);
        cs[i].linkaddr   = (i < n - 1) ? da[i + 1] : 0;
      end
      // descriptors (for commands 1..n-1)
      for (int i = 1; i < n; i++) begin
        bit [31:0] w[$];
        cs[i].descriptor(link_header(cs[i - 1], cs[i], $urandom_range(2) == 0), w);
        put_desc(da[i], w);
      end
      foreach (cs[i]) begin init_src(cs[i]); end
      foreach (cs[i]) void'(expect_cmd(cs[i]));
      env.sb.chk_attr[ch] = 1'b0;                       // attributes change along the chain
      `uvm_info("LINK", $sformatf("chain of %0d on ch%0d: first %s", n, ch, cs[0].convert2string()), UVM_LOW)
      regs.program_cmd(cs[0]);
      regs.enable(ch);
      finish_cmd(cs[n - 1]);
    end
  endtask
endclass
