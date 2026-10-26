//-----------------------------------------------------------------------------
// dma_restart_test.svh
//   Automatic restart: CMDRESTARTCNT with every REGRELOADTYPE, infinite restart broken
//   by DISABLECMD, DONETYPE end-of-cycle with DONEPAUSEEN.
//-----------------------------------------------------------------------------
class dma_restart_test extends dma_feat_base;
  `uvm_component_utils(dma_restart_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [2:0] rl_types[] = '{3'b111, 3'b001, 3'b011, 3'b101, 3'b000};
    foreach (rl_types[r]) begin
      int ch = r % TB_NCH;
      int cnt = $urandom_range(1, 4);
      dma_cmd c = simple(ch, $urandom_range(16, 300));
      dma_cmd its[$];
      c.restartcnt = cnt;
      c.regreload  = rl_types[r];
      for (int it = 0; it <= cnt; it++) begin
        dma_cmd ci;
        $cast(ci, c.clone());
        ci.restartcnt = 0;
        // addresses continue when not reloaded (1D: incremented address)
        if (!(rl_types[r][0] && rl_types[r][1])) ci.srcaddr = (c.srcaddr & ~longint'(c.esize() - 1)) + it * c.srcxsize * c.esize();
        if (!(rl_types[r][0] && rl_types[r][2])) ci.desaddr = (c.desaddr & ~longint'(c.esize() - 1)) + it * c.desxsize * c.esize();
        if (it > 0 && !rl_types[r][0]) break;          // sizes not reloaded: empty iterations
        its.push_back(ci);
      end
      foreach (its[i]) init_src(its[i]);               // all sources first, then predict
      foreach (its[i]) void'(expect_cmd(its[i]));
      `uvm_info("RESTART", $sformatf("cnt=%0d reload=%03b %s", cnt, rl_types[r], c.convert2string()), UVM_LOW)
      env.cov.sample_cmd(c);                          // programmed command (restart / reload)
      set_attr_exp(c);
      regs.program_cmd(c);
      regs.enable(ch);
      finish_cmd(c);
    end
    // infinite restart broken by DISABLECMD
    begin
      dma_cmd c = simple(1 % TB_NCH, 64, 2);
      bit [31:0] st;
      c.restartinf = 1;
      c.regreload  = 3'b111;
      init_src(c);
      void'(expect_cmd(c));
      env.sb.relax(c.ch);                            // number of iterations unknown
      regs.program_cmd(c);
      regs.enable(c.ch);
      repeat (2000) @(posedge vif.clk);
      regs.chw(c.ch, CH_CMD, 32'h4);                 // DISABLECMD
      regs.wait_idle(c.ch, st);
      if (!st[ST_DISABLED]) `uvm_error("TEST", $sformatf("infinite restart: status %08h", st))
      regs.clear_status(c.ch);
      env.sb.unrelax(c.ch);
      n_cmds++;
    end
    // DONETYPE end of each restart cycle + DONEPAUSEEN
    begin
      dma_cmd c = simple(0, 128, 3);
      c.restartcnt = 2;
      c.regreload  = 3'b111;
      c.donetype   = 3'b011;
      c.donepause  = 1;
      init_src(c);
      repeat (3) void'(expect_cmd(c));
      regs.program_cmd(c);
      regs.enable(c.ch);
      for (int i = 0; i < 2; i++) begin
        wait_status_bit(c.ch, ST_RESUMEWAIT);
        wait_status_bit(c.ch, ST_DONE);
        regs.chw(c.ch, CH_STATUS, 1 << ST_DONE);
        regs.chw(c.ch, CH_CMD, 32'h20);              // RESUMECMD
      end
      finish_cmd(c);
    end
  endtask
endclass
