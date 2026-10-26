//-----------------------------------------------------------------------------
// dma_autoboot_test.svh
//   Autoboot: boot_en / boot_addr fetch a command chain into channel 0 after reset.
//-----------------------------------------------------------------------------
class dma_autoboot_test extends dma_feat_base;
  `uvm_component_utils(dma_autoboot_test)
  dma_cmd c0, c1;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task pre_body();
    bit [31:0] w[$];
    longint unsigned b = dsc_base(0) + 'h80;
    c0 = simple(0, 256, 2);
    c1 = simple(0, 100, 0);
    c1.desaddr = c0.desaddr + 'h1000;
    c1.srcaddr = c0.srcaddr + 'h1000;
    c0.linkaddren = 1;
    c0.linkaddr   = b + 'h100;
    c0.descriptor(dma_cmd::full_header(TB_AW > 32), w);
    put_desc(b, w);
    c1.descriptor(link_header(c0, c1, 0), w);
    put_desc(b + 'h100, w);
    init_src(c0);
    init_src(c1);
    void'(expect_cmd(c0));
    void'(expect_cmd(c1));
    vif.boot_en        <= 1'b1;
    vif.boot_addr      <= b[TB_AW-1:2];
    vif.boot_memattr   <= 8'h44;
    vif.boot_shareattr <= 2'b00;
  endtask
  task body();
    bit [31:0] st;
    regs.wait_idle(0, st);
    if (!st[ST_DONE] || st[ST_ERR]) `uvm_error("TEST", $sformatf("autoboot status %08h", st))
    void'(env.sb.check_done(0, tname));
    n_cmds += 2;
  endtask
endclass
