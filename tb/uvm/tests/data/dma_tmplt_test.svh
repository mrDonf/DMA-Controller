//-----------------------------------------------------------------------------
// dma_tmplt_test.svh
//   Constrained random template commands (coverage closure).
//-----------------------------------------------------------------------------
class dma_tmplt_test extends dma_rand_test;
  `uvm_component_utils(dma_tmplt_test)
  function new(string name, uvm_component parent); super.new(name, parent); kind = 3; endfunction
endclass
