//-----------------------------------------------------------------------------
// dma_perf_size_test.svh
//   Throughput versus transfer size: aligned 1D copies with bus width elements
//   and MAXBURSTLEN = 15, ideal memory and a 16 cycle read latency memory.
//   Shows the fixed command cost (start / completion latency) and the
//   asymptotic copy rate.
//-----------------------------------------------------------------------------
class dma_perf_size_test extends dma_perf_base;
  `uvm_component_utils(dma_perf_size_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int sizes[] = '{16, 64, 256, 1024, 4096, 16384, 65536};
    int lats[]  = '{0, 16};
    int ch = (TB_NCH > 2) ? 2 : 0;                    // deepest FIFO of the default build
    suite = "size";
    foreach (lats[l]) begin
      mem_profile(lats[l]);
      foreach (sizes[i])
        measure($sformatf("l%0d_n%0d", lats[l], sizes[i]), '{copy(ch, sizes[i])},
                $sformatf("lat=%0d,size=%0d", lats[l], sizes[i]));
    end
    mem_profile(0);
  endtask
endclass
