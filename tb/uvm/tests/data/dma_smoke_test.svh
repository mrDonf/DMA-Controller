//-----------------------------------------------------------------------------
// dma_smoke_test.svh
//   Smoke test: CIDR read + a few 1D copies on every channel.
//-----------------------------------------------------------------------------
class dma_smoke_test extends dma_base_test;
  `uvm_component_utils(dma_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [31:0] d;
    regs.rd(R_INFO + 'hFC, d);
    if (d != 32'hB1) `uvm_error("TEST", $sformatf("CIDR3 = %0h", d))
    for (int i = 0; i < 6; i++) begin
      dma_cmd c = gen_cmd(i % TB_NCH, 0);
      init_src(c);
      run_cmd(c);
    end
  endtask
endclass
