//-----------------------------------------------------------------------------
// dma_wrapfill_test.svh
//   Constrained random 1D wrap / fill commands (coverage closure).
//-----------------------------------------------------------------------------
class dma_wrapfill_test extends dma_rand_test;
  `uvm_component_utils(dma_wrapfill_test)
  function new(string name, uvm_component parent); super.new(name, parent); kind = 1; endfunction
endclass
