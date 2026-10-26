//-----------------------------------------------------------------------------
// dma_perf_burst_test.svh
//   Throughput versus SRC/DESMAXBURSTLEN (4KB aligned copy) with an ideal
//   memory, a 16 cycle read latency and a 30% READY backpressure.
//   The burst length is also limited by FIFO/2 and the 1KB boundary.
//-----------------------------------------------------------------------------
class dma_perf_burst_test extends dma_perf_base;
  `uvm_component_utils(dma_perf_burst_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int mbl[] = '{0, 1, 3, 7, 15};
    int ch = (TB_NCH > 2) ? 2 : 0;
    suite = "burst";
    for (int prof = 0; prof < 3; prof++) begin
      string pn = (prof == 0) ? "ideal" : (prof == 1) ? "lat16" : "rdy70";
      if (prof == 0) mem_profile(0); else if (prof == 1) mem_profile(16); else mem_profile(0, 0, 70);
      foreach (mbl[i]) begin
        dma_cmd c = copy(ch, 4096);
        c.src_maxburst = mbl[i]; c.des_maxburst = mbl[i];
        measure($sformatf("%s_mb%0d", pn, mbl[i]), '{c}, $sformatf("mem=%s,maxburst=%0d", pn, mbl[i] + 1));
      end
    end
    mem_profile(0);
  endtask
endclass
