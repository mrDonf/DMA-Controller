//-----------------------------------------------------------------------------
// dma_1d_test.svh
//   Constrained random 1D continue commands (coverage closure).
//-----------------------------------------------------------------------------
class dma_1d_test extends dma_rand_test;
  `uvm_component_utils(dma_1d_test)
  function new(string name, uvm_component parent); super.new(name, parent); kind = 0; endfunction
endclass
