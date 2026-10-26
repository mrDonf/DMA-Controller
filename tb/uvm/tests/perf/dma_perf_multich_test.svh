//-----------------------------------------------------------------------------
// dma_perf_multich_test.svh
//   Several channels at the same time:
//     * 1 / 2 / 4 channels, equal priority, all on M0: aggregate rate and
//       fairness of the least recently granted arbitration (completion spread)
//     * dual port: two channels on M0 and M1 in parallel versus both on M0
//   Equal FIFO depths are not available in the default build, so the
//   fairness rows use the same transfer size and report the per channel rate.
//-----------------------------------------------------------------------------
class dma_perf_multich_test extends dma_perf_base;
  `uvm_component_utils(dma_perf_multich_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int ncs[] = '{1, 2, 4};
    int lats[] = '{0, 16};
    suite = "multich";
    foreach (lats[l]) begin
      mem_profile(lats[l]);
      foreach (ncs[k]) begin
        dma_cmd cs[$];
        if (ncs[k] > TB_NCH) continue;
        for (int ch = 0; ch < ncs[k]; ch++) cs.push_back(copy(ch, 8192));
        measure($sformatf("l%0d_n%0d", lats[l], ncs[k]), cs, $sformatf("lat=%0d,nch=%0d", lats[l], ncs[k]));
      end
    end
    // dual port
    if (TB_M1 && TB_NCH > 1) begin
      dma_cmd cs[$];
      foreach (lats[l]) begin
        mem_profile(lats[l]);
        cs.delete();
        cs.push_back(copy(0, 8192)); cs.push_back(copy(2 % TB_NCH, 8192));
        measure($sformatf("l%0d_m0m0", lats[l]), cs, $sformatf("lat=%0d,ports=M0+M0", lats[l]));
        cs.delete();
        cs.push_back(copy(0, 8192)); cs.push_back(copy(2 % TB_NCH, 8192, -1, 0, 0, 1, 1));
        measure($sformatf("l%0d_m0m1", lats[l]), cs, $sformatf("lat=%0d,ports=M0+M1", lats[l]));
        cs.delete();
        cs.push_back(copy(0, 8192, -1, 0, 0, 0, 1)); cs.push_back(copy(2 % TB_NCH, 8192, -1, 0, 0, 1, 0));
        measure($sformatf("l%0d_cross", lats[l]), cs, $sformatf("lat=%0d,ports=M0>M1+M1>M0", lats[l]));
      end
    end
    mem_profile(0);
  endtask
endclass
