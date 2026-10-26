//-----------------------------------------------------------------------------
// dma_perf_align_test.svh
//   Throughput versus source / destination alignment (4KB byte element copy,
//   bandwidth optimisation active): the FIFO realigns the data so unaligned
//   copies keep full width bursts except for the first / last beats.
//-----------------------------------------------------------------------------
class dma_perf_align_test extends dma_perf_base;
  `uvm_component_utils(dma_perf_align_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int ch = (TB_NCH > 2) ? 2 : 0;
    int offs[][2] = '{'{0, 0}, '{1, 0}, '{0, 1}, '{1, 1}, '{3, 5}, '{TB_DWB - 1, 1}, '{TB_DWB / 2, 0}, '{0, TB_DWB / 2}};
    suite = "align";
    mem_profile(0);
    foreach (offs[i]) begin
      measure($sformatf("s%0d_d%0d", offs[i][0], offs[i][1]), '{copy(ch, 4096, 0, offs[i][0], offs[i][1])},
              $sformatf("soff=%0d,doff=%0d", offs[i][0], offs[i][1]));
    end
    mem_profile(16);
    foreach (offs[i]) begin
      measure($sformatf("l16_s%0d_d%0d", offs[i][0], offs[i][1]), '{copy(ch, 4096, 0, offs[i][0], offs[i][1])},
              $sformatf("soff=%0d,doff=%0d,lat=16", offs[i][0], offs[i][1]));
    end
    mem_profile(0);
  endtask
endclass
