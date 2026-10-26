//-----------------------------------------------------------------------------
// dma_perf_tsize_test.svh
//   Throughput versus TRANSIZE (element size) for a 4KB aligned copy: with the
//   TRM bandwidth optimisation (incrementing, normal memory) the bus beats stay
//   full width; with XADDRINC = 0 (fixed address, FIXED bursts) or device
//   memory every element is one narrow transfer.
//-----------------------------------------------------------------------------
class dma_perf_tsize_test extends dma_perf_base;
  `uvm_component_utils(dma_perf_tsize_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int ch = (TB_NCH > 2) ? 2 : 0;
    suite = "tsize";
    mem_profile(0);
    for (int ts = 0; ts <= $clog2(TB_DWB); ts++) begin
      dma_cmd c = copy(ch, 4096, ts);
      measure($sformatf("normal_ts%0d", ts), '{c}, $sformatf("ts=%0d,mem=normal", ts));
      c = copy(ch, 4096, ts);
      c.src_memattr = 8'h00; c.des_memattr = 8'h00;   // device memory: no access merging
      measure($sformatf("device_ts%0d", ts), '{c}, $sformatf("ts=%0d,mem=device", ts));
      c = copy(ch, 1024, ts);
      c.desxinc = 0;                                   // destination FIFO register
      measure($sformatf("fixdst_ts%0d", ts), '{c}, $sformatf("ts=%0d,mem=fixed_dst", ts));
    end
  endtask
endclass
