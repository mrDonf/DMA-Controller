//-----------------------------------------------------------------------------
// dma_rand_test.svh
//   Constrained random commands of every kind (coverage closure). +NCMD=<n>.
//-----------------------------------------------------------------------------
class dma_rand_test extends dma_base_test;
  `uvm_component_utils(dma_rand_test)
  int ncmd = 60;
  int kind = -1;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    void'($value$plusargs("NCMD=%d", ncmd));
    for (int i = 0; i < ncmd; i++) begin
      dma_cmd c = gen_cmd($urandom_range(0, TB_NCH - 1), kind);
      init_src(c);
      run_cmd(c);
    end
  endtask
endclass
