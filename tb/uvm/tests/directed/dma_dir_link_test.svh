//-----------------------------------------------------------------------------
// dma_dir_link_test.svh
//   Command link example of TRM 5.7.1 (HEADER_0 / HEADER_1 / HEADER_2).
//-----------------------------------------------------------------------------
class dma_dir_link_test extends dma_dir_base;
  `uvm_component_utils(dma_dir_link_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    dma_cmd e0, c0, c1, c2;
    bit [31:0] w[$];
    longint unsigned D = dsc_base(0);
    // chain A: empty command -> HEADER_0 (REGCLEAR, complete 32-bit 1D, ends the chain)
    e0 = mk(0, 0, 0, 0, 0);
    e0.xtype = T_DISABLE; e0.linkaddren = 1; e0.linkaddr = D;
    c0 = mk(0, 2, 'h40, 'h40, 16);
    c0.intren = 11'h001;
    // REGCLEAR: registers not in the descriptor take their reset values
    // (XADDRINC = 0 -> both sides keep a fixed address)
    c0.srcxinc = 0; c0.desxinc = 0;
    c0.descriptor(32'h0000_0D5D, w);
    chk(w.size() == 8, "HEADER_0 must give 7 register words");
    put_desc(D, w);
    init_src(c0);
    void'(expect_cmd(c0));
    regs.program_cmd(e0);
    regs.enable(0);
    finish_cmd(c0);
    // chain B: HEADER_1 (8-bit 1D, links to HEADER_2), HEADER_2 (new DESADDR / XSIZE only)
    c1 = mk(0, 0, 'h200, 'h300, 24);
    c1.intren = 11'h001;
    c1.linkaddren = 1; c1.linkaddr = D + 'h38;
    c1.descriptor(32'h4000_0158, w);
    chk(w.size() == 6, "HEADER_1 must give 5 register words");
    put_desc(D + 'h20, w);
    $cast(c2, c1.clone());
    c2.srcaddr = c1.srcaddr + 24;                     // source continues after the first command
    c2.desaddr = dbase(0) + 'h500;
    c2.srcxsize = 10; c2.desxsize = 10;
    c2.linkaddren = 0; c2.linkaddr = 0;
    c2.descriptor(32'h4000_0140, w);
    chk(w.size() == 4, "HEADER_2 must give 3 register words");
    put_desc(D + 'h38, w);
    e0.linkaddr = D + 'h20;
    $cast(c0, e0.clone());
    c0.intren = 11'h001;
    init_src(c1);
    void'(expect_cmd(c1));
    void'(expect_cmd(c2));
    regs.program_cmd(c0);
    regs.enable(0);
    finish_cmd(c2);
  endtask
endclass
