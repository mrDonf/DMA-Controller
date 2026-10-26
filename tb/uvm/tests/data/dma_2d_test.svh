//-----------------------------------------------------------------------------
// dma_2d_test.svh
//   Constrained random 2D commands, all X / Y types (coverage closure).
//-----------------------------------------------------------------------------
class dma_2d_test extends dma_rand_test;
  `uvm_component_utils(dma_2d_test)
  function new(string name, uvm_component parent); super.new(name, parent); kind = 2; endfunction
endclass
